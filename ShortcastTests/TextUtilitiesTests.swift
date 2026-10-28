import XCTest
@testable import Shortcast

final class TextUtilitiesTests: XCTestCase {

    func testIsCyrillicWithCyrillicScalar() {
        let cyrillicA: Unicode.Scalar = "а"
        XCTAssertTrue(TextUtilities.isCyrillic(cyrillicA))
    }

    func testIsCyrillicWithLatinScalar() {
        let latinA: Unicode.Scalar = "a"
        XCTAssertFalse(TextUtilities.isCyrillic(latinA))
    }

    func testIsCyrillicWithDigit() {
        let digit: Unicode.Scalar = "5"
        XCTAssertFalse(TextUtilities.isCyrillic(digit))
    }

    func testContainsCyrillicWithCyrillicText() {
        let text = "Привет мир"
        XCTAssertTrue(TextUtilities.containsCyrillic(text))
    }

    func testContainsCyrillicWithLatinText() {
        let text = "Hello world"
        XCTAssertFalse(TextUtilities.containsCyrillic(text))
    }

    func testContainsCyrillicWithMixedText() {
        let text = "Привет world"
        XCTAssertTrue(TextUtilities.containsCyrillic(text))
    }

    func testContainsCyrillicWithEmptyText() {
        let text = ""
        XCTAssertFalse(TextUtilities.containsCyrillic(text))
    }

    func testDominantScriptCyrillic() {
        let text = "Привет мир это тест"
        let script = TextUtilities.dominantScript(text)
        XCTAssertEqual(script, "Cyrillic")
    }

    func testDominantScriptLatin() {
        let text = "Hello world this is a test"
        let script = TextUtilities.dominantScript(text)
        XCTAssertEqual(script, "Latin")
    }

    func testDominantScriptMixed() {
        let text = "Привет world"
        let script = TextUtilities.dominantScript(text)
        // May return either script depending on which has more characters
        XCTAssertNotNil(script)
    }

    func testDominantScriptEmpty() {
        let text = ""
        let script = TextUtilities.dominantScript(text)
        XCTAssertNil(script)
    }

    func testDominantScriptNumbersOnly() {
        let text = "123 456 789"
        let script = TextUtilities.dominantScript(text)
        XCTAssertNil(script, "Numbers should not determine script")
    }
}
