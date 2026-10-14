import Testing
import Foundation
@testable import Shortcast

@Suite("CinemaContentGenerator Tests")
struct CinemaContentGeneratorTests {

    private let fightClubMovie = TMDBMovie(
        tmdbID: 550,
        title: "Бойцовский клуб",
        year: "1999",
        genres: ["триллер", "драма"],
        overview: "Сотрудник страховой компании страдает хронической бессонницей и отчаянно пытается вырваться из мучительно унылой жизни. Однажды он встречает некоего Тайлера Дёрдена...",
        cast: ["Брэд Питт", "Эдвард Нортон", "Хелена Бонем Картер"],
        director: "Дэвид Финчер",
        imdbRating: 8.8,
        rottenTomatoesScore: 79,
        posterPath: "/fightclub.jpg"
    )

    private let godfatherMovie = TMDBMovie(
        tmdbID: 238,
        title: "Крестный отец",
        year: "1972",
        genres: ["криминал", "драма"],
        overview: "Криминальная сага о сицилийской мафиозной семье Корлеоне в Нью-Йорке. Глава клана дон Вито выдает замуж дочь...",
        cast: ["Марлон Брандо", "Аль Пачино", "Джеймс Каан"],
        director: "Фрэнсис Форд Коппола",
        imdbRating: 9.2,
        rottenTomatoesScore: 97,
        posterPath: "/godfather.jpg"
    )

    @Test("Neither movie nor candidate generates hardcoded stale templates")
    func testNoHardcodedStubTemplates() {
        let context = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: fightClubMovie.title,
            year: fightClubMovie.year,
            genres: fightClubMovie.genres,
            overview: fightClubMovie.overview,
            imdbRating: fightClubMovie.imdbRating,
            candidateHook: "Первое правило Бойцовского клуба: никому не говорить о Бойцовском клубе",
            candidateSummary: "Тайлер Дёрден организует подпольный клуб бойцов, чтобы сломать систему материализма",
            transcriptSlice: "Первое правило Бойцовского клуба — никому не говорить о Бойцовском клубе."
        )

        let result = CinemaContentGenerator.cinemaPlatformContent(context: context)

        let forbiddenPhrases = [
            "Такой развязки никто не ожидал",
            "Такой развязки точно никто не ожидал"
        ]

        for (platform, content) in result {
            for phrase in forbiddenPhrases {
                #expect(!content.hook.contains(phrase), Comment(rawValue: "Platform \(platform.rawValue) hook should not contain stub template '\(phrase)'"))
                #expect(!content.description.contains(phrase), Comment(rawValue: "Platform \(platform.rawValue) description should not contain stub template '\(phrase)'"))
            }
        }
    }

    @Test("Fight Club adaptive copywriting generates unique platform-specific content")
    func testFightClubAdaptiveContent() {
        let context = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: fightClubMovie.title,
            year: fightClubMovie.year,
            genres: fightClubMovie.genres,
            overview: fightClubMovie.overview,
            imdbRating: fightClubMovie.imdbRating,
            cast: fightClubMovie.cast,
            director: fightClubMovie.director,
            candidateHook: "Первое правило Бойцовского клуба...",
            candidateSummary: "Тайлер Дёрден устраивает бойню за гаражами",
            transcriptSlice: "Первое правило Бойцовского клуба — никому не говорить о Бойцовском клубе."
        )

        let content = CinemaContentGenerator.cinemaPlatformContent(context: context)

        // 1. TikTok: Dynamic scene hook, dilemma in description, genre hashtags
        guard let tiktok = content[.tiktok] else {
            Issue.record("Missing TikTok content")
            return
        }
        #expect(tiktok.hook.contains("Бойцовского клуба"))
        #expect(tiktok.description.contains("Как бы ты поступил на месте героя?"))
        #expect(tiktok.description.contains("@telonyx_club"))
        #expect(tiktok.hashtags.contains("#триллер") || tiktok.hashtags.contains("#драма"))
        // TikTok video tags should NOT leak film title to preserve mystery funnel
        #expect(!tiktok.hashtags.contains("#бойцовскийклуб"))

        // 2. Instagram: Cinematographic hook, acting tension, save call
        guard let insta = content[.instagram] else {
            Issue.record("Missing Instagram content")
            return
        }
        #expect(insta.hook.contains("Бойцовского клуба"))
        #expect(insta.description.contains("Сохраняй в закладки"))
        #expect(insta.description.contains("Оцени этот момент от 1 до 10"))
        #expect(insta.hashtags.contains("#reels"))

        // 3. YouTube Shorts: Title with #Shorts, motivation question
        guard let youtube = content[.youtube] else {
            Issue.record("Missing YouTube content")
            return
        }
        #expect(youtube.hook.contains("#Shorts"))
        #expect(youtube.hook.contains("Бойцовского клуба"))
        #expect(youtube.description.contains("Что двигало героем в этот момент"))
        #expect(youtube.hashtags.contains("#Shorts"))

        // 4. Telegram: Rich card with title, year, IMDb rating, director, quote, hashtags
        guard let telegram = content[.telegram] else {
            Issue.record("Missing Telegram content")
            return
        }
        #expect(telegram.hook.contains("Бойцовский клуб"))
        #expect(telegram.hook.contains("1999"))
        #expect(telegram.description.contains("🎬 «Бойцовский клуб» (1999)"))
        #expect(telegram.description.contains("⭐️ IMDb: 8.8"))
        #expect(telegram.description.contains("Дэвид Финчер"))
        #expect(telegram.description.contains("Брэд Питт"))
        #expect(telegram.description.contains("💬 «Первое правило Бойцовского клуба"))
        #expect(telegram.description.contains("❓ Как вам развязка этого фильма?"))
        #expect(telegram.hashtags.contains("#Бойцовскийклуб") || telegram.hashtags.contains("#БойцовскийКлуб"))
    }

    @Test("Godfather content differs from Fight Club and adapts to crime/mafia genre")
    func testGodfatherAdaptiveContent() {
        let fcContext = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: fightClubMovie.title,
            year: fightClubMovie.year,
            genres: fightClubMovie.genres,
            overview: fightClubMovie.overview,
            imdbRating: fightClubMovie.imdbRating,
            candidateHook: "Первое правило Бойцовского клуба...",
            candidateSummary: "Тайлер Дёрден организует клуб"
        )
        let gfContext = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: godfatherMovie.title,
            year: godfatherMovie.year,
            genres: godfatherMovie.genres,
            overview: godfatherMovie.overview,
            imdbRating: godfatherMovie.imdbRating,
            cast: godfatherMovie.cast,
            director: godfatherMovie.director,
            candidateHook: "Я сделаю ему предложение, от которого он не сможет отказаться",
            candidateSummary: "Дон Корлеоне объясняет цену уважения и преданности семье",
            transcriptSlice: "Я сделаю ему предложение, от которого он не сможет отказаться."
        )

        let fcContent = CinemaContentGenerator.cinemaPlatformContent(context: fcContext)
        let gfContent = CinemaContentGenerator.cinemaPlatformContent(context: gfContext)

        // Contents must be completely distinct across all platforms
        #expect(fcContent[.tiktok]?.hook != gfContent[.tiktok]?.hook)
        #expect(fcContent[.tiktok]?.description != gfContent[.tiktok]?.description)
        #expect(fcContent[.instagram]?.description != gfContent[.instagram]?.description)
        #expect(fcContent[.youtube]?.hook != gfContent[.youtube]?.hook)
        #expect(fcContent[.telegram]?.description != gfContent[.telegram]?.description)

        // Godfather Telegram card checks
        let gfTelegram = gfContent[.telegram]!
        #expect(gfTelegram.description.contains("Крестный отец"))
        #expect(gfTelegram.description.contains("1972"))
        #expect(gfTelegram.description.contains("Фрэнсис Форд Коппола"))
        #expect(gfTelegram.description.contains("Марлон Брандо"))
        #expect(gfTelegram.description.contains("⭐️ IMDb: 9.2"))
        #expect(gfTelegram.description.contains("💬 «Я сделаю ему предложение"))
        #expect(gfTelegram.hashtags.contains("#Крестныйотец") || gfTelegram.hashtags.contains("#КрестныйОтец"))
    }

    @Test("Dynamic fallback when no candidate hook is provided adapts to movie genres")
    func testDynamicFallbackWithoutCandidate() {
        let thrillerContext = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: "Некий триллер",
            genres: ["триллер"]
        )
        let crimeContext = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: "Некий криминал",
            genres: ["криминал", "боевик"]
        )
        let comedyContext = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: "Некая комедия",
            genres: ["комедия"]
        )

        let thrillerContent = CinemaContentGenerator.cinemaPlatformContent(context: thrillerContext)
        let crimeContent = CinemaContentGenerator.cinemaPlatformContent(context: crimeContext)
        let comedyContent = CinemaContentGenerator.cinemaPlatformContent(context: comedyContext)

        #expect(thrillerContent[.tiktok]!.hook.contains("напряжение зашкаливает"))
        #expect(crimeContent[.tiktok]!.hook.contains("роковую ошибку"))
        #expect(comedyContent[.tiktok]!.hook.contains("пересматривают сотни раз"))

        #expect(!thrillerContent[.tiktok]!.hook.contains("Такой развязки никто не ожидал"))
        #expect(!crimeContent[.tiktok]!.hook.contains("Такой развязки никто не ожидал"))
    }

    @Test("PostVariant fullDescriptionWithTags and parsing roundtrip")
    func testPostVariantDescriptionAndTags() {
        var variant = PostVariant(
            platform: .tiktok,
            hook: "Культовый момент",
            summary: "Это драматическая сцена, где герой делает роковой выбор.",
            hashtags: ["кино", "триллер", "рек"],
            pinnedComment: ""
        )

        let combined = variant.fullDescriptionWithTags
        #expect(combined.contains("Это драматическая сцена, где герой делает роковой выбор."))
        #expect(combined.contains("#кино #триллер #рек"))

        // Update from combined text
        let updatedText = "Новое описание сцены с неожиданным поворотом.\n\n#фильм #драма #fyp"
        variant.updateFromCombinedDescription(updatedText)

        #expect(variant.summary == "Новое описание сцены с неожиданным поворотом.")
        #expect(variant.hashtags == ["фильм", "драма", "fyp"])
        #expect(variant.hashtagLine == "#фильм #драма #fyp")
        #expect(variant.fullDescriptionWithTags == updatedText)

        // Case with no trailing hashtags
        let noTagsText = "Только текст описания без каких-либо тегов."
        variant.updateFromCombinedDescription(noTagsText)
        #expect(variant.summary == noTagsText)
        #expect(variant.hashtags.isEmpty)
        #expect(variant.fullDescriptionWithTags == noTagsText)
    }

    @Test("Text ad mode injects bot promo while preserving scene-adaptive hook")
    func testTextAdMode() {
        let context = CinemaContentGenerator.CinemaSceneContext(
            movieTitle: fightClubMovie.title,
            year: fightClubMovie.year,
            genres: fightClubMovie.genres,
            candidateHook: "Осознание реальности...",
            candidateSummary: "Главный герой понимает, кем на самом деле является Тайлер",
            textAd: true
        )

        let content = CinemaContentGenerator.cinemaPlatformContent(context: context)

        let tiktok = content[.tiktok]!
        #expect(tiktok.hook.contains("Осознание реальности..."))
        #expect(tiktok.description.contains("Telegram: @telonyx_club"))
        #expect(tiktok.hashtags.contains("#telonyx_club"))

        let insta = content[.instagram]!
        #expect(insta.description.contains("Telegram: @telonyx_club"))
        #expect(insta.hashtags.contains("#telonyx_club"))
    }
}
