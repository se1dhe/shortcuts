# Longform Thematic Cinema Engine Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Реализовать движок создания длинных тематических YouTube-видео (16:9, 5–8 минут) по мотивам фильмов в формате @prrodan (сквозная 4-актная арка вокруг одного концептуального слова, непрерывный саундтрек, фирменный центрированный титр и вирусные метаданные).

**Architecture:** Модульная SOLID-архитектура, дополняющая существующий пайплайн Shortcast новыми протоколами и сервисами: `ThematicConceptDiscovering` для поиска лейтмотивов, `LongformNarrativeDirecting` для сборки 4-актной арки, `LongformSubtitleRenderingProtocol` для центрированных титров, `LongformAudioMasteringProtocol` для сквозного звука с дакингом, и `LongformPipelineCoordinator` для координации сборки.

**Tech Stack:** Swift 5.10 / 6, AVFoundation, CoreGraphics, SwiftUI, WhisperKit, Gemma/LLM Service, XCTest.

**Spec:** `docs/specs/longform_cinema_engine_spec.md`

## Global Constraints

- Сохранять 100% обратную совместимость с существующим генератором шортсов (1:1 / 9:16).
- Все новые компоненты проектировать строго по принципам SOLID (интерфейсы, разделение ответственности, внедрение зависимостей).
- Целевое разрешение для длинных видео: строго 1920x1080 (16:9).
- Целевой хронометраж длинных видео: строго 300.0 – 480.0 секунд (5–8 минут).
- Дизайн титров: строго по формуле @prrodan (крупный белый титр темы ровно по центру, синхронные построчные субтитры в акцентном цвете прямо под ним).

## Review Focus

1. **Длина арки**: Проверить, что сумма сегментов не выходит за пределы 300–480 секунд даже при длинных сценах.
2. **Аудиостыки**: Проверить отсутствие аудиощелчков и разрывов на границах склеек сцен благодаря экспоненциальному кроссфейду.
3. **Дакинг саундтрека**: Проверить, что фоновая музыка разборчиво приглушается во время речи персонажей (-18..-22 dB) и нарастает в паузах (-8..-12 dB) и финале (-2 dB).
4. **Центрирование титров**: Проверить, что якорный титр темы точно сцентрирован на любых кадрах 16:9 и не съезжает при смене реплик субтитров.
5. **Дефолтные темы при отсутствии сети / LLM fallback**: Проверить корректность эвристического генератора тем при недоступности модели.

---

### Task 1: Domain Models & Output Format Enums

**Files:**
- Create: `Shortcast/Models/CinemaOutputFormat.swift`
- Create: `Shortcast/Models/ThematicConcept.swift`
- Create: `Shortcast/Models/LongformNarrativeArc.swift`
- Create: `Shortcast/Models/LongformYouTubeMetadata.swift`
- Modify: `Shortcast/Models/AppSettings.swift`
- Test: `ShortcastTests/LongformModelsTests.swift`

**Steps:**
- [ ] 1.1. Написать юнит-тесты для новых моделей `CinemaOutputFormat`, `ThematicConcept`, `LongformNarrativeArc` и `LongformYouTubeMetadata`.
- [ ] 1.2. Запустить тесты (проверить, что они не компилируются / падают).
- [ ] 1.3. Создать `Shortcast/Models/CinemaOutputFormat.swift` с перечислением режимов вывода (`shortSquare`, `shortVertical`, `longformLandscape`).
- [ ] 1.4. Создать `Shortcast/Models/ThematicConcept.swift` для хранения лейтмотива, слогана, описания идеи и акцентного цвета.
- [ ] 1.5. Создать `Shortcast/Models/LongformNarrativeArc.swift` с 4-актной структурой (`LongformActType`, `LongformAct`, `TimeSegment`, длительность 300–480с).
- [ ] 1.6. Создать `Shortcast/Models/LongformYouTubeMetadata.swift` для вирусных заголовков, описаний-манифестов и тегов.
- [ ] 1.7. Добавить `selectedOutputFormat: CinemaOutputFormat` в `AppSettings.swift`.
- [ ] 1.8. Запустить тесты и убедиться, что они проходят.

---

### Task 2: Thematic Concept Service (`LongformThematicService`)

**Files:**
- Create: `Shortcast/Services/Longform/ThematicConceptDiscovering.swift`
- Create: `Shortcast/Services/Longform/LongformThematicService.swift`
- Test: `ShortcastTests/LongformThematicServiceTests.swift`

**Steps:**
- [ ] 2.1. Написать тест для парсинга и валидации 3–5 концептов из JSON-ответа LLM и эвристического fallback-генератора.
- [ ] 2.2. Запустить тесты и убедиться в падении.
- [ ] 2.3. Создать протокол `ThematicConceptDiscovering` с методами `discoverConcepts(from transcript: Transcript, movieTitle: String) async throws -> [ThematicConcept]`.
- [ ] 2.4. Реализовать `LongformThematicService`:
  - Системный промпт философа-драматурга (выявление концептов уровня @prrodan: "Терпение", "Характер", "Гениальность", "Жалость").
  - Форматирование запроса и парсинг JSON.
  - Надёжный fallback на базе ключевых слов фильма при сбое LLM.
- [ ] 2.5. Запустить тесты и убедиться в успешном прохождении.

---

### Task 3: 4-Act Longform Director (`LongformNarrativeDirector`)

**Files:**
- Create: `Shortcast/Services/Longform/LongformNarrativeDirecting.swift`
- Create: `Shortcast/Services/Longform/LongformNarrativeDirector.swift`
- Test: `ShortcastTests/LongformNarrativeDirectorTests.swift`

**Steps:**
- [ ] 3.1. Написать тест построения 4-актной арки с контролем хронометража (300–480 сек), распределения актов (Хук -> Падение -> Борьба -> Катарсис).
- [ ] 3.2. Запустить тесты и убедиться в падении.
- [ ] 3.3. Создать протокол `LongformNarrativeDirecting`.
- [ ] 3.4. Реализовать `LongformNarrativeDirector`:
  - Выборка ключевых монологов и диалогов фильма под заданную тему `ThematicConcept`.
  - Снаппинг таймкодов к естественным границам предложений (`SentenceBoundaryDetector`).
  - Балансировка длительности каждого акта:
    - Акт 1 (Хук): 30–50с
    - Акт 2 (Падение): 90–150с
    - Акт 3 (Борьба): 100–160с
    - Акт 4 (Катарсис): 60–100с
- [ ] 3.5. Запустить тесты и подтвердить прохождение.

---

### Task 4: Centered Signature Subtitle Renderer (`LongformSubtitleRenderer`)

**Files:**
- Create: `Shortcast/Services/Longform/LongformSubtitleRenderingProtocol.swift`
- Create: `Shortcast/Services/Longform/LongformSubtitleRenderer.swift`
- Test: `ShortcastTests/LongformSubtitleRendererTests.swift`

**Steps:**
- [ ] 4.1. Написать тест для расчета фреймов и слоев титров:
  - Проверка точного центрирования главного слова `(x: width/2, y: height/2)`.
  - Проверка позиционирования строки субтитра строго под главным словом.
  - Проверка цветов (белый для концепта, желтый `#F5D020` или красный `#E50914` для речи).
- [ ] 4.2. Запустить тесты и убедиться в падении.
- [ ] 4.3. Создать протокол `LongformSubtitleRenderingProtocol`.
- [ ] 4.4. Реализовать `LongformSubtitleRenderer` на CoreGraphics / AVVideoCompositionCoreAnimationTool:
  - Отрисовка статичного центрального слова с кинематографической тенью (NSShadow).
  - Динамическая подстановка активных фраз диалога с плавным появлением/исчезновением.
- [ ] 4.5. Запустить тесты и подтвердить правильность геометрии и цветопередачи.

---

### Task 5: Continuous Audio Master & Sidechain Ducking (`LongformAudioMasteringService`)

**Files:**
- Create: `Shortcast/Services/Longform/LongformAudioMasteringProtocol.swift`
- Create: `Shortcast/Services/Longform/LongformAudioMasteringService.swift`
- Test: `ShortcastTests/LongformAudioMasteringTests.swift`

**Steps:**
- [ ] 5.1. Написать тест для расчета кривой громкости саундтрека (ducking во время речи, boost во время тишины, крещендо в последние 45с).
- [ ] 5.2. Запустить тесты и убедиться в падении.
- [ ] 5.3. Создать протокол `LongformAudioMasteringProtocol`.
- [ ] 5.4. Реализовать `LongformAudioMasteringService`:
  - Склейка аудиодорожек сцен с плавным crossfade (0.4с).
  - Генерация огибающей громкости (`AVAudioMixInputParameters`) для фонового саундтрека.
  - Финальное крещендо перед завершением арки.
- [ ] 5.5. Запустить тесты и проверить корректность кривых громкости.

---

### Task 6: Longform Pipeline Coordinator & Video Composition (`LongformClipRenderingService`)

**Files:**
- Create: `Shortcast/Services/Longform/LongformPipelineCoordinating.swift`
- Create: `Shortcast/Services/Longform/LongformPipelineCoordinator.swift`
- Create: `Shortcast/Services/Longform/LongformMetadataGenerator.swift`
- Test: `ShortcastTests/LongformPipelineCoordinatorTests.swift`

**Steps:**
- [ ] 6.1. Написать интеграционный тест сквозного пайплайна координатора (подготовка ассетов, запуск рендера, генерация метаданных).
- [ ] 6.2. Запустить тесты и убедиться в падении.
- [ ] 6.3. Создать `LongformMetadataGenerator` (генерация вирусных заголовков от 2-го лица и описаний-манифестов).
- [ ] 6.4. Создать `LongformPipelineCoordinator`, объединяющий `LongformNarrativeDirector`, `LongformSubtitleRenderer`, `LongformAudioMasteringService` и экспорт AVFoundation в 1920x1080.
- [ ] 6.5. Запустить тесты и проверить работу пайплайна.

---

### Task 7: UI Integration (Mode Switch, Concept Selector & 16:9 Player)

**Files:**
- Modify: `Shortcast/Views/DropZoneView.swift`
- Create: `Shortcast/Views/Longform/ThematicConceptSelectionSheet.swift`
- Create: `Shortcast/Views/Longform/LongformResultsView.swift`
- Modify: `Shortcast/Services/WorkspaceModel.swift`
- Modify: `Shortcast/Views/ContentView.swift`

**Steps:**
- [ ] 7.1. Добавить переключатель формата в `DropZoneView.swift`:
  - Сегментированный контроллер: `[ 📱 Шортсы (1:1 / 9:16) ]` | `[ 🎬 Длинный ролик (16:9 YouTube) ]`.
- [ ] 7.2. Создать `ThematicConceptSelectionSheet.swift`:
  - Красивые интерактивные карточки сгенерированных тем (эмодзи, слово, слоган).
  - Поле для ввода кастомного слова.
  - Кнопка подтверждения и старта сборки.
- [ ] 7.3. Создать `LongformResultsView.swift`:
  - Горизонтальный плеер 16:9.
  - Панель с вирусным заголовком YouTube и описанием с кнопками копирования в буфер обмена.
  - Кнопки сохранения и экспорта файла.
- [ ] 7.4. Интегрировать новый флоу в `WorkspaceModel.swift` и `ContentView.swift`.

---

### Task 8: Full Project Build & Verification

**Files:**
- Project wide

**Steps:**
- [ ] 8.1. Собрать проект через xcodebuild и убедиться в отсутствии предупреждений и ошибок (BUILD SUCCEEDED).
- [ ] 8.2. Запустить полный тестовый набор XCTest.
- [ ] 8.3. Запустить сквозной проверочный скрипт генерации тестового фрагмента длинного ролика и верифицировать соответствие эталонам @prrodan.
