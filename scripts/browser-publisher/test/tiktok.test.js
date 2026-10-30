import test from 'node:test';
import assert from 'node:assert/strict';
import { uploadToTikTok } from '../src/tiktok.js';

function fakePage({ editor = true, captcha = false, confirmed = true, links = [] } = {}) {
  let clicked = 0;
  let linkReads = 0;
  const page = {
    goto: async () => {}, waitForTimeout: async () => {},
    url: () => 'https://www.tiktok.com/creator-center/upload', frames: () => [],
    keyboard: { press: async () => {}, type: async () => {} },
    waitForSelector: async () => { if (!confirmed) throw new Error('timeout'); },
    locator(selector) {
      return {
        first() { return this; }, waitFor: async () => {}, setInputFiles: async () => {},
        count: async () => selector.includes('Log in') ? 0 : 1,
        isVisible: async () => selector.includes('contenteditable') ? editor : selector.includes('captcha') ? captcha : false,
        click: async () => { if (selector.includes('Post')) clicked++; },
        evaluateAll: async () => ++linkReads === 1 ? [] : links,
      };
    },
  };
  return { page, clicks: () => clicked };
}

async function capture(operation) {
  const events = [];
  const original = console.log;
  console.log = value => { events.push(JSON.parse(value)); };
  try { await operation(events); } finally { console.log = original; }
}

test('missing caption editor prevents Post', async () => {
  const { page, clicks } = fakePage({ editor: false });
  await capture(async events => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }), /не найден/);
    assert.equal(clicks(), 0);
    assert.equal(events.some(e => e.type === 'success'), false);
  });
});

test('unresolved captcha prevents Post', async () => {
  const { page, clicks } = fakePage({ captcha: true });
  await capture(async () => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }), /ещё не завершена/);
    assert.equal(clicks(), 0);
  });
});

test('a confirmation timeout is never reported as successful publication', async () => {
  const { page, clicks } = fakePage({ confirmed: false });
  await capture(async events => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }), /не подтвердил/);
    assert.equal(clicks(), 1);
    assert.equal(events.some(e => e.type === 'success'), false);
  });
});

test('one newly confirmed video link is returned; ambiguous links stay unknown', async () => {
  for (const links of [['https://www.tiktok.com/@test/video/1234'], ['https://www.tiktok.com/@test/video/1234', 'https://www.tiktok.com/@test/video/5678']]) {
    const { page } = fakePage({ links });
    await capture(async events => {
      await uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' });
      assert.equal(events.find(e => e.type === 'success').url, links.length === 1 ? links[0] : null);
    });
  }
});
