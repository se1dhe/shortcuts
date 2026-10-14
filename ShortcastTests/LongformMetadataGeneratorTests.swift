import Testing
import Foundation
@testable import Shortcast

@Suite("LongformMetadataGenerator Tests")
struct LongformMetadataGeneratorTests {

    // MARK: - Test Data

    private let fightClubConcept = ThematicConcept(
        word: "Контроль",
        tagline: "Ты не управляешь тем, что создал — оно управляет тобой.",
        philosophicalPremise: "Человек стремится контролировать всё вокруг, лишь чтобы не признать свой глубинный страх пустоты.",
        suggestedTitle: "Вещи, которыми ты владеешь, овладели тобой.",
        accentColorHex: "#F5D020",
        isPrimaryChoice: true,
        aiReasoning: "В сценарии Финчера вся динамика Рассказчика построена на крушении иллюзии контроля."
    )

    private var fightClubArc: LongformNarrativeArc {
        let acts = [
            LongformAct(
                type: .hook,
                title: "Иллюзия порядка",
                dramaticBeat: "Знакомство с монотонной жизнью Рассказчика и его попыткой заполнить внутреннюю пустоту каталогами IKEA.",
                segments: [TimeSegment(start: 0, end: 45)]
            ),
            LongformAct(
                type: .downfall,
                title: "Рождение бунта",
                dramaticBeat: "Появление Тайлера Дёрдена и отказ от социальных догм через физическую боль.",
                segments: [TimeSegment(start: 45, end: 175)]
            ),
            LongformAct(
                type: .struggle,
                title: "Потеря контроля",
                dramaticBeat: "Проект «Разгром» выходит из-под контроля, превращая освобождение в новую форму диктата.",
                segments: [TimeSegment(start: 175, end: 310)]
            ),
            LongformAct(
                type: .catharsis,
                title: "Катарсис и пробуждение",
                dramaticBeat: "Осознание природы Тайлера и выстрел в себя как единственный акт истинного выбора.",
                segments: [TimeSegment(start: 310, end: 420)]
            )
        ]
        return LongformNarrativeArc(
            movieTitle: "Бойцовский клуб",
            concept: fightClubConcept,
            acts: acts,
            summary: "Сотрудник страховой компании страдает бессонницей и строит идеальную материальную жизнь, пока не встречает Тайлера Дёрдена. Через бунт они создают подпольный клуб, перерастающий в проект уничтожения системы.",
            mood: "dramatic"
        )
    }

    private let godfatherConcept = ThematicConcept(
        word: "Семья",
        tagline: "Настоящая власть всегда говорит тихо.",
        philosophicalPremise: "Семья — это единственная опора в жестоком мире, но плата за ее абсолютную защиту — собственная душа.",
        suggestedTitle: "Настоящая власть всегда говорит тихо.",
        accentColorHex: "#E50914",
        isPrimaryChoice: true,
        aiReasoning: "Трагедия Майкла Корлеоне в том, что спасая семью, он уничтожает в себе все человеческое."
    )

    private var godfatherArc: LongformNarrativeArc {
        let acts = [
            LongformAct(
                type: .hook,
                title: "Бремя долга",
                dramaticBeat: "Покушение на дона Вито и неизбежность выбора для Майкла между мирной жизнью и семейным долгом.",
                segments: [TimeSegment(start: 0, end: 50)]
            ),
            LongformAct(
                type: .downfall,
                title: "Точка невозврата",
                dramaticBeat: "Убийство Солоццо и капитана Маккласки в ресторане как пересечение моральной черты.",
                segments: [TimeSegment(start: 50, end: 180)]
            ),
            LongformAct(
                type: .struggle,
                title: "Цена власти",
                dramaticBeat: "Майкл берет управление кланом в свои руки, вытесняя любые эмоции ради выживания семьи.",
                segments: [TimeSegment(start: 180, end: 320)]
            ),
            LongformAct(
                type: .catharsis,
                title: "Катарсис и холод",
                dramaticBeat: "Сцена крещения, синхронизированная с ликвидацией врагов, и финальное закрытие двери перед Кей.",
                segments: [TimeSegment(start: 320, end: 450)]
            )
        ]
        return LongformNarrativeArc(
            movieTitle: "Крестный отец",
            concept: godfatherConcept,
            acts: acts,
            summary: "Криминальная сага о превращении младшего сына дона, Майкла Корлеоне, из идеалиста-ветерана в безжалостного главу мафиозной империи ради защиты своего клана.",
            mood: "epic"
        )
    }

    // MARK: - Tests

    @Test("Neither movie produces hardcoded stub templates or manifestos")
    func testNoStaleHardcodedFormulas() {
        let fcMetadata = LongformMetadataGenerator.generate(
            movieTitle: "Бойцовский клуб",
            concept: fightClubConcept,
            arc: fightClubArc
        )
        let gfMetadata = LongformMetadataGenerator.generate(
            movieTitle: "Крестный отец",
            concept: godfatherConcept,
            arc: godfatherArc
        )

        let staleFormulas = [
            "Ты проигрываешь, пока веришь в это",
            "Однажды ты поймёшь, почему всё произошло именно так",
            "Иногда, чтобы победить, нужно отпустить контроль",
            "Ты никогда не будешь свободен, пока не осознаешь это",
            "Самая опасная ложь — та, в которую ты веришь сам",
            "Этот ролик — про другую сторону",
            "Не про внешние декорации",
            "Не про слова на поверхности",
            "Иногда иллюзия настолько плотно срастается с реальностью",
            "Самый опасный враг — тот, кто прячется там, где ты меньше всего будешь его искать"
        ]

        for meta in [fcMetadata, gfMetadata] {
            for formula in staleFormulas {
                #expect(!meta.title.contains(formula), Comment(rawValue: "Title contains stale formula '\(formula)'"))
                #expect(!meta.description.contains(formula), Comment(rawValue: "Description contains stale formula '\(formula)'"))
                #expect(!meta.pinnedComment.contains(formula), Comment(rawValue: "Pinned comment contains stale formula '\(formula)'"))
            }
        }
    }

    @Test("Fight Club generates rich, film-specific metadata with acts, beats and chapters")
    func testFightClubAdaptiveMetadata() {
        let metadata = LongformMetadataGenerator.generate(
            movieTitle: "Бойцовский клуб",
            concept: fightClubConcept,
            arc: fightClubArc
        )

        // Title: author hook + concept word + movie title
        #expect(metadata.title.contains("Бойцовский клуб"))
        #expect(metadata.title.contains("Контроль"))
        #expect(metadata.title.contains("Вещи, которыми ты владеешь, овладели тобой"))

        // Description: manifesto + arc.summary + all acts with beats + chapters + fair use + hashtags
        #expect(metadata.description.contains("Бойцовский клуб"))
        #expect(metadata.description.contains("Контроль"))
        #expect(metadata.description.contains(fightClubConcept.tagline))
        #expect(metadata.description.contains(fightClubConcept.philosophicalPremise))
        #expect(metadata.description.contains(fightClubArc.summary))
        #expect(metadata.description.contains("Иллюзия порядка"))
        #expect(metadata.description.contains("Рождение бунта"))
        #expect(metadata.description.contains("Потеря контроля"))
        #expect(metadata.description.contains("Катарсис и пробуждение"))
        #expect(metadata.description.contains("Знакомство с монотонной жизнью Рассказчика"))
        #expect(metadata.description.contains("Таймкоды:"))
        #expect(metadata.description.contains("00:00 — Вступление: Контроль"))
        #expect(metadata.description.contains("Fair Use"))
        #expect(metadata.description.contains("#бойцовскийклуб"))
        #expect(metadata.description.contains("#контроль"))

        // Pinned comment: moral dilemma question tailored to film and theme
        #expect(metadata.pinnedComment.contains(fightClubConcept.tagline))
        #expect(metadata.pinnedComment.contains("Бойцовском клубе") || metadata.pinnedComment.contains("Бойцовский клуб"))
        #expect(metadata.pinnedComment.contains("контроль") || metadata.pinnedComment.contains("контролю"))
        #expect(metadata.pinnedComment.contains("Напишите свои мысли в комментариях 👇") || metadata.pinnedComment.contains("Поделитесь своими мыслями в комментариях 👇"))

        // Tags: movie title variants + concept variants + act titles + cinema essay tags
        #expect(metadata.tags.contains("бойцовский клуб"))
        #expect(metadata.tags.contains("бойцовский клуб разбор"))
        #expect(metadata.tags.contains("бойцовский клуб смысл"))
        #expect(metadata.tags.contains("контроль"))
        #expect(metadata.tags.contains("иллюзия порядка"))
        #expect(metadata.tags.contains("рождение бунта"))
        #expect(metadata.tags.contains("киноэссе"))
        #expect(metadata.tags.contains("смысл фильма"))
    }

    @Test("Godfather generates rich, distinct crime/family metadata with acts, beats and chapters")
    func testGodfatherAdaptiveMetadata() {
        let metadata = LongformMetadataGenerator.generate(
            movieTitle: "Крестный отец",
            concept: godfatherConcept,
            arc: godfatherArc
        )

        // Title: author hook + concept word + movie title
        #expect(metadata.title.contains("Крестный отец"))
        #expect(metadata.title.contains("Семья"))
        #expect(metadata.title.contains("Настоящая власть всегда говорит тихо"))

        // Description: manifesto + arc.summary + all acts with beats + chapters + fair use + hashtags
        #expect(metadata.description.contains("Крестный отец"))
        #expect(metadata.description.contains("Семья"))
        #expect(metadata.description.contains(godfatherConcept.tagline))
        #expect(metadata.description.contains(godfatherConcept.philosophicalPremise))
        #expect(metadata.description.contains(godfatherArc.summary))
        #expect(metadata.description.contains("Бремя долга"))
        #expect(metadata.description.contains("Точка невозврата"))
        #expect(metadata.description.contains("Цена власти"))
        #expect(metadata.description.contains("Катарсис и холод"))
        #expect(metadata.description.contains("Покушение на дона Вито"))
        #expect(metadata.description.contains("Таймкоды:"))
        #expect(metadata.description.contains("00:00 — Вступление: Семья"))
        #expect(metadata.description.contains("Fair Use"))
        #expect(metadata.description.contains("#крестныйотец"))
        #expect(metadata.description.contains("#семья"))

        // Pinned comment: moral dilemma question tailored to Godfather
        #expect(metadata.pinnedComment.contains(godfatherConcept.tagline))
        #expect(metadata.pinnedComment.contains("Крестном отце") || metadata.pinnedComment.contains("Крестный отец"))
        #expect(metadata.pinnedComment.contains("семья") || metadata.pinnedComment.contains("семьи"))
        #expect(metadata.pinnedComment.contains("Поделитесь своими мыслями в комментариях 👇"))

        // Tags
        #expect(metadata.tags.contains("крестный отец"))
        #expect(metadata.tags.contains("крестный отец разбор"))
        #expect(metadata.tags.contains("семья"))
        #expect(metadata.tags.contains("бремя долга"))
        #expect(metadata.tags.contains("точка невозврата"))
        #expect(metadata.tags.contains("киноэссе"))
    }

    @Test("Fight Club and Godfather generate completely distinct metadata")
    func testFightClubAndGodfatherAreDistinct() {
        let fc = LongformMetadataGenerator.generate(
            movieTitle: "Бойцовский клуб",
            concept: fightClubConcept,
            arc: fightClubArc
        )
        let gf = LongformMetadataGenerator.generate(
            movieTitle: "Крестный отец",
            concept: godfatherConcept,
            arc: godfatherArc
        )

        #expect(fc.title != gf.title)
        #expect(fc.description != gf.description)
        #expect(fc.pinnedComment != gf.pinnedComment)
        #expect(fc.tags != gf.tags)
    }

    @Test("Garbage movie title gracefully falls back without leaking garbage string")
    func testGarbageMovieTitleFallback() {
        let garbageTitle = "shortcast_temp_render"
        let arc = LongformNarrativeArc(
            movieTitle: garbageTitle,
            concept: fightClubConcept,
            acts: fightClubArc.acts,
            summary: "Универсальный разбор иллюзии контроля.",
            mood: "dark"
        )

        let metadata = LongformMetadataGenerator.generate(
            movieTitle: garbageTitle,
            concept: fightClubConcept,
            arc: arc
        )

        #expect(!metadata.title.contains(garbageTitle))
        #expect(!metadata.description.contains(garbageTitle))
        #expect(!metadata.pinnedComment.contains(garbageTitle))
        #expect(!metadata.tags.contains(garbageTitle.lowercased()))
        #expect(metadata.description.contains("этого произведения"))
        #expect(metadata.pinnedComment.contains("в этой истории"))
    }

    @Test("Empty movie title gracefully falls back without errors")
    func testEmptyMovieTitleFallback() {
        let arc = LongformNarrativeArc(
            movieTitle: "",
            concept: fightClubConcept,
            acts: fightClubArc.acts,
            summary: "Универсальный разбор иллюзии контроля.",
            mood: "dark"
        )

        let metadata = LongformMetadataGenerator.generate(
            movieTitle: "",
            concept: fightClubConcept,
            arc: arc
        )

        #expect(metadata.description.contains("этого произведения"))
        #expect(metadata.pinnedComment.contains("в этой истории"))
    }

    @Test("Dependency injection via LongformMetadataEngine allows custom strategies (SOLID OCP & DIP)")
    func testCustomMetadataEngineInjection() {
        struct MockTitleGenerator: LongformTitleGenerating {
            func generateTitle(movieTitle: String, concept: ThematicConcept, arc: LongformNarrativeArc) -> String {
                "CUSTOM TITLE FOR: \(movieTitle)"
            }
        }

        let engine = LongformMetadataEngine(titleGenerator: MockTitleGenerator())
        let metadata = engine.generate(
            movieTitle: "Бойцовский клуб",
            concept: fightClubConcept,
            arc: fightClubArc
        )

        #expect(metadata.title == "CUSTOM TITLE FOR: Бойцовский клуб")
        #expect(metadata.description.contains("Бойцовский клуб"))
    }
}
