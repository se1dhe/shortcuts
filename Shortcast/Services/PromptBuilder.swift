import Foundation

/// Assembles the full prompt handed to Gemma 4 alongside the video frames and
/// audio: the bundled `social-content-coach` skill, the creator's style, the
/// language instruction, and a strict JSON output contract.
enum PromptBuilder {

    /// Loads the bundled `social-content-coach.md` with locale suffix if available.
    /// Falls back to the base file, then to a terse built-in brief.
    static func coachDocument(languageOverride: String = "") -> String {
        let lang = MomentFinderService.resolvedPromptLanguage(languageOverride)
        let suffix: String
        switch lang {
        case .ru: suffix = ".ru"
        case .uk: suffix = ".uk"
        case .en: suffix = ""
        }
        if !suffix.isEmpty,
           let url = Bundle.main.url(forResource: "social-content-coach\(suffix)", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        if let url = Bundle.main.url(forResource: "social-content-coach", withExtension: "md"),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text
        }
        return fallbackCoach(language: languageOverride)
    }

    static func buildPrompt(languageOverride: String, styleExamples: String,
                            videoTitle: String = "", videoDescription: String = "") -> String {
        buildPrompt(
            coach: coachDocument(languageOverride: languageOverride),
            languageOverride: languageOverride,
            styleExamples: styleExamples,
            videoTitle: videoTitle, videoDescription: videoDescription)
    }

    /// Same as `buildPrompt(languageOverride:styleExamples:)` but with the coach
    /// document supplied directly — used by tests / the probe tool.
    static func buildPrompt(coach: String, languageOverride: String, styleExamples: String,
                            videoTitle: String = "", videoDescription: String = "") -> String {
        assemble(coach: coach, languageOverride: languageOverride,
                 styleExamples: styleExamples, task: taskAndSchema(for: languageOverride),
                 videoTitle: videoTitle, videoDescription: videoDescription)
    }

    /// Captioning prompt for the text-only Copywriter (Qwen). Same coach, style
    /// and JSON contract, but the content is the clip's transcript, not video.
    static func buildTranscriptPrompt(languageOverride: String, styleExamples: String,
                                       videoTitle: String = "", videoDescription: String = "") -> String {
        assemble(coach: coachDocument(languageOverride: languageOverride), languageOverride: languageOverride,
                 styleExamples: styleExamples, task: transcriptTaskAndSchema(for: languageOverride),
                 videoTitle: videoTitle, videoDescription: videoDescription)
    }

    // MARK: - Assembly

    private static func assemble(coach: String, languageOverride: String,
                                 styleExamples: String, task: String,
                                 videoTitle: String = "", videoDescription: String = "") -> String {
        var sections: [String] = [coach]
        let lang = MomentFinderService.resolvedPromptLanguage(languageOverride)

        sections.append(lang.languageInstruction(languageOverride))

        let style = styleExamples.trimmed
        if !style.isEmpty {
            sections.append(lang.styleSection(style))
        }

        if !videoTitle.isEmpty {
            sections.append(lang.videoContextSection(videoTitle, description: videoDescription))
        }

        sections.append(task)
        return sections.joined(separator: "\n\n---\n\n")
    }

    // MARK: - Prompt Language Support

    private static func resolvedLanguage(_ raw: String?) -> MomentFinderService.PromptLanguage {
        MomentFinderService.resolvedPromptLanguage(raw)
    }

    // MARK: - Task & Schema

    private static func taskAndSchema(for languageOverride: String) -> String {
        resolvedLanguage(languageOverride).taskAndSchema
    }

    private static func transcriptTaskAndSchema(for languageOverride: String) -> String {
        resolvedLanguage(languageOverride).transcriptTaskAndSchema
    }

    // MARK: - Fallback Coach

    private static func fallbackCoach(language: String) -> String {
        resolvedLanguage(language).fallbackCoach
    }
}

// MARK: - PromptBuilder Language Extensions

extension MomentFinderService.PromptLanguage {

    var languageInstruction: (_ languageOverride: String) -> String {
        switch self {
        case .en:
            return { lang in
                let language = lang.trimmed
                if language.isEmpty {
                    return """
                    ## Output language
                    Write every field in the SAME language that is spoken in the clip — \
                    detect it. Do not translate it to English.
                    """
                } else {
                    return """
                    ## Output language
                    Write every field in this language: \(language). \
                    Use it regardless of the language spoken in the clip.
                    """
                }
            }
        case .ru:
            return { lang in
                let language = lang.trimmed
                if language.isEmpty {
                    return """
                    ## Язык вывода
                    Каждое поле пиши на том же языке, на котором говорят в клипе — \
                    определи его сам. Не переводи на английский.
                    """
                } else {
                    return """
                    ## Язык вывода
                    Каждое поле пиши на этом языке: \(language). \
                    Используй его вне зависимости от языка, на котором говорят в клипе.
                    """
                }
            }
        case .uk:
            return { lang in
                let language = lang.trimmed
                if language.isEmpty {
                    return """
                    ## Мова виводу
                    Кожне поле пиши тією ж мовою, якою говорять у кліпі — \
                    визнач її самостійно. Не перекладай англійською.
                    """
                } else {
                    return """
                    ## Мова виводу
                    Кожне поле пиши цією мовою: \(language). \
                    Використовуй її незалежно від мови, якою говорять у кліпі.
                    """
                }
            }
        }
    }

    var styleSection: (_ examples: String) -> String {
        switch self {
        case .en:
            return { examples in """
                ## The creator's own voice — match this style
                Below are examples of captions this creator likes. Mirror their tone, \
                rhythm, emoji use and formatting:

                \(examples)
                """ }
        case .ru:
            return { examples in """
                ## Голос автора — повторяй этот стиль
                Ниже примеры подписей, которые нравятся автору. Копируй тон, \
                темп, эмодзи и форматирование:

                \(examples)
                """ }
        case .uk:
            return { examples in """
                ## Голос автора — повторюй цей стиль
                Нижче приклади підписів, які подобаються автору. Копіюй тон, \
                темп, емодзі та форматування:

                \(examples)
                """ }
        }
    }

    var taskAndSchema: String {
        switch self {
        case .en:
            return """
            ## Your task

            You have been given a short vertical video — its sampled frames and its \
            audio track. Watch and listen to it, then write a publishing package for \
            three platforms: TikTok, Instagram Reels and YouTube Shorts.

            Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
            out loud. Use exactly this shape:

            {
              "language": "<BCP-47 code of the language you wrote in, e.g. es, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<scroll-stopping first line, 25 characters or fewer>",
                  "description": "<short, punchy caption>",
                  "hashtags": ["tag", "tag", "tag"]
                },
                {
                  "platform": "instagram",
                  "hook": "<strong first line, 25 characters or fewer>",
                  "description": "<2-4 short paragraphs, storytelling, ending with a call to action>",
                  "hashtags": ["...20 to 30 tags, mixing big and niche reach..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<concise, search-friendly title, 25 characters>",
                  "description": "<keyword-rich description written for search>",
                  "hashtags": ["...3 to 5 tags..."]
                }
              ]
            }

            Rules:
            - hashtags are plain words, with NO leading '#'.
            - Each hashtag must be unique — never repeat the same tag.
            - Exactly three variants, one per platform, in the order above.
            - Never invent facts that are not visible or audible in the video.
            - Output the JSON object and nothing else.
            """
        case .ru:
            return """
            ## Задача

            Тебе дан короткий вертикальный ролик — его кадры и звуковая дорожка. \
            Посмотри и послушай, затем напиши пакет публикации для трёх платформ: \
            TikTok, Instagram Reels и YouTube Shorts.

            Верни ТОЛЬКО один JSON-объект. Никакого текста вокруг, без markdown-блоков. \
            Используй строго такую структуру:

            {
              "language": "<BCP-47 код языка, на котором ты написал, например ru, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<умный, сжатый интригующий хук из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<короткий, броский текст подписи>",
                  "hashtags": ["тег", "тег", "тег"]
                },
                {
                  "platform": "instagram",
                  "hook": "<умный, сжатый интригующий хук из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<2-4 коротких абзаца, сторителлинг, заканчивается призывом к действию>",
                  "hashtags": ["...20-30 тегов, смесь широкого охвата и ниши..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<умный, поисковый заголовок из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<описание с ключевыми словами для поиска>",
                  "hashtags": ["...3-5 тегов..."]
                }
              ]
            }

            Правила:
            - хештеги — это просто слова, БЕЗ ведущего '#'.
            - Каждый хештег должен быть уникальным — не повторяй один и тот же.
            - Ровно три варианта, по одному на платформу, в указанном порядке.
            - Не придумывай факты, которых нет в видео.
            - Выведи только JSON-объект и ничего больше.
            """
        case .uk:
            return """
            ## Завдання

            Тобі дано короткий вертикальний ролик — його кадри та звукова доріжка. \
            Подивись та послухай, потім напиши пакет публікації для трьох платформ: \
            TikTok, Instagram Reels та YouTube Shorts.

            Поверни ТІЛЬКИ один JSON-об'єкт. Жодного тексту навколо, без markdown-блоків. \
            Використовуй строго таку структуру:

            {
              "language": "<BCP-47 код мови, якою ти написав, наприклад uk, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<перша фраза, яка зупиняє скролл, максимум 50 символів>",
                  "description": "<короткий, броский текст підпису>",
                  "hashtags": ["тег", "тег", "тег"]
                },
                {
                  "platform": "instagram",
                  "hook": "<сильна перша строка, максимум 50 символів>",
                  "description": "<2-4 коротких абзаци, сторітелінг, закінчується закликом до дії>",
                  "hashtags": ["...20-30 тегів, суміш широкого охоплення та ніші..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<лаконічний, пошуковий заголовок, 50 символів>",
                  "description": "<опис з ключовими словами для пошуку>",
                  "hashtags": ["...3-5 тегів..."]
                }
              ]
            }

            Правила:
            - хештеги — це просто слова, БЕЗ ведучого '#'.
            - Кожен хештег має бути унікальним — не повторюй один і той самий.
            - Рівно три варіанти, по одному на платформу, у вказаному порядку.
            - Не вигадуй факти, яких немає у відео.
            - Виведи тільки JSON-об'єкт і нічого більше.
            """
        }
    }

    var transcriptTaskAndSchema: String {
        switch self {
        case .en:
            return """
            ## Your task

            You have been given the transcript of one short vertical clip (it was cut \
            from a longer video). A suggested hook line is provided. Using the \
            transcript, write a publishing package for three platforms: TikTok, \
            Instagram Reels and YouTube Shorts.

            Return ONLY a single JSON object. No prose, no markdown fences, no thinking \
            out loud. Use exactly this shape:

            {
              "language": "<BCP-47 code of the language you wrote in, e.g. es, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<scroll-stopping first line, 25 characters or fewer>",
                  "description": "<short, punchy caption>",
                  "hashtags": ["tag", "tag", "tag"]
                },
                {
                  "platform": "instagram",
                  "hook": "<strong first line, 25 characters or fewer>",
                  "description": "<2-4 short paragraphs, storytelling, ending with a call to action>",
                  "hashtags": ["...20 to 30 tags, mixing big and niche reach..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<concise, search-friendly title, 25 characters>",
                  "description": "<keyword-rich description written for search>",
                  "hashtags": ["...3 to 5 tags..."]
                }
              ]
            }

            Rules:
            - hashtags are plain words, with NO leading '#'.
            - Each hashtag must be unique — never repeat the same tag.
            - Exactly three variants, one per platform, in the order above.
            - Never invent facts that are not in the transcript.
            - Output the JSON object and nothing else.
            """
        case .ru:
            return """
            ## Задача

            Тебе дана транскрипция одного короткого вертикального клипа (он был вырезан \
            из длинного видео). Предложен хук. Используя транскрипцию, напиши \
            пакет публикации для трёх платформ: TikTok, Instagram Reels и YouTube Shorts.

            Верни ТОЛЬКО один JSON-объект. Никакого текста вокруг, без markdown-блоков. \
            Используй строго такую структуру:

            {
              "language": "<BCP-47 код языка, на котором ты написал, например ru, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<умный, сжатый интригующий хук из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<короткий, броский текст подписи>",
                  "hashtags": ["тег", "тег", "тег"]
                },
                {
                  "platform": "instagram",
                  "hook": "<умный, сжатый интригующий хук из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<2-4 коротких абзаца, сторителлинг, заканчивается призывом к действию>",
                  "hashtags": ["...20-30 тегов, смесь широкого охвата и ниши..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<умный, поисковый заголовок из 5-7 слов на основе транскрипции, БЕЗ названия фильма>",
                  "description": "<описание с ключевыми словами для поиска>",
                  "hashtags": ["...3-5 тегов..."]
                }
              ]
            }

            Правила:
            - хештеги — это просто слова, БЕЗ ведущего '#'.
            - Каждый хештег должен быть уникальным — не повторяй один и тот же.
            - Ровно три варианта, по одному на платформу, в указанном порядке.
            - Не придумывай факты, которых нет в транскрипции.
            - Выведи только JSON-объект и ничего больше.
            """
        case .uk:
            return """
            ## Завдання

            Тобі дана транскрипція одного короткого вертикального кліпу (він був вирізаний \
            з довгого відео). Запропонований хук. Використовуючи транскрипцію, напиши \
            пакет публікації для трьох платформ: TikTok, Instagram Reels та YouTube Shorts.

            Поверни ТІЛЬКИ один JSON-об'єкт. Жодного тексту навколо, без markdown-блоків. \
            Використовуй строго таку структуру:

            {
              "language": "<BCP-47 код мови, якою ти написав, наприклад uk, en>",
              "variants": [
                {
                  "platform": "tiktok",
                  "hook": "<перша фраза, яка зупиняє скролл, максимум 50 символів>",
                  "description": "<короткий, броский текст підпису>",
                  "hashtags": ["тег", "тег", "тег"]
                },
                {
                  "platform": "instagram",
                  "hook": "<сильна перша строка, максимум 50 символів>",
                  "description": "<2-4 коротких абзаци, сторітелінг, закінчується закликом до дії>",
                  "hashtags": ["...20-30 тегів, суміш широкого охоплення та ніші..."]
                },
                {
                  "platform": "youtube",
                  "hook": "<лаконічний, пошуковий заголовок, 50 символів>",
                  "description": "<опис з ключовими словами для пошуку>",
                  "hashtags": ["...3-5 тегів..."]
                }
              ]
            }

            Правила:
            - хештеги — це просто слова, БЕЗ ведучого '#'.
            - Кожен хештег має бути унікальним — не повторюй один і той самий.
            - Рівно три варіанти, по одному на платформу, у вказаному порядку.
            - Не вигадуй факти, яких немає в транскрипції.
            - Виведи тільки JSON-об'єкт і нічого більше.
            """
        }
    }

    var fallbackCoach: String {
        switch self {
        case .en:
            return """
            # social-content-coach (fallback)

            You are an expert short-form social copywriter. Write hooks that stop the \
            scroll in the first second, captions that are easy to skim, and hashtags \
            that match the actual content. TikTok rewards punchy energy, Instagram \
            rewards storytelling and a clear call to action, YouTube Shorts rewards \
            clear, searchable titles.
            """
        case .ru:
            return """
            # social-content-coach (запасной)

            Ты — экспертный копирайтер для short-формата. Пиши хуки, которые \
            останавливают скролл в первую секунду, подписи, которые легко просматривать, \
            и хештеги, которые соответствуют реальному контенту. TikTok любит дерзкую \
            энергию, Instagram — сторителлинг и чёткий призыв к действию, YouTube Shorts — \
            ясные, поисковые заголовки.
            """
        case .uk:
            return """
            # social-content-coach (запасний)

            Ти — експертний копірайтер для short-формату. Пиши хуки, які \
            зупиняють скролл у першу секунду, підписи, які легко просматривати, \
            та хештеги, що відповідають реальному контенту. TikTok любить гостру \
            енергію, Instagram — сторітелінг та чіткий заклик до дії, YouTube Shorts — \
            ясні, пошукові заголовки.
            """
        }
    }

    // MARK: - Video context

    func videoContextSection(_ title: String, description: String) -> String {
        switch self {
        case .en:
            var s = "## Video context\n\nTitle: \(title)"
            if !description.isEmpty { s += "\nDescription: \(description)" }
            s += "\nThe viewer chose this video for this topic. Use this context to write hooks and captions that are relevant and specific."
            return s
        case .ru:
            var s = "## Контекст видео\n\nНазвание: \(title)"
            if !description.isEmpty { s += "\nОписание: \(description)" }
            s += "\nЗритель выбрал это видео ради этой темы. Используй этот контекст, чтобы писать хуки и подписи, релевантные и конкретные."
            return s
        case .uk:
            var s = "## Контекст відео\n\nНазва: \(title)"
            if !description.isEmpty { s += "\nОпис: \(description)" }
            s += "\nГлядач обрав це відео заради цієї теми. Використовуй цей контекст, щоб писати хуки та підписи, релевантні та конкретні."
            return s
        }
    }
}
