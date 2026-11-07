import XCTest
@testable import Runner

final class FQReaderPluginTests: XCTestCase {
  func testSafeNamesCannotEscapeStagingDirectory() {
    let name = FQReaderPlugin.safeName("../../恶意\\文件\u{0000}.txt", fallback: "book.txt")
    XCTAssertFalse(name.contains("/"))
    XCTAssertFalse(name.contains("\\"))
    XCTAssertFalse(name.contains("\u{0000}"))
    XCTAssertEqual(FQReaderPlugin.safeName("...", fallback: "book.txt"), "book.txt")
    XCTAssertLessThanOrEqual(FQReaderPlugin.safeName(String(repeating: "字", count: 300),
      fallback: "book.txt").count, 120)
  }

  func testTextDecodingSupportsChineseAndBOM() throws {
    XCTAssertEqual(try FQReaderPlugin.decodeText(Data([0xef, 0xbb, 0xbf]) + Data("中文".utf8)), "中文")
    XCTAssertEqual(try FQReaderPlugin.decodeText(Data([0xd6, 0xd0, 0xce, 0xc4])), "中文")
    XCTAssertEqual(try FQReaderPlugin.decodeText(Data([0xff, 0xfe, 0x2d, 0x4e])), "中")
  }
}
