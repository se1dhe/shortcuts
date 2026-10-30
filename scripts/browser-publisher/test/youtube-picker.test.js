import test from 'node:test';
import assert from 'node:assert/strict';
import { openYouTubeFilePicker, selectYouTubeVideoFile } from '../src/youtube-picker.js';

function studio({ direct = false, alreadyOpen = false, neverOpen = false } = {}) {
  const state = { time: 0, createdAt: null, picker: alreadyOpen, clicked: 0, chooser: false, file: null };
  const button = kind => ({
    first() { return this; }, or() { return this; },
    async isVisible() {
      if (kind === 'picker') return state.picker;
      return state.createdAt !== null && !direct && state.time - state.createdAt >= 750;
    },
    async click() {
      if (kind === 'create') {
        state.createdAt = state.time;
        if (direct && !neverOpen) state.picker = true;
      } else if (kind === 'menu') {
        state.clicked++;
        if (!neverOpen) state.picker = true;
      } else {
        assert.equal(state.chooser, true, 'subscribe before clicking the picker');
        state.resolveChooser({ setFiles: async file => { state.file = file; } });
      }
    },
  });
  return Object.assign(state, {
    locator() { return button('create'); },
    getByRole(role) { return button(role === 'button' ? 'picker' : 'menu'); },
    async waitForTimeout(ms) { state.time += ms; },
    waitForEvent(event) {
      assert.equal(event, 'filechooser'); state.chooser = true;
      return new Promise(resolve => { state.resolveChooser = resolve; });
    },
  });
}

test('waits for a delayed Create menu instead of an already attached hidden upload input', async () => {
  const page = studio();
  const picker = await openYouTubeFilePicker(page, { now: () => page.time });
  assert.equal(page.clicked, 1);
  assert.ok(page.time >= 750);
  await selectYouTubeVideoFile(page, picker, 'essay.mp4');
  assert.equal(page.file, 'essay.mp4');
});

test('a directly opened picker needs no menu click or visible uploads host', async () => {
  const page = studio({ direct: true });
  await openYouTubeFilePicker(page, { now: () => page.time });
  assert.equal(page.clicked, 0);
});

test('an already open picker is reused without toggling Create', async () => {
  const page = studio({ alreadyOpen: true });
  await openYouTubeFilePicker(page);
  assert.equal(page.createdAt, null);
});

test('a missing picker stops before selecting or transmitting a file', async () => {
  const page = studio({ neverOpen: true });
  await assert.rejects(openYouTubeFilePicker(page, { now: () => page.time, timeoutMs: 2000 }), /Файл не отправлялся/);
  assert.equal(page.file, null);
  assert.equal(page.chooser, false);
  assert.equal(page.clicked, 1);
});
