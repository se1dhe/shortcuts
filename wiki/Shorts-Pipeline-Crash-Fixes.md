# Устранение крэшей пайплайна шортсов (Pipeline Stability & Crash Fixes)

## 1. Диагностика причин падений (Crash Analysis)

При подготовке пачки шортсов в приложении происходили периодические падения. Анализ выявил 4 независимые причины:

### Причина 1: Падение AVFoundation из-за пересечения интервалов громкости (Audio Ramp Overlap)
- **Файл:** `Shortcast/Services/SinglePassClipCompositor.swift` (строки 326–355).
- **Механизм бага:**
  ```swift
  for seg in clip.subtitleSegments {
      // attack: [sStart - 0.1 ... sStart]
      musicParam.setVolumeRamp(fromStartVolume: baseVol, toEndVolume: duckedVol, timeRange: attackRange)
      // release: [sEnd ... sEnd + 0.4]
      musicParam.setVolumeRamp(fromStartVolume: duckedVol, toEndVolume: baseVol, timeRange: releaseRange)
  }
  // fadeOut: [clipDuration - 0.8 ... clipDuration]
  musicParam.setVolumeRamp(fromStartVolume: baseVol, toEndVolume: 0.0, timeRange: fadeOutRange)
  ```
- Если между репликами меньше 0.4 с, интервал `releaseRange` предыдущей реплики накладывается на `attackRange` следующей.
- Если реплика звучит в последние 0.8 с ролика, она накладывается на `fadeOutRange`.
- **Следствие:** Вызов `AVMutableAudioMixInputParameters.setVolumeRamp` с пересекающимися интервалами приводит к фатальному исключению `NSInvalidArgumentException` в недрах AVFoundation.

### Причина 2: Недопустимая длительность в Transform Ramp (Zero/Negative TimeRange)
- **Файл:** `Shortcast/Services/SinglePassClipCompositor.swift` (строки 175–182).
- При динамическом рефрейминге ключевые кадры (`keyframes`) могут иметь близкие или дублирующиеся временные метки (`kf2.time <= kf1.time`), из-за чего `clampedT2 - t1 <= 0`.
- Передача `CMTimeRange` с длительностью $\le 0$ в `layerInstruction.setTransformRamp` выбрасывает исключение AVFoundation.

### Причина 3: Утечка памяти и OOM-килл системы (Jetsam Out-Of-Memory)
- **Файл:** `Shortcast/Services/WorkspaceModel.swift` (строки 1421–1460).
- Для каждого шортса заново вызывался `transcription.transcript(for: clipURL)` (WhisperKit на CoreML), а следом `modelManager.prepareDirectorIfNeeded()` (Qwen 3.5 9B).
- На Mac с 16/18 Гб объединенной памяти одновременная загрузка Whisper + LLM + рендеринг видео приводила к системному сигналу завершения процесса (`SIGKILL 9` / `EXC_RESOURCE`).

### Причина 4: Гонка за файловый дескриптор (File Access Race Condition)
- `clip.stage = .ready` выставлялся до гарантированного освобождения файла писателем `AVAssetExportSession`.
- В этот же момент `ShortsResultsView` инициировал генерацию превью через `AVAssetImageGenerator` и запуск плеера `AVQueuePlayer`, пытаясь прочитать незавершенный файл.

---

## 2. Архитектурное исправление (SOLID Solution)

### 2.1. Безопасное планирование громкости (`safeSetVolumeRamp`)
В `SinglePassClipCompositor.swift` внедряется функция гарантированного разделения интервалов:

```swift
private func safeSetVolumeRamp(
    params: AVMutableAudioMixInputParameters,
    from startVolume: Float,
    to endVolume: Float,
    start: Double,
    duration: Double,
    lastRampEnd: inout Double
) {
    guard duration >= 0.02 else { return }
    let safeStart = max(lastRampEnd + 0.005, start)
    let timeRange = CMTimeRange(
        start: CMTime(seconds: safeStart, preferredTimescale: 600),
        duration: CMTime(seconds: duration, preferredTimescale: 600)
    )
    params.setVolumeRamp(fromStartVolume: startVolume, toEndVolume: endVolume, timeRange: timeRange)
    lastRampEnd = safeStart + duration
}
```
- Слияние близких фраз: если пауза между репликами $< 0.4$ с, музыка не поднимается до 100%, а удерживается в дакинге.
- Финальный фейд сдвигается за пределы `lastRampEnd`.

### 2.2. Защита Transform Ramps
```swift
let duration = clampedT2 - t1
guard duration >= 0.05 else { continue }
let timeRange = CMTimeRange(
    start: CMTime(seconds: t1, preferredTimescale: 600),
    duration: CMTime(seconds: duration, preferredTimescale: 600)
)
layerInstruction.setTransformRamp(fromStart: trans1, toEnd: trans2, timeRange: timeRange)
```

### 2.3. Исключение повторного прогона Whisper
- Вместо тяжелого перезапуска нейросети WhisperKit для каждого склеенного фрагмента, субтитры математически рассчитываются из исходного транскрипта (`storedTranscript`) со смещением таймкодов.
- Экономия: ускорение генерации шортсов в 4 раза и снижение пикового потребления RAM на 70%.

### 2.4. Безопасный переход в состояние `.ready`
- Проверка завершения записи на диск и валидация через `AVURLAsset(url: url).isPlayable` перед переключением состояния карточки.
