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

export function canonicalTikTokVideoURL(value, expectedHandle) {
  try {
    const url = new URL(value);
    const match = url.pathname.match(/^\/@([a-zA-Z0-9_.]{2,24})\/video\/(\d+)\/?$/);
    if (url.protocol !== 'https:' || !['www.tiktok.com', 'tiktok.com'].includes(url.hostname) || !match) return null;
    const owner = match[1].toLowerCase();
    if (expectedHandle && owner !== normalizeTikTokHandle(expectedHandle)) return null;
    return `https://www.tiktok.com/@${owner}/video/${match[2]}`;
  } catch { return null; }
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

// Studio's home also contains comments and recommendations from other accounts.
// Only the owner's profile card (profile links + its own three counters) is identity evidence.
export async function readTikTokStudioOwner(page) {
  const href = await page.evaluate(() => {
    const visible = node => node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden';
    const handle = value => {
      try {
        const url = new URL(value, 'https://www.tiktok.com');
        if (!['www.tiktok.com', 'tiktok.com'].includes(url.hostname)) return null;
        return url.pathname.match(/^\/@([a-zA-Z0-9_.]{2,24})\/?$/)?.[1].toLowerCase() || null;
      } catch { return null; }
    };
    const owners = new Set();
    for (const link of document.querySelectorAll('a[href*="/@"]')) {
      if (!visible(link)) continue;
      const owner = handle(link.href);
      if (!owner) continue;
      let area = link.parentElement;
      for (let depth = 0; area && area !== document.body && depth < 7; depth++, area = area.parentElement) {
        const links = [...area.querySelectorAll('a[href*="/@"]')].filter(visible);
        const handles = new Set(links.map(node => handle(node.href)).filter(Boolean));
        if (handles.size > 1) break;
        const text = (area.innerText || '').replace(/\s+/g, ' ');
        if (text.length > 2000) break;
        if (links.length >= 2 && handles.size === 1
          && /(?:\bLikes\b|Лайки|Вподобання)/i.test(text)
          && /(?:\bFollowers\b|Подписчики|Підписники)/i.test(text)
          && /(?:\bFollowing\b|Подписки|Підписки)/i.test(text)) {
          owners.add(owner); break;
        }
      }
    }
    return owners.size === 1 ? `https://www.tiktok.com/@${[...owners][0]}` : null;
  }).catch(() => null);
  try { return href ? normalizeTikTokHandle(href) : null; } catch { return null; }
}

export async function readTikTokStudioAccount(context) {
  const page = await context.newPage();
  try {
    await page.goto('https://www.tiktok.com/tiktokstudio', { waitUntil: 'domcontentloaded', timeout: 30000 });
    for (let attempt = 0; attempt < 30; attempt++) {
      const url = new URL(page.url());
      if (url.pathname.includes('/login')) return null;
      if (url.pathname.replace(/\/$/, '') === '/tiktokstudio') {
        const owner = await readTikTokStudioOwner(page);
        if (owner) return owner;
      }
      if (attempt < 29) await page.waitForTimeout(500);
    }
    return null;
  } finally { await page.close().catch(() => {}); }
}

export async function requireTikTokAccount(page, expected, { uploadStarted = false } = {}) {
  const stage = uploadStarted ? "Ролик загружен, публикация остановлена." : "Файл не загружался.";
  const target = normalizeTikTokHandle(expected);
  let actual = await readTikTokAccount(page);
  if (!actual && typeof page.context === 'function') actual = await readTikTokStudioAccount(page.context());
  if (!actual) throw new Error(`Не удалось подтвердить аккаунт TikTok @${target}. Откройте вход в настройках и проверьте профиль. ${stage}`);
  if (actual !== target) throw new Error(`В TikTok открыт @${actual}, а выбран @${target}. Переключите аккаунт через вход в настройках. ${stage}`);
  return actual;
}
