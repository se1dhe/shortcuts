import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { EventEmitter } from 'node:events';
import { classifyYouTubeStatus, waitForYouTubePhase, setVerifiedYouTubeField, requireReadyToPublish } from '../src/youtube-waits.js';
import { assertYouTubeMetadata, youtubeDescription } from '../src/youtube.js';
import { cleanStaleLocks } from '../src/browser.js';
import { waitForBrowserClose } from '../src/manual-review.js';

function clock() {
  let time = 0;
  return { now: () => time, sleep: async ms => { time += ms; } };
}

test('5 percent and an available preview link are never upload completion', () => {
  for (const progressText of ['Uploading 5%', 'Загрузка 5%', 'Завантаження 5%', 'Загружено 5%']) {
    assert.equal(classifyYouTubeStatus({ progressText, checksText: '', url: 'https://youtu.be/abcdefghijk' }).uploadComplete, false);
  }
});

test('actual Studio Russian transfer labels distinguish transfer completion from queued processing', () => {
  const pending = classifyYouTubeStatus({ progressText: 'Загружено: 83 % ...' });
  assert.equal(pending.uploadPending, true);
  assert.equal(pending.uploadComplete, false);
  const done = classifyYouTubeStatus({ progressText: 'Загрузка видео завершена. ... Скоро начнется обработка.' });
  assert.equal(done.uploadComplete, true);
  assert.equal(done.processingPending, true);
  assert.equal(classifyYouTubeStatus({ progressText: 'Обработка в HD… ... Осталось 3 минуты' }).uploadComplete, true);
  assert.equal(classifyYouTubeStatus({ progressText: 'Обработка в HD… ... Осталось 3 минуты' }).processingPending, true);
  assert.equal(classifyYouTubeStatus({ progressText: 'Проверка завершена. Нарушений не найдено.' }).uploadComplete, true);
});

test('waits beyond the former one-minute cutoff while transfer continues', async () => {
  const time = clock();
  let calls = 0;
  const result = await waitForYouTubePhase({}, 'upload', {
    ...time, read: async () => ({ progressText: ++calls > 65 ? 'Upload complete' : 'Uploading ' + calls + '%' }),
  });
  assert.ok(time.now() >= 120000);
  assert.equal(result.uploadComplete, true);
});

test('unknown statuses fail closed; processing percentage cannot confirm processing completion', async () => {
  assert.equal(classifyYouTubeStatus({ progressText: 'Processing HD 100%' }).processingPending, true);
  await assert.rejects(waitForYouTubePhase({}, 'upload', {
    ...clock(), timeoutMs: 6000, read: async () => ({ progressText: '', checksText: '' }),
  }), /Истекло время/);
});

test('a stalled 5 percent transfer requests review instead of success', async () => {
  await assert.rejects(waitForYouTubePhase({}, 'upload', {
    ...clock(), stallMs: 10000, read: async () => ({ progressText: 'Uploading 5%' }),
  }), /Передача файла не менялась/);
});

test('content checks and active HD processing are both awaited', async () => {
  const statuses = [
    { progressText: 'Processing HD 83%', checksText: 'Checking' },
    { progressText: 'Processing HD 99%', checksText: 'Checks complete. No issues found' },
    { progressText: 'Checks complete', checksText: 'No issues found' },
  ];
  let calls = 0;
  const result = await waitForYouTubePhase({}, 'checks', {
    ...clock(), read: async () => statuses[Math.min(calls++, statuses.length - 1)],
  });
  assert.equal(calls, 3);
  assert.equal(result.checksComplete, true);
});

test('copyright or upload errors stop the publication gate', async () => {
  for (const snapshot of [
    { progressText: 'Upload complete', checksText: 'Copyright-protected content found' },
    { progressText: 'Загрузка завершена', checksText: 'Найдены материалы, защищенные авторским правом' },
    { checksText: 'Проверка завершена. На контент заявлены права.' },
    { checksText: 'В этом видео есть контент, на который заявлены права. Видео заблокировано.' },
    { errorText: 'Upload failed. Network error' },
  ]) {
    await assert.rejects(waitForYouTubePhase({}, 'checks', { ...clock(), read: async () => snapshot }), /ошибке|ограничение/);
  }
});

test('Russian and Ukrainian completed checks are recognized', () => {
  for (const checksText of ['Проверки завершены. Проблем не обнаружено', 'Перевірки завершено. Порушень не виявлено']) {
    assert.equal(classifyYouTubeStatus({ checksText }).checksComplete, true);
  }
  assert.equal(classifyYouTubeStatus({ checksText: 'Проверяется' }).checksComplete, false);
});

test('confirmed no-impact claims allow publication, unknown effects and actual restrictions do not', async () => {
  const cleanClaim = {
    progressText: 'Upload complete',
    checksText: 'Проверка завершена. В этом видео есть контент, на который заявлены права. Пока это не влияет на видео, но если вы начнете зарабатывать на YouTube, это может отразиться на вашем доходе. Нарушений не найдено',
  };
  const checked = await waitForYouTubePhase({}, 'checks', { ...clock(), read: async () => cleanClaim });
  assert.equal(checked.harmlessClaim, true);
  assert.equal(checked.contentIssue, false);
  assert.equal(classifyYouTubeStatus({ checksText: 'Проверка завершена. На контент заявлены права. Эта заявка не повлияла на доступ к видео и его функции.' }).harmlessClaim, true);
  assert.doesNotThrow(() => requireReadyToPublish({ uploadComplete: true }, checked, { checksText: 'Проверка завершена. На контент заявлены права.' }));
  for (const text of ['На контент заявлены права.', 'Видео заблокировано',
    'На контент заявлены права. Это не влияет на видео. Видео заблокировано в некоторых странах',
    'На контент заявлены права. Это не влияет на видео. Получено предупреждение за нарушение авторских прав']) {
    assert.equal(classifyYouTubeStatus({ checksText: text }).contentIssue, true, text);
  }
  assert.throws(() => requireReadyToPublish({ uploadComplete: true }, checked, { checksText: 'Видео заблокировано' }));
});

test('Publish requires both previous gates and rejects fresh checking or errors', () => {
  const uploaded = { uploadComplete: true };
  const checked = { checksComplete: true, processingPending: false };
  assert.doesNotThrow(() => requireReadyToPublish(uploaded, checked, {}));
  for (const args of [
    [{ uploadComplete: false }, checked, {}],
    [uploaded, { checksComplete: false }, {}],
    [uploaded, checked, { checksText: 'Checking' }],
    [uploaded, checked, { progressText: 'Uploading 5%' }],
    [uploaded, checked, { progressText: 'Processing HD 5%' }],
    [uploaded, checked, { errorText: 'Network error' }],
  ]) assert.throws(() => requireReadyToPublish(...args), /остановлена/);
});

test('a late filename overwrite forces field refill and a stable read-back', async () => {
  const time = clock();
  let value = '', fills = 0, reads = 0;
  const field = {
    waitFor: async () => {}, scrollIntoViewIfNeeded: async () => {},
    fill: async text => { value = text; fills++; }, press: async () => {},
    innerText: async () => {
      reads++;
      if (fills === 1 && reads > 2) value = 'longform_abc.mp4';
      return value;
    },
  };
  await setVerifiedYouTubeField({}, field, 'Назва | Фільм', 'Заголовок', { ...time, stableMs: 1000 });
  assert.equal(fills, 2);
  assert.equal(value, 'Назва | Фільм');
});

test('a description that does not stick is never silently accepted', async () => {
  const field = { waitFor: async () => {}, scrollIntoViewIfNeeded: async () => {}, fill: async () => {},
    press: async () => {}, innerText: async () => 'wrong text' };
  await assert.rejects(setVerifiedYouTubeField({}, field, 'Повний опис', 'Описание', { ...clock(), stableMs: 1000 }), /не сохранил/);
});

test('metadata is compared after upload; hashtag tokens are not duplicated', async () => {
  const dialog = { locator: selector => ({ first: () => ({ innerText: async () => selector.includes('title') ? 'wrong title' : 'description' }) }) };
  await assert.rejects(assertYouTubeMetadata(dialog, 'title', 'description'), /изменилось/);
  const text = youtubeDescription('Повний опис #Кіноесе', ['Кіноесе', 'Shorts', 'Shorts'], true);
  assert.equal((text.match(/#Кіноесе/g) || []).length, 1);
  assert.equal((text.match(/#Shorts/g) || []).length, 1);
});

test('an active Chrome profile is refused without killing the process or deleting locks', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shortcast-lock-test-'));
  try {
    fs.symlinkSync(os.hostname() + '-' + process.pid, path.join(dir, 'SingletonLock'));
    assert.throws(() => cleanStaleLocks(dir), /уже используется/);
    assert.equal(fs.lstatSync(path.join(dir, 'SingletonLock')).isSymbolicLink(), true);
    assert.doesNotThrow(() => process.kill(process.pid, 0));
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('only a proven dead local Chrome lock is removed', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'shortcast-stale-test-'));
  try {
    fs.symlinkSync(os.hostname() + '-2147483647', path.join(dir, 'SingletonLock'));
    cleanStaleLocks(dir);
    assert.equal(fs.existsSync(path.join(dir, 'SingletonLock')), false);
  } finally { fs.rmSync(dir, { recursive: true }); }
});

test('a failed upload browser remains open until the user closes it', async () => {
  const context = new EventEmitter();
  context.browser = () => null;
  context.pages = () => [{}];
  let completed = false;
  const waiting = waitForBrowserClose(context).then(() => { completed = true; });
  await Promise.resolve();
  assert.equal(completed, false);
  context.emit('close');
  await waiting;
  assert.equal(completed, true);
});
