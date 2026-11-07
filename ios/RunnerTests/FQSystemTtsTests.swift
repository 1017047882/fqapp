import XCTest
@testable import Runner

final class FQSystemTtsTests: XCTestCase {
  func testSpeechRateRejectsNonFiniteAndClampsPreference() {
    XCTAssertEqual(FQSystemTtsPlugin.speechRate(.nan), FQSystemTtsPlugin.speechRate(1))
    XCTAssertEqual(FQSystemTtsPlugin.speechRate(.infinity), FQSystemTtsPlugin.speechRate(1))
    XCTAssertEqual(FQSystemTtsPlugin.speechRate(0), FQSystemTtsPlugin.speechRate(0.5))
    XCTAssertEqual(FQSystemTtsPlugin.speechRate(4), FQSystemTtsPlugin.speechRate(3))
    XCTAssertLessThan(FQSystemTtsPlugin.speechRate(0.5), FQSystemTtsPlugin.speechRate(1))
    XCTAssertLessThan(FQSystemTtsPlugin.speechRate(1), FQSystemTtsPlugin.speechRate(3))
  }

  func testRangeUsesUTF16CoordinatesAndRejectsOverflow() {
    let text = "甲😀乙"
    XCTAssertEqual(FQSystemTtsPlugin.validRange(NSRange(location: 1, length: 2), text: text), 1..<3)
    XCTAssertEqual(FQSystemTtsPlugin.validRange(NSRange(location: 3, length: 1), text: text), 3..<4)
    XCTAssertNil(FQSystemTtsPlugin.validRange(NSRange(location: NSNotFound, length: 1), text: text))
    XCTAssertNil(FQSystemTtsPlugin.validRange(NSRange(location: 1, length: Int.max), text: text))
    XCTAssertNil(FQSystemTtsPlugin.validRange(NSRange(location: 4, length: 1), text: text))
    XCTAssertNil(FQSystemTtsPlugin.validRange(NSRange(location: 0, length: 0), text: text))
  }
}
