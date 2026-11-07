import CoreFoundation
import CryptoKit
import Darwin
import Flutter
import UIKit
import UniformTypeIdentifiers

/**
 * @brief 阅读设备会话与系统文件选择桥接（iOS 15+）。
 * @note UIKit、会话和 Flutter 回调仅在主线程串行访问；文件 I/O 在独立队列。
 *       亮度、常亮和电量监测是应用共享资源，仅恢复本会话保存的状态。
 *       不在中断上下文调用；选择器全局互斥，结果仅消费一次。
 */
final class FQReaderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  UIDocumentPickerDelegate {
  private enum Operation { case book, font, backupOpen, backupSave, textSave }
  private struct Pending {
    let id: UUID
    let operation: Operation
    let result: FlutterResult
    var staged: URL?
  }

  private let files = DispatchQueue(label: "fqapp.reader.files", qos: .userInitiated)
  private var channels: [FlutterMethodChannel] = []
  private var events: FlutterEventChannel?
  private var sink: FlutterEventSink?
  private var session: String?
  private var originalBrightness: CGFloat?
  private var followsSystem = true
  private var originalIdle: Bool?
  private var originalBatteryMonitoring: Bool?
  private var observers: [NSObjectProtocol] = []
  private var timer: Timer?
  private var pending: Pending?
  private var picker: UIDocumentPickerViewController?
  private var sharing = false
  private var detached = false

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = FQReaderPlugin(messenger: registrar.messenger())
    registrar.publish(plugin)
  }

  init(messenger: FlutterBinaryMessenger) {
    super.init()
    for name in ["fqapp/reader", "fqapp/local_books", "fqapp/library_backup",
      "fqapp/downloads", "fqapp/share"] {
      let channel = FlutterMethodChannel(name: name, binaryMessenger: messenger)
      channel.setMethodCallHandler { [weak self] call, result in
        DispatchQueue.main.async {
          guard let self = self else {
            result(FlutterError(code: "UNAVAILABLE", message: "原生桥接已关闭", details: nil))
            return
          }
          guard !self.detached else {
            result(FlutterError(code: "UNAVAILABLE", message: "原生桥接已关闭", details: nil))
            return
          }
          self.handle(channel: name, call: call, result: result)
        }
      }
      channels.append(channel)
    }
    let stream = FlutterEventChannel(name: "fqapp/reader/events", binaryMessenger: messenger)
    stream.setStreamHandler(self)
    events = stream
  }

  deinit {
    timer?.invalidate()
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    channels.forEach { $0.setMethodCallHandler(nil) }
    events?.setStreamHandler(nil)
    // 引擎持有者应在主线程释放；不从析构线程触碰 UIKit。
    let brightness = originalBrightness
    let idle = originalIdle
    let battery = originalBatteryMonitoring
    DispatchQueue.main.async {
      if let brightness = brightness { UIScreen.main.brightness = brightness }
      if let idle = idle { UIApplication.shared.isIdleTimerDisabled = idle }
      if let battery = battery { UIDevice.current.isBatteryMonitoringEnabled = battery }
    }
  }

  /** @brief 引擎关闭时主动断开事件持有链；所有未完成请求只结束一次。 */
  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    if !Thread.isMainThread {
      DispatchQueue.main.async { [self] in detachFromEngine(for: registrar) }
      return
    }
    guard !detached else { return }
    detached = true
    channels.forEach { $0.setMethodCallHandler(nil) }
    channels.removeAll()
    events?.setStreamHandler(nil)
    events = nil
    sink = nil
    restoreReader()
    let activePicker = picker
    activePicker?.delegate = nil
    activePicker?.dismiss(animated: false)
    finish(FlutterError(code: "UNAVAILABLE", message: "原生桥接已关闭", details: nil))
    sharing = false
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    handle(channel: "fqapp/reader", call: call, result: result)
  }

  private func handle(channel: String, call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    switch (channel, call.method) {
    case ("fqapp/reader", "pickFont"):
      open(.font, types: [UTType(filenameExtension: "ttf") ?? .data,
        UTType(filenameExtension: "otf") ?? .data], result: result)
    case ("fqapp/reader", "keepScreenOn"):
      guard let id = args["session"] as? String, id == session else { result(nil); return }
      if args["on"] as? Bool == true {
        if originalIdle == nil { originalIdle = UIApplication.shared.isIdleTimerDisabled }
        UIApplication.shared.isIdleTimerDisabled = true
      } else if let idle = originalIdle {
        UIApplication.shared.isIdleTimerDisabled = idle
        originalIdle = nil
      }
      result(nil)
    case ("fqapp/reader", "setImmersive"):
      // iOS 状态栏由 FlutterViewController 管理；Dart 保留 SafeArea 回退。
      result(FlutterMethodNotImplemented)
    case ("fqapp/reader", "start"), ("fqapp/reader", "setBrightness"):
      guard let id = args["session"] as? String, !id.isEmpty else {
        fail(result, "BAD_SESSION", "阅读会话无效"); return
      }
      guard let raw = args["brightness"] as? NSNumber,
        raw.doubleValue.isFinite,
        raw.doubleValue == -1 || (0.02...1).contains(raw.doubleValue) else {
        fail(result, "BAD_BRIGHTNESS", "亮度值无效"); return
      }
      if call.method == "setBrightness" && session != id { result(false); return }
      if session != id {
        restoreReader()
        session = id
        originalBrightness = UIScreen.main.brightness
        beginMonitoring()
      }
      if raw.doubleValue == -1 {
        followsSystem = true
        if let original = originalBrightness { UIScreen.main.brightness = original }
      } else {
        followsSystem = false
        UIScreen.main.brightness = CGFloat(raw.doubleValue)
      }
      if call.method == "start" { result(snapshot()) } else { result(true) }
    case ("fqapp/reader", "suspend"), ("fqapp/reader", "stop"):
      if let id = args["session"] as? String, id == session { restoreReader() }
      result(nil)
    case ("fqapp/local_books", "pickBookFile"):
      open(.book, types: [.plainText, UTType(filenameExtension: "epub") ?? .data], result: result)
    case ("fqapp/library_backup", "openBackup"):
      open(.backupOpen, types: [.json, .data], result: result)
    case ("fqapp/library_backup", "saveBackup"):
      guard let bytes = args["bytes"] as? FlutterStandardTypedData,
        !bytes.data.isEmpty, bytes.data.count <= 16 * 1024 * 1024 else {
        fail(result, "BAD_BACKUP", "备份文件不得超过 16 MiB"); return
      }
      export(.backupSave, data: bytes.data,
        name: args["name"] as? String ?? "fqapp-backup.json", result: result)
    case ("fqapp/downloads", "saveText"):
      guard let text = args["text"] as? String else {
        fail(result, "BAD_TEXT", "导出文本无效"); return
      }
      export(.textSave, data: Data(text.utf8),
        name: args["fileName"] as? String ?? "book.txt", result: result)
    case ("fqapp/share", "shareText"):
      share(args: args, result: result)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /** @brief 旧会话迟到的 stop/suspend 不得撤销新会话。 */
  private func restoreReader() {
    session = nil
    timer?.invalidate()
    timer = nil
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    observers.removeAll()
    if let brightness = originalBrightness { UIScreen.main.brightness = brightness }
    originalBrightness = nil
    followsSystem = true
    if let idle = originalIdle { UIApplication.shared.isIdleTimerDisabled = idle }
    originalIdle = nil
    if let battery = originalBatteryMonitoring { UIDevice.current.isBatteryMonitoringEnabled = battery }
    originalBatteryMonitoring = nil
  }

  private func beginMonitoring() {
    originalBatteryMonitoring = UIDevice.current.isBatteryMonitoringEnabled
    UIDevice.current.isBatteryMonitoringEnabled = true
    for name in [UIDevice.batteryLevelDidChangeNotification, UIDevice.batteryStateDidChangeNotification,
      UIScreen.brightnessDidChangeNotification, UIApplication.significantTimeChangeNotification] {
      observers.append(NotificationCenter.default.addObserver(forName: name, object: nil,
        queue: .main) { [weak self] notification in
          guard let self = self else { return }
          if notification.name == UIScreen.brightnessDidChangeNotification && self.followsSystem {
            self.originalBrightness = UIScreen.main.brightness
          }
          self.emit()
        })
    }
    observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification,
      object: nil, queue: .main) { [weak self] _ in self?.restoreReader() })
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in self?.emit() }
  }

  private func snapshot() -> [String: Any] {
    let device = UIDevice.current
    let level = device.batteryLevel
    return ["session": session ?? "", "timestamp": Int64(Date().timeIntervalSince1970 * 1000),
      "battery": level < 0 ? -1 : Int((level * 100).rounded()),
      "charging": device.batteryState == .charging || device.batteryState == .full,
      // iOS 没有独立的自动亮度读取接口；手动阅读亮度期间报告进入时的恢复值。
      "systemBrightness": Double(originalBrightness ?? UIScreen.main.brightness)]
  }

  private func emit() { if session != nil { sink?(snapshot()) } }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    emit()
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private var presenter: UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    guard let window = scenes.first(where: { $0.activationState == .foregroundActive })?
      .windows.first(where: { $0.isKeyWindow }) else { return nil }
    var controller = window.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  private func reserve(_ operation: Operation, result: @escaping FlutterResult) -> UUID? {
    guard pending == nil, !sharing else { fail(result, "PICKER_BUSY", "系统选择器正在使用"); return nil }
    guard let controller = presenter, !controller.isBeingDismissed else {
      fail(result, "NO_ACTIVITY", "当前没有可用窗口"); return nil
    }
    let id = UUID()
    pending = Pending(id: id, operation: operation, result: result)
    return id
  }

  private func open(_ operation: Operation, types: [UTType], result: @escaping FlutterResult) {
    guard reserve(operation, result: result) != nil else { return }
    presentPicker(UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false))
  }

  private func presentPicker(_ controller: UIDocumentPickerViewController) {
    guard let parent = presenter else {
      finish(FlutterError(code: "NO_ACTIVITY", message: "当前没有可用窗口", details: nil)); return
    }
    picker = controller
    controller.delegate = self
    controller.allowsMultipleSelection = false
    parent.present(controller, animated: true)
  }

  /** @brief 每次导出单独暂存目录；仅删除已知文件，禁止递归清理。 */
  private func export(_ operation: Operation, data: Data, name: String, result: @escaping FlutterResult) {
    guard let id = reserve(operation, result: result) else { return }
    files.async { [weak self] in
      do {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fqexport-\(id.uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let url = directory.appendingPathComponent(Self.safeName(name, fallback: "export.txt"))
        try data.write(to: url, options: .atomic)
        DispatchQueue.main.async {
          guard let self = self, self.pending?.id == id else { Self.removeStage(url); return }
          self.pending?.staged = url
          self.presentPicker(UIDocumentPickerViewController(forExporting: [url], asCopy: true))
        }
      } catch {
        DispatchQueue.main.async { self?.finishIf(id, value: FlutterError(code: "EXPORT_FAILED",
          message: error.localizedDescription, details: nil)) }
      }
    }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    guard controller === picker else { return }
    finish(pending?.operation == .backupSave ? false : nil)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard controller === picker, let request = pending, let url = urls.first else { return }
    picker = nil
    switch request.operation {
    case .backupSave: finish(true)
    case .textSave:
      // 文件提供者返回所选目标；不将 iOS“文件”位置伪称为 Android Downloads。
      finish(["path": url.isFileURL ? url.path : url.absoluteString, "public": true])
    case .book, .font, .backupOpen:
      files.async { [weak self] in
        let value: Any
        do { value = try Self.read(url, operation: request.operation) }
        catch { value = FlutterError(code: "FILE_READ_FAILED", message: error.localizedDescription, details: nil) }
        DispatchQueue.main.async { self?.finishIf(request.id, value: value) }
      }
    }
  }

  private func finishIf(_ id: UUID, value: Any?) {
    guard pending?.id == id else { return }
    finish(value)
  }

  private func finish(_ value: Any?) {
    guard let request = pending else { return }
    pending = nil
    picker = nil
    if let staged = request.staged { files.async { Self.removeStage(staged) } }
    request.result(value)
  }

  private static func removeStage(_ url: URL) {
    // 目录仅在确认已经为空后以 POSIX rmdir 删除，永不递归删除。
    try? FileManager.default.removeItem(at: url)
    url.deletingLastPathComponent().withUnsafeFileSystemRepresentation { path in
      if let path = path { _ = rmdir(path) }
    }
  }

  /** @brief 分块有界读取，避免文件提供者虚报长度引发无界分配。 */
  private static func read(_ url: URL, operation: Operation) throws -> Any {
    let scoped = url.startAccessingSecurityScopedResource()
    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
    let limit = (operation == .backupOpen ? 16 : 32) * 1024 * 1024
    var coordinationError: NSError?
    var loaded: Result<Data, Error>?
    NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readable in
      loaded = Result {
        let handle = try FileHandle(forReadingFrom: readable)
        defer { try? handle.close() }
        var data = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
          guard data.count <= limit - chunk.count else { throw fileError("文件超过大小限制") }
          data.append(chunk)
        }
        return data
      }
    }
    if let error = coordinationError { throw error }
    guard let loaded = loaded else { throw fileError("无法读取文件") }
    let bytes = try loaded.get()
    let name = url.lastPathComponent
    switch operation {
    case .backupOpen: return FlutterStandardTypedData(bytes: bytes)
    case .font:
      let signatures: [[UInt8]] = [[0, 1, 0, 0], [0x4f, 0x54, 0x54, 0x4f],
        [0x74, 0x72, 0x75, 0x65], [0x74, 0x74, 0x63, 0x66]]
      guard ["ttf", "otf"].contains(url.pathExtension.lowercased()), bytes.count >= 12,
        signatures.contains(where: { bytes.starts(with: $0) }) else {
        throw fileError("请选择有效的 TTF 或 OTF 字体")
      }
      let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
        appropriateFor: nil, create: true).appendingPathComponent("ReaderFonts", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      // 内容摘要路径由 CryptoKit 生成，重复选择同一字体不会持续增加文件。
      let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
      let path = directory.appendingPathComponent(digest + "." + url.pathExtension.lowercased())
      if !FileManager.default.fileExists(atPath: path.path) { try bytes.write(to: path, options: .atomic) }
      return ["name": name, "path": path.path]
    case .book:
      if url.pathExtension.lowercased() == "txt" {
        return ["name": name, "text": try decodeText(bytes), "byteLength": bytes.count]
      }
      guard url.pathExtension.lowercased() == "epub" else { throw fileError("仅支持 TXT 或 EPUB") }
      return ["name": name, "bytes": FlutterStandardTypedData(bytes: bytes), "byteLength": bytes.count]
    default: throw fileError("文件操作无效")
    }
  }

  static func decodeText(_ bytes: Data) throws -> String {
    if bytes.starts(with: [0xff, 0xfe]), let text = String(data: bytes.dropFirst(2), encoding: .utf16LittleEndian) {
      return text
    }
    if bytes.starts(with: [0xfe, 0xff]), let text = String(data: bytes.dropFirst(2), encoding: .utf16BigEndian) {
      return text
    }
    let payload = bytes.starts(with: [0xef, 0xbb, 0xbf]) ? Data(bytes.dropFirst(3)) : bytes
    if let text = String(data: payload, encoding: .utf8) { return text }
    let encoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
    if let text = String(data: payload, encoding: String.Encoding(rawValue: encoding)) { return text }
    throw fileError("无法解码文本，请使用 UTF-8 或 GB18030")
  }

  static func safeName(_ raw: String, fallback: String) -> String {
    let forbidden = CharacterSet.controlCharacters.union(CharacterSet(charactersIn: "/\\:*?\"<>|"))
    let replacement: Unicode.Scalar = "_"
    let cleaned = String(String.UnicodeScalarView(raw.unicodeScalars.map {
      forbidden.contains($0) ? replacement : $0
    }))
      .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
    return cleaned.isEmpty ? fallback : String(cleaned.prefix(120))
  }

  private static func fileError(_ message: String) -> NSError {
    NSError(domain: "fqapp.reader", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
  }

  private func fail(_ result: FlutterResult, _ code: String, _ message: String) {
    result(FlutterError(code: code, message: message, details: nil))
  }

  private func share(args: [String: Any], result: @escaping FlutterResult) {
    guard let text = args["text"] as? String, !text.isEmpty else {
      fail(result, "BAD_TEXT", "分享文本为空"); return
    }
    guard pending == nil, !sharing else { fail(result, "PICKER_BUSY", "系统选择器正在使用"); return }
    guard let parent = presenter else { fail(result, "NO_ACTIVITY", "当前没有可用窗口"); return }
    sharing = true
    let controller = UIActivityViewController(activityItems: [text], applicationActivities: nil)
    controller.title = args["title"] as? String
    controller.popoverPresentationController?.sourceView = parent.view
    controller.popoverPresentationController?.sourceRect = CGRect(x: parent.view.bounds.midX,
      y: parent.view.bounds.midY, width: 1, height: 1)
    controller.completionWithItemsHandler = { [weak self] _, _, _, _ in
      DispatchQueue.main.async {
        self?.sharing = false
      }
    }
    parent.present(controller, animated: true) { result(true) }
  }
}
