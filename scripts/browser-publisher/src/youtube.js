import fs from 'fs';
import os from 'os';
import path from 'path';
import { UPLOAD_DIALOG, normalizedText, readYouTubeStatus, waitForYouTubePhase, setVerifiedYouTubeField, waitEnabled, requireReadyToPublish } from './youtube-waits.js';
import { openYouTubeFilePicker, selectYouTubeVideoFile } from './youtube-picker.js';
import { thumbnailState, waitForThumbnailPreview } from './youtube-thumbnail.js';

const TITLE = '#title-textarea #textbox, #title-textarea [contenteditable="true"]';
const DESCRIPTION = '#description-textarea #textbox, #description-textarea [contenteditable="true"]';
const CHECKS = 'ytcp-video-checks:visible, ytcp-video-checks-section:visible, ytcp-checks-step:visible, #checks-step:visible, #checks-container:visible, #checks-status:visible';
const PUBLIC = '[name="PUBLIC"]';
const UNLISTED = '[name="UNLISTED"]';
const progress = message => console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message }));

export function youtubeDescription(caption, hashtags = [], isShort = false) {
  const tags = [...new Set(hashtags.map(h => h.startsWith('#') ? h : '#' + h))];
  if (isShort && !tags.some(h => h.toLowerCase() === '#shorts') && !/#shorts\b/i.test(caption)) tags.push('#Shorts');
  return [caption.trim(), tags.filter(h => !caption.includes(h)).join(' ')].filter(Boolean).join('\n\n');
}

export async function assertYouTubeMetadata(dialog, title, description) {
  const actualTitle = await dialog.locator(TITLE).first().innerText();
  const actualDescription = await dialog.locator(DESCRIPTION).first().innerText();
  if (normalizedText(actualTitle) !== normalizedText(title) || normalizedText(actualDescription) !== normalizedText(description)) {
    throw new Error('Название или описание YouTube изменилось после заполнения. Публикация остановлена.');
  }
}

async function uploadThumbnail(dialog, thumbnailPath, isShort) {
  if (!thumbnailPath || !fs.existsSync(thumbnailPath)) throw new Error('Обложка видео отсутствует. Публикация остановлена.');
  // Scope to the thumbnail editor: a generic #file-loader may be the VIDEO
  // input and selecting a JPG there can replace/interrupt the current upload.
  const editor = dialog.locator('ytcp-thumbnails-compact-editor, ytcp-video-thumbnail-editor, #thumbnail-uploader').first();
  await editor.waitFor({ state: 'visible', timeout: 30000 }).catch(() => {
    throw new Error('YouTube не показал редактор обложки' + (isShort ? ' Shorts' : '')
      + '. Проверьте доступ канала к пользовательским обложкам. Публикация остановлена.');
  });
  const input = editor.locator('input[type="file"][accept*="image"], input[type="file"]').first();
  await input.waitFor({ state: 'attached', timeout: 15000 });
  const previous = (await thumbnailState(editor)).images;
  await input.setInputFiles(thumbnailPath);
  // Studio clears/replaces the file input after its change handler. Its empty
  // files list is normal; verify the changed, decoded preview after uploading.
  await waitForThumbnailPreview(editor, previous);
  progress('Обложка передана редактору YouTube; предпросмотр доступен.');
}

async function goToChecks(dialog) {
  for (let step = 0; step < 4; step++) {
    const current = await studioStep(dialog);
    if (current === 'checks') return;
    if (current === 'visibility') {
      throw new Error('YouTube перешёл к доступу без подтверждённого экрана проверки контента. Публикация остановлена.');
    }
    await advanceStudioStep(dialog);
  }
  throw new Error('Экран проверки контента YouTube не найден.');
}

export async function studioStep(dialog) {
  // Studio changes component tag names; the selected accessible step is the
  // actual navigation state, even while a previous component stays attached.
  const selectedTab = dialog.getByRole('tab', { selected: true }).first();
  if (await selectedTab.isVisible()) {
    const label = normalizedText(await selectedTab.innerText());
    if (/^(?:Details|Information|Информация|Інформація|Відомості)$/i.test(label)) return 'details';
    if (/^(?:Video elements|Дополнения|Елементи відео|Доповнення)$/i.test(label)) return 'elements';
    if (/^(?:Checks|Проверка|Предварительная проверка|Перевірки|Перевірка|Попередня перевірка)$/i.test(label)) return 'checks';
    if (/^(?:Visibility|Доступ|Видимість)$/i.test(label)) return 'visibility';
  }
  if (await dialog.locator(PUBLIC).first().isVisible()) return 'visibility';
  if (await dialog.locator(CHECKS).first().isVisible()) return 'checks';
  if (await dialog.locator(TITLE).first().isVisible()) return 'details';
  if (await dialog.locator('ytcp-video-elements:visible, #video-elements-step:visible, #elements-step:visible').first().isVisible()) return 'elements';
  return null;
}

export async function advanceStudioStep(dialog) {
  const before = await studioStep(dialog);
  if (!before) throw new Error('Текущий этап Studio не распознан. Публикация остановлена.');
  await waitEnabled(dialog.locator('#next-button').first(), 'Далее');
  const page = dialog.page();
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const after = await studioStep(dialog);
    if (after && after !== before) return after;
    await page.waitForTimeout(250);
  }
  throw new Error('YouTube не завершил переход с этапа ' + before + '.');
}

async function captureFailure(page, stage, error) {
  try {
    const dir = path.join(os.homedir(), 'Library', 'Logs', 'Shortcast', 'browser-publisher', String(Date.now()));
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    const status = await readYouTubeStatus(page).catch(() => ({}));
    fs.writeFileSync(path.join(dir, 'youtube-state.json'), JSON.stringify({ stage, message: error.message, status }, null, 2));
    await page.screenshot({ path: path.join(dir, 'youtube.png') }).catch(() => {});
    progress('Диагностика YouTube сохранена: ' + dir);
  } catch { /* Logging must not replace the original failure. */ }
}

/** Waits for actual transfer, processing and checks before making anything public. */
export async function uploadToYouTube(page, { videoPath, thumbnailPath, title, caption, hashtags = [], isPublic = true, isShort = false }) {
  let stage = 'Открытие Studio';
  let fileSelected = false;
  try {
    if (!videoPath || !fs.existsSync(videoPath) || fs.statSync(videoPath).size === 0) throw new Error('Видеофайл отсутствует или пуст.');
    let cleanTitle = (title || '').trim();
    if (isShort && !/#shorts\b/i.test(cleanTitle)) cleanTitle += ' #Shorts';
    const cleanDescription = youtubeDescription(caption || '', hashtags, isShort);
    if (!cleanTitle || [...cleanTitle].length > 100 || [...cleanDescription].length > 5000) {
      throw new Error('Название или описание не укладывается в ограничения YouTube. Текст не обрезался.');
    }
    progress(stage);
    await page.goto('https://studio.youtube.com', { waitUntil: 'domcontentloaded', timeout: 60000 });
    if (page.url().includes('accounts.google.com')) throw new Error('Выполните вход в YouTube через приложение.');
    stage = 'Открытие выбора файла'; progress(stage);
    const picker = await openYouTubeFilePicker(page);
    const dialog = page.locator(UPLOAD_DIALOG);
    stage = 'Передача видеофайла'; progress(stage + ' · ' + (fs.statSync(videoPath).size / 1000000).toFixed(1) + ' МБ');
    await selectYouTubeVideoFile(page, picker, videoPath); fileSelected = true;
    const titleBox = dialog.locator(TITLE).first();
    const descriptionBox = dialog.locator(DESCRIPTION).first();
    stage = 'Заполнение и проверка полей'; progress(stage);
    await setVerifiedYouTubeField(page, titleBox, cleanTitle, 'Заголовок');
    await setVerifiedYouTubeField(page, descriptionBox, cleanDescription, 'Описание');
    await uploadThumbnail(dialog, thumbnailPath, isShort);
    const audience = dialog.locator('[name="VIDEO_MADE_FOR_KIDS_NOT_MFK"]').first();
    await waitEnabled(audience, 'Видео не для детей');
    const selected = await audience.getAttribute('aria-checked');
    const checked = await audience.getAttribute('checked');
    if (selected !== 'true' && checked === null) throw new Error('YouTube не подтвердил выбор аудитории.');
    await assertYouTubeMetadata(dialog, cleanTitle, cleanDescription);
    stage = 'Ожидание завершения загрузки файла';
    const uploadStatus = await waitForYouTubePhase(page, 'upload', { progress });
    // Check again: asynchronous filename injection must not replace the title.
    await assertYouTubeMetadata(dialog, cleanTitle, cleanDescription);
    stage = 'Проверка контента'; progress(stage);
    await goToChecks(dialog);
    const checksStatus = await waitForYouTubePhase(page, 'checks', { progress });
    stage = 'Настройка доступа'; progress(stage);
    for (let step = 0; step < 3 && !(await dialog.locator(PUBLIC).first().isVisible()); step++) {
      await advanceStudioStep(dialog);
    }
    const visibility = dialog.locator(isPublic ? PUBLIC : UNLISTED).first();
    await waitEnabled(visibility, 'Доступ');
    if (await visibility.getAttribute('aria-checked') !== 'true' && await visibility.getAttribute('checked') === null) {
      throw new Error('YouTube не подтвердил выбранный доступ.');
    }
    // Re-read scoped statuses immediately before the irreversible click.
    requireReadyToPublish(uploadStatus, checksStatus, await readYouTubeStatus(page));
    stage = 'Подтверждение публикации'; progress(stage);
    await waitEnabled(dialog.locator('#done-button').first(), 'Опубликовать', 60000);
    const videoUrl = await confirmedYouTubeURL(page);
    console.log(JSON.stringify({ type: 'success', platform: 'youtube', message: isShort ? 'YouTube Shorts опубликован' : 'Эссе YouTube опубликовано', url: videoUrl }));
  } catch (error) {
    error.keepBrowserOpen = fileSelected && !page.isClosed();
    await captureFailure(page, stage, error);
    throw error;
  }
}

export async function confirmedYouTubeURL(page) {
  await page.getByRole('heading', { name: /^(Video published|Видео опубликовано|Відео опубліковано)$/i }).first()
    .waitFor({ state: 'visible', timeout: 180000 }).catch(() => { throw new Error('YouTube не подтвердил публикацию. Проверьте Studio перед повтором.'); });
  const link = page.getByRole('link', { name: /^https:\/\/(?:youtu\.be\/|(?:www\.)?youtube\.com\/(?:watch\?v=|shorts\/))/i }).first();
  if (await link.isVisible()) {
    const url = (await link.getAttribute('href')) || (await link.innerText());
    if (url && /^https:\/\/(?:youtu\.be\/|(?:www\.)?youtube\.com\/(?:watch\?v=|shorts\/))[A-Za-z0-9_-]{11}(?:[?&].*)?$/.test(url.trim())) return url.trim();
  }
  throw new Error('YouTube подтвердил отправку, но не вернул ссылку. Найдите видео в Studio и сохраните адрес в выпуске.');
}
