# План реализации: Устранение обрезки фраз, клиппинга звука и предупреждений/ошибок в логах

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Полностью устранить обрезку фраз посреди слов и предложений, рваную микро-нарезку диалогов (16 склеек за 38 секунд), межсценовые склейки из разных актов фильма, цифровой клиппинг звука (-7 LUFS) и ликвидировать все предупреждения и ошибки компиляции Xcode и рантайм-логов, сохранив квадратный формат 1:1 (1080x1080).

**Architecture:**
- Создание изолированного сервиса `SentenceBoundaryDetector` по принципам SOLID (SRP, DIP), отвечающего за определение естественных границ речи по таймштампам Whisper и пунктуации (`.`, `!`, `?`, `…`), с добавлением защитного паддинга (head: 200–250ms, tail: 400–500ms) и запретом обрезки посреди незавершенной фразы при ограничении 58 секунд (откат к предыдущему законченному предложению).
- Корректировка директив и оценки в `CinemaMomentDirector`: наивысший приоритет отдается одиночным монолитным сценам диалога (`segments.count == 1`, +30 очков), запрещаются хаотичные склейки сцен из разных частей фильма.
- Переработка `TimeCondensationService`: повышение порога обнаружения «пустоты» до >= 1.4s, сохранение естественных диалоговых пауз (>= 500ms room tone) и отключение искусственных микро-дёрганий внутри непрерывной реплики персонажей.
- Исправление калибровки `CinemaAudioMasteringService`: сброс `dialogueBoostDB` с деструктивных +10.5 dB до безопасных +2.0 dB, предотвращение перегрузки DAC и клиппинга 0 dBFS, обеспечение стандартов -14 LUFS и True Peak < -1.5 dBTP.
- Ликвидация предупреждений сборки Xcode (`MediaExtractor.swift`, `SubtitleRenderer.swift`), повышение устойчивости `JSONVariantParser.swift` к дублированным запятым (`,,`), изоляция CoreAnimation транзакций (`CATransaction`) и чистый демонтаж экземпляров `AVPlayer` при закрытии экранов.

**Tech Stack:** Swift, AVFoundation, CoreMedia, CoreAnimation, Swift Concurrency, Regex.

**Spec:** Требования пользователя: формат строго 1:1; фразы должны быть законченными и не обрываться на полуслове; диалог не должен быть рваным; ноль ошибок и ноль предупреждений в Xcode и рантайм-логах; строгое соблюдение принципов SOLID.

---

## Global Constraints

- Сохранять соотношение сторон для шортсов строго 1:1 (1080x1080), не переводить в 9:16.
- При ограничении длительности до 58.0 секунд обрезать видео ИСКЛЮЧИТЕЛЬНО по границе законченного предложения (знак препинания или пауза), откатываясь назад, а не отсекая хвост посреди слова.
- Ноль предупреждений компилятора в Xcode при сборке схемы `Shortcast`.
- Ноль ошибок и предупреждений `uncommitted CATransaction`, `FigFilePlayer err=-12860`, `VRP err=-12852`, `JSON parse failed` в консольных логах приложения.
- Каждое изменение должно следовать принципам SOLID (единая ответственность, открытость/закрытость, слабая связанность).
- Все ответы и комментарии оформлять на русском языке.

---

## Review Focus

1. **Обрезка фразы на 58-й секунде**: Если сцена длится 63 секунды, а предложение заканчивается на 54.2s, клип должен завершиться на 54.2s (+ padding), а не на 58.0s посреди слова.
2. **Паузы внутри реплики персонажа**: Естественные драматические паузы в диалоге длительностью 0.5–1.2s не должны вырезаться `TimeCondensationService`, порождая эффект заикания (micro jump cuts).
3. **Громкость и клиппинг**: При максимальном звуке диалога True Peak не должен превышать -1.0 dBTP, а интегрированная громкость должна быть в диапазоне -14.0 ± 0.5 LUFS без хрипов и срезанных пиков.
4. **Сбои парсера JSON при повторе запятых**: Модели LLM иногда возвращают `"самопознание",, "психология"`; парсер обязан восстанавливать валидный JSON без вылета в исключение.
5. **Утечки CoreMedia и фоновые транзакции**: Закрытие модального окна просмотра клипа или фоновый рендеринг слоев не должны порождать ошибки в stderr.

---

### Task 1: Устранение всех предупреждений сборки в Xcode

**Files:**
- Modify: `Shortcast/Services/MediaExtractor.swift:105-117`
- Modify: `Shortcast/Services/SubtitleRenderer.swift:1185-1205`
- Test: `scratch/test_task1_build_warnings.sh`

**Interfaces:**
- Consumes: `ProcessRunner.shared.run(executableURL:arguments:) async throws -> ProcessResult`
- Produces: Чистая компиляция без warning о неиспользуемом возвращаемом значении и неиспользуемой переменной

- [ ] **Step 1: Написать проверочный скрипт для поиска предупреждений**

Создать `scratch/test_task1_build_warnings.sh`:
```bash
#!/bin/bash
set -e
# Проверяем строки с неиспользуемыми вызовами ProcessRunner и переменными в SubtitleRenderer
grep -n "try await ProcessRunner.shared.run" Shortcast/Services/MediaExtractor.swift
```

- [ ] **Step 2: Запустить скрипт и зафиксировать наличие мест вызовов без discard**

Run: `bash scratch/test_task1_build_warnings.sh`
Expected: строки 107 и 111 содержат `try await ProcessRunner.shared.run(...)` без `_ =`.

- [ ] **Step 3: Внести исправления в `MediaExtractor.swift` и `SubtitleRenderer.swift`**

В `Shortcast/Services/MediaExtractor.swift`:
```swift
_ = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: hardwareArguments)
...
_ = try await ProcessRunner.shared.run(executableURL: ffmpeg, arguments: softwareArguments)
```

В `Shortcast/Services/SubtitleRenderer.swift`:
Убедиться, что `redColor` используется либо помечен `_`, и проверить отсутствие неиспользуемых объявлений констант.

- [ ] **Step 4: Проверить синтаксис Swift с локальным кэшем модулей**

Run: `swift -module-cache-path ./DerivedData/ModuleCache -typecheck Shortcast/Services/MediaExtractor.swift Shortcast/Services/SubtitleRenderer.swift 2>&1 || true`
Expected: Отсутствие предупреждений о `unused result` и `never used`.

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/MediaExtractor.swift Shortcast/Services/SubtitleRenderer.swift
git commit -m "fix(build): eliminate xcode warnings for unused process results and variables"
```

---

### Task 2: Устойчивость к дефектам вывода LLM в `JSONVariantParser`

**Files:**
- Modify: `Shortcast/Services/JSONVariantParser.swift:50-65`
- Test: `scratch/test_json_parser.swift`

**Interfaces:**
- Consumes: `raw: String` (содержащий опечатки LLM, такие как `,,`, лишние запятые перед скобками, неэкранированные переносы)
- Produces: `GenerationResult` с валидным парсингом вариантов публикации

- [ ] **Step 1: Написать падающий тест на опечатки LLM (двойные запятые `,,` и висячие запятые)**

Создать `scratch/test_json_parser.swift`:
```swift
import Foundation

let malformedJSON = """
{
  "language": "ru",
  "variants": [
    {
      "platform": "reels",
      "hook": "Тест",
      "caption": "Описание",
      "hashtags": ["бойцовскийклуб",, "самопознание"]
    },
  ]
}
"""

// Вызов функции repairDrift
let repaired = JSONVariantParser.repairDrift(malformedJSON)
guard let data = repaired.data(using: .utf8),
      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let variants = obj["variants"] as? [[String: Any]],
      let tags = variants.first?["hashtags"] as? [String],
      tags.count == 2 else {
    print("TEST FAILED: Could not parse malformed JSON with duplicate commas")
    exit(1)
}
print("TEST PASSED")
```

- [ ] **Step 2: Запустить тест и убедиться в падении**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_json_parser.swift`
Expected: `TEST FAILED` (JSONSerialization завершается с ошибкой из-за `,,` и `, ]`).

- [ ] **Step 3: Реализовать исправление дублированных и некорректных запятых в `JSONVariantParser.swift`**

В функции `repairDrift`:
```swift
// Дублированные запятые внутри списков или объектов: `,,` или `, ,` -> `,`
s = regexReplace(s, #",\s*,"#, with: ",")
// Запятая сразу после открывающей скобки: `[,` или `{,` -> `[` или `{`
s = regexReplace(s, #"(\[|\{)\s*,"#, with: "$1")
// Висячая запятая перед закрывающей скобкой: `,]` или `,}` -> `]` или `}`
s = regexReplace(s, #",(\s*[}\]])"#, with: "$1")
```

- [ ] **Step 4: Запустить тест и убедиться в успешном прохождении**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_json_parser.swift`
Expected: `TEST PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/JSONVariantParser.swift
git commit -m "fix(llm): sanitize duplicate and leading commas in json repair drift"
```

---

### Task 3: Модуль контроля границ фраз (`SentenceBoundaryDetector`)

**Files:**
- Create: `Shortcast/Services/SentenceBoundaryDetector.swift`
- Test: `scratch/test_sentence_boundary.swift`

**Interfaces:**
- Consumes: `TranscriptSegment` / `SubtitleSegment`, `TimeSegment`, `maxDuration: Double`
- Produces:
  ```swift
  public protocol SentenceBoundaryDetecting: Sendable {
      func snapToSentenceStart(timestamp: Double, in segments: [TranscriptSegment]) -> Double
      func snapToSentenceEnd(timestamp: Double, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> Double
      func refineSceneBoundary(range: TimeSegment, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> TimeSegment
  }
  ```

- [ ] **Step 1: Написать модульный тест для `SentenceBoundaryDetector`**

Создать `scratch/test_sentence_boundary.swift`, моделирующий транскрипт с предложениями и проверяющий:
1. Выравнивание начала на начало фразы с head padding -0.20s.
2. Выравнивание конца на знак препинания (`.`, `!`, `?`) с tail padding +0.45s.
3. Откат назад к предыдущему законченному предложению, если текущая фраза выходит за 58.0s (никаких обрывов посреди слова).

- [ ] **Step 2: Запустить тест и убедиться в ошибке (файла еще нет)**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_sentence_boundary.swift`
Expected: Ошибка компиляции `SentenceBoundaryDetector not found`.

- [ ] **Step 3: Реализовать `SentenceBoundaryDetector.swift` по принципам SOLID**

Создать `Shortcast/Services/SentenceBoundaryDetector.swift`:
- Реализует протокол `SentenceBoundaryDetecting`.
- Константы: `headPadding = 0.20`, `tailPadding = 0.45`, `minSegmentDuration = 10.0`, `maxShortsDuration = 58.0`.
- Метод `findPreviousSentenceEnd(before: Double, in segments: [TranscriptSegment]) -> Double?`.
- Метод `refineSceneBoundary(range: TimeSegment, maxAllowedDuration: Double, in segments: [TranscriptSegment]) -> TimeSegment`.
- Обработка знаков препинания: `.`, `!`, `?`, `…`, а также пауз между сегментами >= 1.0s как естественных границ мыслей.

- [ ] **Step 4: Запустить тест и убедиться в успешном прохождении всех сценариев**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_sentence_boundary.swift`
Expected: `ALL SENTENCE BOUNDARY TESTS PASSED`.

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/SentenceBoundaryDetector.swift
git commit -m "feat(director): add SentenceBoundaryDetector for dialogue phrase preservation"
```

---

### Task 4: Приоритет цельных сцен и безопасное ограничение длительности в `CinemaMomentDirector`

**Files:**
- Modify: `Shortcast/Services/CinemaMomentDirector.swift:75-105`
- Modify: `Shortcast/Services/CinemaMomentDirector.swift:365-386`
- Modify: `Shortcast/Services/CinemaMomentDirector.swift:395-425`
- Test: `scratch/test_director_continuous_scene.swift`

**Interfaces:**
- Consumes: `SentenceBoundaryDetector`, `CinemaStoryArc`
- Produces: Сгенерированные и отфильтрованные арки, отдающие высший приоритет единым непрерывным сценам диалога (`segments.count == 1`) без межсценовых склеек.

- [ ] **Step 1: Написать тест проверки оценки и фильтрации арок**

Создать `scratch/test_director_continuous_scene.swift`:
- Создать арку с 1 сценой длительностью 48s и арку с 3 сценами из разных частей фильма.
- Проверить, что арка с 1 сценой получает более высокий `viralScore`.
- Проверить, что если арка длится 64s, `filterEliteCandidates` не режет вслепую `last.end - 6s`, а сохраняет границы предложений.

- [ ] **Step 2: Запустить тест и убедиться в несоответствии текущего алгоритма**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_director_continuous_scene.swift`
Expected: FAIL (сейчас мульти-сегментные сцены получают +25 очков, а одиночные лишь +20).

- [ ] **Step 3: Обновить логику оценки и промпт в `CinemaMomentDirector.swift`**

1. В системном промпте:
   - Четко потребовать: "PRIORITIZE 1 CONTINUOUS DIALOGUE SCENE (1 segment). Do NOT splice distant unrelated scenes from different acts of the movie."
2. В функции `calculateAlgorithmicScore`:
   - Для `segments.count == 1`: начислять +30 очков за непрерывность диалога.
   - Для разрозненных сегментов из разных мест фильма: штрафовать (-15 очков).
3. В `filterEliteCandidates`:
   - Заменить слепую формулу `last.end - excess` на безопасный вызов `SentenceBoundaryDetector`.

- [ ] **Step 4: Запустить тест и убедиться в успешном прохождении**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_director_continuous_scene.swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/CinemaMomentDirector.swift
git commit -m "fix(director): prioritize continuous dialogue scenes and eliminate blind duration cuts"
```

---

### Task 5: Естественный темп и устранение заикания (micro jump-cuts) в `TimeCondensationService` и `ClipRenderingService`

**Files:**
- Modify: `Shortcast/Services/TimeCondensationService.swift:15-62`
- Modify: `Shortcast/Services/ClipRenderingService.swift:55-125`
- Test: `scratch/test_time_condensation.swift`

**Interfaces:**
- Consumes: `speechTuples: [(start: Double, end: Double)]`, `mood: CinematicMoodProfile`
- Produces: `[CMTimeRange]` без микро-нарезки на фразах с паузами менее 1.4 секунды

- [ ] **Step 1: Написать тест проверки конденсации времени на естественном диалоге**

Создать `scratch/test_time_condensation.swift`:
- Создать последовательность реплик с паузами 0.4s, 0.7s, 1.1s (естественные паузы актеров в Бойцовском клубе).
- Ожидаемый результат: `condenseTime` оставляет сцену единым непрерывным фрагментом, не создавая 10+ микро-склеек с паддингом в 1 кадр (18мс).

- [ ] **Step 2: Запустить тест и зафиксировать падение**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_time_condensation.swift`
Expected: FAIL (текущий сервис нарезает сцену на множество микро-кусков).

- [ ] **Step 3: Реализовать рефакторинг `TimeCondensationService.swift` и `ClipRenderingService.swift`**

В `TimeCondensationService.swift`:
1. Исправить расчет прогресса:
   ```swift
   let clipStart = segments.first?.start ?? 0.0
   let clipEnd = segments.last?.end ?? clipStart
   let totalDuration = max(clipEnd - clipStart, 0.01)
   let progress = min(max(0.0, (currentEnd - clipStart) / totalDuration), 1.0)
   ```
2. Повысить минимальную паузу для вырезания:
   - Паузы менее 1.4 секунды считаются частью живого диалога и драматической паузой — они не вырезаются.
   - Если пауза > 1.4s, оставлять не менее 0.50s естественного дыхания/звука комнаты (padding: 0.30s на конце реплики, 0.20s перед следующей репликой).

В `ClipRenderingService.swift`:
1. Для непрерывных сцен диалога (`segments.count == 1`):
   - Не разрезать сцену на микро-фрагменты по каждому субтитру Whisper. Использовать цельный отрезок, если нет огромных пауз молчания (> 3 секунд).
2. При ограничении 58.0 секунд (строки 105–120):
   - Заменить `duration: CMTime(seconds: remaining)` на привязку к последнему законченному предложению, возвращенному `SentenceBoundaryDetector`.

- [ ] **Step 4: Запустить тест и подтвердить сохранение непрерывности**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_time_condensation.swift`
Expected: PASS (0 микро-склеек на естественных диалоговых паузах).

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/TimeCondensationService.swift Shortcast/Services/ClipRenderingService.swift
git commit -m "fix(rendering): eliminate micro jump-cuts in dialogue and preserve natural conversational pauses"
```

---

### Task 6: Безопасный мастеринг звука и защита от клиппинга в `CinemaAudioMasteringService`

**Files:**
- Modify: `Shortcast/Services/CinemaAudioMasteringService.swift:40-95`
- Modify: `Shortcast/Services/CinemaAudioMasteringService.swift:145-200`
- Test: `scratch/test_audio_mastering_levels.swift`

**Interfaces:**
- Consumes: `AudioMixConfig`, `AVMutableAudioMixInputParameters`
- Produces: Аудиодорожка с чистым подъемом диалога (+2.0 dB) и гарантированным отсутствием цифрового клиппинга выше -1.0 dBTP

- [ ] **Step 1: Написать тест проверки параметров громкости**

Создать `scratch/test_audio_mastering_levels.swift`:
- Проверить значения по умолчанию в `AudioMixConfig.init(...)`.
- Проверить, что `dialogueBoostDB` не превышает +3.0 dB (ранее было +10.5 dB, дававшее искажения и -7 LUFS).

- [ ] **Step 2: Запустить тест и подтвердить ошибку**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_audio_mastering_levels.swift`
Expected: FAIL (дефолт в init равен 10.5 dB).

- [ ] **Step 3: Исправить настройки и нормализацию в `CinemaAudioMasteringService.swift`**

1. В `AudioMixConfig.init(...)`:
   - Установить `dialogueBoostDB: Float = 2.0` (безопасный линейный коэффициент ~1.25x вместо 3.35x).
   - Зафиксировать `targetTruePeak: Double = -1.5`.
2. В `applyMastering`:
   - Добавить проверку пикового уровня или применить защитное плавное затухание на границах.
   - Если выполняется нормализация, гарантировать сохранение динамического диапазона без перегрузки тракта ЦАП.

- [ ] **Step 4: Запустить тест и убедиться в соответствии стандартам**

Run: `swift -module-cache-path ./DerivedData/ModuleCache scratch/test_audio_mastering_levels.swift`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Shortcast/Services/CinemaAudioMasteringService.swift
git commit -m "fix(audio): calibrate dialogue boost to +2.0dB and enforce -1.5dBTP true peak ceiling"
```

---

### Task 7: Ликвидация предупреждений `CATransaction` и ошибок teardown в `AVPlayer`

**Files:**
- Modify: `Shortcast/Services/SubtitleRenderer.swift:390-410`
- Modify: `Shortcast/Services/WatermarkRenderer.swift:100-120`
- Modify: `Shortcast/Views/PhoneVideoPlayer.swift:38-65`
- Modify: `Shortcast/Views/ShortClipTile.swift:340-360`
- Test: `scratch/test_catransaction_isolation.swift`

**Interfaces:**
- Consumes: CoreAnimation слои, жизненный цикл SwiftUI вьюх с `AVPlayer`
- Produces: Чистые консольные логи без `uncommitted CATransaction` и CoreMedia err=-12852 / -12860

- [ ] **Step 1: Написать тест проверки оберток `CATransaction`**

Создать `scratch/test_catransaction_isolation.swift` для проверки создания слоев с `CATransaction.begin()` / `CATransaction.commit()`.

- [ ] **Step 2: Внести правки в слои CoreAnimation и демонтаж AVPlayer**

1. В `SubtitleRenderer.swift` и `WatermarkRenderer.swift`:
   - Обернуть создание и модификацию CALayer в:
     ```swift
     CATransaction.begin()
     CATransaction.setDisableActions(true)
     defer { CATransaction.commit() }
     ```
2. В `PhoneVideoPlayer.swift`:
   - В `dismantleNSView`:
     ```swift
     coordinator.player?.pause()
     coordinator.looper?.disableLooping()
     coordinator.player?.removeAllItems()
     coordinator.player?.replaceCurrentItem(with: nil)
     nsView.player = nil
     ```
3. В `ShortClipTile.swift`:
   - Добавить модификатор `.onDisappear` для модального окна просмотра клипа с очисткой:
     ```swift
     .onDisappear {
         player?.pause()
         player?.replaceCurrentItem(with: nil)
         player = nil
     }
     ```

- [ ] **Step 3: Проверить синтаксис и компиляцию**

Run: `swift -module-cache-path ./DerivedData/ModuleCache -typecheck Shortcast/Views/PhoneVideoPlayer.swift Shortcast/Views/ShortClipTile.swift Shortcast/Services/SubtitleRenderer.swift 2>&1 || true`
Expected: 0 ошибок.

- [ ] **Step 4: Commit**

```bash
git add Shortcast/Services/SubtitleRenderer.swift Shortcast/Services/WatermarkRenderer.swift Shortcast/Views/PhoneVideoPlayer.swift Shortcast/Views/ShortClipTile.swift
git commit -m "fix(lifecycle): commit CATransactions explicitly and cleanly tear down AVPlayer instances"
```

---

### Task 8: Сквозная верификация пайплайна на материале «Бойцовского клуба»

**Files:**
- Test: `scratch/verify_pipeline_fight_club.sh`
- Output: `./судья/` (новые отрендеренные клипы)

**Interfaces:**
- Consumes: Исходный файл `input/Fight Club. 1999. 1080p. HEVC. 10 bit.mkv`
- Produces: Квадратное видео 1080x1080, чистый лог без ошибок/warning, завершенные фразы в диалоге, звук ~ -14 LUFS

- [ ] **Step 1: Создать скрипт проверки громкости и целостности видео через ffmpeg/ffprobe**

Создать `scratch/verify_pipeline_fight_club.sh`:
- Запускает `ffprobe` для проверки разрешения (строго 1080x1080, 1:1).
- Запускает `ffmpeg -af ebur128` для проверки LUFS (должно быть в диапазоне -14.5 ... -13.5 LUFS, без True Peak клиппинга > -1.0 dBTP).
- Анализирует лог приложения на предмет отсутствия ошибок компиляции, warning, `err=-12852`, `err=-12860`, `CATransaction`.

- [ ] **Step 2: Запустить тестовый рендер сцены**

Запустить рендер через приложение/тестовый раннер.

- [ ] **Step 3: Запустить скрипт верификации**

Run: `bash scratch/verify_pipeline_fight_club.sh`
Expected:
- Разрешение: 1080x1080 (1:1).
- Громкость: -14 LUFS (без клиппинга).
- Хвост диалога: естественное окончание фразы без резкого срезания согласных/слов.
- Логи: чистые, без warning и ошибок.

- [ ] **Step 4: Зафиксировать результаты аудита и финальный коммит**

```bash
git commit --allow-empty -m "chore: verify end-to-end cinema shorts pipeline passes all quality and log checks"
```
