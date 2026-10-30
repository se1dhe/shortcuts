import test from 'node:test';
import assert from 'node:assert/strict';
import { commentTarget, ensurePinnedComment, navigateCommentPage } from '../src/youtube-comment.js';

function setup({ existing = 0, pinned = false, failPin = false, failVerify = false } = {}) {
  const journal = { state: {}, save(next) { Object.assign(this.state, next); } };
  const adapter = {
    rows: Array.from({ length: existing }, () => ({ pinned })), posts: 0, pins: 0,
    async open() {}, async findOwn() { return this.rows; },
    async post(_text, willSubmit) { willSubmit(); this.posts++; this.rows.push({ pinned: false }); },
    async waitOwn() { return this.rows[0]; },
    async url() { return 'https://www.youtube.com/watch?v=abcdefghijk&lc=UgxCommentId'; },
    async isPinned(row) { return row.pinned; },
    async pin(row) { this.pins++; if (failPin) throw new Error('Pin unavailable'); row.pinned = true; },
    async verify() { if (failVerify) throw new Error('Pin not persisted'); },
  };
  return { adapter, journal };
}

test('a prepared comment is posted once, pinned and verified before success', async () => {
  const { adapter, journal } = setup();
  const url = await ensurePinnedComment(adapter, 'Питання?', journal);
  assert.equal(adapter.posts, 1); assert.equal(adapter.pins, 1);
  assert.equal(journal.state.pinned, true); assert.ok(url.includes('&lc='));
  await ensurePinnedComment(adapter, 'Питання?', journal);
  assert.equal(adapter.posts, 1); assert.equal(adapter.pins, 1);
});
test('an interrupted pin reuses the existing own comment without posting it again', async () => {
  const { adapter, journal } = setup({ existing: 1 });
  journal.state.intent = true;
  await ensurePinnedComment(adapter, 'Питання?', journal);
  assert.equal(adapter.posts, 0); assert.equal(adapter.pins, 1);
});
test('an existing pinned comment is verified and never unpinned or duplicated', async () => {
  const { adapter, journal } = setup({ existing: 1, pinned: true });
  await ensurePinnedComment(adapter, 'Питання?', journal);
  assert.equal(adapter.posts, 0); assert.equal(adapter.pins, 0);
});
test('unknown post outcome or ambiguous duplicates fail closed', async () => {
  const unknown = setup(); unknown.journal.state.intent = true;
  await assert.rejects(ensurePinnedComment(unknown.adapter, 'Питання?', unknown.journal), /не подтверждена/);
  assert.equal(unknown.adapter.posts, 0);
  const duplicate = setup({ existing: 2 });
  await assert.rejects(ensurePinnedComment(duplicate.adapter, 'Питання?', duplicate.journal), /несколько/);
  assert.equal(duplicate.adapter.posts, 0);
});
test('posting alone and an optimistic pin do not count as confirmed pinning', async () => {
  for (const options of [{ failPin: true }, { failVerify: true }]) {
    const { adapter, journal } = setup(options);
    await assert.rejects(ensurePinnedComment(adapter, 'Питання?', journal));
    assert.equal(adapter.posts, 1);
    assert.equal(journal.state.pinned, undefined);
    assert.ok(journal.state.url);
  }
});
test('a UI failure before submission does not create an uncertain posting intent', async () => {
  const { adapter, journal } = setup(); adapter.post = async () => { throw new Error('editor missing'); };
  await assert.rejects(ensurePinnedComment(adapter, 'Питання?', journal));
  assert.equal(journal.state.intent, undefined);
});
test('comment targets are exact videos, never channels or another host', () => {
  assert.equal(commentTarget('https://youtube.com/shorts/abcdefghijk').id, 'abcdefghijk');
  for (const url of ['https://youtube.com/@channel', 'https://youtube.com.evil.test/watch?v=abcdefghijk']) {
    assert.throws(() => commentTarget(url));
  }
});

test('a replaced first navigation is retried before any comment action', async () => {
  let calls = 0;
  await navigateCommentPage({ goto: async () => { if (++calls === 1) throw new Error('net::ERR_ABORTED'); }, waitForTimeout: async () => {} }, 'https://www.youtube.com/watch?v=abcdefghijk');
  assert.equal(calls, 2);
});
test('navigation retries are bounded and do not swallow other failures', async () => {
  let calls = 0;
  await assert.rejects(navigateCommentPage({ goto: async () => { calls++; throw new Error('net::ERR_ABORTED'); }, waitForTimeout: async () => {} }, 'url'));
  assert.equal(calls, 3);
  await assert.rejects(navigateCommentPage({ goto: async () => { throw new Error('network down'); } }, 'url'), /network down/);
});
