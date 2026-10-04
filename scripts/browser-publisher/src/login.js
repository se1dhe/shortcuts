import { launchBrowser } from './browser.js';

/**
 * Checks authentication status for TikTok, Instagram, and YouTube based on cookies.
 *
 * @param {import('playwright-core').BrowserContext} context
 * @returns {Promise<{ tiktok: boolean, instagram: boolean, youtube: boolean }>}
 */
export async function checkAuthStatus(context) {
  const cookies = await context.cookies();

  const tiktok = cookies.some(
    (c) => c.domain.includes('tiktok.com') && (c.name === 'sessionid' || c.name === 'sid_guard')
  );

  const instagram = cookies.some(
    (c) => c.domain.includes('instagram.com') && (c.name === 'sessionid' || c.name === 'ds_user_id')
  );

  const youtube = cookies.some(
    (c) => (c.domain.includes('youtube.com') || c.domain.includes('google.com')) &&
           (c.name === 'SID' || c.name === 'SAPISID' || c.name === 'LOGIN_INFO')
  );

  return { tiktok, instagram, youtube };
}

/**
 * Opens a visible browser window with tabs for TikTok, Instagram, and YouTube Studio
 * allowing the user to log in naturally. Waits until the user closes the window.
 */
export async function openInteractiveLogin() {
  const { context, page } = await launchBrowser({ headless: false });

  console.log(JSON.stringify({
    type: 'status',
    message: 'Окно Chrome открыто. Войдите в ваши аккаунты TikTok, Instagram и YouTube Studio. Закройте браузер после завершения.',
  }));

  // Tab 1: TikTok Creator Center
  await page.goto('https://www.tiktok.com/creator-center/upload', { waitUntil: 'domcontentloaded' }).catch(() => {});

  // Tab 2: Instagram
  const igPage = await context.newPage();
  await igPage.goto('https://www.instagram.com', { waitUntil: 'domcontentloaded' }).catch(() => {});

  // Tab 3: YouTube Studio
  const ytPage = await context.newPage();
  await ytPage.goto('https://studio.youtube.com', { waitUntil: 'domcontentloaded' }).catch(() => {});

  // Keep alive until all pages/context are closed by user
  await new Promise((resolve) => {
    context.on('close', resolve);

    // Periodically check if all pages are closed
    const interval = setInterval(async () => {
      try {
        if (context.pages().length === 0) {
          clearInterval(interval);
          await context.close().catch(() => {});
          resolve();
        }
      } catch {
        clearInterval(interval);
        resolve();
      }
    }, 1500);
  });

  // Allow Chrome to flush cookies to disk and exit cleanly
  await new Promise((r) => setTimeout(r, 1500));

  // Re-open headless to inspect cookies and report auth status
  const headlessSession = await launchBrowser({ headless: true });
  const authReport = await checkAuthStatus(headlessSession.context);
  await headlessSession.context.close().catch(() => {});

  console.log(JSON.stringify({
    type: 'auth_report',
    auth: authReport,
    message: 'Сессия сохранена локально в BrowserProfile.',
  }));

  return authReport;
}
