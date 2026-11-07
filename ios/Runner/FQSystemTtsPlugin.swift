import AVFoundation
import Flutter
import UIKit

/**
 * @brief iOS 系统中文朗读，通道及 UTF-16 进度坐标与 Dart/Android 保持一致。
 * @note 合成器、事件接收器和会话标记只在主线程访问；不允许并发重入。
 *       音频会话为全应用共享资源，仅在本插件申请后释放。系统打断只通知
 *       Dart 恢复意图，不在原生层擅自续播；停止前清除身份以拒绝迟到回调。
 */
final class FQSystemTtsPlugin: NSObject, FlutterPlugin, FlutterStreamHandler,
  AVSpeechSynthesizerDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var sink: FlutterEventSink?
  private var voice: AVSpeechSynthesisVoice?
  private var rate = AVSpeechUtteranceDefaultSpeechRate
  private var live: [ObjectIdentifier: String] = [:]
  private var ownsSession = false
  private var interrupted = false
  private var interruptionActive = false
  private var observers: [NSObjectProtocol] = []

  static func register(with registrar: FlutterPluginRegistrar) {
    let plugin = FQSystemTtsPlugin()
    let methods = FlutterMethodChannel(name: "fqapp/system_tts", binaryMessenger: registrar.messenger())
    let events = FlutterEventChannel(name: "fqapp/system_tts_events", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(plugin, channel: methods)
    events.setStreamHandler(plugin)
    registrar.publish(plugin)
  }

  override init() {
    super.init()
    synthesizer.delegate = self
    synthesizer.usesApplicationAudioSession = true
    let center = NotificationCenter.default
    observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
      object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      self?.handleInterruption(notification)
    })
    observers.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: AVAudioSession.sharedInstance(), queue: .main) { [weak self] notification in
      guard let self = self,
        let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber,
        AVAudioSession.RouteChangeReason(rawValue: raw.uintValue) == .oldDeviceUnavailable,
        self.ownsSession || self.interrupted else { return }
      self.stop(keepSession: false)
      self.sink?(["type": "interrupted", "keepFocus": false])
    })
  }

  deinit {
    observers.forEach { NotificationCenter.default.removeObserver($0) }
    synthesizer.delegate = nil
  }

  /** @brief 将外部回调串行化，避免后台 delegate 与 Flutter 调用竞争。 */
  private func onMain(_ operation: @escaping () -> Void) {
    if Thread.isMainThread { operation() } else { DispatchQueue.main.async(execute: operation) }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    onMain { [self] in
      let args = call.arguments as? [String: Any] ?? [:]
      switch call.method {
      case "engines":
        let voices = Self.chineseVoices()
        result([
          "engines": voices.map { ["package": $0.identifier, "label": "\($0.name) (\($0.language))"] },
          "defaultEngine": Self.defaultVoice(voices)?.identifier as Any? ?? NSNull(),
        ])
      case "initialize":
        stop(keepSession: false)
        voice = nil
        let voices = Self.chineseVoices()
        let requested = args["engine"] as? String
        if let requested = requested, !requested.isEmpty {
          voice = voices.first { $0.identifier == requested }
        } else {
          voice = Self.defaultVoice(voices)
        }
        guard voice != nil else {
          result(FlutterError(code: "no_engine", message: "未找到所选中文音色，请在 iOS 设置中下载或重新选择音色", details: nil))
          return
        }
        rate = Self.speechRate((args["rate"] as? NSNumber)?.doubleValue ?? 1)
        result(4000)
      case "speak":
        speak(args, result: result)
      case "pause":
        stop(keepSession: true)
        result(nil)
      case "stop":
        stop(keepSession: false)
        result(nil)
      case "shutdown":
        stop(keepSession: false)
        voice = nil
        result(nil)
      case "settings":
        // iOS 无公开的语音下载页 URL，使用公开 API 打开本应用设置页。
        guard let url = URL(string: UIApplication.openSettingsURLString) else {
          result(FlutterError(code: "settings_failed", message: "无法打开系统设置", details: nil))
          return
        }
        UIApplication.shared.open(url, options: [:]) { opened in
          result(opened ? nil : FlutterError(code: "settings_failed", message: "无法打开系统设置", details: nil))
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private static func chineseVoices() -> [AVSpeechSynthesisVoice] {
    AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix("zh") }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  private static func defaultVoice(_ voices: [AVSpeechSynthesisVoice]) -> AVSpeechSynthesisVoice? {
    if let preferred = AVSpeechSynthesisVoice(language: "zh-CN"),
      let installed = voices.first(where: { $0.identifier == preferred.identifier }) {
      return installed
    }
    return voices.first { $0.language.caseInsensitiveCompare("zh-CN") == .orderedSame } ?? voices.first
  }

  /** @brief 将业务倍率限制在有效范围，再映射至系统支持的语速范围。纯函数，无共享资源。 */
  static func speechRate(_ multiplier: Double) -> Float {
    let value = multiplier.isFinite ? min(3, max(0.5, multiplier)) : 1
    return min(AVSpeechUtteranceMaximumSpeechRate,
      max(AVSpeechUtteranceMinimumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(value)))
  }

  /** @brief 检查系统给出的 UTF-16 区间，先做减法边界检查以防整数溢出。纯函数。 */
  static func validRange(_ range: NSRange, text: String) -> Range<Int>? {
    let count = text.utf16.count
    guard range.location >= 0, range.location < count, range.length > 0,
      range.length <= count - range.location else { return nil }
    return range.location..<(range.location + range.length)
  }

  private func speak(_ args: [String: Any], result: @escaping FlutterResult) {
    guard !interruptionActive else {
      result(FlutterError(code: "audio_interrupted", message: "系统正在占用音频，请稍后继续", details: nil))
      return
    }
    guard let voice = voice else {
      result(FlutterError(code: "not_ready", message: "朗读引擎尚未就绪", details: nil))
      return
    }
    guard let text = args["text"] as? String,
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf16.count <= 4000,
      let id = args["id"] as? String, !id.isEmpty else {
      result(FlutterError(code: "invalid_text", message: "朗读片段为空或过长", details: nil))
      return
    }
    if args["queue"] as? Bool != true { stop(keepSession: true) }
    do {
      try FQAudioSession.activate(owner: "tts")
      ownsSession = true
      interrupted = false
    } catch {
      stop(keepSession: false)
      result(FlutterError(code: "audio_focus", message: "无法启用音频，请稍后继续", details: nil))
      return
    }
    let utterance = AVSpeechUtterance(string: text)
    utterance.voice = voice
    utterance.rate = rate
    live[ObjectIdentifier(utterance)] = id
    synthesizer.speak(utterance)
    result(nil)
  }

  /**
   * @brief 先使回调身份失效再停合成器；临时打断保留恢复通知资格。
   * @note 只能在主线程调用。会话共享，未申请时不得停用其他播放路径的会话。
   */
  private func stop(keepSession: Bool) {
    live.removeAll()
    synthesizer.stopSpeaking(at: .immediate)
    if !keepSession {
      interrupted = false
      if ownsSession {
        FQAudioSession.release(owner: "tts")
      }
      ownsSession = false
    }
  }

  private func handleInterruption(_ notification: Notification) {
    guard let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
      let type = AVAudioSession.InterruptionType(rawValue: raw.uintValue) else { return }
    switch type {
    case .began:
      interruptionActive = true
      guard ownsSession else { return }
      interrupted = true
      stop(keepSession: true)
      sink?(["type": "interrupted", "keepFocus": true])
    case .ended:
      interruptionActive = false
      guard interrupted else { return }
      interrupted = false
      let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber
      let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions?.uintValue ?? 0)
      if options.contains(.shouldResume) {
        sink?(["type": "focus_resume"])
      } else {
        stop(keepSession: false)
        sink?(["type": "interrupted", "keepFocus": false])
      }
    @unknown default:
      break
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    onMain { [self] in sink = events }
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    onMain { [self] in sink = nil }
    return nil
  }

  func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    onMain { [self] in
      stop(keepSession: false)
      voice = nil
      sink = nil
      synthesizer.delegate = nil
      observers.forEach { NotificationCenter.default.removeObserver($0) }
      observers.removeAll()
    }
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    emit("start", utterance: utterance)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    emit("done", utterance: utterance, terminal: true)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    // 主动停止已清除 live；仍有效的取消属于系统异常终止，交 Dart 停止会话。
    emit("error", utterance: utterance, terminal: true)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
    willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
    guard let range = Self.validRange(characterRange, text: utterance.speechString) else { return }
    emit("range", utterance: utterance, extra: ["start": range.lowerBound, "end": range.upperBound])
  }

  private func emit(_ type: String, utterance: AVSpeechUtterance,
    terminal: Bool = false, extra: [String: Any] = [:]) {
    onMain { [self] in
      let identity = ObjectIdentifier(utterance)
      guard let id = live[identity] else { return }
      if terminal { live.removeValue(forKey: identity) }
      var event = extra
      event["type"] = type
      event["id"] = id
      sink?(event)
    }
  }
}
