import XCTest
@testable import Runner

final class FQAudioPlayerTests: XCTestCase {
  func testOnlyAnInterruptedPlayingSessionCanResume() {
    var state = FQPlaybackIntent()
    XCTAssertFalse(state.beginInterruption())
    XCTAssertFalse(state.endInterruption(shouldResume: true))
    state.play()
    XCTAssertTrue(state.beginInterruption())
    XCTAssertFalse(state.canPlay)
    XCTAssertTrue(state.endInterruption(shouldResume: true))
    XCTAssertTrue(state.canPlay)
    XCTAssertFalse(state.endInterruption(shouldResume: true))
  }

  func testUserPauseDuringInterruptionPreventsResurrection() {
    var state = FQPlaybackIntent()
    state.play()
    XCTAssertTrue(state.beginInterruption())
    state.pause()
    XCTAssertFalse(state.canPlay)
    XCTAssertFalse(state.endInterruption(shouldResume: true))
    state.play()
    XCTAssertTrue(state.beginInterruption())
    XCTAssertFalse(state.endInterruption(shouldResume: false))
  }

  func testRateAndPositionRejectInvalidNumbers() {
    XCTAssertTrue(FQAudioPlayerPlugin.validRate(1))
    XCTAssertTrue(FQAudioPlayerPlugin.validRate(3))
    for value in [Double.nan, .infinity, -.infinity, 0, -1, 4] {
      XCTAssertFalse(FQAudioPlayerPlugin.validRate(value))
    }
    XCTAssertEqual(FQAudioPlayerPlugin.milliseconds(1.25), 1250)
    XCTAssertEqual(FQAudioPlayerPlugin.milliseconds(.nan), 0)
    XCTAssertEqual(FQAudioPlayerPlugin.milliseconds(.infinity), 0)
    XCTAssertEqual(FQAudioPlayerPlugin.milliseconds(-1), 0)
  }

  func testClearSourcesAllowStreamingWithoutARangeProbe() {
    XCTAssertEqual(FQAudioPlayerPlugin.sourceURL("https://example.org/live.m3u8")?.scheme, "https")
    XCTAssertEqual(FQAudioPlayerPlugin.sourceURL("/private/audio.mp3")?.isFileURL, true)
    XCTAssertEqual(FQAudioPlayerPlugin.sourceURL("file:///private/audio.mp3")?.isFileURL, true)
    XCTAssertNil(FQAudioPlayerPlugin.sourceURL("javascript:invalid"))
    XCTAssertNil(FQAudioPlayerPlugin.sourceURL("https:///"))
  }
}
