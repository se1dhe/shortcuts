import { chromium } from 'playwright-core';
import path from 'path';
import os from 'os';
import fs from 'fs';

const CHROME_PATH = '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome';
const DEFAULT_PROFILE_DIR = path.join(
  os.homedir(),
  'Library',
  'Application Support',
  'Shortcast',
  'BrowserProfile'
);

/**
 * Returns the default persistent profile directory, ensuring it exists.
 */
export function getProfileDirectory() {
  if (!fs.existsSync(DEFAULT_PROFILE_DIR)) {
    fs.mkdirSync(DEFAULT_PROFILE_DIR, { recursive: true });
  }
  return DEFAULT_PROFILE_DIR;
}

/**
 * Release only a proven stale local lock. Never terminate an active browser:
 * a second auth check must not kill a video that is still uploading.
 */
export function cleanStaleLocks(profileDir = getProfileDirectory()) {
  const lock = path.join(profileDir, 'SingletonLock');
  let target;
  try {
    target = fs.readlinkSync(lock);
  } catch (error) {
    if (error.code === 'ENOENT') return;
    throw new Error('Профиль Chrome занят или его блокировку нельзя проверить. Завершите текущее окно браузера перед новым запуском.');
  }
  const match = target.match(/^(.*)-(\d+)$/);
  if (!match || match[1] !== os.hostname()) {
    throw new Error('Профиль Chrome занят. Его блокировка не удалялась.');
  }
  let alive = true;
  try { process.kill(Number(match[2]), 0); }
  catch (error) { if (error.code === 'ESRCH') alive = false; }
  if (alive) throw new Error('Профиль Chrome уже используется. Дождитесь текущей загрузки или закройте окно входа. Видео не прерывалось.');

  const lockFiles = ['SingletonLock', 'SingletonCookie', 'SingletonSocket'];
  for (const file of lockFiles) {
    const filePath = path.join(profileDir, file);
    try {
      const stats = fs.lstatSync(filePath);
      if (stats.isSymbolicLink() || stats.isFile()) {
        fs.unlinkSync(filePath);
      }
    } catch {}
  }
}

/**
 * Launches a persistent browser context using native Google Chrome.
 *
 * @param {Object} options
 * @param {boolean} [options.headless=true] - Whether to run headlessly.
 * @param {string} [options.profileDir] - Custom profile directory.
 * @returns {Promise<{ context: import('playwright-core').BrowserContext, page: import('playwright-core').Page }>}
 */
export async function launchBrowser({ headless = true, profileDir = getProfileDirectory() } = {}) {
  if (!fs.existsSync(CHROME_PATH)) {
    throw new Error(`Google Chrome not found at ${CHROME_PATH}. Please install Google Chrome.`);
  }

  // An active profile is an error, never a reason to kill its process.
  cleanStaleLocks(profileDir);

  const args = [
    '--disable-blink-features=AutomationControlled',
    '--no-default-browser-check',
    '--disable-infobars',
    '--window-size=1280,850',
    '--start-maximized',
  ];

  const context = await chromium.launchPersistentContext(profileDir, {
    executablePath: CHROME_PATH,
    headless: headless,
    viewport: null, // use actual window size
    args,
    ignoreDefaultArgs: ['--enable-automation'],
  });

  // Apply stealth evasions on every new page
  await context.addInitScript(() => {
    // 1. Hide navigator.webdriver
    Object.defineProperty(navigator, 'webdriver', {
      get: () => undefined,
    });

    // 2. Mock chrome runtime object
    window.chrome = {
      runtime: {},
      loadTimes: () => {},
      csi: () => {},
      app: {},
    };

    // 3. Mock languages & plugins
    Object.defineProperty(navigator, 'languages', {
      get: () => ['ru-RU', 'ru', 'en-US', 'en'],
    });

    Object.defineProperty(navigator, 'plugins', {
      get: () => [1, 2, 3, 4, 5],
    });
  });

  const pages = context.pages();
  const page = pages.length > 0 ? pages[0] : await context.newPage();

  return { context, page };
}
