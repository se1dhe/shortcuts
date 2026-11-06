# Drive: local editorial pipeline and acceptance record

Content language remains Ukrainian. The user explicitly chose local models only;
no cloud provider or API key dependency was added. Nothing was published or deleted.

## Null is not a theme

The generic editorial completion gateway previously mapped several different
failures to `nil`: no loaded model, incomplete/non-object output and stream errors.
It now saves the raw completion and logs the specific reason. A literal response
`null`, an empty stream and a token-limit stop have distinct diagnostics.
`preferredTheme: null` inside a valid semantic-review object remains permitted.

The candidate parser rejects transport placeholders, and the theme picker filters
them from legacy input too. If the primary theme is invalid, alternatives are not
silently promoted to the model's primary recommendation. The user's exact earlier
null response was not present in the retained raw logs, so its generating call
has not been conclusively identified.

## Viewer promise and visible argument

New editions begin at output time zero without the old opening padding/fade.
The title, opening question and four authored argument cards are stored together
with literal scene evidence and authorship provenance. A changed scene requires
revalidation. Model review is scoped to the opening or the individual act's actual
dialogue. A malformed reviewer response cannot masquerade as a semantic rejection.

The real Drive pilot uses a previously accepted local-model scene montage about
debt. Its authored title/question/cards were reviewed by the assistant against
whole selected conversations and carry `assistant-editorial-review`, not
`local-model`. Earlier Gemma and Qwen copy attempts failed quality checks. This
pilot alone does not establish reliable unattended editorial quality.

The saved draft and the user's subsequently selected theme «ВИНА» differ. The pilot
is exported separately; it must not overwrite that newer selection.

## Render inspection

The first real export passed audio/duration validation but failed visual review:
the opening remained nearly black and new argument layers were missing. Source
inspection found a leading fade in the selected hook. The recovery frame now
comes from the same scene after that fade, without altering dialogue timing.
The export executor explicitly flushes Core Animation updates before export.
Repeat frame inspection confirmed a readable image at frame zero and a visible
argument card above the film image at 31 seconds.

## Shorts and music acceptance — 5 November

The local Director scanned the whole transcript, a local vision model checked
six shortlisted scenes, and the Director chose two disjoint windows. Selection
now returns a scene ID and a numbered source line; the program resolves the
original quote without asking the model to retype it. Copy editing remains a
separate mandatory pass, including a semantic review and distinct title/hook
checks. Scenes persist before the copy or music stages can fail.

The two actual exports completed through production services, without assistant
copy substitution:

| Short | Source range | Duration | Local edit/music choice |
| --- | --- | --- | --- |
| «Я не чекаю, поки вас візьмуть» | 2949.460–2995.480 | 46.037 s | coolNight, cut; Constance, entry 14.458 s |
| «Ціна брехні» | 3518.780–3564.560 | 45.800 s | coolNight, cut; Constance, entry 52.048 s |

The official Incompetech catalogue is fetched and cached with its published
licence page. The model chooses only IDs from that catalogue. MP3 downloads are
validated, the track entry is selected from measured energy windows, and the
music envelope ducks under dialogue. Source metadata, licence evidence, track
identity and entry time persist beside the exports. Attribution is appended to
both YouTube and TikTok descriptions. This is source-based selection plus signal
analysis, not a claim that the language model listened to the audio.

The old drop detector incorrectly treated decoder buffers as seconds. The new
implementation bins PCM using presentation timestamps and is tested against a
generated six-second WAV. Offset selection excludes silence and incomplete tails.
Four-beat intervals based on catalogue BPM are approximate phrase candidates,
not an inferred beat-perfect grid.

Colour correction applies to the picture band, preserving the caption/matte
colours. Optional transition accents follow detected source shot changes. Both
pilots selected clean cuts rather than flashes. Unpublished renders use style 4;
protected deliveries retain their existing exports.

The offscreen GPU face detector failed with Vision error 6014. A supported CPU
revision recovered 39 portrait candidates, and local vision confirmed the chosen
lead. Person segmentation still failed in this host: the cover composer now uses
a compact heading beside the face instead of drawing its depth-layout word over
the actor's eyes. The final cover was visually inspected.

MP3 validation initially failed on URLSession's temporary file. Validation now
uses a staged `.mp3` filename and reports download status and audio decoding
failures separately. Constance was downloaded and read successfully afterwards.

## Evidence and artifacts

- Long video: `tmp/drive-pilot/Exports/Драйв/longform_борг_FEB289.mp4`, 431.488 s, 1920×1080, H.264/AAC stereo 48 kHz.
- Short 1: `tmp/drive-pilot/Exports/Драйв/shorts/essay_short1_65755E.mp4`.
- Short 2: `tmp/drive-pilot/Exports/Драйв/shorts/essay_short2_F459AC.mp4`.
- Export metadata: `tmp/drive-pilot-result.json`.
- Frame checks and complete short audio decoding: `tmp/drive-pilot/qa/media-validation.json` and the PNGs beside it.
- Separate application project: `CC18B6AF-0DA2-4599-B95F-E4036F67D34C`, «Драйв — редакторський пілот». No publication receipts.

The long-video acceptance run passed 42 checks, the initial edit/music unit run
passed 59 checks, and the complete shorts/music acceptance passed 47 checks.
These sets overlap and must not be added together. A broader later run passed
124 checks but failed its separate live Qwen essay-editor acceptance; that failure
is not evidence of unattended editorial quality.

## Installed result

Final regression run: **127 tests passed**, 12 suites, including the saved real
Drive shorts release, stale-theme montage refusal, null handling, source-line
selection, PCM timing, music attribution, packaging and editorial regressions.
Log: `/private/tmp/shortcast-release-regressions-final.log`. The ordinary app build
succeeded; installation to `/Applications/КАДР & СЕНС.app` completed and synced
the browser-publisher scripts. The installed signature verified and the app was
launched. Content language remains `uk`. No social-network write or publication
was performed.

The separate live long-essay editor remains a known limitation. An earlier model
self-review accepted a word later found to be malformed. Its stale success file
was renamed `local-editorial-rejected-before-spelling-gate.json`; it is not the
pilot's publication copy. After adding the independent Ukrainian dictionary gate,
both local models initially exhausted the bounded attempts on this montage.
Targeted local spelling repair subsequently completed a live Gemma run, including
source and semantic gates (`/private/tmp/shortcast-local-editor-polish.log`,
13 tests). Its wording still contains clumsy abstractions; passing these checks
does not establish strong editorial taste or consistent independent performance.
The reviewed assistant-authored essay is therefore retained with explicit provenance;
the application does not silently pass that text off as local-model approval.

Short selection, short copy, music selection/download, entry selection and the
two real vertical exports did complete autonomously with local models.


## Third Short and scene recovery — 6 November

The third Short is a separate full-frame music montage. Local visual sampling
covers 72 windows across the film (two frames each); this is sampling, not full
motion understanding. Gemma selects source catalogue IDs, then the music editor
chooses a licensed track and an entry point using measured audio energy. Cuts
follow a BPM grid with phase estimated from the waveform; colour grading and
punch zoom apply to the montage. The two dialogue Shorts retain their exports.

Verified real render: `tmp/drive-pilot/Exports/Драйв/shorts/essay_short3_7E7219.mp4`,
20.300 seconds, H.264 1080×1920, AAC stereo 48 kHz. Real render acceptance passed
61 tests; timing version 3 clears the stale render flag after retiming. This
supersedes the earlier QA path ending `6B10AD`.

American Psycho recovery reproduced the actual `S004_alt` failure from saved
model output. Targeted repair retained every good source row, replaced the bad
row and added the missing final-act slot. All 15 source ranges passed evidence
validation; local semantic review and Ukrainian hook polish passed. The accepted
analysis was saved to the current project after checking it had not changed.

Theme discovery now imports saved project history, excludes previously offered
words for that film and supplies frequently proposed/generated themes across
films as editorial guidance. A different film can still honestly use the same
theme; uniqueness never substitutes for transcript support. Synonymous repeated
arguments are discouraged in the prompt, not guaranteed detectable.

At the user's request, upper “Думка есе” argument cards were removed from the
export pipeline. The editorial plan remains available to guide the opening and
packaging. Existing encoded exports need rendering again to change their image.

Final focused Swift regression: 67 tests passed. Browser regression: 54 passed,
2 opt-in tests skipped. TikTok `telonyx_cinema` connection was cancelled by the
user; no account switch or publication was performed.
