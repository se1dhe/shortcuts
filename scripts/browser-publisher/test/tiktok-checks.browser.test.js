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
