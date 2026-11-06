import test from 'node:test';
import assert from 'node:assert/strict';
import { classifyTikTokCheck, waitForTikTokChecks, requireTikTokChecksPassed } from '../src/tiktok-waits.js';
import { uploadToTikTok } from '../src/tiktok.js';

function clock() {
  let time = 0;
  return { now: () => time, sleep: async ms => { time += ms; } };
}

test('music and content checks finish independently, regardless of the order', async () => {
  for (const first of ['musicText', 'contentText']) {
    let reads = 0;
    const result = await waitForTikTokChecks({}, {
      ...clock(), read: async () => {
        reads++;
        return { musicText: reads > 3 ? 'No issues found' : 'Checking...',
          contentText: reads > 3 ? 'No issues found' : 'Checking...',
          [first]: 'No issues found' };
      },
    });
    assert.equal(reads, 4);
    requireTikTokChecksPassed(result);
  }
});

test('unknown checks never become success and confirmed violations stop the wait', async () => {
  await assert.rejects(waitForTikTokChecks({}, { ...clock(), timeoutMs: 4000,
    read: async () => ({ musicText: 'No issues found', contentText: '' }) }), /не завершил/);
  for (const field of ['musicText', 'contentText']) {
    await assert.rejects(waitForTikTokChecks({}, { ...clock(), read: async () => ({
      musicText: 'No issues found', contentText: 'No issues found', [field]: 'Copyright issues detected',
    }) }), /нарушении/);
  }
});

test('localized completion and a fresh pending check are distinguished', () => {
  for (const text of ['No copyright issues detected', 'Проверка завершена. Нарушений не найдено',
    'Перевірку завершено. Порушень не виявлено']) assert.equal(classifyTikTokCheck(text), 'passed', text);
  assert.equal(classifyTikTokCheck('Проверка выполняется'), 'pending');
  assert.equal(classifyTikTokCheck('Проверка завершена. Обнаружены нарушения'), 'failed');
  assert.throws(() => requireTikTokChecksPassed({ musicText: 'No issues found', contentText: 'Checking...' }));
});

test('full upload cannot click Post while content passed but music is still checking', async () => {
  let reads = 0, posted = false, waited = false;
  const page = {
    goto: async () => {}, url: () => 'https://www.tiktok.com/creator-center/upload', frames: () => [],
    isClosed: () => false, waitForTimeout: async () => { waited = true; },
    keyboard: { press: async () => {}, type: async () => {} },
    evaluate: async () => ({ musicText: ++reads < 4 ? 'Checking...' : 'No issues found', contentText: 'No issues found' }),
    waitForSelector: async () => { assert.equal(posted, true); },
    getByText() { return { first() { return this; }, isVisible: async () => false }; },
    locator(selector) { return {
      first() { return this; }, count: async () => selector.includes('Log in') ? 0 : 1,
      isVisible: async () => selector.includes('contenteditable'), waitFor: async () => {},
      setInputFiles: async () => {}, evaluateAll: async () => [],
      click: async () => { if (selector.includes('has-text("Post")')) {
        assert.ok(reads >= 5, 'Both checks plus a fresh status must precede Post'); posted = true;
      } },
    }; },
  };
  await uploadToTikTok(page, { videoPath: 'fixture.mp4', caption: 'Текст' }, { captureFailure: async () => {} });
  assert.equal(posted, true);
  assert.equal(waited, true);
});
