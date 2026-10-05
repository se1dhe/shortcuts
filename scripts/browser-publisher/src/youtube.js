import fs from 'fs';

/**
 * Automation module for publishing videos and Shorts to YouTube Studio.
 *
 * @param {import('playwright-core').Page} page
 * @param {Object} postData
 * @param {string} postData.videoPath - Absolute path to the .mp4 file
 * @param {string} [postData.thumbnailPath] - Absolute path to the thumbnail image file (1920x1080)
 * @param {string} postData.title - Video title
 * @param {string} postData.caption - Description text
 * @param {string[]} postData.hashtags - Array of hashtags
 * @param {boolean} [postData.isPublic=true] - Whether to publish Public
 * @param {boolean} [postData.isShort=false] - Whether this is a 9:16 Short
 */
export async function uploadToYouTube(page, { videoPath, thumbnailPath, title, caption, hashtags = [], isPublic = true, isShort = false }) {
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
    throw new Error('Не авторизован в YouTube Studio. Выполните вход через кнопку "Войти в Google…".');
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
  await page.waitForSelector('#title-textarea, #textbox[aria-label*="title" i], #textbox[aria-label*="назван" i]', { timeout: 60000 });

  // YouTube Studio asynchronously initializes title to the file name. Wait 3 seconds for this initial setup to settle.
  await page.waitForTimeout(3000);

  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Заполнение названия видео...' }));

  // Format title (append #Shorts only if this is a short)
  let formattedTitle = (title || 'Video').trim();
  if (isShort && !formattedTitle.toLowerCase().includes('#shorts')) {
    formattedTitle += ' #Shorts';
  }
  const cleanTitle = formattedTitle.slice(0, 100);

  // Set Title (handle Polymer web-components and asynchronous filename injection)
  const titleBox = page.locator('#title-textarea #textbox, ytcp-social-suggestions-textbox#title-textarea [contenteditable="true"], #title-textarea [contenteditable="true"], [aria-label*="title" i], [aria-label*="назван" i]').first();
  await titleBox.waitFor({ state: 'visible', timeout: 30000 });
  await titleBox.scrollIntoViewIfNeeded().catch(() => {});
  await titleBox.click();
  await page.waitForTimeout(300);

  // Select all and clear
  await titleBox.press('ControlOrMeta+a').catch(() => {});
  await titleBox.press('Backspace').catch(() => {});
  await page.waitForTimeout(200);

  // Force DOM clear and set via evaluate to guarantee custom Polymer event dispatch
  await page.evaluate(({ el, text }) => {
    if (el) {
      el.innerText = text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }, { el: await titleBox.elementHandle(), text: cleanTitle }).catch(() => {});

  // Also type text to trigger synthetic keyboard events if needed
  await page.waitForTimeout(300);
  const currentTitle = await titleBox.innerText().catch(() => '');
  if (!currentTitle || currentTitle !== cleanTitle) {
    await titleBox.click();
    await titleBox.press('ControlOrMeta+a').catch(() => {});
    await titleBox.press('Backspace').catch(() => {});
    await page.keyboard.type(cleanTitle, { delay: 15 });
  }

  // Set Description
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Заполнение описания видео...' }));
  const descParts = [
    caption,
    hashtags.map((h) => (h.startsWith('#') ? h : `#${h}`)).join(' '),
  ];
  if (isShort) {
    descParts.push('#Shorts');
  }
  const fullDescription = descParts.filter(Boolean).join('\n\n');
  const cleanDesc = fullDescription.slice(0, 4950);

  const descBox = page.locator('#description-textarea #textbox, ytcp-social-suggestions-textbox#description-textarea [contenteditable="true"], #description-textarea [contenteditable="true"], [aria-label*="description" i], [aria-label*="описан" i]').first();
  await descBox.scrollIntoViewIfNeeded().catch(() => {});
  await descBox.waitFor({ state: 'visible', timeout: 25000 });
  await descBox.click();
  await page.waitForTimeout(300);

  await descBox.press('ControlOrMeta+a').catch(() => {});
  await descBox.press('Backspace').catch(() => {});
  await page.waitForTimeout(200);

  // Use DOM injection for instant and complete filling of large descriptions
  await page.evaluate(({ el, text }) => {
    if (el) {
      el.innerText = text;
      el.dispatchEvent(new Event('input', { bubbles: true }));
      el.dispatchEvent(new Event('change', { bubbles: true }));
    }
  }, { el: await descBox.elementHandle(), text: cleanDesc }).catch(() => {});
  await page.waitForTimeout(500);

  // Upload Thumbnail if provided
  if (thumbnailPath && fs.existsSync(thumbnailPath)) {
    console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Загрузка авторской обложки (1920x1080)...' }));
    try {
      const thumbInput = page.locator('input#file-loader, input[type="file"][accept*="image"]').first();
      if ((await thumbInput.count()) > 0) {
        await thumbInput.setInputFiles(thumbnailPath);
        await page.waitForTimeout(3000);
        console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Обложка успешно загружена в YouTube Studio' }));
      } else {
        const thumbBtn = page.locator('#select-button, [aria-label*="thumbnail" i], [aria-label*="значок" i]').first();
        await thumbBtn.scrollIntoViewIfNeeded().catch(() => {});
        if (await thumbBtn.isVisible().catch(() => false)) {
          const [fileChooser] = await Promise.all([
            page.waitForEvent('filechooser', { timeout: 10000 }),
            thumbBtn.click(),
          ]);
          await fileChooser.setFiles(thumbnailPath);
          await page.waitForTimeout(3000);
          console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Обложка успешно передана через диалог' }));
        }
      }
    } catch (thumbErr) {
      console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: `Предупреждение по обложке: ${thumbErr.message}` }));
    }
  }

  // Set Audience: "Not made for kids" (mandatory in YouTube Studio)
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Выбор аудитории (видео не для детей)...' }));
  const notForKidsRadio = page.locator('tp-yt-paper-radio-button[name="VIDEO_MADE_FOR_KIDS_NOT_MFK"], [name="VIDEO_MADE_FOR_KIDS_NOT_MFK"], [aria-label*="не для детей" i], [aria-label*="not made for kids" i]').first();
  await notForKidsRadio.scrollIntoViewIfNeeded().catch(() => {});
  await notForKidsRadio.waitFor({ state: 'visible', timeout: 15000 });
  await notForKidsRadio.click();
  await page.waitForTimeout(800);

  // Navigate through steps (Details -> Elements -> Checks -> Visibility)
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Переход к параметрам доступа...' }));
  const publicRadio = page.locator('tp-yt-paper-radio-button[name="PUBLIC"], [name="PUBLIC"], [aria-label*="Открытый" i], [aria-label*="Public" i]').first();
  const unlistedRadio = page.locator('tp-yt-paper-radio-button[name="UNLISTED"], [name="UNLISTED"], [aria-label*="Доступ по ссылке" i], [aria-label*="Unlisted" i]').first();

  for (let step = 0; step < 5; step++) {
    if ((await publicRadio.isVisible().catch(() => false)) || (await unlistedRadio.isVisible().catch(() => false))) {
      break;
    }

    const nextBtn = page.locator('#next-button, button:has-text("Next"), button:has-text("Далее")').first();
    await nextBtn.scrollIntoViewIfNeeded().catch(() => {});
    await nextBtn.waitFor({ state: 'visible', timeout: 12000 });

    // Wait until Next button is enabled
    for (let w = 0; w < 10; w++) {
      if (await nextBtn.isEnabled().catch(() => false)) break;
      await page.waitForTimeout(500);
    }

    await nextBtn.click();
    await page.waitForTimeout(1500);
  }

  // Set Visibility
  console.log(JSON.stringify({
    type: 'progress',
    platform: 'youtube',
    message: isPublic ? 'Установка открытого доступа (Public)...' : 'Установка доступа по ссылке (Unlisted)...',
  }));

  if (isPublic) {
    await publicRadio.waitFor({ state: 'visible', timeout: 15000 });
    await publicRadio.scrollIntoViewIfNeeded().catch(() => {});
    await publicRadio.click();
  } else {
    await unlistedRadio.waitFor({ state: 'visible', timeout: 15000 });
    await unlistedRadio.scrollIntoViewIfNeeded().catch(() => {});
    await unlistedRadio.click();
  }
  await page.waitForTimeout(1000);

  // Click Publish / Save (#done-button)
  console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message: 'Публикация видео на YouTube...' }));

  const doneBtn = page.locator('#done-button, button:has-text("Save"), button:has-text("Опубликовать"), button:has-text("Publish")').first();
  await doneBtn.waitFor({ state: 'visible', timeout: 20000 });

  for (let w = 0; w < 10; w++) {
    if (await doneBtn.isEnabled().catch(() => false)) break;
    await page.waitForTimeout(500);
  }
  await doneBtn.click();

  // Wait for upload completion confirmation dialog
  await page.waitForSelector(
    'ytcp-video-share-dialog, #share-url, a[href*="youtu.be"], text="Video published", text="Видео опубликовано", text="Processing", text="Обработка"',
    { timeout: 60000 }
  ).catch(() => {});

  let videoUrl = null;
  const shareLink = page.locator('a.ytcp-video-share-dialog, a[href*="youtu.be"], #share-url').first();
  if (await shareLink.isVisible().catch(() => false)) {
    videoUrl = (await shareLink.getAttribute('href')) || (await shareLink.innerText().catch(() => null));
  }

  console.log(JSON.stringify({
    type: 'success',
    platform: 'youtube',
    message: isShort ? 'YouTube Shorts успешно опубликован!' : 'Видео успешно опубликовано на YouTube!',
    url: videoUrl,
  }));
}
