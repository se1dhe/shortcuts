import test from 'node:test';
import assert from 'node:assert/strict';
import { chromium } from 'playwright-core';
import { readTikTokChecks, enableTikTokChecks, requireTikTokChecksPassed } from '../src/tiktok-waits.js';

test('real Chrome DOM: enable both checks and keep their statuses separate from the caption', {
  skip: process.env.SHORTCAST_BROWSER_DOM_TEST !== '1',
}, async () => {
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`<div contenteditable="true">Content check No issues found. Sound copyright check No issues found.</div>
      <section><h3>Sound copyright check</h3><input id="music" type="checkbox"><p id="music-status">Not started</p></section>
      <section><h3>Content check</h3><input id="content" type="checkbox"><p id="content-status">Not started</p></section>
      <script>for (const name of ['music','content']) document.getElementById(name).onchange = () => {
        document.getElementById(name + '-status').textContent = 'Checking...';
      };</script>`);
    const unknown = await readTikTokChecks(page);
    assert.deepEqual(unknown, { musicText: '', contentText: '' });
    assert.throws(() => requireTikTokChecksPassed(unknown));
    await enableTikTokChecks(page);
    assert.equal(await page.locator('#music').isChecked(), true);
    assert.equal(await page.locator('#content').isChecked(), true);
    await page.locator('#content-status').evaluate(node => { node.textContent = 'No issues found'; });
    const pending = await readTikTokChecks(page);
    assert.match(pending.musicText, /Checking/);
    assert.match(pending.contentText, /No issues found/);
    assert.throws(() => requireTikTokChecksPassed(pending));
    await page.locator('#music-status').evaluate(node => { node.textContent = 'No copyright issues detected'; });
    requireTikTokChecksPassed(await readTikTokChecks(page));
  } finally { await browser.close(); }
});

// Regression for the live Studio page: owner links coexist with comment authors
// and inspiration cards. A page-wide unique handle check fails as soon as those hydrate.
test('real Chrome DOM: owner card wins over comments, recommendations and caption mentions', {
  skip: process.env.SHORTCAST_BROWSER_DOM_TEST !== '1',
}, async () => {
  const { readTikTokStudioOwner } = await import('../src/tiktok-account.js');
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage();
    const card = handle => `<section><div><a href="https://www.tiktok.com/@${handle}"><img alt="profile"></a>
      <a href="https://www.tiktok.com/@${handle}">${handle}</a><a href="https://www.tiktok.com/@${handle}">Bio</a>
      <p>Лайки 317K · Подписчики 5.4K · Подписки 2</p></div></section>`;
    const comments = `<section><a href="https://www.tiktok.com/@other_user">other_user</a><a href="https://www.tiktok.com/@other_user">comment</a></section>`;
    await page.setContent(card('telonyx_cinema') + comments + '<a href="https://www.tiktok.com/@inspiration">recommended author</a>');
    assert.equal(await readTikTokStudioOwner(page), 'telonyx_cinema');
    await page.setContent(card('other_owner') + '<p>@telonyx_cinema Likes Followers Following</p>' + comments);
    assert.equal(await readTikTokStudioOwner(page), 'other_owner');
    await page.setContent(comments);
    assert.equal(await readTikTokStudioOwner(page), null);
    await page.setContent(card('one_owner') + card('two_owner'));
    assert.equal(await readTikTokStudioOwner(page), null);
  } finally { await browser.close(); }
});

test('real Chrome DOM: current Russian quick check and explicit public audience', {
  skip: process.env.SHORTCAST_BROWSER_DOM_TEST !== '1',
}, async () => {
  const { ensureTikTokPublic } = await import('../src/tiktok-privacy.js');
  const browser = await chromium.launch({ executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome', headless: true });
  try {
    const page = await browser.newPage();
    await page.setContent(`<section><span>Кто может видеть эту публикацию</span><div role="combobox" id="audience">Только я</div></section>
      <div role="option" onclick="document.getElementById('audience').textContent='Все'">Все</div>
      <section><h3>Проверка авторских прав на музыку</h3><p>Проблем не обнаружено</p></section>
      <section><h3>Быстрая проверка контента</h3><p>Идет проверка. Это может занять около 10 минут.</p></section>`);
    await ensureTikTokPublic(page);
    assert.equal(await page.locator('#audience').innerText(), 'Все');
    const pending = await readTikTokChecks(page);
    assert.match(pending.contentText, /Идет проверка/);
    assert.throws(() => requireTikTokChecksPassed(pending));
    await page.locator('section').last().locator('p').evaluate(node => { node.textContent = 'Проблем не обнаружено'; });
    requireTikTokChecksPassed(await readTikTokChecks(page));
    await page.setContent('<p>Публичная аудитория не найдена</p>');
    await assert.rejects(ensureTikTokPublic(page), /Публичность не подтверждена/);
  } finally { await browser.close(); }
});
