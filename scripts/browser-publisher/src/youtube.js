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
export async function uploadToYouTube(page, { videoPath, title, caption, hashtags = [], isPublic = true }) {
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Открытие YouTube Studio...' }));

  await page.goto('https://studio.youtube.com', {
    waitUntil: 'networkidle',
    timeout: 45000,
  });

  // Check login state
  if (page.url().includes('accounts.google.com') || (await page.locator('a:has-text("Sign in"), a:has-text("Войти")').count()) > 0) {
    throw new Error('Не авторизован в YouTube Studio. Выполните вход через кнопку "Войти в аккаунты".');
  }

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Открытие меню загрузки видео...' }));

  // Click Create button
  const createBtn = page.locator('#create-icon, ytcp-button#create-icon, button:has-text("Create"), button:has-text("Создать")').first();
  await createBtn.waitFor({ state: 'visible', timeout: 20000 });
  await createBtn.click();

  // Click Upload videos
  const uploadItem = page.locator('tp-yt-paper-item:has-text("Upload videos"), tp-yt-paper-item:has-text("Добавить видео")').first();
  await uploadItem.waitFor({ state: 'visible', timeout: 15000 });
  await uploadItem.click();

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Выбор видеофайла для загрузки...' }));

  // File input
  const fileInput = page.locator('input[type="file"]').first();
  await fileInput.waitFor({ state: 'attached', timeout: 15000 });
  await fileInput.setInputFiles(videoPath);

  // Wait for details form to appear
  await page.waitForSelector('#title-textarea, #textbox[aria-label*="title"]', { timeout: 35000 });

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Заполнение названия и описания Shorts...' }));

  // Format title with #Shorts
  let formattedTitle = (title || 'Shorts').trim();
  if (!formattedTitle.toLowerCase().includes('#shorts')) {
    formattedTitle += ' #Shorts';
  }

  // Set Title
  const titleBox = page.locator('div#title-textarea #textbox, #textbox[aria-label*="title"]').first();
  await titleBox.click();
  await page.keyboard.press('Meta+A').catch(() => {});
  await page.keyboard.press('Backspace').catch(() => {});
  await page.keyboard.type(formattedTitle.slice(0, 100), { delay: 10 });

  // Set Description
  const fullDescription = [
    caption,
    hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' '),
    '#Shorts',
  ]
    .filter(Boolean)
    .join('\n\n');

  const descBox = page.locator('div#description-textarea #textbox, #textbox[aria-label*="description"]').first();
  if (await descBox.isVisible().catch(() => false)) {
    await descBox.click();
    await page.keyboard.type(fullDescription.slice(0, 4900), { delay: 5 });
  }

  // Set Audience: "Not made for kids" (required by YouTube)
  const notForKidsRadio = page.locator('tp-yt-paper-radio-button[name="VIDEO_MADE_FOR_KIDS_NOT_MFK"]').first();
  await notForKidsRadio.scrollIntoViewIfNeeded().catch(() => {});
  await notForKidsRadio.click().catch(() => {});

  // Step 1 -> Step 2 (Elements)
  const nextBtn = page.locator('#next-button, button:has-text("Next"), button:has-text("Далее")').first();
  await nextBtn.click();
  await page.waitForTimeout(1000);

  // Step 2 -> Step 3 (Checks)
  await nextBtn.click();
  await page.waitForTimeout(1000);

  // Step 3 -> Step 4 (Visibility)
  await nextBtn.click();
  await page.waitForTimeout(1500);

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Установка открытого доступа...' }));

  // Set Visibility
  if (isPublic) {
    const publicRadio = page.locator('tp-yt-paper-radio-button[name="PUBLIC"]').first();
    await publicRadio.click().catch(() => {});
  } else {
    const unlistedRadio = page.locator('tp-yt-paper-radio-button[name="UNLISTED"]').first();
    await unlistedRadio.click().catch(() => {});
  }

  // Click Publish / Save (#done-button)
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Публикация YouTube Shorts...' }));

  const doneBtn = page.locator('#done-button, button:has-text("Save"), button:has-text("Опубликовать")').first();
  await doneBtn.waitFor({ state: 'visible', timeout: 15000 });
  await doneBtn.click();

  // Wait for upload completion confirmation dialog
  await page.waitForSelector(
    'ytcp-video-share-dialog, #share-url, text="Video published", text="Видео опубликовано"',
    { timeout: 45000 }
  ).catch(() => {});

  let videoUrl = null;
  const shareLink = page.locator('a.ytcp-video-share-dialog, a[href*="youtu.be"]').first();
  if (await shareLink.isVisible().catch(() => false)) {
    videoUrl = await shareLink.getAttribute('href');
  }

  console.log(JSON.stringify({
    type: 'success',
    platform: 'youtube',
    message: 'YouTube Shorts успешно опубликован!',
    url: videoUrl,
  }));
}
