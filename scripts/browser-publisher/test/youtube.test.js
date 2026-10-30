import test from 'node:test';
import assert from 'node:assert/strict';
import { confirmedYouTubeURL } from '../src/youtube.js';

test('processing alone cannot confirm publication', async () => {
  let selector;
  await assert.rejects(confirmedYouTubeURL({ getByRole: (_role, options) => ({ first() { return this; }, waitFor: async () => { selector = String(options.name); throw new Error('timeout'); } }) }), /не подтвердил/);
  assert.equal(selector.includes('Processing'), false);
  assert.equal(selector.includes('Обработка'), false);
});

test('confirmed publication requires an actual share URL', async () => {
  for (const url of ['https://youtu.be/abcdefghijk', 'https://youtube.com/shorts/veQZlMATcdg?feature=share', null]) {
    const link = { first() { return this; }, isVisible: async () => true, getAttribute: async () => url, innerText: async () => url };
    const page = { getByRole: role => role === 'heading' ? { first() { return this; }, waitFor: async () => {} } : link };
    if (url) assert.equal(await confirmedYouTubeURL(page), url);
    else await assert.rejects(confirmedYouTubeURL(page), /не вернул ссылку/);
  }
});
