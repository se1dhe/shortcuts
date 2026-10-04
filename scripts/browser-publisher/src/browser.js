import { chromium } from 'playwright-core';
import path from 'path';
import os from 'os';
import fs from 'fs';
import { execSync } from 'child_process';

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
 * Automatically releases any stale Chromium ProcessSingleton locks and terminates
 * orphaned browser processes holding the profile.
 */
export function cleanStaleLocks(profileDir = getProfileDirectory()) {
  try {
    const stdout = execSync(`ps aux | grep -i "${profileDir}" | grep -v grep | awk '{print $2}' || true`, {
      encoding: 'utf8',
    }).trim();
    if (stdout) {
      const pids = stdout.split(/\s+/).map((p) => parseInt(p, 10)).filter(Boolean);
      for (const pid of pids) {
        if (pid !== process.pid) {
          try {
            process.kill(pid, 'SIGKILL');
          } catch {}
        }
      }
    }
  } catch {}

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

  // Ensure no stale locks prevent Chromium from starting
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
    userAgent:
      'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/133.0.0.0 Safari/537.36',
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
