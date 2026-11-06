import test from 'node:test';
import assert from 'node:assert/strict';
import { uploadToTikTok } from '../src/tiktok.js';

function fakePage({ editor = true, captcha = false, confirmed = true, links = [], accounts = [] } = {}) {
  let clicked = 0;
  let linkReads = 0;
  const page = {
    goto: async () => {}, waitForTimeout: async () => {},
    isClosed: () => false,
    evaluate: async () => ({ musicText: 'Sound copyright check. No issues found', contentText: 'Content check. No issues found' }),
    getByText(pattern) { return {
      first() { return this; }, isVisible: async () => pattern.source.includes('Who can'),
      locator() { return { locator() { return { first() { return this; }, count: async () => 1, innerText: async () => 'Everyone' }; } }; }
    }; },
    url: () => 'https://www.tiktok.com/creator-center/upload', frames: () => [],
    keyboard: { press: async () => {}, type: async () => {} },
    waitForSelector: async () => { if (!confirmed) throw new Error('timeout'); },
    locator(selector) {
      return {
        first() { return this; }, waitFor: async () => {}, setInputFiles: async () => {},
        count: async () => selector.includes('Log in') ? 0 : 1,
        isVisible: async () => selector.includes('contenteditable') ? editor : selector.includes('captcha') ? captcha : false,
        click: async () => { if (selector.includes('Post')) clicked++; },
        evaluateAll: async () => selector.includes('/video/') ? (++linkReads === 1 ? [] : links) : accounts,
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
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {} }), /не найден/);
    assert.equal(clicks(), 0);
    assert.equal(events.some(e => e.type === 'success'), false);
  });
});

test('unresolved captcha prevents Post', async () => {
  const { page, clicks } = fakePage({ captcha: true });
  await capture(async () => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {} }), /ещё не завершена/);
    assert.equal(clicks(), 0);
  });
});

test('a confirmation timeout is never reported as successful publication', async () => {
  const { page, clicks } = fakePage({ confirmed: false });
  await capture(async events => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {} }), error => {
      assert.equal(error.keepBrowserOpen, true);
      assert.equal(error.uploadStarted, true);
      assert.equal(error.publicationAttempted, true);
      return /не подтвердил/.test(error.message);
    });
    assert.equal(clicks(), 1);
    assert.equal(events.some(e => e.type === 'success'), false);
  });
});

test('only one new confirmed video link is successful; ambiguity is not success', async () => {
  for (const links of [['https://www.tiktok.com/@test/video/1234'], ['https://www.tiktok.com/@test/video/1234', 'https://www.tiktok.com/@test/video/5678'], []]) {
    const { page } = fakePage({ links });
    await capture(async events => {
      const run = () => uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {}, receiptAttempts: 1 });
      if (links.length === 1) {
        await run();
        assert.equal(events.find(e => e.type === 'success').url, links[0]);
      } else {
        await assert.rejects(run(), /однозначную ссылку/);
        assert.equal(events.some(e => e.type === 'success'), false);
      }
    });
  }
});

test('verification prepares a real upload path without ever clicking Post', async () => {
  const { page, clicks } = fakePage();
  await capture(async events => {
    assert.deepEqual(await uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { prepareOnly: true }), { prepared: true });
    assert.equal(clicks(), 0);
    assert.equal(events.some(e => e.type === 'prepared'), true);
    assert.equal(events.some(e => e.type === 'success'), false);
  });
});

test('a check that restarts immediately before Post prevents publication and preserves the upload', async () => {
  const { page, clicks } = fakePage();
  let reads = 0;
  page.evaluate = async () => ({ musicText: 'No issues found', contentText: ++reads === 1 ? 'No issues found' : 'Checking...' });
  await capture(async events => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {} }), error => {
      assert.equal(error.keepBrowserOpen, true);
      return /обе проверки/.test(error.message);
    });
    assert.equal(clicks(), 0);
    assert.equal(events.some(event => event.type === 'success'), false);
  });
});

test('a foreign video link cannot confirm publication into the expected account', async () => {
  const { page } = fakePage({ accounts: ['/@telonyx_cinema'], links: ['https://www.tiktok.com/@other_user/video/1234'] });
  await capture(async events => {
    await assert.rejects(uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст', expectedHandle: 'telonyx_cinema' },
      { captureFailure: async () => {}, receiptAttempts: 1 }), /однозначную ссылку/);
    assert.equal(events.some(event => event.type === 'success'), false);
  });
});

test('different share URLs for the same confirmed post form a single receipt', async () => {
  const { page } = fakePage({ accounts: ['/@telonyx_cinema'], links: ['https://www.tiktok.com/@telonyx_cinema/video/1234?share=1', 'https://tiktok.com/@telonyx_cinema/video/1234/'] });
  await capture(async events => {
    await uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст', expectedHandle: 'https://www.tiktok.com/@telonyx_cinema' }, { receiptAttempts: 1 });
    assert.equal(events.find(event => event.type === 'success').url, 'https://www.tiktok.com/@telonyx_cinema/video/1234');
  });
});
