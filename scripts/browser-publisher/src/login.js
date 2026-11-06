import { launchBrowser } from './browser.js';
import { readTikTokStudioAccount } from './tiktok-account.js';

/**
 * Checks authentication status for TikTok and YouTube based on cookies.
 *
 * @param {import('playwright-core').BrowserContext} context
 * @returns {Promise<{ tiktok: boolean, youtube: boolean }>}
 */
export async function checkAuthStatus(context) {
  const cookies = await context.cookies();

  const tiktok = cookies.some(
    (c) => c.domain.includes('tiktok.com') && (c.name === 'sessionid' || c.name === 'sid_guard')
  );

  const youtube = cookies.some(
    (c) => (c.domain.includes('youtube.com') || c.domain.includes('google.com')) &&
           (c.name === 'SID' || c.name === 'SAPISID' || c.name === 'LOGIN_INFO')
  );

  let tiktokHandle = null;
  if (tiktok) {
    try { tiktokHandle = await readTikTokStudioAccount(context); } catch {}
  }
  return { tiktok, youtube, tiktokHandle };
}

/**
 * Opens a visible browser window with tabs for TikTok and YouTube Studio
 * allowing the user to log in naturally. Waits until the user closes the window.
 */
export async function openInteractiveLogin({ tiktokOnly = false } = {}) {
  const { context, page } = await launchBrowser({ headless: false });

  console.log(JSON.stringify({
    type: 'status',
    message: tiktokOnly
      ? 'Войдите в TikTok @telonyx_cinema в открывшемся Chrome, затем закройте это окно Chrome, чтобы сохранить вход.'
      : 'Окно Chrome открыто. Войдите в ваши аккаунты TikTok и YouTube Studio. Закройте браузер после завершения.',
  }));

  // Tab 1: TikTok Creator Center
  await page.goto('https://www.tiktok.com/tiktokstudio', { waitUntil: 'domcontentloaded' }).catch(() => {});


  // Tab 2: YouTube Studio
  if (!tiktokOnly) {
    const ytPage = await context.newPage();
    await ytPage.goto('https://studio.youtube.com', { waitUntil: 'domcontentloaded' }).catch(() => {});
  }

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
