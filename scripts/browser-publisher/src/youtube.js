/**
 * Automation module for publishing Shorts to YouTube Studio.
 *
 * @param {import('playwright-core').Page} page
 * @param {Object} postData
 * @param {string} postData.videoPath - Absolute path to the .mp4 file
 * @param {string} postData.title - Video title
 * @param {string} postData.caption - Description text
 * @param {string[]} postData.hashtags - Array of hashtags
 * @param {boolean} [postData.isPublic=true] - Whether to publish Public
 */
export async function uploadToYouTube(page, { videoPath, title, caption, hashtags = [], isPublic = true, isShort = false }) {
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Открытие YouTube Studio...' }));

  await page.goto('https://studio.youtube.com', {
    waitUntil: 'domcontentloaded',
    timeout: 60000,
  });

  // Short pause for SPA hydration
  await page.waitForTimeout(2500);

  // Check login state
  const isLoginPage = page.url().includes('accounts.google.com') ||
    (await page.locator('a:has-text("Sign in"), a:has-text("Войти"), input[type="email"]').count()) > 0;

  if (isLoginPage) {
    throw new Error('Не авторизован в YouTube Studio. Выполните вход через кнопку "Войти в аккаунты".');
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Открытие меню загрузки видео...' }));

  // Click Create button or Upload button
  const createBtn = page.locator('#create-icon, ytcp-button#create-icon, #upload-button, ytcp-button#upload-button, button:has-text("Create"), button:has-text("Создать")').first();
  await createBtn.waitFor({ state: 'visible', timeout: 30000 });
  await createBtn.click();

  // Click Upload videos if dropdown appeared
  const uploadItem = page.locator('tp-yt-paper-item:has-text("Upload videos"), tp-yt-paper-item:has-text("Добавить видео"), [test-id="upload-videos"]').first();
  if (await uploadItem.isVisible({ timeout: 4000 }).catch(() => false)) {
    await uploadItem.click();
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Выбор видеофайла для загрузки...' }));

  // File input
  const fileInput = page.locator('input[type="file"]').first();
  await fileInput.waitFor({ state: 'attached', timeout: 20000 });
  await fileInput.setInputFiles(videoPath);

  // Wait for details form to appear
  await page.waitForSelector('#title-textarea, #textbox[aria-label*="title"]', { timeout: 45000 });

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Заполнение названия и описания видео...' }));

  // Format title (append #Shorts only if this is a short)
  let formattedTitle = (title || 'Video').trim();
  if (isShort && !formattedTitle.toLowerCase().includes('#shorts')) {
    formattedTitle += ' #Shorts';
  }

  // Set Title
  const titleBox = page.locator('div#title-textarea #textbox, #textbox[aria-label*="title"]').first();
  await titleBox.click();
  await page.keyboard.press('Meta+A').catch(() => {});
  await page.keyboard.press('Backspace').catch(() => {});
  await page.keyboard.type(formattedTitle.slice(0, 100), { delay: 10 });

  // Set Description
  const descParts = [
    caption,
    hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' '),
  ];
  if (isShort) {
    descParts.push('#Shorts');
  }
  const fullDescription = descParts.filter(Boolean).join('\n\n');

  const descBox = page.locator('div#description-textarea #textbox, #textbox[aria-label*="description"]').first();
  if (await descBox.isVisible().catch(() => false)) {
    await descBox.click();
    await page.keyboard.press('Meta+A').catch(() => {});
    await page.keyboard.press('Backspace').catch(() => {});
    await page.keyboard.type(fullDescription.slice(0, 4900), { delay: 5 });
  }

  // Set Audience: "Not made for kids" (required by YouTube)
  const notForKidsRadio = page.locator('tp-yt-paper-radio-button[name="VIDEO_MADE_FOR_KIDS_NOT_MFK"], [aria-label*="не для детей"], [aria-label*="not made for kids"]').first();
  await notForKidsRadio.scrollIntoViewIfNeeded().catch(() => {});
  await notForKidsRadio.click().catch(() => {});

  // Step 1 -> Step 2 (Elements)
  const nextBtn = page.locator('#next-button, button:has-text("Next"), button:has-text("Далее")').first();
  await nextBtn.waitFor({ state: 'visible', timeout: 15000 });
  await nextBtn.click();
  await page.waitForTimeout(1000);

  // Step 2 -> Step 3 (Checks)
  await nextBtn.click();
  await page.waitForTimeout(1000);

  // Step 3 -> Step 4 (Visibility)
  await nextBtn.click();
  await page.waitForTimeout(1500);

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Установка доступа к видео...' }));

  // Set Visibility
  if (isPublic) {
    const publicRadio = page.locator('tp-yt-paper-radio-button[name="PUBLIC"], [aria-label*="Открытый"], [aria-label*="Public"]').first();
    await publicRadio.scrollIntoViewIfNeeded().catch(() => {});
    await publicRadio.click().catch(() => {});
  } else {
    const unlistedRadio = page.locator('tp-yt-paper-radio-button[name="UNLISTED"], [aria-label*="Доступ по ссылке"], [aria-label*="Unlisted"]').first();
    await unlistedRadio.scrollIntoViewIfNeeded().catch(() => {});
    await unlistedRadio.click().catch(() => {});
  }

  // Click Publish / Save (#done-button)
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Публикация на YouTube...' }));

  const doneBtn = page.locator('#done-button, button:has-text("Save"), button:has-text("Опубликовать"), button:has-text("Publish")').first();
  await doneBtn.waitFor({ state: 'visible', timeout: 20000 });
  await doneBtn.click();

  // Wait for upload completion confirmation dialog
  await page.waitForSelector(
    'ytcp-video-share-dialog, #share-url, text="Video published", text="Видео опубликовано", text="Processing", text="Обработка"',
    { timeout: 60000 }
  ).catch(() => {});

  let videoUrl = null;
  const shareLink = page.locator('a.ytcp-video-share-dialog, a[href*="youtu.be"]').first();
  if (await shareLink.isVisible().catch(() => false)) {
    videoUrl = await shareLink.getAttribute('href');
  }

  console.log(JSON.stringify({
    type: 'success',
    platform: 'youtube',
    message: isShort ? 'YouTube Shorts успешно опубликован!' : 'Видео успешно опубликовано на YouTube!',
    url: videoUrl,
  }));
}
