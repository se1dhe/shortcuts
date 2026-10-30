import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createHash } from 'node:crypto';
import { normalizedText } from './youtube-waits.js';

export function commentTarget(value) {
  const url = new URL(value);
  if (url.protocol !== 'https:' || !['youtube.com', 'www.youtube.com', 'youtu.be'].includes(url.hostname)) throw new Error('Нужен точный адрес видео YouTube.');
  const id = url.hostname === 'youtu.be' ? url.pathname.slice(1) : url.pathname === '/watch'
    ? url.searchParams.get('v') : url.pathname.startsWith('/shorts/') ? url.pathname.split('/')[2] : null;
  if (!/^[\w-]{11}$/.test(id || '')) throw new Error('Неверный ID видео для комментария.');
  return { id, url: 'https://www.youtube.com/watch?v=' + id };
}

// Durable intent prevents a second post after a timeout with an unknown result.
function commentJournal(id, text) {
  const hash = createHash('sha256').update(normalizedText(text)).digest('hex');
  const dir = path.join(os.homedir(), 'Library', 'Application Support', 'Shortcast', 'YouTubeComments');
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, id + '-' + hash + '.json');
  let state = {};
  if (fs.existsSync(file)) state = JSON.parse(fs.readFileSync(file, 'utf8'));
  return {
    get state() { return state; },
    save(next) {
      state = { ...state, ...next };
      const temp = file + '.' + process.pid + '.tmp';
      fs.writeFileSync(temp, JSON.stringify(state), { mode: 0o600 }); fs.renameSync(temp, file);
    },
  };
}

export async function ensurePinnedComment(adapter, text, journal) {
  await adapter.open(journal.state.url);
  let matches = await adapter.findOwn(text);
  if (matches.length > 1) throw new Error('Найдено несколько одинаковых комментариев канала. Дубликаты не создавались.');
  let row = matches[0];
  if (!row) {
    if (journal.state.intent) throw new Error('Предыдущая отправка комментария не подтверждена. Проверьте комментарии; повторный текст не отправлялся.');
    await adapter.post(text, () => journal.save({ intent: true }));
    row = await adapter.waitOwn(text);
  }
  const url = await adapter.url(row);
  journal.save({ url });
  if (!(await adapter.isPinned(row))) await adapter.pin(row);
  await adapter.verify(url, text);
  journal.save({ pinned: true });
  return url;
}

export async function navigateCommentPage(page, url) {
  for (let attempt = 0; attempt < 3; attempt++) {
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 }); return;
    } catch (error) {
      if (!error.message.includes('net::ERR_ABORTED') || attempt === 2) throw error;
      // Chrome/YouTube can replace the first navigation while a restored tab
      // initializes. Retrying navigation is safe; posting is never retried here.
      await page.waitForTimeout(500);
    }
  }
}

class YouTubeCommentPage {
  constructor(page, target, progress) { this.page = page; this.target = target; this.progress = progress; }
  async open(savedURL) {
    await navigateCommentPage(this.page, savedURL || this.target.url);
    const edit = this.page.locator('a[href*="studio.youtube.com/video/' + this.target.id + '/edit"]').first();
    await edit.waitFor({ state: 'visible', timeout: 60000 }).catch(() => {
      throw new Error('YouTube не подтвердил, что активный канал владеет этим видео. Комментарий не отправлялся.');
    });
    const owner = this.page.locator('ytd-video-owner-renderer a[href*="/@"], ytd-video-owner-renderer a[href*="/channel/"]').first();
    this.owner = this.authorKey(await owner.getAttribute('href'));
    if (!this.owner) throw new Error('Не удалось проверить автора канала.');
    this.comments = this.page.locator('ytd-comments#comments').first();
    await this.comments.scrollIntoViewIfNeeded();
    await this.comments.locator('ytd-comments-header-renderer').waitFor({ state: 'visible', timeout: 60000 });
    await this.comments.locator('ytd-comment-simplebox-renderer').first().waitFor({ state: 'visible', timeout: 30000 });
    await this.comments.locator('ytd-continuation-item-renderer #spinner:visible').waitFor({ state: 'hidden', timeout: 30000 });
  }
  authorKey(value) {
    if (!value) return null;
    return new URL(value, 'https://www.youtube.com').pathname.replace(/\/$/, '').toLowerCase();
  }
  async findOwn(text) {
    const rows = this.comments.locator('ytd-comment-thread-renderer');
    const matches = [];
    for (let i = 0; i < await rows.count(); i++) {
      const row = rows.nth(i);
      const body = row.locator('#content-text').first();
      if (await body.count() && normalizedText(await body.innerText()) === normalizedText(text)) {
        const author = row.locator('#author-text').first();
        if (this.authorKey(await author.getAttribute('href')) === this.owner) matches.push(row);
      }
    }
    return matches;
  }
  async post(text, willSubmit) {
    this.progress('Публикация подготовленного комментария…');
    const box = this.comments.locator('ytd-comment-simplebox-renderer').first();
    await box.locator('#simplebox-placeholder').click({ timeout: 30000 });
    const editor = box.locator('#contenteditable-root[contenteditable="true"]').first();
    await editor.fill(text);
    if (normalizedText(await editor.innerText()) !== normalizedText(text)) throw new Error('YouTube изменил текст комментария до отправки.');
    willSubmit();
    await box.locator('#submit-button').click({ timeout: 30000 });
  }
  async waitOwn(text) {
    const deadline = Date.now() + 60000;
    while (Date.now() < deadline) {
      const rows = await this.findOwn(text);
      if (rows.length === 1) return rows[0];
      if (rows.length > 1) throw new Error('Неоднозначный результат отправки комментария.');
      await this.page.waitForTimeout(500);
    }
    throw new Error('YouTube не подтвердил отправку комментария. Повторная отправка отключена до проверки.');
  }
  async url(row) {
    const links = row.locator('a[href*="lc="]');
    for (let i = 0; i < await links.count(); i++) {
      const url = new URL(await links.nth(i).getAttribute('href'), 'https://www.youtube.com');
      const id = url.searchParams.get('lc');
      if (commentTarget(url.href).id === this.target.id && /^[\w-]{5,256}$/.test(id || '')) return this.target.url + '&lc=' + id;
    }
    throw new Error('Комментарий найден, но YouTube не вернул его точную ссылку. Повторный комментарий не создавался.');
  }
  badge(row) { return row.locator('ytd-pinned-comment-badge-renderer, #pinned-comment-badge').first(); }
  async isPinned(row) { return this.badge(row).isVisible(); }
  async pin(row) {
    this.progress('Закрепление комментария…');
    await row.hover();
    await row.locator('#action-menu button, ytd-menu-renderer button').first().click({ timeout: 30000 });
    const pin = this.page.getByRole('menuitem', { name: /^(Pin|Закрепить|Закріпити)$/i }).first();
    await pin.waitFor({ state: 'visible', timeout: 10000 }).catch(() => {
      throw new Error('YouTube не показал «Закрепить». Комментарий сохранён; проверьте расширенные функции канала.');
    });
    await pin.click();
    const confirm = this.page.getByRole('button', { name: /^(Pin|Закрепить|Закріпити)$/i }).first();
    await Promise.any([
      this.badge(row).waitFor({ state: 'visible', timeout: 15000 }),
      confirm.waitFor({ state: 'visible', timeout: 15000 }),
    ]);
    if (await confirm.isVisible()) await confirm.click();
    await this.badge(row).waitFor({ state: 'visible', timeout: 30000 });
  }
  async verify(url, text) {
    this.progress('Проверка закрепления после повторного открытия видео…');
    await this.open(url);
    const row = await this.waitOwn(text);
    await this.badge(row).waitFor({ state: 'visible', timeout: 30000 }).catch(() => {
      throw new Error('Комментарий опубликован, но закрепление не подтвердилось после перезагрузки.');
    });
  }
}

export async function publishPinnedYouTubeComment(page, { targetVideoURL, pinnedComment }) {
  const target = commentTarget(targetVideoURL);
  if (!normalizedText(pinnedComment) || [...pinnedComment].length > 10000) throw new Error('Подготовленный комментарий пуст или слишком длинный.');
  const progress = message => console.log(JSON.stringify({ type: 'progress', platform: 'youtube', message }));
  try {
    const url = await ensurePinnedComment(new YouTubeCommentPage(page, target, progress), pinnedComment, commentJournal(target.id, pinnedComment));
    console.log(JSON.stringify({ type: 'success', platform: 'youtube', message: 'Комментарий опубликован и закреплён', url }));
    return url;
  } catch (error) {
    // No video transfer is running: preserve the journal and allow the next
    // comment to run, rather than holding the entire release in a browser.
    const dir = path.join(os.homedir(), 'Library', 'Logs', 'Shortcast', 'browser-publisher', String(Date.now()));
    fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
    await page.screenshot({ path: path.join(dir, 'youtube-comment.png') }).catch(() => {});
    throw error;
  }
}
