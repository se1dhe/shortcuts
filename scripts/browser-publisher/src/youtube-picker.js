// Studio keeps an uploads host in the DOM even when it has no visible box.
// Its presence (or an attached hidden file input) is not evidence that the
// picker is open. Wait for the rendered control and use its file chooser.
export const SELECT_FILES_NAME = /^(Select files|Выбрать файлы|Вибрати файли|Обрати файли)$/i;

export async function openYouTubeFilePicker(page, { timeoutMs = 30000, now = Date.now } = {}) {
  const picker = page.getByRole('button', { name: SELECT_FILES_NAME }).first();
  if (await picker.isVisible()) return picker;
  const create = page.locator('#create-icon:visible, #upload-button:visible, button:has-text("Create"):visible, button:has-text("Создать"):visible, button:has-text("Створити"):visible').first();
  await create.click({ timeout: timeoutMs });
  const menuItem = page.getByRole('menuitem', { name: /Upload videos|Добавить видео|Загрузить видео|Завантажити відео/i })
    .or(page.locator('tp-yt-paper-item:has-text("Upload videos"):visible, tp-yt-paper-item:has-text("Добавить видео"):visible, tp-yt-paper-item:has-text("Завантажити відео"):visible, [test-id="upload-videos"]:visible')).first();
  let menuClicked = false;
  const deadline = now() + timeoutMs;
  while (now() < deadline) {
    if (await picker.isVisible()) return picker;
    if (!menuClicked && await menuItem.isVisible()) {
      await menuItem.click({ timeout: Math.max(1, deadline - now()) });
      menuClicked = true;
    }
    await page.waitForTimeout(250);
  }
  throw new Error('YouTube не показал кнопку «Выбрать файлы». Файл не отправлялся. Проверьте окно Studio.');
}

export async function selectYouTubeVideoFile(page, picker, videoPath) {
  // Subscribe before clicking so a fast native chooser cannot be missed.
  const [chooser] = await Promise.all([
    page.waitForEvent('filechooser', { timeout: 30000 }),
    picker.click({ timeout: 30000 }),
  ]);
  await chooser.setFiles(videoPath);
}
