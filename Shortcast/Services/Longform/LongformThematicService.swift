import Foundation
import MLXLMCommon

/// Реализация ThematicConceptDiscovering для выявления тем Shortcast Cinema
final class LongformThematicService: ThematicConceptDiscovering, Sendable {

    /// Подсказка для LLM в роли сценариста-философа и вирусного YouTube-режиссера
    static func thematicSystemPrompt(movieTitle: String) -> String {
        """
        Ты — элитный кинорежиссер, драматург и автор глубоких философских видео-эссе на YouTube для Shortcast Cinema.
        Твоя задача — проанализировать сценарий фильма "\(movieTitle)" и выявить СТРОГО от 4 до 7 фундаментальных философских тем / лейтмотивов фильма.

        Каждая тема строится вокруг ОДНОГО мощного слова (Концепта):
        Примеры слов из эталонов: "Эго", "Обман", "Страх", "Иллюзия", "Терпение", "Гениальность", "Характер", "Жалость", "Власть", "Одиночество", "Предательство", "Семья", "Гнев".

        ФОРМАТ ВЫВОДА:
        Ответь СТРОГО валидным JSON-массивом объектов без лишних предисловий и комментариев:
        [
          {
            "word": "Эго",
            "tagline": "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей собственной голове.",
            "philosophicalPremise": "Единственный способ освободиться — признать, что твой враг — это не другие люди, а ты сам.",
            "suggestedTitle": "Этот фильм уничтожит твою гордость.",
            "accentColorHex": "#F5D020"
          }
        ]

        ТРЕБОВАНИЯ К ПОЛЯМ:
        - "word": СТРОГО 1 слово с большой буквы (максимум 2 слова, если неразрывно связаны).
        - "tagline": Краткая хлесткая мысль (1 предложение).
        - "philosophicalPremise": Глубокий тезис о человеческой психологии и цене успеха/власти.
        - "suggestedTitle": Вирусный заголовок YouTube от 2-го лица ("Ты...", "Иногда, чтобы...").
        - "accentColorHex": "#F5D020" (золотисто-желтый) или "#E50914" (красный для тем агрессии/кризиса).
        """
    }

    func discoverConcepts(from transcript: Transcript, movieTitle: String, modelManager: ModelManager? = nil) async throws -> [ThematicConcept] {
        // 1. Проверяем, есть ли для фильма авторские эталоны тем (Револьвер, Бойцовский клуб, Крестный отец и др.)
        let bespoke = bespokeConcepts(for: movieTitle)
        if !bespoke.isEmpty {
            return bespoke
        }

        let sampleText = transcript.segments.prefix(100).map(\.text).joined(separator: "\n")

        // 2. Для остальных фильмов генерируем уникальные концепты через модель Director
        if let mm = modelManager, !sampleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            await mm.prepareDirectorIfNeeded()
            let aiConcepts = await mm.momentFinder.generateThematicConcepts(transcriptSample: sampleText, movieTitle: movieTitle)
            if aiConcepts.count >= 3 {
                return aiConcepts
            }
        }

        // 3. Фолбэк на кинематографические эталоны фильма
        return fallbackConcepts(for: movieTitle)
    }

    /// Парсит структурированный ответ модели в список ThematicConcept
    static func parseConcepts(from jsonText: String) -> [ThematicConcept] {
        var clean = jsonText.trimmingCharacters(in: .whitespacesAndNewlines)
        if let start = clean.range(of: "["),
           let end = clean.range(of: "]", options: .backwards),
           start.lowerBound <= end.lowerBound {
            clean = String(clean[start.lowerBound..<end.upperBound])
        }

        struct RawConcept: Decodable {
            let word: String?
            let tagline: String?
            let philosophicalPremise: String?
            let suggestedTitle: String?
            let accentColorHex: String?
        }

        if let data = clean.data(using: .utf8),
           let rawList = try? JSONDecoder().decode([RawConcept].self, from: data) {
            let parsed = rawList.compactMap { item -> ThematicConcept? in
                guard let w = item.word?.trimmingCharacters(in: .whitespacesAndNewlines), !w.isEmpty,
                      let tag = item.tagline?.trimmingCharacters(in: .whitespacesAndNewlines), !tag.isEmpty,
                      let prem = item.philosophicalPremise?.trimmingCharacters(in: .whitespacesAndNewlines), !prem.isEmpty,
                      let title = item.suggestedTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty
                else { return nil }
                return ThematicConcept(
                    word: w,
                    tagline: tag,
                    philosophicalPremise: prem,
                    suggestedTitle: title,
                    accentColorHex: item.accentColorHex ?? "#F5D020"
                )
            }
            if !parsed.isEmpty {
                return parsed
            }
        }

        return []
    }

    /// Высококачественные авторские эталонные темы для ключевых шедевров кинематографа
    func bespokeConcepts(for movieTitle: String) -> [ThematicConcept] {
        let titleLower = movieTitle.lowercased()

        if titleLower.contains("револьвер") || titleLower.contains("revolver") {
            return [
                ThematicConcept(
                    word: "Эго",
                    tagline: "Твой главный враг прячется там, где ты меньше всего будешь его искать — в твоей голове.",
                    philosophicalPremise: "Единственный способ победить внутреннего врага — перестать кормить собственную гордость.",
                    suggestedTitle: "Этот фильм уничтожит твою гордость. Философия Револьвера",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Обман",
                    tagline: "Единственный способ стать умнее — играть с более умным противником.",
                    philosophicalPremise: "Первое правило шахмат: защищай свои интересы, понимая истинную игру манипулятора.",
                    suggestedTitle: "Ты проиграешь, если не поймешь эту разводку.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Страх",
                    tagline: "Страх потери контроля разрушает человека быстрее любой пули.",
                    philosophicalPremise: "Пока ты боишься потерять то, чем дорожишь — тобой управляет кто-то другой.",
                    suggestedTitle: "Твой главный страх управляет каждым твоим решением.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Иллюзия",
                    tagline: "Ты думаешь, что контролируешь ситуацию, но ситуация контролирует тебя.",
                    philosophicalPremise: "Иллюзия выбора — самое изощренное оружие против человека, уверенного в своей правоте.",
                    suggestedTitle: "Ты живёшь в иллюзии контроля. Жесткая правда.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Жадность",
                    tagline: "Жадность ослепляет разум, заставляя верить в собственную неуязвимость.",
                    philosophicalPremise: "Деньги не спасают от внутренней пустоты, они лишь делают финал неизбежным.",
                    suggestedTitle: "Алчность всегда требует платы кровью.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Свобода",
                    tagline: "Ты свободен только тогда, когда готов отказаться от того, за что держишься сильнее всего.",
                    philosophicalPremise: "Истинная свобода начинается в тот момент, когда тебе больше нечего терять и нечего доказывать.",
                    suggestedTitle: "Как стать по-настоящему свободным. Урок Револьвера",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("бойцовск") || titleLower.contains("fight club") {
            return [
                ThematicConcept(
                    word: "Бунт",
                    tagline: "Вещи, которыми ты владеешь, в конце концов начинают владеть тобой.",
                    philosophicalPremise: "Отказ от иллюзорного комфорта общества потребления ради пробуждения настоящей жизни.",
                    suggestedTitle: "Вещи, которыми ты владеешь, овладели тобой.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Боль",
                    tagline: "Лишь утратив всё до конца, мы обретаем истинную свободу.",
                    philosophicalPremise: "Физическая боль как единственный способ вырваться из оцепенения современного мира.",
                    suggestedTitle: "Лишь потеряв всё, ты поймёшь, кто ты есть.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Двойственность",
                    tagline: "Кто ты на самом деле, когда никто не видит?",
                    philosophicalPremise: "Раскол личности между тихим конформистом и разрушительным лидером.",
                    suggestedTitle: "Внутри тебя живёт тот, кого ты боишься.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Свобода",
                    tagline: "Самосовершенствование — это онанизм. Саморазрушение — вот ответ.",
                    philosophicalPremise: "Освобождение через разрушение навязанных социальных ожиданий и статусов.",
                    suggestedTitle: "Прекрати пытаться нравиться этому миру.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("крестн") || titleLower.contains("крёстн") || titleLower.contains("godfather") {
            return [
                ThematicConcept(
                    word: "Власть",
                    tagline: "Никогда не сердись и не угрожай. Заставь людей рассуждать здраво.",
                    philosophicalPremise: "Настоящая сила заключается в хладнокровии и умении предвидеть последствия каждого слова.",
                    suggestedTitle: "Настоящая власть всегда говорит тихо.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Семья",
                    tagline: "Мужчина, который не уделяет времени семье, никогда не станет настоящим мужчиной.",
                    philosophicalPremise: "Вся империя строится ради защиты близких, но сама же их и пожирает.",
                    suggestedTitle: "Единственное, ради чего стоит жить.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Преданность",
                    tagline: "Держи друзей близко, а врагов еще ближе.",
                    philosophicalPremise: "Цена предательства всегда неизбежна, а преданность проверяется в кризис.",
                    suggestedTitle: "Никогда не доверяй тому, кто однажды предал.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Холоднокровие",
                    tagline: "Это ничего личного. Это просто бизнес.",
                    philosophicalPremise: "Эмоции в принятии судьбоносных решений ведут к неминуемой гибели.",
                    suggestedTitle: "Твои эмоции — твой главный враг.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("рыцарь") || titleLower.contains("dark knight") {
            return [
                ThematicConcept(
                    word: "Хаос",
                    tagline: "Некоторым людям просто хочется видеть мир в огне.",
                    philosophicalPremise: "Разум бессилен против хаоса, если у человека нет твердого морального компаса.",
                    suggestedTitle: "Почему порядок всегда проигрывает хаосу.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Символ",
                    tagline: "Либо ты умираешь героем, либо живешь до тех пор, пока не станешь злодеем.",
                    philosophicalPremise: "Тяжесть быть защитником города, готовым принять всеобщее осуждение ради высшего блага.",
                    suggestedTitle: "Ты умрёшь героем или станешь злодеем?",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Выбор",
                    tagline: "В самые темные времена люди показывают свою истинную суть.",
                    philosophicalPremise: "Нравственная дилемма: спасти себя или сохранить человечность перед лицом неминуемой гибели.",
                    suggestedTitle: "В критический момент каждый покажет свое лицо.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Тьма",
                    tagline: "Ночь темнее всего перед самым рассветом.",
                    philosophicalPremise: "Способность выдержать удары судьбы и ненависть толпы ради спасения тех, кто тебя не понимает.",
                    suggestedTitle: "Тот, кто принимает удар за всех.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("сопрано") || titleLower.contains("soprano") {
            return [
                ThematicConcept(
                    word: "Жалость",
                    tagline: "Тони может контролировать всё, кроме собственной пустоты.",
                    philosophicalPremise: "Есть вещи, от которых не спасает ни сила, ни статус, ни деньги — пустота внутри.",
                    suggestedTitle: "Однажды ты поймёшь, что всё это тебя не спасло.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Характер",
                    tagline: "В этом мире нельзя казаться слабым ни на секунду.",
                    philosophicalPremise: "Чем выше ты поднимаешься, тем больше вокруг тех, кто рядом только из страха или выгоды.",
                    suggestedTitle: "В этом мире нельзя быть слабым.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Одиночество",
                    tagline: "Когда ты номер один — в итоге со всеми проблемами остаешься один.",
                    philosophicalPremise: "Власть требует платы, которую большинство не способно вынести.",
                    suggestedTitle: "Цена того, чтобы быть первым.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Семья",
                    tagline: "Ты пытаешься защитить близких от мира, но защищать их приходится от тебя.",
                    philosophicalPremise: "Лицемерие человека, прикрывающего криминал любовью к семье.",
                    suggestedTitle: "Самый тяжелый груз, который ты несешь.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("левша") || titleLower.contains("southpaw") {
            return [
                ThematicConcept(
                    word: "Трудность",
                    tagline: "Ты поймешь, насколько ты силен, только когда потеряешь всё.",
                    philosophicalPremise: "Можно потерять титул, дом и семью, но подняться ради ребенка.",
                    suggestedTitle: "Ты поймешь, насколько ты силен, только когда потеряешь всё.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Гнев",
                    tagline: "Ярость делает тебя опасным, но дисциплина делает тебя непобедимым.",
                    philosophicalPremise: "Твой главный враг на ринге — это ты сам, пока ты не обуздаешь свою боль.",
                    suggestedTitle: "Твой гнев уничтожит тебя, если ты не научишься этому.",
                    accentColorHex: "#E50914"
                ),
                ThematicConcept(
                    word: "Возвращение",
                    tagline: "Падение — это не финал, а начало пути обратно.",
                    philosophicalPremise: "Настоящий чемпион определяется не тем, как он бьет, а тем, как держит удар.",
                    suggestedTitle: "Никогда не сдавайся, когда остался один.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        if titleLower.contains("социальн") || titleLower.contains("social network") {
            return [
                ThematicConcept(
                    word: "Гениальность",
                    tagline: "Иногда тебя не понимают просто потому, что ты видишь будущее.",
                    philosophicalPremise: "Марк создал сеть для сотен миллионов людей, но остался абсолютно одинок.",
                    suggestedTitle: "Иногда, чтобы победить, нужно перестать быть удобным.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Фокус",
                    tagline: "Ты не можешь завести 500 миллионов друзей, не нажив несколько врагов.",
                    philosophicalPremise: "Бескомпромиссная преданность идее требует безжалостного отсечения лишнего.",
                    suggestedTitle: "Ты проиграешь, если будешь пытаться нравиться всем.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Предательство",
                    tagline: "В бизнесе дружба стоит дешевле, чем развитие продукта.",
                    philosophicalPremise: "Трагедия тех, кто идет до конца — оставить позади тех, с кем начинал.",
                    suggestedTitle: "Цена масштаба, о которой никто не предупреждает.",
                    accentColorHex: "#E50914"
                )
            ]
        }

        if titleLower.contains("счасть") || titleLower.contains("happyness") {
            return [
                ThematicConcept(
                    word: "Терпение",
                    tagline: "Способность выдержать период, когда ничего не получается.",
                    philosophicalPremise: "Пока ты продолжаешь идти — история еще не закончена.",
                    suggestedTitle: "Ты никогда не узнаешь, насколько был близок!",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Отец",
                    tagline: "Обещание сыну, которое невозможно нарушить.",
                    philosophicalPremise: "Никому не позволяй говорить, что ты чего-то не можешь. Даже мне.",
                    suggestedTitle: "Защищай свою мечту любой ценой.",
                    accentColorHex: "#F5D020"
                ),
                ThematicConcept(
                    word: "Надежда",
                    tagline: "Эта маленькая часть моей жизни называется Счастье.",
                    philosophicalPremise: "Достоинство человека проверяется в моменты, когда у него нет даже пяти долларов.",
                    suggestedTitle: "Ты поймешь это только пройдя через ад.",
                    accentColorHex: "#F5D020"
                )
            ]
        }

        return []
    }

    /// Фолбэк на кинематографические эталоны фильма
    func fallbackConcepts(for movieTitle: String) -> [ThematicConcept] {
        let bespoke = bespokeConcepts(for: movieTitle)
        if !bespoke.isEmpty {
            return bespoke
        }
        return universalFallbackConcepts()
    }

    /// Универсальный кинематографический эталон
    func universalFallbackConcepts() -> [ThematicConcept] {
        return [
            ThematicConcept(
                word: "Характер",
                tagline: "Способность стоять до конца, когда весь мир против тебя.",
                philosophicalPremise: "Истинная сила проявляется в моменты, когда от тебя ничего не ждут.",
                suggestedTitle: "В этом мире нельзя быть слабым.",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Терпение",
                tagline: "Выдержка в самый темный час определяет победителя.",
                philosophicalPremise: "Большинство сдается за шаг до того, как всё изменится.",
                suggestedTitle: "Ты никогда не узнаешь, насколько был близок!",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Гениальность",
                tagline: "Одиночество того, кто видит дальше других.",
                philosophicalPremise: "Чтобы победить систему, нужно перестать играть по ее правилам.",
                suggestedTitle: "Иногда, чтобы победить, нужно перестать быть удобным.",
                accentColorHex: "#F5D020"
            ),
            ThematicConcept(
                word: "Власть",
                tagline: "Цена контроля над собственной судьбой и чужими жизнями.",
                philosophicalPremise: "Каждое завоеванное преимущество увеличивает тяжесть расплаты.",
                suggestedTitle: "Цена того, чтобы быть во главе.",
                accentColorHex: "#E50914"
            ),
            ThematicConcept(
                word: "Одиночество",
                tagline: "Когда ты на вершине, разделить победу часто оказывается не с кем.",
                philosophicalPremise: "Истинный путь лидера полон изоляции и трудного выбора.",
                suggestedTitle: "Правда о вершине, о которой молчат.",
                accentColorHex: "#F5D020"
            )
        ]
    }
}
