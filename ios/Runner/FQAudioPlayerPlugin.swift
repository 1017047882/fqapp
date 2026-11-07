import AVFoundation
import Flutter
import MediaPlayer
import UIKit

/** @brief 播放意图与系统中断独立保存，避免用户暂停后被中断结束重新唤醒。纯值类型。 */
struct FQPlaybackIntent {
  private(set) var wantsPlay = false
  private(set) var isInterrupted = false
  private var wasInterrupted = false
  var canPlay: Bool { wantsPlay && !isInterrupted }
  mutating func play() { wantsPlay = true; wasInterrupted = isInterrupted }
  mutating func pause() { wantsPlay = false; wasInterrupted = false }
  mutating func beginInterruption() -> Bool {
    if isInterrupted { return wantsPlay }
    isInterrupted = true
    wasInterrupted = wantsPlay
    return wasInterrupted
  }
  mutating func endInterruption(shouldResume: Bool) -> Bool {
    let resume = wasInterrupted && wantsPlay && shouldResume
    isInterrupted = false
    wasInterrupted = false
    return resume
  }
}

/**
 * @brief 将 Android 听书通道映射到 AVPlayer，音源和 CENC 解密逻辑保持共用。
 * @note 播放状态、KVO 和 Flutter 回调在主线程串行；Rust open/close 在工作队列。
 *       通过对象身份拒绝销毁/切章后的迟到结果；绝不记录音源 URL、内容密钥或能力地址。
 */
final class FQAudioPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private final class Entry {
    let id: Int
    var intent = FQPlaybackIntent()
    var player: AVPlayer?
    var mediaID: String?
    var rate: Float = 1
    var ready = false
    var startMs: Int64 = 0
    var seekGeneration = 0
    var lastDuration: Int64 = -1
    var observations: [NSKeyValueObservation] = []
    var endObserver: NSObjectProtocol?
    var tick: Any?
    var pending: [[String: Any]] = []
    init(id: Int) { self.id = id }
    var owner: String { "player-\(id)" }
  }

  private let channel: FlutterMethodChannel
  private let work = DispatchQueue(label: "fqapp.ios.media", qos: .userInitiated, attributes: .concurrent)
  private var entries: [Int: Entry] = [:]
  private var nextID = 0
  private var sink: FlutterEventSink?
  private var observers: [NSObjectProtocol] = []
  private var commands: [(MPRemoteCommand, Any)] = []
  private var metadataVisible = false
  private var remotePlaying = false
  private var activeID: Int?
  private var interruptionActive = false
  private var keepScreenOn = false
  private var previousIdleTimer = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = FQAudioPlayerPlugin(messenger: registrar.messenger())
    registrar.publish(plugin)
  }

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "fqapp/native_player", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(FlutterError(code: "detached", message: "播放器已关闭", details: nil)); return }
      self.handle(call, result: result)
    }
    FlutterEventChannel(name: "fqapp/native_player/events", binaryMessenger: messenger).setStreamHandler(self)
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main) { [weak self] note in self?.interruption(note) })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
        AVAudioSession.RouteChangeReason(rawValue: raw.uintValue) == .oldDeviceUnavailable else { return }
      self?.pauseForRouteChange()
    })
    installRemoteCommands()
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    commands.forEach { $0.0.removeTarget($0.1) }
  }

  private func onMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
  }

  private func current(_ entry: Entry) -> Bool { entries[entry.id] === entry }

  static func validRate(_ value: Double) -> Bool { value.isFinite && value >= 0.5 && value <= 3 }

  static func sourceURL(_ source: String) -> URL? {
    if source.hasPrefix("/") { return URL(fileURLWithPath: source) }
    guard let url = URL(string: source), let scheme = url.scheme?.lowercased(),
      ["https", "http", "file"].contains(scheme) else { return nil }
    if scheme != "file" && url.host?.isEmpty != false { return nil }
    return url
  }

  static func milliseconds(_ seconds: Double) -> Int64 {
    guard seconds.isFinite, seconds > 0, seconds < Double(Int64.max) / 1000 else { return 0 }
    return Int64(seconds * 1000)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    onMain { [self] in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "create": create(args, result: result)
      case "startListenForeground": updateNowPlaying(args); result(nil)
      case "stopListenForeground":
        metadataVisible = false
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        setRemoteEnabled(false)
        result(nil)
      case "setKeepScreenOn":
        let enabled = args["on"] as? Bool == true
        if enabled && !keepScreenOn { previousIdleTimer = UIApplication.shared.isIdleTimerDisabled }
        if enabled || keepScreenOn { UIApplication.shared.isIdleTimerDisabled = enabled || previousIdleTimer }
        keepScreenOn = enabled
        result(nil)
      case "canDrawOverlays", "requestOverlayPermission": result(false)
      case "dispose":
        if let id = args["id"] as? Int, let entry = entries.removeValue(forKey: id) { dispose(entry) }
        result(nil)
      case "play", "pause", "seek", "setRate", "setVolume":
        guard let id = args["id"] as? Int, let entry = entries[id], let player = entry.player else {
          result(FlutterError(code: "player_missing", message: "听书播放器尚未就绪", details: nil)); return
        }
        do {
          switch call.method {
          case "play":
            var intent = entry.intent
            intent.play()
            if intent.canPlay { try FQAudioSession.activate(owner: entry.owner) }
            entry.intent = intent
            activeID = id
            if intent.canPlay { player.playImmediately(atRate: entry.rate) }
            emit(entry, "playWhenReady", true)
          case "pause":
            pause(entry)
          case "seek":
            guard let position = args["positionMs"] as? NSNumber,
              position.doubleValue.isFinite, position.doubleValue >= 0,
              position.doubleValue < Double(Int64.max) else { throw PlayerError.invalidArgument }
            seek(entry, milliseconds: position.int64Value, result: result)
            return
          case "setRate":
            guard let rate = args["rate"] as? NSNumber, Self.validRate(rate.doubleValue) else { throw PlayerError.invalidArgument }
            entry.rate = rate.floatValue
            player.currentItem?.audioTimePitchAlgorithm = .timeDomain
            if entry.intent.canPlay { player.rate = entry.rate }
          case "setVolume":
            guard let volume = args["volume"] as? NSNumber, volume.doubleValue.isFinite,
              (0...1).contains(volume.doubleValue) else { throw PlayerError.invalidArgument }
            player.volume = volume.floatValue
          default: break
          }
          result(nil)
        } catch {
          result(FlutterError(code: "audio_operation", message: "无法执行听书操作，请重试", details: nil))
        }
      default: result(FlutterMethodNotImplemented)
      }
    }
  }

  private enum PlayerError: Error { case invalidArgument }

  private func create(_ args: [String: Any], result: @escaping FlutterResult) {
    guard entries.count < 8 else {
      result(FlutterError(code: "player_limit", message: "听书会话过多，请先关闭其他播放", details: nil)); return
    }
    guard args["audioOnly"] as? Bool == true,
      let source = args["cdnUrl"] as? String, let sourceURL = Self.sourceURL(source),
      let key = args["keyHex"] as? String,
      let data = try? JSONSerialization.data(withJSONObject: ["url": source, "key": key]),
      let request = String(data: data, encoding: .utf8) else {
      result(FlutterError(code: "unsupported_media", message: "当前 iOS 播放器仅支持听书音频", details: nil)); return
    }
    nextID += 1
    let entry = Entry(id: nextID)
    if interruptionActive { _ = entry.intent.beginInterruption() }
    if let start = args["startPositionMs"] as? NSNumber,
      start.doubleValue.isFinite, start.doubleValue > 0, start.doubleValue < Double(Int64.max) {
      entry.startMs = start.int64Value
    }
    entries[entry.id] = entry
    result(["playerId": entry.id, "textureId": -1])
    // 明文音源与 Android 一样直接播放，支持不提供 Range 的音频及系统支持的 HLS。
    if key.isEmpty {
      prepare(entry, url: sourceURL)
      return
    }
    // 打开包含 CDN 探测/元数据解密，不能阻塞 Flutter 或 AVPlayer 的主线程。
    work.async { [weak self] in
      let output: [String: Any]?
      if let raw = request.withCString({ fq_desktop_media_open($0) }) {
        let text = String(cString: raw)
        fq_desktop_media_free(raw)
        output = text.data(using: .utf8).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
      } else { output = nil }
      DispatchQueue.main.async {
        guard let self = self, self.current(entry) else {
          if let id = output?["id"] as? String { Self.closeMedia(id) }
          return
        }
        guard let id = output?["id"] as? String,
          let address = output?["url"] as? String, let url = URL(string: address),
          url.scheme == "http", url.host == "127.0.0.1" else {
          if let id = output?["id"] as? String { Self.closeMedia(id) }
          var failure: [String: Any] = ["message": "音频加载失败，请检查网络或重试"]
          if let kind = output?["kind"] as? String {
            failure["errorCode"] = ["connect": 2001, "timeout": 2002, "http": 2004,
              "range": 2004, "file": 2005, "decrypt": 3001][kind]
          }
          if let status = output?["status"] as? Int { failure["httpStatusCode"] = status }
          self.emit(entry, "error", failure)
          return
        }
        entry.mediaID = id
        self.prepare(entry, url: url)
      }
    }
  }

  private func prepare(_ entry: Entry, url: URL) {
    let item = AVPlayerItem(url: url)
    item.audioTimePitchAlgorithm = .timeDomain
    let player = AVPlayer(playerItem: item)
    player.automaticallyWaitsToMinimizeStalling = true
    entry.player = player
    entry.observations.append(item.observe(\.status, options: [.initial, .new]) { [weak self, weak entry] item, _ in
      self?.onMain {
        guard let self = self, let entry = entry, self.current(entry) else { return }
        switch item.status {
        case .readyToPlay:
          guard !entry.ready else { return }
          entry.ready = true
          let finish = {
            guard self.current(entry) else { return }
            self.emit(entry, "created", -1)
            self.reportDuration(entry)
            self.emit(entry, "buffering", false)
          }
          if entry.startMs > 0 {
            player.seek(to: CMTime(value: entry.startMs, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
              DispatchQueue.main.async(execute: finish)
            }
          } else { finish() }
        case .failed:
          self.pause(entry)
          self.emit(entry, "buffering", false)
          self.emit(entry, "error", ["message": "音频格式不受支持或加载失败", "errorCode": 3001])
        default: self.emit(entry, "buffering", true)
        }
      }
    })
    entry.observations.append(player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self, weak entry] player, _ in
      self?.onMain {
        guard let self = self, let entry = entry, self.current(entry) else { return }
        self.emit(entry, "playing", player.timeControlStatus == .playing)
        self.emit(entry, "buffering", player.timeControlStatus == .waitingToPlayAtSpecifiedRate)
      }
    })
    entry.tick = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 5), queue: .main) { [weak self, weak entry] time in
      guard let self = self, let entry = entry, self.current(entry) else { return }
      self.emit(entry, "position", Self.milliseconds(time.seconds))
      self.reportDuration(entry)
    }
    entry.endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
      object: item, queue: .main) { [weak self, weak entry] _ in
      guard let self = self, let entry = entry, self.current(entry) else { return }
      self.pause(entry)
      self.emit(entry, "completed", true)
    }
  }

  private func emit(_ entry: Entry, _ type: String, _ value: Any) {
    guard current(entry) else { return }
    let event: [String: Any] = ["playerId": entry.id, "type": type, "value": value]
    if let sink = sink { sink(event) }
    else if type != "position" && type != "duration" {
      if entry.pending.count >= 16 { entry.pending.removeFirst() }
      entry.pending.append(event)
    }
  }

  private func reportDuration(_ entry: Entry) {
    let duration = Self.milliseconds(entry.player?.currentItem?.duration.seconds ?? 0)
    guard duration > 0, duration != entry.lastDuration else { return }
    entry.lastDuration = duration
    emit(entry, "duration", duration)
  }

  private func pause(_ entry: Entry) {
    entry.intent.pause()
    entry.player?.pause()
    FQAudioSession.release(owner: entry.owner)
    emit(entry, "playWhenReady", false)
    emit(entry, "playing", false)
  }

  private func seek(_ entry: Entry, milliseconds: Int64, result: @escaping FlutterResult) {
    guard let player = entry.player else { result(FlutterError(code: "player_missing", message: "播放器已关闭", details: nil)); return }
    entry.seekGeneration += 1
    let generation = entry.seekGeneration
    player.seek(to: CMTime(value: milliseconds, timescale: 1000), toleranceBefore: .zero, toleranceAfter: .zero) { [weak self, weak entry] finished in
      DispatchQueue.main.async {
        guard let self = self, let entry = entry, self.current(entry), finished else {
          result(FlutterError(code: "seek_cancelled", message: "定位已取消", details: nil)); return
        }
        if generation == entry.seekGeneration {
          self.emit(entry, "completed", false)
          self.emit(entry, "position", Self.milliseconds(player.currentTime().seconds))
        }
        result(nil)
      }
    }
  }

  private static func closeMedia(_ id: String) {
    DispatchQueue.global(qos: .utility).async { id.withCString { fq_desktop_media_close($0) } }
  }

  private func dispose(_ entry: Entry) {
    entry.intent.pause()
    entry.observations.removeAll()
    if let tick = entry.tick { entry.player?.removeTimeObserver(tick); entry.tick = nil }
    if let token = entry.endObserver { NotificationCenter.default.removeObserver(token) }
    entry.player?.pause()
    entry.player?.replaceCurrentItem(with: nil)
    entry.player = nil
    if let id = entry.mediaID { Self.closeMedia(id); entry.mediaID = nil }
    FQAudioSession.release(owner: entry.owner)
    if activeID == entry.id { activeID = nil }
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
      let type = AVAudioSession.InterruptionType(rawValue: raw.uintValue) else { return }
    switch type {
    case .began:
      interruptionActive = true
      for entry in entries.values where entry.intent.beginInterruption() {
        entry.player?.pause()
        emit(entry, "playing", false)
      }
    case .ended:
      interruptionActive = false
      let rawOptions = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber
      let resume = AVAudioSession.InterruptionOptions(rawValue: rawOptions?.uintValue ?? 0).contains(.shouldResume)
      for entry in entries.values {
        if entry.intent.endInterruption(shouldResume: resume) {
          do {
            try FQAudioSession.activate(owner: entry.owner)
            entry.player?.playImmediately(atRate: entry.rate)
          } catch {
            pause(entry)
            emit(entry, "error", ["message": "音频中断后恢复失败，请手动继续"])
          }
        } else if !resume && entry.intent.wantsPlay {
          pause(entry)
          channel.invokeMethod("onAudioBecomingNoisy", arguments: nil)
        }
      }
    @unknown default: break
    }
  }

  private func pauseForRouteChange() {
    for entry in entries.values { pause(entry) }
    channel.invokeMethod("onAudioBecomingNoisy", arguments: nil)
  }

  private func updateNowPlaying(_ args: [String: Any]) {
    metadataVisible = true
    remotePlaying = args["playing"] as? Bool == true
    let position = max(0, (args["positionMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    let duration = max(0, (args["durationMs"] as? NSNumber)?.doubleValue ?? 0) / 1000
    let speed = (args["speed"] as? NSNumber)?.doubleValue ?? 1
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: args["title"] as? String ?? "听书",
      MPMediaItemPropertyAlbumTitle: args["episode"] as? String ?? "",
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: remotePlaying && Self.validRate(speed) ? speed : 0,
    ]
    setRemoteEnabled(true)
    let center = MPRemoteCommandCenter.shared()
    center.previousTrackCommand.isEnabled = args["hasPrev"] as? Bool == true
    center.nextTrackCommand.isEnabled = args["hasNext"] as? Bool == true
    center.changePlaybackPositionCommand.isEnabled = duration > 0 && activeID != nil
  }

  private func setRemoteEnabled(_ enabled: Bool) {
    commands.forEach { $0.0.isEnabled = enabled }
  }

  private func installRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    func bind(_ command: MPRemoteCommand, action: String, desired: Bool? = nil) {
      let token = command.addTarget { [weak self] _ in
        guard let self = self else { return .commandFailed }
        self.onMain {
          guard self.metadataVisible else { return }
          if let desired = desired, desired == self.remotePlaying { return }
          if let desired = desired { self.remotePlaying = desired }
          self.channel.invokeMethod("onNotificationAction", arguments: ["action": action])
        }
        return .success
      }
      commands.append((command, token))
    }
    bind(center.playCommand, action: "playPause", desired: true)
    bind(center.pauseCommand, action: "playPause", desired: false)
    bind(center.togglePlayPauseCommand, action: "playPause")
    bind(center.previousTrackCommand, action: "prev")
    bind(center.nextTrackCommand, action: "next")
    bind(center.stopCommand, action: "stop")
    let token = center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let self = self, let event = event as? MPChangePlaybackPositionCommandEvent,
        event.positionTime.isFinite, event.positionTime >= 0 else { return .commandFailed }
      self.onMain {
        guard self.metadataVisible, let id = self.activeID, let entry = self.entries[id] else { return }
        self.seek(entry, milliseconds: Self.milliseconds(event.positionTime)) { _ in }
      }
      return .success
    }
    commands.append((center.changePlaybackPositionCommand, token))
    setRemoteEnabled(false)
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onMain { [self] in
      sink = events
      for entry in entries.values {
        let pending = entry.pending
        entry.pending.removeAll()
        pending.forEach(events)
        if entry.ready {
          entry.lastDuration = -1
          reportDuration(entry)
        }
      }
    }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onMain { [self] in sink = nil }
    return nil
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    onMain { [self] in
      let detached = Array(entries.values)
      entries.removeAll()
      detached.forEach(dispose)
      sink = nil
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
      commands.forEach { $0.0.removeTarget($0.1) }
      commands.removeAll()
      MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
      if keepScreenOn { UIApplication.shared.isIdleTimerDisabled = previousIdleTimer; keepScreenOn = false }
    }
  }
}
