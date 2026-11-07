// The desktop player receives clear bytes over a per-player loopback capability.
// Keys and original URLs stay inside the process; no decrypted movie is written.
/**
 * @brief iOS 与 Windows 共用内存 CENC 解密及回环服务，不记录密钥或源 URL。
 * @note 每个 reader 的访问与释放由会话互斥锁串行化；关闭通过原子变量取消。
 *       FFI open 会阻塞网络读取，不应在 UI 线程或中断上下文调用。
 */
use crate::desktop_fetch::{
    fetch_known_range, fetch_range, shared_client, with_retries, FetchError, OpenError,
    CHUNK_TIMEOUT, PROBE_TIMEOUT,
};
use reqwest::blocking::Client;
use serde::Deserialize;
use std::{
    collections::HashMap,
    ffi::{c_char, c_void, CStr, CString},
    fs::File,
    io::{Read, Seek, SeekFrom, Write},
    net::{Shutdown, TcpListener, TcpStream},
    ptr,
    sync::{
        atomic::{AtomicBool, AtomicUsize, Ordering},
        Arc, Mutex, OnceLock,
    },
    thread,
    time::{Duration, Instant},
};

#[repr(C)]
struct SpError {
    code: i32,
    message: [c_char; 192],
}
#[repr(C)]
struct SpIo {
    user: *mut c_void,
    size: extern "C" fn(*mut c_void) -> i64,
    read_at: extern "C" fn(*mut c_void, u64, *mut u8, usize) -> isize,
    cancel: extern "C" fn(*mut c_void),
    close: extern "C" fn(*mut c_void),
}
unsafe extern "C" {
    fn sp_stream_open(io: *const SpIo, key: *const u8, error: *mut SpError) -> *mut c_void;
    fn sp_stream_read(
        stream: *mut c_void,
        buffer: *mut u8,
        length: usize,
        error: *mut SpError,
    ) -> isize;
    fn sp_stream_seek(stream: *mut c_void, position: i64, error: *mut SpError) -> i64;
    fn sp_stream_size(stream: *const c_void) -> i64;
    fn sp_stream_close(stream: *mut c_void);
}

struct Source {
    file: Option<File>,
    client: Option<&'static Client>,
    url: String,
    size: u64,
    cache_start: u64,
    cache: Vec<u8>,
    /// Set when the session closes, so a stalled read stops retrying.
    cancelled: Arc<AtomicBool>,
    /// The last network failure, kept for classifying a failed decrypt open.
    last_error: Arc<Mutex<Option<FetchError>>>,
}
impl Source {
    fn open(url: String) -> Result<Self, OpenError> {
        let file = if url.starts_with("file:") {
            let path = url::Url::parse(&url)
                .map_err(|_| OpenError::new("离线文件地址无效", "file"))?
                .to_file_path()
                .map_err(|_| OpenError::new("离线文件地址无效", "file"))?;
            Some(File::open(path).map_err(|_| OpenError::new("离线文件不存在或无法读取", "file"))?)
        } else if !url.starts_with("https://") && !url.starts_with("http://") {
            Some(File::open(&url).map_err(|_| OpenError::new("离线文件不存在或无法读取", "file"))?)
        } else {
            None
        };
        let cancelled = Arc::new(AtomicBool::new(false));
        let (client, size) = if let Some(file) = &file {
            let size = file
                .metadata()
                .map_err(|_| OpenError::new("无法读取文件长度", "file"))?
                .len();
            (None, size)
        } else {
            let client = shared_client().ok_or(OpenError::new("无法初始化媒体连接", "other"))?;
            let (_, total) = with_retries(&cancelled, || {
                fetch_range(client, &url, 0, 0, PROBE_TIMEOUT)
            })
            .map_err(OpenError::fetch)?;
            (Some(client), total)
        };
        if size == 0 || size > i64::MAX as u64 {
            return Err(OpenError::new("媒体文件长度无效", "range"));
        }
        Ok(Self {
            file,
            client,
            url,
            size,
            cache_start: 0,
            cache: Vec::new(),
            cancelled,
            last_error: Arc::default(),
        })
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        if self.cancelled.load(Ordering::Acquire) {
            return Err(());
        }
        if offset >= self.size {
            return Ok(0);
        }
        if let Some(file) = &mut self.file {
            file.seek(SeekFrom::Start(offset)).map_err(|_| ())?;
            return file.read(bytes).map_err(|_| ());
        }
        let cache_end = self
            .cache_start
            .checked_add(self.cache.len() as u64)
            .ok_or(())?;
        if offset < self.cache_start || offset >= cache_end {
            let end = offset
                .checked_add(1024 * 1024 - 1)
                .ok_or(())?
                .min(self.size - 1);
            let client = self.client.ok_or(())?;
            let result = with_retries(&self.cancelled, || {
                fetch_known_range(client, &self.url, offset, end, CHUNK_TIMEOUT, self.size)
            });
            let data = match result {
                Ok(data) => data,
                Err(error) => {
                    if let Ok(mut last) = self.last_error.lock() {
                        *last = Some(error);
                    }
                    return Err(());
                }
            };
            self.cache_start = offset;
            self.cache = data;
        }
        let start =
            usize::try_from(offset.checked_sub(self.cache_start).ok_or(())?).map_err(|_| ())?;
        let count = bytes
            .len()
            .min(self.cache.len().checked_sub(start).ok_or(())?);
        bytes[..count].copy_from_slice(&self.cache[start..start + count]);
        Ok(count)
    }
}
extern "C" fn io_size(user: *mut c_void) -> i64 {
    unsafe { (*(user as *mut Source)).size as i64 }
}
extern "C" fn io_read(user: *mut c_void, offset: u64, buffer: *mut u8, length: usize) -> isize {
    std::panic::catch_unwind(|| unsafe {
        let source = &mut *(user as *mut Source);
        source
            .read_at(offset, std::slice::from_raw_parts_mut(buffer, length))
            .map(|n| n as isize)
            .unwrap_or(-1)
    })
    .unwrap_or(-1)
}
// sp_stream calls this on every seek to abandon the old position, so it must
// not end the source; closing the session sets `Source::cancelled` instead.
extern "C" fn io_cancel(_: *mut c_void) {}
extern "C" fn io_close(user: *mut c_void) {
    unsafe {
        drop(Box::from_raw(user as *mut Source));
    }
}

enum Reader {
    Clear(Box<Source>),
    Encrypted(*mut c_void),
}
// Every operation, including Drop, is protected by the session mutex.
unsafe impl Send for Reader {}
impl Drop for Reader {
    fn drop(&mut self) {
        if let Self::Encrypted(stream) = self {
            unsafe {
                sp_stream_close(*stream);
            }
        }
    }
}
impl Reader {
    fn size(&self) -> u64 {
        match self {
            Self::Clear(source) => source.size,
            Self::Encrypted(stream) => unsafe { sp_stream_size(*stream) as u64 },
        }
    }
    fn read_at(&mut self, offset: u64, bytes: &mut [u8]) -> Result<usize, ()> {
        match self {
            Self::Clear(source) => source.read_at(offset, bytes),
            Self::Encrypted(stream) => unsafe {
                let mut error = SpError {
                    code: 0,
                    message: [0; 192],
                };
                if sp_stream_seek(*stream, offset as i64, &mut error) < 0 {
                    return Err(());
                }
                let n = sp_stream_read(*stream, bytes.as_mut_ptr(), bytes.len(), &mut error);
                if n < 0 {
                    Err(())
                } else {
                    Ok(n as usize)
                }
            },
        }
    }
}
struct Session {
    reader: Mutex<Reader>,
    stop: AtomicBool,
    /// Shared with the network source: closing ends its pending retries.
    cancelled: Option<Arc<AtomicBool>>,
    size: u64,
    authority: String,
    path: String,
    content_type: &'static str,
    sockets: Mutex<SocketRegistry>,
}

#[derive(Default)]
struct SocketRegistry {
    stopped: bool,
    next_id: u64,
    sockets: HashMap<u64, TcpStream>,
}

static ACTIVE_SOCKETS: AtomicUsize = AtomicUsize::new(0);

struct SocketAdmission {
    session: Arc<Session>,
    id: u64,
}

impl SocketAdmission {
    fn register(session: Arc<Session>, socket: &TcpStream) -> Option<Self> {
        let clone = socket.try_clone().ok()?;
        let mut registry = session
            .sockets
            .lock()
            .unwrap_or_else(|error| error.into_inner());
        if registry.stopped || registry.sockets.len() >= 8 {
            return None;
        }
        let id = registry.next_id.checked_add(1)?;
        ACTIVE_SOCKETS
            .try_update(Ordering::AcqRel, Ordering::Acquire, |count| {
                (count < 32).then_some(count + 1)
            })
            .ok()?;
        registry.next_id = id;
        registry.sockets.insert(id, clone);
        drop(registry);
        Some(Self { session, id })
    }
}

impl Drop for SocketAdmission {
    fn drop(&mut self) {
        self.session
            .sockets
            .lock()
            .unwrap_or_else(|error| error.into_inner())
            .sockets
            .remove(&self.id);
        ACTIVE_SOCKETS.fetch_sub(1, Ordering::AcqRel);
    }
}

impl Session {
    fn close(&self) {
        let sockets = {
            let mut registry = self
                .sockets
                .lock()
                .unwrap_or_else(|error| error.into_inner());
            registry.stopped = true;
            self.stop.store(true, Ordering::Release);
            if let Some(cancelled) = &self.cancelled {
                cancelled.store(true, Ordering::Release);
            }
            std::mem::take(&mut registry.sockets)
        };
        for socket in sockets.into_values() {
            let _ = socket.shutdown(Shutdown::Both);
        }
    }
}
static SESSIONS: OnceLock<Mutex<HashMap<String, Arc<Session>>>> = OnceLock::new();
fn sessions() -> &'static Mutex<HashMap<String, Arc<Session>>> {
    SESSIONS.get_or_init(Default::default)
}

fn parse_range(header: Option<&str>, size: u64) -> Result<(u64, u64, bool), ()> {
    let Some(value) = header else {
        return Ok((0, size - 1, false));
    };
    let (start, end) = value
        .strip_prefix("bytes=")
        .ok_or(())?
        .split_once('-')
        .ok_or(())?;
    if end.contains(',') {
        return Err(());
    }
    let (start, end) = if start.is_empty() {
        let suffix: u64 = end.parse().map_err(|_| ())?;
        if suffix == 0 {
            return Err(());
        }
        (size.saturating_sub(suffix), size - 1)
    } else {
        (
            start.parse::<u64>().map_err(|_| ())?,
            if end.is_empty() {
                size - 1
            } else {
                end.parse::<u64>().map_err(|_| ())?.min(size - 1)
            },
        )
    };
    if start > end || start >= size {
        return Err(());
    }
    Ok((start, end, true))
}
fn serve(mut socket: TcpStream, session: Arc<Session>) -> std::io::Result<()> {
    // Winsock can inherit FIONBIO from the nonblocking listener. Accepted
    // connections are handled by dedicated workers and must perform blocking
    // reads; otherwise a partially arrived HTTP header is mistaken for EOF.
    socket.set_nonblocking(false)?;
    socket.set_write_timeout(Some(Duration::from_secs(3)))?;
    let deadline = Instant::now() + Duration::from_secs(3);
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        let remaining = deadline.saturating_duration_since(Instant::now());
        if remaining.is_zero() || session.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        socket.set_read_timeout(Some(remaining))?;
        let mut byte = [0];
        if request.len() >= 16384 || socket.read(&mut byte)? == 0 {
            return Ok(());
        }
        request.push(byte[0]);
    }
    let request = String::from_utf8_lossy(&request);
    let mut lines = request.split("\r\n");
    let first: Vec<_> = lines.next().unwrap_or("").split_whitespace().collect();
    let mut host = None;
    let mut range = None;
    let mut origin = false;
    for line in lines {
        if let Some((name, value)) = line.split_once(':') {
            match name.to_ascii_lowercase().as_str() {
                "host" => host = Some(value.trim()),
                "range" => range = Some(value.trim()),
                "origin" => origin = true,
                _ => (),
            }
        }
    }
    if first.len() != 3
        || !matches!(first[0], "GET" | "HEAD")
        || first[1] != session.path
        || host != Some(session.authority.as_str())
        || origin
        || session.stop.load(Ordering::Acquire)
    {
        return socket.write_all(
            b"HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        );
    }
    let (mut position, end, partial) = match parse_range(range, session.size) {
        Ok(range) => range,
        Err(_) => return write!(socket, "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */{}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", session.size),
    };
    let status = if partial {
        "206 Partial Content"
    } else {
        "200 OK"
    };
    write!(socket, "HTTP/1.1 {status}\r\nContent-Type: {}\r\nAccept-Ranges: bytes\r\nContent-Length: {}\r\nCache-Control: no-store\r\nConnection: close\r\n", session.content_type, end - position + 1)?;
    if partial {
        write!(
            socket,
            "Content-Range: bytes {position}-{end}/{}\r\n",
            session.size
        )?;
    }
    socket.write_all(b"\r\n")?;
    if first[0] == "HEAD" {
        return Ok(());
    }
    let mut bytes = vec![0; 64 * 1024];
    while position <= end && !session.stop.load(Ordering::Acquire) {
        let count = (bytes.len() as u64).min(end - position + 1) as usize;
        let n = session
            .reader
            .lock()
            .map_err(|_| std::io::Error::other("media lock"))?
            .read_at(position, &mut bytes[..count])
            .map_err(|_| std::io::Error::other("media read"))?;
        if n == 0 {
            return Err(std::io::Error::other("unexpected media EOF"));
        }
        if session.stop.load(Ordering::Acquire) {
            return Ok(());
        }
        socket.write_all(&bytes[..n])?;
        position = position
            .checked_add(n as u64)
            .ok_or_else(|| std::io::Error::other("media offset"))?;
    }
    Ok(())
}
#[derive(Deserialize)]
struct OpenRequest {
    url: String,
    #[serde(default)]
    key: String,
}

/// @brief CENC 仅支持 MP4；明文使用 URL 路径判断类型，未知格式交给播放器探测。
#[cfg(any(target_os = "ios", test))]
fn ios_content_type(source: &str, encrypted: bool) -> &'static str {
    if encrypted {
        return "audio/mp4";
    }
    let parsed = url::Url::parse(source).ok();
    let path = parsed.as_ref().map_or(source, |url| url.path());
    match path
        .rsplit('.')
        .next()
        .unwrap_or("")
        .to_ascii_lowercase()
        .as_str()
    {
        "m4a" | "mp4" => "audio/mp4",
        "mp3" => "audio/mpeg",
        "aac" => "audio/aac",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        _ => "application/octet-stream",
    }
}

fn open(request: OpenRequest) -> Result<serde_json::Value, OpenError> {
    #[cfg(target_os = "ios")]
    let content_type = ios_content_type(&request.url, !request.key.is_empty());
    #[cfg(not(target_os = "ios"))]
    let content_type = "application/octet-stream";
    let source = Box::new(Source::open(request.url)?);
    let cancelled = source.client.map(|_| source.cancelled.clone());
    let last_error = source.last_error.clone();
    let reader = if request.key.is_empty() {
        Reader::Clear(source)
    } else {
        let key =
            hex::decode(&request.key).map_err(|_| OpenError::new("媒体密钥无效", "decrypt"))?;
        if key.len() != 16 {
            return Err(OpenError::new("媒体密钥无效", "decrypt"));
        }
        let user = Box::into_raw(source) as *mut c_void;
        let io = SpIo {
            user,
            size: io_size,
            read_at: io_read,
            cancel: io_cancel,
            close: io_close,
        };
        let mut error = SpError {
            code: 0,
            message: [0; 192],
        };
        let stream = unsafe { sp_stream_open(&io, key.as_ptr(), &mut error) };
        if stream.is_null() {
            io_close(user);
            // The header is read through the network source: a failed read
            // there is a network problem, not a broken file.
            let fetch = last_error.lock().ok().and_then(|last| *last);
            return Err(match fetch {
                Some(error) => OpenError::fetch(error),
                None => OpenError::new("无法打开加密媒体，请重试或切换清晰度", "decrypt"),
            });
        }
        Reader::Encrypted(stream)
    };
    let local = |message| move |_| OpenError::new(message, "other");
    let listener = TcpListener::bind(("127.0.0.1", 0)).map_err(local("无法打开本机媒体端口"))?;
    listener
        .set_nonblocking(true)
        .map_err(local("无法初始化媒体端口"))?;
    let authority = listener
        .local_addr()
        .map_err(local("媒体端口不可用"))?
        .to_string();
    let token = hex::encode(rand::random::<[u8; 32]>());
    let path = format!("/media/{token}");
    let url = format!("http://{authority}{path}");
    let session = Arc::new(Session {
        size: reader.size(),
        reader: Mutex::new(reader),
        stop: AtomicBool::new(false),
        cancelled,
        authority,
        path,
        content_type,
        sockets: Mutex::default(),
    });
    sessions()
        .lock()
        .map_err(|_| OpenError::new("媒体会话不可用", "other"))?
        .insert(token.clone(), session.clone());
    let listener_session = session.clone();
    if thread::Builder::new()
        .name("media-listener".into())
        .spawn(move || {
            let session = listener_session;
            while !session.stop.load(Ordering::Acquire) {
                match listener.accept() {
                    Ok((socket, address)) if address.ip().is_loopback() => {
                        if let Some(admission) = SocketAdmission::register(session.clone(), &socket)
                        {
                            let _ = thread::Builder::new().name("media-socket".into()).spawn(
                                move || {
                                    let _ = serve(socket, admission.session.clone());
                                    drop(admission);
                                },
                            );
                        }
                    }
                    Ok(_) => (),
                    Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                        thread::sleep(Duration::from_millis(20))
                    }
                    Err(_) => break,
                }
            }
        })
        .is_err()
    {
        session.close();
        if let Ok(mut sessions) = sessions().lock() {
            sessions.remove(&token);
        }
        return Err(OpenError::new("无法启动媒体端口", "other"));
    }
    Ok(serde_json::json!({"id": token, "url": url}))
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_open(request: *const c_char) -> *mut c_char {
    let result = std::panic::catch_unwind(|| {
        if request.is_null() {
            return Err(OpenError::new("媒体请求无效", "other"));
        }
        let request: OpenRequest = serde_json::from_slice(CStr::from_ptr(request).to_bytes())
            .map_err(|_| OpenError::new("媒体请求无效", "other"))?;
        open(request)
    })
    .unwrap_or_else(|_| Err(OpenError::new("媒体初始化失败", "other")));
    let value = match result {
        Ok(value) => value,
        Err(error) => serde_json::json!({
            "error": error.message,
            "kind": error.kind,
            "status": error.status,
        }),
    };
    CString::new(value.to_string())
        .map(CString::into_raw)
        .unwrap_or(ptr::null_mut())
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_close(id: *const c_char) {
    if id.is_null() {
        return;
    }
    if let Ok(id) = CStr::from_ptr(id).to_str() {
        let session = sessions()
            .lock()
            .ok()
            .and_then(|mut sessions| sessions.remove(id));
        if let Some(session) = session {
            session.close();
        }
    }
}
#[no_mangle]
pub unsafe extern "C" fn fq_desktop_media_free(value: *mut c_char) {
    if !value.is_null() {
        drop(CString::from_raw(value));
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn ios_mime_keeps_clear_audio_formats_and_identifies_cenc_mp4() {
        for (source, encrypted, expected) in [
            ("https://cdn.invalid/opaque?token=x", true, "audio/mp4"),
            ("https://cdn.invalid/episode.MP3?token=x", false, "audio/mpeg"),
            ("file:///var/mobile/episode.m4a", false, "audio/mp4"),
            ("/var/mobile/episode.aac", false, "audio/aac"),
            (
                "https://cdn.invalid/opaque?name=episode.mp3",
                false,
                "application/octet-stream",
            ),
        ] {
            assert_eq!(ios_content_type(source, encrypted), expected);
        }
    }

    #[test]
    fn avplayer_probe_and_seek_use_the_same_capability() {
        let path = std::env::temp_dir().join(format!(
            "fq-media-test-{}",
            hex::encode(rand::random::<[u8; 16]>())
        ));
        std::fs::write(&path, b"0123456789").unwrap();
        let source = Source::open(path.to_str().unwrap().to_owned()).unwrap();
        let listener = TcpListener::bind(("127.0.0.1", 0)).unwrap();
        let authority = listener.local_addr().unwrap().to_string();
        let session = Arc::new(Session {
            reader: Mutex::new(Reader::Clear(Box::new(source))),
            stop: AtomicBool::new(false),
            cancelled: None,
            size: 10,
            authority: authority.clone(),
            path: "/media/test".into(),
            content_type: "audio/mp4",
            sockets: Mutex::default(),
        });
        let worker = thread::spawn(move || {
            for _ in 0..3 {
                let (socket, _) = listener.accept().unwrap();
                serve(socket, session.clone()).unwrap();
            }
        });
        for (method, range, expected_status, expected_body) in [
            ("HEAD", "bytes=0-1", "206 Partial Content", ""),
            ("GET", "bytes=4-", "206 Partial Content", "456789"),
            ("GET", "bytes=10-", "416 Range Not Satisfiable", ""),
        ] {
            let mut socket = TcpStream::connect(&authority).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            write!(socket, "{method} /media/test HTTP/1.1\r\nHost: {authority}\r\nRange: {range}\r\n\r\n").unwrap();
            let mut response = String::new();
            socket.read_to_string(&mut response).unwrap();
            let (headers, body) = response.split_once("\r\n\r\n").unwrap();
            assert!(headers.starts_with(&format!("HTTP/1.1 {expected_status}")));
            assert_eq!(body, expected_body);
            if expected_status.starts_with("206") {
                assert!(headers.contains("Content-Type: audio/mp4"));
                assert!(headers.contains("Accept-Ranges: bytes"));
                assert!(headers.contains(if method == "HEAD" {
                    "Content-Range: bytes 0-1/10"
                } else {
                    "Content-Range: bytes 4-9/10"
                }));
            }
        }
        worker.join().unwrap();
        std::fs::remove_file(path).unwrap();
    }

    #[test]
    fn range_contract() {
        assert_eq!(parse_range(None, 100), Ok((0, 99, false)));
        assert_eq!(parse_range(Some("bytes=10-19"), 100), Ok((10, 19, true)));
        assert_eq!(parse_range(Some("bytes=90-"), 100), Ok((90, 99, true)));
        assert_eq!(parse_range(Some("bytes=-8"), 100), Ok((92, 99, true)));
        for bad in ["bytes=100-", "bytes=9-2", "bytes=0-1,4-5", "bytes=-0"] {
            assert!(parse_range(Some(bad), 100).is_err());
        }
    }
}
