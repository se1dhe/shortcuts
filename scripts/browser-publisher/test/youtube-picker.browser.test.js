import test from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright-core';
import { openYouTubeFilePicker, selectYouTubeVideoFile } from '../src/youtube-picker.js';
import { thumbnailState, waitForThumbnailPreview } from '../src/youtube-thumbnail.js';
import { studioStep } from '../src/youtube.js';
import { readYouTubeStatus, classifyYouTubeStatus } from '../src/youtube-waits.js';

// Opt-in real DOM regression, no network, no user profile or YouTube account.
test('real Chrome: a hidden uploads dialog with a separate visible picker selects only its own input', {
  skip: process.env.SHORTCAST_BROWSER_DOM_TEST !== '1',
}, async () => {
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`
      <input type="file" id="unrelated" hidden>
      <button id="create-icon" onclick="setTimeout(() => menu.hidden = false, 300)">Создать</button>
      <button role="menuitem" id="menu" hidden onclick="picker.hidden = false; this.hidden = true">Добавить видео</button>
      <ytcp-uploads-dialog hidden workflow-step="SELECT_FILES"><input type="file" hidden></ytcp-uploads-dialog>
      <ytcp-uploads-file-picker>
        <section id="picker" hidden>
          <button onclick="document.querySelector('#video').click()">Выбрать файлы</button>
          <input type="file" id="video" accept="video/*" hidden>
        </section>
      </ytcp-uploads-file-picker>`);
    const picker = await openYouTubeFilePicker(page, { timeoutMs: 3000 });
    assert.equal(await page.locator('ytcp-uploads-dialog').isVisible(), false);
    assert.equal(await picker.isVisible(), true);
    await selectYouTubeVideoFile(page, picker, { name: 'essay.mp4', mimeType: 'video/mp4', buffer: Buffer.from('fixture') });
    assert.equal(await page.locator('#video').evaluate(input => input.files[0]?.name), 'essay.mp4');
    assert.equal(await page.locator('#unrelated').evaluate(input => input.files.length), 0);

    await page.setContent(`<div id="editor"><input type="file" accept="image/*"></div>
    <script>document.querySelector('input').onchange = function () {
      this.value = '';
      const img = document.createElement('img');
      img.src = 'data:image/svg+xml,' + encodeURIComponent('<svg xmlns="http://www.w3.org/2000/svg" width="2" height="2"></svg>');
      this.parentElement.append(img);
      const busy = document.createElement('span'); busy.textContent = 'Загрузка...';
      this.parentElement.append(busy); setTimeout(() => busy.remove(), 500);
    };</script>`);
    const editor = page.locator('#editor');
    const previous = (await thumbnailState(editor)).images;
    await editor.locator('input').setInputFiles({ name: 'cover.jpg', mimeType: 'image/jpeg', buffer: Buffer.from('fixture') });
    assert.equal(await editor.locator('input').evaluate(input => input.files.length), 0);
    await waitForThumbnailPreview(editor, previous, { timeoutMs: 3000 });
    assert.equal((await thumbnailState(editor)).busy, false);

    await page.setContent(`<ytcp-uploads-dialog style="display:block">
      <button role="tab" aria-selected="true">Дополнения</button>
      <div id="title-textarea" hidden>Checks complete. No issues found</div>
      <custom-checks-panel><h1>Предварительная проверка</h1>
        <section><h2>Авторские права</h2><p>На контент заявлены права. Пока это не влияет на видео.</p></section>
        <section><h2>Правила сообщества</h2><p>Нарушений не найдено.</p></section>
      </custom-checks-panel>
      <div id="footer">Проверка завершена. На контент заявлены права.</div>
    </ytcp-uploads-dialog>`);
    assert.equal(await studioStep(page.locator('ytcp-uploads-dialog')), 'elements');
    const status = classifyYouTubeStatus(await readYouTubeStatus(page));
    assert.equal(status.harmlessClaim, true);
    assert.equal(status.checks.includes('No issues found'), false, 'metadata is not evidence of checks');
  } finally { await browser.close(); }
});
