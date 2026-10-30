import XCTest
@testable import Shortcast

final class FilterNonCyrillicWhitelistTests: XCTestCase {

    func testUkrainianTextPreserved() {
        let input = "ТЕРПІННЯ — головна тема фільму"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "ТЕРПІННЯ — головна тема фільму")
    }

    func testEnglishCinemaTermsPreserved() {
        let input = "hook catharsis form psychology philosophy CTA"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "hook catharsis form psychology philosophy CTA")
    }

    func testEnglishPlatformsPreserved() {
        let input = "Telegram YouTube Shorts TikTok Instagram Netflix HBO Disney Pixar Marvel DC"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "Telegram YouTube Shorts TikTok Instagram Netflix HBO Disney Pixar Marvel DC")
    }

    func testEnglishDirectorsPreserved() {
        let input = "Nolan Fincher Scorsese Coen Villeneuve Besson Darabont Chazelle Refn Tarantino"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "Nolan Fincher Scorsese Coen Villeneuve Besson Darabont Chazelle Refn Tarantino")
    }

    func testEnglishActorsPreserved() {
        let input = "DiCaprio Pitt Jolie Clooney Gosling Bale Ledger"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "DiCaprio Pitt Jolie Clooney Gosling Bale Ledger")
    }

    func testUkrainianCinemaTermsPreserved() {
        let input = "хук катарсис форма психологія філософія"
        let result = LongformThematicService.filterNonCyrillic(input)
        // All terms are Cyrillic, so they are preserved
        XCTAssertEqual(result, "хук катарсис форма психологія філософія")
    }

    func testUkrainianPlatformsPreserved() {
        let input = "Телеграм Ютуб ТікТок Інстаграм Нетфлікс Дісней Піксар Марвел"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "Телеграм Ютуб ТікТок Інстаграм Нетфлікс Дісней Піксар Марвел")
    }

    func testMixedUkrainianAndWhitelistPreserved() {
        let input = "ТЕРПІННЯ — головна тема фільму Nolan, доступний на Netflix"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "ТЕРПІННЯ — головна тема фільму Nolan, доступний на Netflix")
    }

    func testNonWhitelistEnglishRemoved() {
        let input = "ТЕРПІННЯ — це English word, яке не в whitelist"
        let result = LongformThematicService.filterNonCyrillic(input)
        // "English", "word", "whitelist" are not in whitelist, so they are removed
        // Spaces around removed words are preserved
        XCTAssertEqual(result, "ТЕРПІННЯ — це  , яке не в ")
    }

    func testJapaneseTextRemoved() {
        let input = "ТЕРПІННЯ — 忍耐というテーマ"
        let result = LongformThematicService.filterNonCyrillic(input)
        // Japanese characters are removed
        XCTAssertEqual(result, "ТЕРПІННЯ — ")
    }

    func testEmptyTextReturnsEmpty() {
        let input = ""
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "")
    }

    func testOnlyWhitelistTermsPreserved() {
        let input = "hook catharsis Nolan Netflix"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "hook catharsis Nolan Netflix")
    }

    func testPunctuationPreserved() {
        let input = "ТЕРПІННЯ: головна тема — Nolan's Netflix!"
        let result = LongformThematicService.filterNonCyrillic(input)
        // Apostrophe is punctuation (preserved), but 's' is not Cyrillic/whitelist (removed)
        XCTAssertEqual(result, "ТЕРПІННЯ: головна тема — Nolan' Netflix!")
    }

    func testNumbersPreserved() {
        let input = "ТЕРПІННЯ 101 причина дивитися Netflix 24/7"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "ТЕРПІННЯ 101 причина дивитися Netflix 24/7")
    }

    func testCaseInsensitiveWholeTokenMatch() {
        // Распознаём термин в любом регистре, но в текст подставляем ровно тот
        // токен, что написала модель: «HOOK» остаётся «HOOK». Регистр не может
        // ничего дописать, а подстрока могла — см. следующий тест.
        let input = "HOOK hook Hook"
        let result = LongformThematicService.filterNonCyrillic(input)
        XCTAssertEqual(result, "HOOK hook Hook")
    }

    func testWhitelistTermIsNotMatchedAsASubstring() {
        // «Performance» contain-ил бы «form» и свернулся в него — то есть фильтр
        // дописал бы в текст модели то, чего она не писала.
        XCTAssertEqual(
            LongformThematicService.filterNonCyrillic("Performance"),
            "")
        XCTAssertEqual(
            LongformThematicService.filterNonCyrillic("трансформер"),
            "трансформер")
    }
}
