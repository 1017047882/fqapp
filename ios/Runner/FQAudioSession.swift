import AVFoundation

/**
 * @brief 应用内播放器与 TTS 共用音频会话，最后一名使用者释放时才停用。
 * @note owners 只能在主线程访问；重复申请/释放幂等，不在中断回调中擅自续播。
 */
enum FQAudioSession {
  private static var owners: Set<String> = []

  static func activate(owner: String) throws {
    precondition(Thread.isMainThread)
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playback, mode: .spokenAudio)
    try session.setActive(true)
    owners.insert(owner)
  }

  static func release(owner: String) {
    precondition(Thread.isMainThread)
    guard owners.remove(owner) != nil, owners.isEmpty else { return }
    try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
  }
}
