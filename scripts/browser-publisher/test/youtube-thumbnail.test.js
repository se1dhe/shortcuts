import test from 'node:test';
import assert from 'node:assert/strict';
import { waitForThumbnailPreview } from '../src/youtube-thumbnail.js';

function scenario(states) {
  let time = 0, index = 0;
  return { now: () => time, sleep: async ms => { time += ms; }, timeoutMs: 2000,
    read: async () => states[Math.min(index++, states.length - 1)] };
}
const state = (images, busy = false, error = '') => ({ images, busy, error });

test('a cleared thumbnail file input is accepted only after a new preview finishes uploading', async () => {
  const options = scenario([state(['old']), state(['new'], true), state(['new'])]);
  await waitForThumbnailPreview({}, ['old'], options);
  assert.equal(options.now(), 500);
});
test('an unchanged or undecoded thumbnail never confirms the intended cover', async () => {
  for (const images of [[], ['old']]) {
    await assert.rejects(waitForThumbnailPreview({}, ['old'], scenario([state(images)])), /не подтвердил/);
  }
});
test('a new thumbnail still uploading is awaited, and a server error stops the upload', async () => {
  await assert.rejects(waitForThumbnailPreview({}, [], scenario([state(['new'], true)])), /не подтвердил/);
  await assert.rejects(waitForThumbnailPreview({}, [], scenario([state(['new'], false, 'Файл слишком большой')])), /слишком большой/);
});
