import test from 'node:test';
import assert from 'node:assert/strict';
import { normalizeTikTokHandle, readTikTokAccount, requireTikTokAccount } from '../src/tiktok-account.js';
import { uploadToTikTok } from '../src/tiktok.js';

test('target accepts an owned profile URL and rejects video links and other domains', () => {
  assert.equal(normalizeTikTokHandle('https://www.tiktok.com/@telonyx_cinema'), 'telonyx_cinema');
  assert.equal(normalizeTikTokHandle(' @Telonyx_Cinema '), 'telonyx_cinema');
  for (const value of ['https://example.com/@telonyx_cinema', 'https://www.tiktok.com/@author/video/123', 'null/invalid']) {
    assert.throws(() => normalizeTikTokHandle(value));
  }
});

function pageWithAccounts(accounts) {
  return { locator: () => ({ evaluateAll: async () => accounts }), waitForTimeout: async () => {} };
}

test('creator identity must be unique and match the target', async () => {
  assert.equal(await requireTikTokAccount(pageWithAccounts(['/@telonyx_cinema']), '@telonyx_cinema'), 'telonyx_cinema');
  assert.equal(await readTikTokAccount(pageWithAccounts(['/@a_user', '/@other_user'])), null);
  await assert.rejects(requireTikTokAccount(pageWithAccounts([]), 'telonyx_cinema'), /Не удалось подтвердить/);
  await assert.rejects(requireTikTokAccount(pageWithAccounts(['/@other_user']), 'telonyx_cinema'), /открыт @other_user/);
});

test('wrong account prevents selecting the video file', async () => {
  let selected = false;
  const page = pageWithAccounts(['/@other_user']);
  page.goto = async () => {};
  page.url = () => 'https://www.tiktok.com/tiktokstudio/upload';
  page.locator = () => ({ count: async () => 0, evaluateAll: async () => ['/@other_user'], setInputFiles: async () => { selected = true; } });
  await assert.rejects(uploadToTikTok(page, { videoPath: 'unused.mp4', caption: '', expectedHandle: 'telonyx_cinema' }, { captureFailure: async () => {} }), /открыт @other_user/);
  assert.equal(selected, false);
});
