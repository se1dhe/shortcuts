/**
 * Automation module for publishing Reels to Instagram Web.
 *
 * @param {import('playwright-core').Page} page
 * @param {Object} postData
 * @param {string} postData.videoPath - Absolute path to the .mp4 file
 * @param {string} postData.caption - Caption text
 * @param {string[]} postData.hashtags - Array of hashtags
 */
export async function uploadToInstagram(page, { videoPath, caption, hashtags = [] }) {
  console.log(JSON.stringify({ type: 'progress', platform: 'instagram', message: 'Открытие Instagram Web...' }));

  await page.goto('https://www.instagram.com', {
    waitUntil: 'networkidle',
    timeout: 45000,
  });

  // Check login state
  const isLoginPage = page.url().includes('/accounts/login') ||
    (await page.locator('input[name="username"]').count()) > 0;

  if (isLoginPage) {
    throw new Error('Не авторизован в Instagram. Выполните вход через кнопку "Войти в аккаунты".');
  }

  // Dismiss any "Not Now" / "Не сейчас" popups (notifications, save login info)
  const notNowBtn = page.locator('button:has-text("Not Now"), button:has-text("Не сейчас")').first();
  if (await notNowBtn.isVisible({ timeout: 4000 }).catch(() => false)) {
    await notNowBtn.click().catch(() => {});
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'instagram', message: 'Открытие меню создания публикации...' }));

  // Click Create button in sidebar
  const createButton = page.locator(
    'svg[aria-label="New post"], svg[aria-label="Новая публикация"], a[href="#"]:has-text("Create"), a:has-text("Создать")'
  ).first();

  await createButton.waitFor({ state: 'visible', timeout: 20000 });
  await createButton.click();

  // If a dropdown appears (Post vs Live), click Post / Публикация
  const postItem = page.locator('span:has-text("Post"), span:has-text("Публикация")').first();
  if (await postItem.isVisible({ timeout: 2000 }).catch(() => false)) {
    await postItem.click().catch(() => {});
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'instagram', message: 'Выбор видеофайла...' }));

  // File input
  const fileInput = page.locator('input[type="file"]').first();
  await fileInput.waitFor({ state: 'attached', timeout: 15000 });
  await fileInput.setInputFiles(videoPath);

  // If modal "Video posts are now shared as reels" appears, click OK
  const okReelsBtn = page.locator('button:has-text("OK"), button:has-text("Понятно")').first();
  if (await okReelsBtn.isVisible({ timeout: 4000 }).catch(() => false)) {
    await okReelsBtn.click().catch(() => {});
  }

  await page.waitForTimeout(2000);

  // Click Next (Далее) to filters
  const nextButton1 = page.locator('button:has-text("Next"), div[role="button"]:has-text("Далее")').first();
  await nextButton1.waitFor({ state: 'visible', timeout: 15000 });
  await nextButton1.click();

  await page.waitForTimeout(2000);

  // Click Next (Далее) to caption & sharing
  const nextButton2 = page.locator('button:has-text("Next"), div[role="button"]:has-text("Далее")').first();
  await nextButton2.waitFor({ state: 'visible', timeout: 15000 });
  await nextButton2.click();

  console.log(JSON.stringify({ type: 'progress', platform: 'instagram', message: 'Ввод описания и хэштегов...' }));

  // Fill caption
  const fullText = [caption, hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' ')]
    .filter(Boolean)
    .join(' ');

  const captionArea = page.locator(
    'div[aria-label*="caption"], div[aria-label*="подпись"], div[contenteditable="true"]'
  ).first();

  await captionArea.waitFor({ state: 'visible', timeout: 15000 });
  await captionArea.click();
  await page.keyboard.type(fullText, { delay: 10 });

  await page.waitForTimeout(1500);

  // Click Share (Поделиться)
  console.log(JSON.stringify({ type: 'progress', platform: 'instagram', message: 'Публикация Reels...' }));

  const shareButton = page.locator('button:has-text("Share"), div[role="button"]:has-text("Поделиться")').first();
  await shareButton.waitFor({ state: 'visible', timeout: 15000 });
  await shareButton.click();

  // Wait for success indicator
  await page.waitForSelector(
    'text="Your reel has been shared", text="Ваш видеоролик опубликован", text="Reel shared", text="Публикация отправлена"',
    { timeout: 60000 }
  );

  console.log(JSON.stringify({
    type: 'success',
    platform: 'instagram',
    message: 'Reels успешно опубликован в Instagram!',
  }));
}
