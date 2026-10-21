# План исправления дефектов генерации Longform-эссе и архитектурного рефакторинга

> **Для исполнителей-агентов:** ОБЯЗАТЕЛЬНЫЙ НАВЫК: Используйте `superpowers:subagent-driven-development` (рекомендуется) или `superpowers:executing-plans` для пошаговой реализации плана. Шаги используют синтаксис чекбоксов (`- [ ]`) для отслеживания.

**Цель:** Устранить критические дефекты генерации кино-эссе (пустой Акт IV, опечатка «СПРАЖНІСТЬ», арабские галлюцинации LLM, затирание `longformResult` при перезагрузке, потеря правок субтитров), оживить LLM-титрование актов и привести кодовую базу в соответствие с принципами SOLID.

**Архитектура:** Разделение ответственности (SRP) в конвейере сборки видео через вынос композитора `LongformVideoCompositor`; внедрение лексической валидации и автокоррекции тем (`NSSpellChecker` + подключение `correctUkrainianWord`); переработка динамического балансирования 4-актной арки вместо жесткого отсечения коротких сцен; обеспечение надежной персистентности модели `FilmProject`.

**Стек технологий:** Swift 6, AVFoundation, CoreMedia, CoreAnimation, MLX Swift / Gemma-4 / Qwen, EBU R128 Loudnorm (ffmpeg), Apple Vision Framework, XCTest / Swift Testing.

**Спецификация:** [SHORTCAST_MASTERPLAN.md](file:///Users/se1dhe/projects/shortcast/SHORTCAST_MASTERPLAN.md)

## Глобальные ограничения

- Строго следовать принципам **SOLID** (Single Responsibility, Open/Closed, Liskov Substitution, Interface Segregation, Dependency Inversion).
- Сохранять полную потокобезопасность (`Sendable`, Swift Concurrency, `MainActor`).
- Целевые аудио-стандарты Shortcast Cinema: `-16.0 LUFS` интегрированная громкость, `-2.0 dBTP` True Peak.
- Язык всех текстов эссе, заголовков и метаданных: исключительно правильный украинский литературный язык (без русизмов, суржика и опечаток).
- Все существующие unit-тесты (185 тестов) должны продолжать проходить.

## Фокус проверки (Review Focus)

1. Десериализация целочисленных таймкодов LLM (например, `750` вместо `750.0`) не должна приводить к потере сцен.
2. Ни одна сцена короче 8 секунд не должна молча отбрасываться, если это оставляет акт пустым — сцена должна расширяться до контекстного минимума.
3. Опечатка в концепте (напр. `СПРАЖНІСТЬ`) должна автоматически исправляться спеллчекером/словарем до вывода на обложку и в видео.
4. При перезагрузке проекта ранее сгенерированный результат `longformResult` не должен затираться или обнуляться на диске.
5. Фильм любой стандартной длины (включая 90–120 мин) должен получать защиту от финальных титров.

---

### Задача 1: Исправление парсинга таймкодов и фильтрация чужих алфавитов в `LongformThematicService`

**Файлы:**
- Изменить: `Shortcast/Services/Longform/LongformThematicService.swift`
- Тест: `ShortcastTests/ThematicParsingTests.swift`

**Интерфейсы:**
- Потребляет: `JSONVariantParser.extractJSONObject`, `JSONVariantParser.deserializeTolerant`
- Производит: валидный `ThematicAnalysisResult` без некириллических символов и с корректно прочитанными таймкодами чисел любого типа (`Int`, `Double`, `NSNumber`).

- [ ] **Шаг 1: Написать падающий тест на парсинг целых чисел в `startTime`/`endTime` и отсечение арабских/латинских символов**

В `ShortcastTests/ThematicParsingTests.swift`:
```swift
@Test func parsesIntegerTimestampsInSelectedMoments() {
    let json = """
    {
      "reasoning": "Драматургічний розбір фільму...",
      "primaryConcept": {
        "word": "Свобода",
        "tagline": "Справжня свобода всередині тебе.",
        "suggestedTitle": "Ціна твоєї свободи",
        "accentColorHex": "#F5D020"
      },
      "selectedMoments": [
        {
          "startTime": 100,
          "endTime": 200,
          "reason": "Важлива сцена",
          "dramaticWeight": 0.8
        }
      ]
    }
    """
    let result = LongformThematicService.parseThematicAnalysis(from: json)
    #expect(result != nil)
    #expect(result?.selectedMoments.count == 1)
    #expect(result?.selectedMoments.first?.startTime == 100.0)
    #expect(result?.selectedMoments.first?.endTime == 200.0)
}

@Test func sanitizesNonCyrillicTokensFromReasoningAndMoments() {
    let json = """
    {
      "reasoning": "Розбір сюжету...",
      "primaryConcept": {
        "word": "Істина",
        "tagline": "Істина робить тебе вільним.",
        "suggestedTitle": "Пошук істини",
        "accentColorHex": "#F5D020"
      },
      "selectedMoments": [
        {
          "startTime": 10.0,
          "endTime": 30.0,
          "reason": "تعريف реплікантів як рабів",
          "dramaticWeight": 0.9
        }
      ]
    }
    """
    let result = LongformThematicService.parseThematicAnalysis(from: json)
    #expect(result != nil)
    #expect(result?.selectedMoments.first?.reason.contains("تعريف") == false)
}
```

- [ ] **Шаг 2: Запустить тест и убедиться в падении**

Запуск: `xcodebuild test -scheme Shortcast -only-testing:ShortcastTests/ThematicParsingTests`

- [ ] **Шаг 3: Реализовать поддержку `NSNumber`/`Int` и символьную санитизацию**

В `Shortcast/Services/Longform/LongformThematicService.swift`:
1. В `parseSelectedMoments` парсить числа через helper:
   ```swift
   private static func toDouble(_ value: Any?) -> Double? {
       if let d = value as? Double { return d }
       if let n = value as? NSNumber { return n.doubleValue }
       if let i = value as? Int { return Double(i) }
       return nil
   }
   ```
2. Очищать строки `reason` и `tagline` от символов посторонних алфавитов (арабский, иероглифы и т.п.):
   ```swift
   static func sanitizeCyrillicText(_ text: String) -> String {
       // Удаляем изолированные некириллические/неславянские блоки символов
       text.replacingOccurrences(of: #"[^\p{Latin}\p{Cyrillic}\p{Punctuation}\p{Whitespace}\p{Number}]"#, with: "", options: .regularExpression)
           .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
           .trimmingCharacters(in: .whitespacesAndNewlines)
   }
   ```
3. В системном промпте `thematicSystemPrompt` удалить негативную провокацию `НИЖНІЙ (не "спідний")`.

- [ ] **Шаг 4: Запустить тесты и убедиться в прохождении**

- [ ] **Шаг 5: Закоммитить изменения**
```bash
git add Shortcast/Services/Longform/LongformThematicService.swift ShortcastTests/ThematicParsingTests.swift
git commit -m "fix: support integer moment timecodes and sanitize foreign script hallucinations"
```

---

### Задача 2: Валидация орфографии тем и подключение автокоррекции слов

**Файлы:**
- Создать: `Shortcast/Services/Longform/UkrainianSpellingService.swift`
- Создать: `ShortcastTests/UkrainianSpellingTests.swift`
- Изменить: `Shortcast/Services/Longform/LongformThematicService.swift`
- Изменить: `Shortcast/Services/MomentFinderService.swift`

**Интерфейсы:**
- Потребляет: `NSSpellChecker` (macOS), `MomentFinderService.correctUkrainianWord`
- Производит: протокол `UkrainianSpellingValidating` с методом `validateAndCorrect(word:context:) -> String`

- [ ] **Шаг 1: Написать падающий тест для спеллчекера украинских тем**

```swift
@Test func detectsAndCorrectsMisspelledUkrainianConcept() async {
    let checker = UkrainianSpellingService()
    // "СПРАЖНІСТЬ" -> "СПРАВЖНІСТЬ"
    let corrected = await checker.correctConceptWord("СПРАЖНІСТЬ")
    #expect(corrected == "СПРАВЖНІСТЬ")
}

@Test func preservesValidUkrainianWords() async {
    let checker = UkrainianSpellingService()
    let valid = await checker.correctConceptWord("СПРАВЖНІСТЬ")
    #expect(valid == "СПРАВЖНІСТЬ")
    let freedom = await checker.correctConceptWord("СВОБОДА")
    #expect(freedom == "СВОБОДА")
}
```

- [ ] **Шаг 2: Реализовать `UkrainianSpellingService` (SOLID: Single Responsibility)**

Создать сервис, комбинирующий:
1. Системный `NSSpellChecker.shared.checkSpelling(of: language: "uk_UA")`.
2. Встроенный белый список базовых философских тем кино (ІЛЮЗІЯ, СПРАВЖНІСТЬ, СПОКІЙ, ВИБІР, БОРГ, ТЕРПІННЯ, ПАМ'ЯТЬ, СВОБОДА, ІСТИНА, ГОРДИНЯ).
3. LLM fallback через `MomentFinderService.shared.correctUkrainianWord`.

- [ ] **Шаг 3: Встроить валидацию концепта в `LongformThematicService`**

Перед возвратом `ThematicAnalysisResult` проверять `primaryConcept.word` и альтернативы через `spellingService`, гарантируя, что слово на обложке будет валидным литературным словом.

- [ ] **Шаг 4: Запустить тесты и закоммитить**
```bash
git add Shortcast/Services/Longform/UkrainianSpellingService.swift ShortcastTests/UkrainianSpellingTests.swift Shortcast/Services/Longform/LongformThematicService.swift
git commit -m "feat: add Ukrainian spelling validation and auto-correction for essay concepts"
```

---

### Задача 3: Исправление распределения по актам и расширение коротких сцен

**Файлы:**
- Изменить: `Shortcast/Services/Longform/LongformNarrativeDirector.swift`
- Изменить: `ShortcastTests/LongformMomentSanitationTests.swift`
- Изменить: `ShortcastTests/LongformActDistributionTests.swift`

**Интерфейсы:**
- Потребляет: санитайзинг моментов, длительность фильма
- Производит: сбалансированную 4-актную арку, где каждый акт имеет хронометраж и контент, а короткие сцены расширяются до `minRunDuration`.

- [ ] **Шаг 1: Написать тест на расширение коротких сцен вместо их удаления**

```swift
@Test func shortMomentIsExpandedToMinRunDurationInsteadOfDroppedWhenContextPermits() {
    // Момент 3.3 секунды (5210.4..5213.7) не должен выбрасываться, если он единственный в своем акте
    let raw = [SelectedMoment(startTime: 5210.4, endTime: 5213.7, reason: "Принятие природы", dramaticWeight: 0.9)]
    let sanitized = LongformNarrativeDirector.sanitizeSelectedMoments(
        raw,
        totalMovieDuration: 9000,
        expandSubMinRuns: true
    )
    #expect(sanitized.count == 1)
    #expect(sanitized[0].endTime - sanitized[0].startTime >= LongformNarrativeDirector.minRunDuration)
}

@Test func actsNeverHaveZeroSegmentsWhenAtLeastFourMomentsExist() throws {
    // Проверка, что при наличии моментов арка распределяет их по всем 4 актам без пустых заглушек
    let moments = [
        SelectedMoment(startTime: 100, endTime: 120, reason: "1", dramaticWeight: 0.8),
        SelectedMoment(startTime: 200, endTime: 220, reason: "2", dramaticWeight: 0.8),
        SelectedMoment(startTime: 300, endTime: 320, reason: "3", dramaticWeight: 0.8),
        SelectedMoment(startTime: 7000, endTime: 7020, reason: "4", dramaticWeight: 0.8)
    ]
    let director = LongformNarrativeDirector()
    let arc = try director.buildArcFromSelectedMoments(...)
    for (i, act) in arc.acts.enumerated() {
        #expect(!act.segments.isEmpty, "Акт \(i+1) не должен быть пустым")
    }
}
```

- [ ] **Шаг 2: Реализовать симметричное расширение сцен и адаптивное квантование по 4 актам**

В `LongformNarrativeDirector.swift`:
1. В `sanitizeSelectedMoments`: если сцена короче `minRunDuration`, расширять её симметрично в обе стороны (с ограничением `0...totalMovieDuration`), вместо безусловного удаления.
2. В `buildArcFromSelectedMoments`: если при делении на 25%-ные квартили один из актов оказывается пустым, производить динамическую кластеризацию k-means (или k-quantiles по количеству моментов), чтобы все 4 акта гарантированно получили материал.

- [ ] **Шаг 3: Запустить тесты и закоммитить**
```bash
git add Shortcast/Services/Longform/LongformNarrativeDirector.swift ShortcastTests/
git commit -m "fix: expand short moments to minRunDuration and balance 4-act distribution"
```

---

### Задача 4: Унификация защиты от титров (Credits Guard)

**Файлы:**
- Изменить: `Shortcast/Services/Longform/LongformNarrativeDirector.swift`
- Тест: `ShortcastTests/LongformCreditsAndHallucinationTests.swift`

- [ ] **Шаг 1: Написать тест на отсечение титров для фильмов длительностью 90–120 мин в эвристическом режиме**

```swift
@Test func heuristicArcAppliesCreditsGuardToStandardFeatureFilms() async throws {
    let director = LongformNarrativeDirector()
    // Фильм длительностью 6000 секунд (100 минут)
    let transcript = makeTestTranscript(duration: 6000.0)
    let arc = try await director.buildArcHeuristic(from: transcript, ...)
    let maxTime = arc.segments.map(\.end).max() ?? 0
    #expect(maxTime <= 6000.0 * 0.95 + 1.0)
}
```

- [ ] **Шаг 2: Убрать условие `> 9000.0` в `buildArcHeuristic`**

Унифицировать порог: отсекать последние 5% фильма для любых видео длиннее 1200 секунд (20 минут).

- [ ] **Шаг 3: Запустить тесты и закоммитить**
```bash
git add Shortcast/Services/Longform/LongformNarrativeDirector.swift ShortcastTests/LongformCreditsAndHallucinationTests.swift
git commit -m "fix: unify credits guard cutoff across LLM and heuristic paths for all feature films"
```

---

### Задача 5: Надежная персистентность `FilmProject` и подключение LLM Act Titling в `WorkspaceModel`

**Файлы:**
- Изменить: `Shortcast/Services/WorkspaceModel.swift`
- Тест: `ShortcastTests/FilmProjectTests.swift`

- [ ] **Шаг 1: Написать тест на сохранение отредактированного транскрипта и сохранение `longformResult`**

```swift
@Test func persistThemeStateRetainsTranscriptAndExistingLongformResult() async throws {
    let service = MockFilmProjectService()
    var project = FilmProject(...)
    // Проверяем, что storedTranscript и longformResult не обнуляются
}
```

- [ ] **Шаг 2: Исправить `WorkspaceModel.swift`**

1. В `startLongformPipeline`:
   ```swift
   // Сохраняем уже имеющийся результат, если он есть
   if self.longformResult == nil, let existing = self.currentProject?.longformResult {
       self.longformResult = existing
   }
   ```
2. В `persistThemeState`:
   ```swift
   if let stored = storedTranscript {
       project.transcript = stored
   }
   ```
3. При создании `LongformPipelineCoordinator`:
   Прокидывать шлюз `DirectorChatGateway` в `LongformActTitleService`, чтобы названия актов генерировались моделью:
   ```swift
   let actTitling = LongformActTitleService(model: modelManager.directorGateway)
   let coordinator = LongformPipelineCoordinator(actTitling: actTitling)
   ```

- [ ] **Шаг 3: Запустить тесты и закоммитить**
```bash
git add Shortcast/Services/WorkspaceModel.swift ShortcastTests/FilmProjectTests.swift
git commit -m "fix: persist edited transcript and inject director gateway into act titling service"
```

---

### Задача 6: Исправление опечаток в метаданных и актуализация стандартов LUFS

**Файлы:**
- Изменить: `Shortcast/Services/Longform/LongformMetadataGenerator.swift`
- Изменить: `Shortcast/Services/Longform/LongformPipelineCoordinator.swift`
- Тест: `ShortcastTests/LongformMetadataTests.swift`

- [ ] **Шаг 1: Написать тест на корректные теги и текст описания**

Проверить отсутствие `#кіноеесе` (исправить на `#кіноесе`), исправить `усвідоміш` $\to$ `усвідомиш`.

- [ ] **Шаг 2: Исправить строки и комментарии**

В `LongformMetadataGenerator.swift`:
- Заменить все вхождения `#кіноеесе` и `"кіноеесе"` на `#кіноесе` и `"кіноесе"`.
- Исправить орфографию в шаблоне `усвідоміш` $\to$ `усвідомиш`.

В `LongformPipelineCoordinator.swift`:
- Заменить `Нормализация громкости до -14 LUFS...` на `Нормализация громкости до -16 LUFS...`.
- Обновить комментарии с -14 LUFS на -16 LUFS.

- [ ] **Шаг 3: Запустить тесты и закоммитить**
```bash
git add Shortcast/Services/Longform/LongformMetadataGenerator.swift Shortcast/Services/Longform/LongformPipelineCoordinator.swift ShortcastTests/
git commit -m "fix: correct typography typos in YouTube metadata and align LUFS messages with -16 standard"
```

---

### Задача 7: Архитектурный рефакторинг SOLID (Вынос моделей и `LongformVideoCompositor`)

**Файлы:**
- Создать: `Shortcast/Models/Transcript.swift`
- Создать: `Shortcast/Services/Longform/LongformVideoCompositor.swift`
- Изменить: `Shortcast/Services/TranscriptionService.swift`
- Изменить: `Shortcast/Services/Longform/LongformPipelineCoordinator.swift`

- [ ] **Шаг 1: Вынести модели транскрипта в слой `Shortcast/Models`**

Переместить `TranscriptSegment`, `Transcript`, `TranscriptProvenance` из `TranscriptionService.swift` в `Shortcast/Models/Transcript.swift`. Устранить нарушение инверсии зависимостей (слой моделей не должен зависеть от слоя сервисов).

- [ ] **Шаг 2: Инкапсулировать композицию AVFoundation в `LongformVideoCompositor`**

Вынести методы создания дорожек `AVMutableComposition`, расчета рамп `scheduleOpacityRamp`, леттербоксинга и анимации слоев `CALayer` из `LongformPipelineCoordinator` (596 строк) в специализированный класс `LongformVideoCompositor` (SOLID: Single Responsibility Principle). Координатор должен заниматься только высокоуровневым пайплайном.

- [ ] **Шаг 3: Запустить полный тестовый сьют**
```bash
xcodebuild test -scheme Shortcast -destination 'platform=macOS'
```
Ожидаемый результат: Все тесты проходят (185+ тестов).

- [ ] **Шаг 4: Закоммитить изменения**
```bash
git add Shortcast/Models/Transcript.swift Shortcast/Services/Longform/LongformVideoCompositor.swift Shortcast/Services/Longform/LongformPipelineCoordinator.swift Shortcast/Services/TranscriptionService.swift
git commit -m "refactor(solid): extract Transcript models and LongformVideoCompositor"
```
