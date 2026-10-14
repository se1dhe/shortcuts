import Testing
import Foundation
@testable import Shortcast

@Suite("TranscriptMomentSearchService Tests")
struct TranscriptMomentSearchServiceTests {

    private let searchService: TranscriptMomentSearchingProtocol = TranscriptMomentSearchService()

    private let fightClubSegments: [TranscriptSegment] = [
        TranscriptSegment(start: 10.0, end: 12.0, text: "Ты знаешь, кто такой Тайлер Дёрден?"),
        TranscriptSegment(start: 12.5, end: 14.5, text: "Я знаю это лучше, чем кто-либо."),
        TranscriptSegment(start: 35.0, end: 38.0, text: "Первое правило бойцовского клуба:"),
        TranscriptSegment(start: 38.5, end: 42.0, text: "никому не рассказывать о бойцовском клубе."),
        TranscriptSegment(start: 100.0, end: 103.0, text: "Мы встретились"),
        TranscriptSegment(start: 103.8, end: 107.5, text: "в странный период моей жизни."),
        TranscriptSegment(start: 108.2, end: 110.0, text: "Всё рушится вокруг нас."),
        TranscriptSegment(start: 200.0, end: 204.0, text: "Лишь утратив всё до конца, мы обретаем свободу.")
    ]

    // MARK: - Exact and Case-Insensitive Matching

    @Test("Точный поиск фразы, разбитой на 2 смежных сегмента диалога")
    func testExactPhraseAcrossTwoSegments() {
        let matches = searchService.searchMoments(
            query: "Мы встретились в странный период моей жизни",
            in: fightClubSegments,
            contextPaddingBefore: 1.0,
            contextPaddingAfter: 2.0
        )

        #expect(!matches.isEmpty)
        guard let first = matches.first else { return }

        #expect(first.score >= 100.0)
        #expect(first.matchedDialogue.contains("Мы встретились"))
        #expect(first.matchedDialogue.contains("странный период"))
        #expect(abs(first.start - 99.0) < 0.01) // 100.0 - 1.0 padding
        #expect(abs(first.end - 109.5) < 0.01)   // 107.5 + 2.0 padding
        #expect(first.fullContextText.contains("Всё рушится вокруг нас"))
    }

    @Test("Регистронезависимый поиск с удалением пунктуации")
    func testCaseAndPunctuationInsensitive() {
        let matches = searchService.searchMoments(
            query: "  «МЫ ВСТРЕТИЛИСЬ... в странный период!?»  ",
            in: fightClubSegments,
            contextPaddingBefore: 0.5,
            contextPaddingAfter: 1.5
        )

        #expect(!matches.isEmpty)
        let first = matches[0]
        #expect(first.score >= 100.0)
        #expect(abs(first.start - 99.5) < 0.01)
        #expect(abs(first.end - 109.0) < 0.01)
    }

    @Test("Поиск культовой фразы про правила бойцовского клуба через границу сегментов")
    func testRulePhraseAcrossBoundaries() {
        let matches = searchService.searchMoments(
            query: "бойцовского клуба никому не рассказывать",
            in: fightClubSegments,
            contextPaddingBefore: 1.0,
            contextPaddingAfter: 1.0
        )

        #expect(!matches.isEmpty)
        let first = matches[0]
        #expect(first.score >= 80.0)
        #expect(first.matchedSegments.count == 2)
        #expect(abs(first.start - 34.0) < 0.01) // 35.0 - 1.0
        #expect(abs(first.end - 43.0) < 0.01)   // 42.0 + 1.0
    }

    // MARK: - Edge Cases

    @Test("Пустой поисковый запрос возвращает пустой список")
    func testEmptyQueryReturnsEmpty() {
        let empty = searchService.searchMoments(query: "", in: fightClubSegments)
        #expect(empty.isEmpty)

        let whitespace = searchService.searchMoments(query: "   \n\t  ", in: fightClubSegments)
        #expect(whitespace.isEmpty)
    }

    @Test("Пустой список сегментов возвращает пустой результат")
    func testEmptySegmentsReturnsEmpty() {
        let matches = searchService.searchMoments(query: "свобода", in: [])
        #expect(matches.isEmpty)
    }

    @Test("Запрос, отсутствующий в транскрипте, возвращает пустой список")
    func testNonExistentPhraseReturnsEmpty() {
        let matches = searchService.searchMoments(query: "космический корабль летит на марс", in: fightClubSegments)
        #expect(matches.isEmpty)
    }

    // MARK: - Context Padding and Zero Bound

    @Test("Проверка контекстных отступов и неотрицательного времени старта")
    func testPaddingAndNonNegativeStartTime() {
        let edgeSegments = [
            TranscriptSegment(start: 0.4, end: 2.0, text: "Начало всего фильма.")
        ]

        let matches = searchService.searchMoments(
            query: "Начало всего",
            in: edgeSegments,
            contextPaddingBefore: 2.0,
            contextPaddingAfter: 3.0
        )

        #expect(!matches.isEmpty)
        let match = matches[0]
        #expect(match.start == 0.0) // 0.4 - 2.0 должно быть зажато в 0.0
        #expect(abs(match.end - 5.0) < 0.01) // 2.0 + 3.0
    }

    // MARK: - Clustering & Pause Handling

    @Test("Сегменты с паузой более 3.5 секунд не объединяются в одно окно")
    func testSegmentsWithLargePauseDoNotMergeInWindow() {
        let splitSegments = [
            TranscriptSegment(start: 10.0, end: 12.0, text: "Первая фраза диалога"),
            TranscriptSegment(start: 25.0, end: 27.0, text: "Вторая фраза диалога через 13 секунд")
        ]

        // Поиск фразы, которая была бы "Первая фраза диалога Вторая фраза диалога"
        let matches = searchService.searchMoments(
            query: "Первая фраза диалога Вторая фраза диалога",
            in: splitSegments
        )

        // Должен найти частичные совпадения, но не объединенный гигантский 17-секундный блок
        for m in matches {
            #expect(m.matchedSegments.count == 1)
        }
    }

    // MARK: - Sorting and Relevance

    @Test("Сортировка: более точное совпадение имеет более высокий score и идет первым")
    func testRelevanceSorting() {
        let testSegments = [
            TranscriptSegment(start: 5.0, end: 8.0, text: "Какая-то странная случайная фраза."),
            TranscriptSegment(start: 20.0, end: 24.0, text: "Мы встретились в странный период моей жизни."),
            TranscriptSegment(start: 50.0, end: 54.0, text: "В этот период времени всё было странно.")
        ]

        let matches = searchService.searchMoments(
            query: "Мы встретились в странный период моей жизни",
            in: testSegments
        )

        #expect(!matches.isEmpty)
        #expect(matches[0].matchedSegments.first?.start == 20.0)
        #expect(matches[0].score >= 100.0)
    }
}
