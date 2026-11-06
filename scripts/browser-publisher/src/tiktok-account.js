export function normalizeTikTokHandle(value) {
  let text = String(value ?? '').trim();
  if (/^https?:\/\//i.test(text)) {
    const url = new URL(text);
    if (!['tiktok.com', 'www.tiktok.com'].includes(url.hostname)) throw new Error('Ожидается ссылка на профиль TikTok.');
    text = url.pathname.replace(/^\/@/, '').replace(/\/$/, '');
  }
  text = text.replace(/^@/, '').toLowerCase();
  if (!/^[a-z0-9_.]{2,24}$/.test(text)) throw new Error('Укажите TikTok @username или ссылку на профиль.');
  return text;
}

// Only account controls in the creator navigation count as identity evidence.
// Video authors and arbitrary @mentions in the page body are never considered.
export async function readTikTokAccount(page) {
  const handles = await page.locator(
    'header a[href*="/@"], nav a[href*="/@"], aside a[href*="/@"], '
    + '[data-e2e="profile-icon"] a[href*="/@"], a[data-e2e="profile-icon"][href*="/@"]'
  ).evaluateAll(links => links.map(link => link.getAttribute('href'))).catch(() => []);
  const unique = new Set();
  for (const href of handles) {
    try { unique.add(normalizeTikTokHandle(new URL(href, 'https://www.tiktok.com').href)); } catch {}
  }
  return unique.size === 1 ? [...unique][0] : null;
}

// The upload-only screen has no account navigation in current TikTok Studio.
// Its home shows the owner's profile card and own video list. Inspect it in a
// separate tab so an existing upload/draft is never navigated away or reset.
export async function readTikTokStudioAccount(context) {
  const page = await context.newPage();
  try {
    await page.goto('https://www.tiktok.com/tiktokstudio', { waitUntil: 'domcontentloaded', timeout: 30000 });
    if (new URL(page.url()).pathname.replace(/\/$/, '') !== '/tiktokstudio') return null;
    for (let attempt = 0; attempt < 5; attempt++) {
      const links = await page.locator('a[href*="/@"]').evaluateAll(es => es.map(e => e.getAttribute('href')));
      const profiles = [];
      for (const href of links) {
        try { profiles.push(normalizeTikTokHandle(new URL(href, 'https://www.tiktok.com').href)); } catch {}
      }
      const unique = new Set(profiles);
      if (unique.size === 1 && profiles.length >= 2) return [...unique][0];
      if (attempt < 4) await page.waitForTimeout(1000);
    }
    return null;
  } finally { await page.close().catch(() => {}); }
}

export async function requireTikTokAccount(page, expected) {
  const target = normalizeTikTokHandle(expected);
  let actual = await readTikTokAccount(page);
  if (!actual && typeof page.context === 'function') actual = await readTikTokStudioAccount(page.context());
  if (!actual) throw new Error(`Не удалось подтвердить аккаунт TikTok @${target}. Откройте вход в настройках и проверьте профиль. Файл не загружался.`);
  if (actual !== target) throw new Error(`В TikTok открыт @${actual}, а выбран @${target}. Переключите аккаунт через вход в настройках. Файл не загружался.`);
  return actual;
}
