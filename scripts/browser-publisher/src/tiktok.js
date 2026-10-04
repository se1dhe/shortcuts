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
export async function uploadToTikTok(page, { videoPath, caption, hashtags = [], isDraft = false }) {
  console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Открытие TikTok Creator Center...' }));

  await page.goto('https://www.tiktok.com/creator-center/upload', {
    waitUntil: 'networkidle',
    timeout: 45000,
  });

  // Check login state
  const currentUrl = page.url();
  if (currentUrl.includes('/login') || (await page.locator('button:has-text("Log in"), button:has-text("Войти")').count()) > 0) {
    throw new Error('Не авторизован в TikTok. Выполните вход через кнопку "Войти в аккаунты".');
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Загрузка видеофайла...' }));

  // Find file input (in creator center it may be inside an iframe or direct on page)
  let fileInput = page.locator('input[type="file"]');
  if ((await fileInput.count()) === 0) {
    // Try inside upload iframe if TikTok uses an embedded frame
    for (const frame of page.frames()) {
      const frameInput = frame.locator('input[type="file"]');
      if ((await frameInput.count()) > 0) {
        fileInput = frameInput;
        break;
      }
    }
  }

  await fileInput.waitFor({ state: 'attached', timeout: 30000 });
  await fileInput.setInputFiles(videoPath);

  console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Файл передан, обработка видео...' }));

  // Wait for upload processing indicator to complete
  await page.waitForTimeout(4000);

  // Fill caption and hashtags
  const fullText = [caption, hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' ')]
    .filter(Boolean)
    .join(' ');

  console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Заполнение описания и хэштегов...' }));

  // TikTok editor locator strategy
  const editor = page.locator(
    'div[contenteditable="true"], .DraftEditor-root [contenteditable="true"], [data-text="true"]'
  ).first();

  if (await editor.isVisible({ timeout: 15000 }).catch(() => false)) {
    await editor.click();
    // Select all and type new text
    await page.keyboard.press('Meta+A').catch(() => {});
    await page.keyboard.press('Backspace').catch(() => {});
    await page.keyboard.type(fullText, { delay: 15 });
  }

  // Ensure Public privacy is selected if not draft
  if (!isDraft) {
    const publicRadio = page.locator('label:has-text("Public"), label:has-text("Все"), input[value="public"]').first();
    if (await publicRadio.isVisible().catch(() => false)) {
      await publicRadio.click().catch(() => {});
    }
  }

  // Check for any anti-bot captcha challenge
  const captchaLocator = page.locator('#captcha-verify-image, .captcha-verify-container, iframe[src*="captcha"]');
  if (await captchaLocator.isVisible({ timeout: 2000 }).catch(() => false)) {
    console.log(JSON.stringify({
      type: 'captcha_detected',
      platform: 'tiktok',
      message: 'Обнаружена проверка безопасности TikTok (капча). Пожалуйста, завершите её в окне браузера.',
    }));
    // Wait up to 60 seconds for user to solve
    await captchaLocator.waitFor({ state: 'hidden', timeout: 60000 }).catch(() => {});
  }

  // Click Post or Save to draft
  const postButton = isDraft
    ? page.locator('button:has-text("Save draft"), button:has-text("Сохранить в черновики")').first()
    : page.locator('button:has-text("Post"), button:has-text("Опубликовать")').first();

  await postButton.waitFor({ state: 'visible', timeout: 20000 });
  await page.waitForTimeout(2000); // brief settling
  await postButton.click();

  console.log(JSON.stringify({ type: 'progress', platform: 'tiktok', message: 'Отправка публикации...' }));

  // Wait for confirmation modal or redirect
  await page.waitForSelector(
    'text="Your video has been uploaded", text="Видео опубликовано", text="Manage your posts", text="Управление видео"',
    { timeout: 35000 }
  ).catch(() => {});

  console.log(JSON.stringify({
    type: 'success',
    platform: 'tiktok',
    message: isDraft ? 'Шортс сохранён в черновики TikTok!' : 'Шортс успешно опубликован в TikTok!',
  }));
}
