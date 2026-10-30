import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { uploadToYouTube } from '../src/youtube.js';

// Offline Studio contract: it deliberately accepts Next/Publish while bytes
// are still transferring, just as the real UI can. The uploader must enforce
// its own gates and must not close or publish after only a preview link.
class Studio {
  constructor({ claim = false, neverSaveDescription = false } = {}) {
    this.step = 'picker'; this.title = 'filename.mp4'; this.description = '';
    this.time = 0; this.sent = false; this.claim = claim;
    this.neverSaveDescription = neverSaveDescription; this.events = [];
  }
  locator(selector) { return new Element(this, selector); }
  getByRole(role) { return new Element(this, ({ button: 'select-files', menuitem: 'upload-menu-item', heading: 'published-heading', link: 'share-url' })[role]); }
  async waitForEvent(event) {
    assert.equal(event, 'filechooser');
    return { setFiles: async file => {
      this.step = 'details'; this.events.push('file'); this.video = file;
    } };
  }
  url() { return 'https://studio.youtube.com'; }
  isClosed() { return false; }
  async goto() {}
  async waitForTimeout(ms) { this.time += ms; await new Promise(resolve => setImmediate(resolve)); }
  async waitForSelector(selector) {
    if (!this.sent) throw new Error('Not published');
  }
  async evaluate() {
    return {
      progressText: this.time < 12000 ? 'Uploading 5%' : this.time < 16000 ? 'Uploading 98%' : 'Upload complete',
      checksText: this.step === 'checks'
        ? (this.claim ? 'Copyright-protected content found' : this.time < 22000 ? 'Checking' : 'Checks complete. No issues found')
        : '',
      errorText: '',
    };
  }
  async screenshot() {}
}
class Element {
  constructor(page, selector, parent = '') { this.p = page; this.selector = selector; this.parent = parent; }
  first() { return this; }
  or() { return this; }
  page() { return this.p; }
  locator(selector) { return new Element(this.p, selector, this.selector); }
  getByRole(role) { assert.equal(role, 'tab'); return new Element(this.p, 'selected-tab'); }
  async count() { return 1; }
  async waitFor() {}
  async scrollIntoViewIfNeeded() {}
  async isVisible() {
    const s = this.selector;
    if (s.includes('PUBLIC') || s.includes('UNLISTED')) return this.p.step === 'visibility';
    if (s.includes('checks-step') || s.includes('ytcp-video-checks')) return this.p.step === 'checks';
    if (s.includes('ytcp-video-elements')) return this.p.step === 'elements';
    if (s.includes('title-textarea')) return this.p.step === 'details';
    return true;
  }
  async setInputFiles(file) {
    if (this.parent.includes('thumbnail')) this.p.thumbnail = file;
    else { this.p.step = 'details'; this.p.events.push('file'); }
  }
  async fill(value) {
    if (this.selector.includes('title')) this.p.title = value;
    else if (!this.p.neverSaveDescription) this.p.description = value;
  }
  async press() {}
  async innerText() {
    if (this.selector === 'selected-tab') return ({ details: 'Информация', elements: 'Дополнения', checks: 'Предварительная проверка', visibility: 'Доступ' })[this.p.step] || '';
    if (this.selector.includes('share-url')) return 'https://youtu.be/abcdefghijk';
    return this.selector.includes('title') ? this.p.title : this.p.description;
  }
  async getAttribute(name) {
    if (name === 'href') return 'https://youtu.be/abcdefghijk';
    if (name === 'aria-checked') return 'true';
    return null;
  }
  async evaluate() { return { images: this.p.thumbnail ? ['blob:new-thumbnail'] : [], busy: false, error: '' }; }
  async click() {
    if (this.selector === '#next-button') {
      assert.ok(this.p.time >= 16000, 'Next must not skip file transfer');
      this.p.step = this.p.step === 'details' ? 'elements' : this.p.step === 'elements' ? 'checks' : 'visibility';
      this.p.events.push(this.p.step);
    }
    if (this.selector === '#done-button') {
      assert.ok(this.p.time >= 22000, 'Publish must wait for checks');
      assert.equal(this.p.claim, false);
      assert.equal(this.p.description.includes('https://t.me/kadr_sens'), true);
      this.p.sent = true; this.p.events.push('publish');
    }
  }
}
async function withFiles(operation) {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shortcast-yt-flow-'));
  const videoPath = path.join(dir, 'essay.mp4'), thumbnailPath = path.join(dir, 'cover.jpg');
  fs.writeFileSync(videoPath, 'test'); fs.writeFileSync(thumbnailPath, 'test');
  try { await operation({ videoPath, thumbnailPath, title: 'Сенс | Фільм',
    caption: 'Опис есе\n\nhttps://t.me/kadr_sens', hashtags: ['Кіноесе'] }); }
  finally { fs.rmSync(dir, { recursive: true }); }
}

test('full upload fills fields and thumbnail, then waits for transfer and clean checks before Publish', async () => {
  await withFiles(async job => {
    const studio = new Studio();
    await uploadToYouTube(studio, job);
    assert.deepEqual(studio.events, ['file', 'elements', 'checks', 'visibility', 'publish']);
    assert.equal(studio.title, job.title);
    assert.equal(studio.thumbnail, job.thumbnailPath);
    assert.ok(studio.description.includes('#Кіноесе'));
  });
});

test('a copyright finding prevents visibility and publication and leaves the browser for review', async () => {
  await withFiles(async job => {
    const studio = new Studio({ claim: true });
    await assert.rejects(uploadToYouTube(studio, job), error => {
      assert.equal(error.keepBrowserOpen, true);
      return /ограничение/.test(error.message);
    });
    assert.equal(studio.sent, false);
    assert.equal(studio.events.includes('visibility'), false);
  });
});

test('Shorts receive their prepared vertical thumbnail and a single Shorts hashtag', async () => {
  await withFiles(async job => {
    const studio = new Studio();
    await uploadToYouTube(studio, { ...job, isShort: true, hashtags: ['Кіноесе', 'Shorts'] });
    assert.equal(studio.thumbnail, job.thumbnailPath);
    assert.equal((studio.title.match(/#Shorts/g) || []).length, 1);
    assert.equal((studio.description.match(/#Shorts/g) || []).length, 1);
    assert.equal(studio.sent, true);
  });
});
