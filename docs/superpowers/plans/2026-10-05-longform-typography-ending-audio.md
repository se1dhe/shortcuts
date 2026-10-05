# Longform Cinema: Act Typography, Ending Completion & Vocal Isolation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Устранить обрыв мысли в финале видео (Акт IV), заменить любительские плашки актов на монументальную кино-типографику в стиле @prrodan и реализовать глубокое подавление фоновой музыки фильма с кристально чистым выделением речи.

**Architecture:** 
1. `LongformNarrativeDirector` + `SentenceBoundaryDetector`: расширение окна поиска финала до 99.8% хронометража, семантический фильтр завершенности мысли (`ThoughtCompletionScorer`) с запретом на выкрики/обрывы, и 3.5-секундный фейдаут.
2. `LongformSubtitleRenderer`: замена плашек с рамками на чистую кино-типографику (глава, акцентный номер, белая монументальная надпись с тенью).
3. `LongformVocalIsolationService` + `MediaExtractor`: двухуровневая изоляция вокала — 100% чистый центральный канал (`c2` / FC) без подмешивания саундтрека из L/R для 5.1/7.1, и Mid/Side / AI-подавление музыки для стерео 2.0.

**Tech Stack:** Swift 6, AVFoundation, CoreAnimation, CoreGraphics, FFmpeg (Channel Pan & Dialogue Enhancement), Swift Testing.

---

## Global Constraints

- Ответы строго на русском языке.
- Следовать принципам SOLID (Single Responsibility, Open-Closed, Dependency Inversion).
- Сохранять полную работоспособность существующих тестов (20 из 20 в 7 сьютах).

## Review Focus

1. **Неполная финальная реплика:** сцена не должна заканчиваться на знаке вопроса, союзе или крике («Дела плохие!»).
2. **5.1 vs 2.0 каналы:** центральный канал `c2` должен извлекаться без подмешивания 0.18*c0 и 0.1*c4, устраняя 100% саундтрека фильма.
3. **Отсутствие плашек/рамок:** визуальный рендерер актов не должен содержать `cornerRadius`, `borderWidth` и непрозрачных прямоугольников — только чистый текст с кино-тенью.
4. **Синхронизация анимаций CoreAnimation:** карточки актов должны плавно появляться на 0.4с и растворяться на 0.4с без скачков прозрачности.
5. **Тестируемость:** все новые модули должны иметь модульные тесты в `ShortcastTests`.

---

### Task 1: Устранение обрыва мысли в финале (Акт IV / Катарсис)

**Files:**
- Modify: `Shortcast/Services/Longform/LongformNarrativeDirector.swift`
- Modify: `Shortcast/Services/SentenceBoundaryDetector.swift`
- Test: `ShortcastTests/SentenceBoundaryTests.swift`

**Interfaces:**
- Consumes: `allSegments: [TranscriptSegment]`, `targetDuration: Double`, `actType: ActType`
- Produces: `TimeSegment` с гарантированно завершенной мыслью, семантическим скорингом финала и 3.5с фейдаутом.

- [ ] **Step 1: Написать падающий тест на выбор завершенного монолога финала**
  В `ShortcastTests/SentenceBoundaryTests.swift` добавить тест, проверяющий, что Акт IV предпочитает семантически завершенный монолог («Его лучшая разводка...») незаконченному крику («Дела плохие!»).
- [ ] **Step 2: Запустить тест и убедиться в падении**
  Run: `xcodebuild test -scheme Shortcast -destination 'platform=macOS'`
- [ ] **Step 3: Реализовать `ThoughtCompletionScorer` и обновить `LongformNarrativeDirector`**
  - Расширить окно Акта IV до `(movieDuration * 0.70)...(movieDuration * 0.998)`.
  - Внедрить скоринг завершенности: бонус за философские тезисные маркеры и штраф за выкрики, вопросы, открытые союзы.
  - Добавить 3.5с пост-ролл чистого видеоряда под финальное затухание музыки.
- [ ] **Step 4: Запустить тесты и подтвердить прохождение**
  Expected: PASS
- [ ] **Step 5: Commit**
  `git commit -m "feat(narrative): guarantee complete philosophical thought in Act IV finale"`

---

### Task 2: Монументальная кино-типографика смены актов (@prrodan style)

**Files:**
- Modify: `Shortcast/Services/Longform/LongformSubtitleRenderer.swift`
- Test: `ShortcastTests/LongformThumbnailGeneratorTests.swift` (или новый тест карточек актов)

**Interfaces:**
- Consumes: `acts: [LongformAct]`, `concept: ThematicConcept`, `renderSize: CGSize`
- Produces: `CALayer` без серых рамок и плашек, с элегантной кино-типографикой главы.

- [ ] **Step 1: Написать тест на структуру слоя смены акта**
  Проверить, что оверлей актов не создает рамочных `backgroundColor` прямоугольников, а формирует прозрачные текстовые слои с `kern` и тенью.
- [ ] **Step 2: Запустить тест и убедиться в падении / проверке**
- [ ] **Step 3: Переписать `buildActTransitionCardsLayer` в `LongformSubtitleRenderer.swift`**
  - Удалить `cardLayer.backgroundColor`, `cardLayer.cornerRadius`, `cardLayer.borderWidth`.
  - Оформить 3-строчную композицию:
    1. «— ЧАСТЬ II —» (кегль 18pt, золотой акцент, трекинг 5.0)
    2. «НАЗВАНИЕ АКТА» (кегль 36pt, белый цвет, трекинг 3.5, глубокая тень)
    3. Тонкая акцентная линия 120x3px.
  - Плавная анимация появления (0.4с) и растворения (0.4с).
- [ ] **Step 4: Запустить тесты и подтвердить прохождение**
- [ ] **Step 5: Commit**
  `git commit -m "feat(overlay): replace act boxes with cinema typography in @prrodan style"`

---

### Task 3: Глубокая изоляция речи и удаление музыки из фильма (Двухуровневая система)

**Files:**
- Modify: `Shortcast/Services/MediaExtractor.swift`
- Create: `Shortcast/Services/Longform/LongformVocalIsolationService.swift`
- Modify: `Shortcast/Services/Longform/LongformAudioMasteringService.swift`
- Test: `ShortcastTests/VocalIsolationTests.swift`

**Interfaces:**
- Consumes: исходный медиа-файл (многоканальный 5.1/7.1 или стерео 2.0).
- Produces: изолированная дорожка диалогов со 100% подавлением фонового саундтрека фильма.

- [ ] **Step 1: Написать падающий тест на фильтрацию аудио 5.1**
  Убедиться, что для 5.1 аудио генерируется чистая фильтрация `c0=c2|c1=c2` без добавления каналов `c0, c1, c4, c5`.
- [ ] **Step 2: Запустить тест и убедиться в падении**
- [ ] **Step 3: Реализовать чистую изоляцию в `MediaExtractor.swift` и `LongformVocalIsolationService`**
  - Для 5.1/7.1: `pan=stereo|c0=c2|c1=c2` + `dialoguenhance` (полное удаление L/R/Surround саундтрека фильма).
  - Для стерео 2.0: Mid/Side вычитание стерео-музыки и фильтр речевого эквалайзера.
- [ ] **Step 4: Запустить все тесты проекта**
  Expected: 100% PASS
- [ ] **Step 5: Commit**
  `git commit -m "feat(audio): isolate pure speech center channel and eliminate movie soundtrack"`

---

### Task 4: Интеграционное тестирование и пересборка приложения

- [ ] **Step 1: Прогнать полный тестовый сьют `xcodebuild test`**
- [ ] **Step 2: Собрать финальный Debug билд и перезапустить приложение**
- [ ] **Step 3: Проверить статус приложения в системе**
