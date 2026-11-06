import fs from 'node:fs';
import { requireTikTokAccount } from './tiktok-account.js';
import os from 'node:os';
import path from 'node:path';
import { enableTikTokChecks, readTikTokChecks, waitForTikTokChecks, requireTikTokChecksPassed } from './tiktok-waits.js';

/**
 * Automation module for publishing shorts to TikTok Creator Center.
 *
 * @param {import('playwright-core').Page} page
 * @param {Object} postData
 * @param {string} postData.videoPath - Absolute path to the .mp4 file
 * @param {string} postData.caption - Caption text
 * @param {string[]} postData.hashtags - Array of hashtags
 * @param {boolean} [postData.isDraft=false] - Whether to save as draft or publish public
 */
export async function uploadToTikTok(page, { videoPath, caption, hashtags = [], isDraft = false, expectedHandle }, options = {}) {
  let fileSelected = false;
  let surface = page;
  try {
    console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Открытие TikTok Creator Center...' }));

    await page.goto('https://www.tiktok.com/creator-center/upload', {
      waitUntil: 'domcontentloaded',
      timeout: 60000,
    });

    await page.waitForTimeout(2000);

    // Check login state
    const currentUrl = page.url();
    if (currentUrl.includes('/login') || (await page.locator('button:has-text("Log in"), button:has-text("Войти")').count()) > 0) {
      throw new Error('Не авторизован в TikTok. Выполните вход через кнопку "Войти в аккаунты".');
    }

    if (expectedHandle) await requireTikTokAccount(page, expectedHandle);

    console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Загрузка видеофайла...' }));

    // Find file input (in creator center it may be inside an iframe or direct on page)
    let fileInput = page.locator('input[type="file"]');
    if ((await fileInput.count()) === 0) {
      // Try inside upload iframe if TikTok uses an embedded frame
      for (const frame of page.frames()) {
        const frameInput = frame.locator('input[type="file"]');
        if ((await frameInput.count()) > 0) {
          fileInput = frameInput;
          surface = frame;
          break;
        }
      }
    }

    await fileInput.waitFor({ state: 'attached', timeout: 30000 });
    await fileInput.setInputFiles(videoPath);
    fileSelected = true;

    console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Файл передан, обработка видео...' }));

    // Fill caption and hashtags
    const fullText = [caption, hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' ')]
      .filter(Boolean)
      .join(' ');

    console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Заполнение описания и хэштегов...' }));

    // TikTok editor locator strategy
    const editor = surface.locator(
      'div[contenteditable="true"], .DraftEditor-root [contenteditable="true"], [data-text="true"]'
    ).first();

    await editor.waitFor({ state: 'visible', timeout: 120000 }).catch(() => {
      throw new Error('Редактор описания TikTok не найден. Публикация не выполнялась.');
    });
    if (await editor.isVisible().catch(() => false)) {
      await editor.click();
      // Select all and type new text
      await page.keyboard.press('Meta+A').catch(() => {});
      await page.keyboard.press('Backspace').catch(() => {});
      await page.keyboard.type(fullText, { delay: 15 });
    } else {
      throw new Error('Редактор описания TikTok не найден. Публикация не выполнялась.');
    }

    // Ensure Public privacy is selected if not draft
    if (!isDraft) {
      const publicRadio = surface.locator('label:has-text("Public"), label:has-text("Все"), input[value="public"]').first();
      if (await publicRadio.isVisible().catch(() => false)) {
        await publicRadio.click().catch(() => {});
      }
    }

    // Check for any anti-bot captcha challenge
    const captchaLocator = surface.locator('#captcha-verify-image, .captcha-verify-container, iframe[src*="captcha"]');
    if (await captchaLocator.isVisible({ timeout: 2000 }).catch(() => false)) {
      console.log(JSON.stringify({
        type: 'captcha_detected',
        platform: 'tiktok',
        message: 'Обнаружена проверка безопасности TikTok (капча). Пожалуйста, завершите её в окне браузера.',
      }));
      // Wait up to 60 seconds for user to solve
      await captchaLocator.waitFor({ state: 'hidden', timeout: 60000 }).catch(() => {});
      if (await captchaLocator.isVisible().catch(() => false)) {
        throw new Error('Проверка TikTok ещё не завершена. Публикация не выполнялась.');
      }
    }

    // Explicitly enable and await both independent checks. The Post button may
    // become actionable while one of them is still running.
    await enableTikTokChecks(surface);
    await waitForTikTokChecks(surface, { progress: message => console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message })) });

    // Click Post or Save to draft
    const postButton = isDraft
      ? surface.locator('button:has-text("Save draft"), button:has-text("Сохранить в черновики")').first()
      : surface.locator('button:has-text("Post"), button:has-text("Опубликовать")').first();

    await postButton.waitFor({ state: 'visible', timeout: 20000 });
    requireTikTokChecksPassed(await readTikTokChecks(surface));
    const existingLinks = new Set(await page.locator('a[href*="/video/"]').evaluateAll(nodes => nodes.map(node => node.href)));
    await postButton.click();

    console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Отправка публикации...' }));

    // Wait for confirmation modal or redirect
    await page.waitForSelector(
      'text="Your video has been uploaded", text="Your video has been posted", text="Видео опубликовано", text="Відео опубліковано", text="Saved to drafts", text="Сохранено в черновики"',
      { timeout: 10 * 60 * 1000 }
    ).catch(() => { throw new Error('TikTok не подтвердил результат отправки. Загрузка оставлена открытой; проверьте профиль перед повтором.'); });

    const links = await page.locator('a[href*="/video/"]').evaluateAll(nodes => nodes.map(node => node.href));
    const candidates = [...new Set(links)].filter(link => !existingLinks.has(link) && /^https:\/\/(www\.)?tiktok\.com\/@[^/]+\/video\/\d+\/?(?:\?.*)?$/.test(link));
    const postURL = candidates.length === 1 ? candidates[0] : null;

    console.log(JSON.stringify({
      type: 'success',
      platform: 'tiktok',
      message: isDraft ? 'Шортс сохранён в черновики TikTok!' : 'Шортс успешно опубликован в TikTok!',
      url: postURL,
    }));
  } catch (error) {
    error.keepBrowserOpen = fileSelected && !page.isClosed?.();
    if (fileSelected && options.captureFailure) await options.captureFailure(error).catch(() => {});
    else if (fileSelected) {
      try {
        const dir = path.join(os.homedir(), 'Library', 'Logs', 'Shortcast', 'browser-publisher', String(Date.now()));
        fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
        const status = await readTikTokChecks(surface).catch(() => ({}));
        fs.writeFileSync(path.join(dir, 'tiktok-state.json'), JSON.stringify({ message: error.message, status }, null, 2));
        await page.screenshot({ path: path.join(dir, 'tiktok.png') }).catch(() => {});
      } catch { /* Preserve the publication failure even if diagnostics fail. */ }
    }
    throw error;
  }
}
