// Studio status gates. Only status components are inspected; captions and
// titles are never used as evidence that an upload or a check has completed.
export const UPLOAD_DIALOG = 'ytcp-uploads-dialog';

export function normalizedText(value) {
  return String(value || '').normalize('NFC').replace(/\s+/g, ' ').trim();
}

export function classifyYouTubeStatus(snapshot) {
  const progress = normalizedText(snapshot.progressText);
  const checks = normalizedText(snapshot.checksText);
  const error = normalizedText(snapshot.errorText);
  const percentage = progress.match(/(\d{1,3})\s*%/);
  const processing = /processing|обработ|оброб|провер|перевір|checks|checking/i.test(progress);
  const uploadPending = /uploading|загрузка|загружено|завантаження|завантажено/i.test(progress)
    && !/upload(?:ed| complete)|загрузка(?: видео)? завершена|завантаження(?: відео)? завершено|100\s*%/i.test(progress);
  const uploadComplete = !uploadPending && (
    /upload complete|upload finished|uploaded|загрузка(?: видео)? завершена|завантаження(?: відео)? завершено/i.test(progress)
    || (percentage && Number(percentage[1]) === 100 && !processing)
    || /processing (?:sd|hd|video)|(?:sd|hd) processing|обработка (?:видео|(?:в )?(?:sd|hd))|обробка (?:відео|(?:у )?(?:sd|hd))|checks complete|проверки завершены|проверка (?:завершена|:)|перевірки завершено|перевірка (?:завершена|:)/i.test(progress)
  );
  const checking = /checks? (?:running|in progress)|checking|still checking|проверяется|перевіряється|проверка(?:\s+.*)?(?:выполняется|продолжается)|ид[её]т проверка|перевірка триває/i.test(checks);
  const checksComplete = !checking && (
    /checks complete|проверки завершены|проверка завершена|перевірки завершено|no issues found|проблем не (?:обнаружено|выявлено|найдено)|порушень не виявлено|проблем не виявлено/i.test(checks)
  );
  const copyrightClaim = /copyright.protected content (?:found|detected)|copyright claim(?:\s*:|$)|найден(?:ы)? (?:контент|материалы).*(?:авторск|защищ)|обнаружен.*авторск|на (?:этот )?контент заявлены права|на (?:який|который) заявлен[ыі] права|(?:виявлено|знайдено).*авторськ/i.test(checks);
  const blocked = /video (?:is )?blocked|blocked (?:worldwide|in)|видео заблокировано|(?:полная|частичная) блокировка|заблокировано (?:во|в)|відео заблоковано/i.test(checks);
  // A claim is not a strike. The user permits claims when Studio explicitly
  // confirms no video restriction. Unknown effects still need review.
  const strike = /(?:received|issued|applied|active) (?:a )?copyright strike|copyright strike (?:issued|received|active)|(?:вынесено|получено|вынесли|получили) (?:вам )?предупреждение|предупреждение за нарушение авторских прав/i.test(checks)
    && !/no copyright strike|not a copyright strike|не вынесли вам предупреждения|предупреждени[ея] (?:не вынесено|нет)/i.test(checks);
  const claimDoesNotRestrict = /does(?:n't| not) affect (?:your|the) video|no (?:impact|restrictions?) on (?:your|the) video|не (?:повлияло|влияет) на (?:охват )?видео|заявка не повлияла на доступ к видео и его функции|не впливає на (?:ваше )?відео|заявка не вплинула на доступ до відео/i.test(checks);
  const harmlessClaim = copyrightClaim && claimDoesNotRestrict && !blocked && !strike;
  const contentIssue = blocked || strike || (copyrightClaim && !harmlessClaim);
  const processingPending = /processing.*(?:\d+\s*%|will begin|in progress)|(?:sd|hd) processing(?!.*complete)|обработка.*(?:\d+\s*%|начн|продолж)|обработка в (?:sd|hd)|начн[её]тся обработка|обробка.*(?:\d+\s*%|трива)|обробка у (?:sd|hd)|почнеться обробка/i.test(progress);
  return { progress, checks, uploadPending, uploadComplete: Boolean(uploadComplete), checksComplete,
    processingPending, checking, contentIssue, copyrightClaim, harmlessClaim, blocked, strike, error,
    percentage: percentage ? Number(percentage[1]) : null };
}

export async function readYouTubeStatus(page) {
  return page.evaluate(() => {
    const dialog = document.querySelector('ytcp-uploads-dialog');
    const visible = element => Boolean(element && element.getClientRects().length
      && getComputedStyle(element).visibility !== 'hidden' && getComputedStyle(element).display !== 'none');
    const texts = selectors => [...(dialog || document).querySelectorAll(selectors)]
      .filter(visible).map(element => element.innerText || element.textContent || '').join('\n');
    // Accessible headings survive Studio's component renames. Read only the
    // checks content area containing both policy headings, never video fields.
    let checksBody = '';
    if (dialog) {
      const headings = [...dialog.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible);
      const heading = headings.find(node => /^(?:Checks|Предварительная проверка|Проверка|Попередня перевірка|Перевірка)$/i.test(node.innerText.trim()));
      let area = heading?.parentElement;
      while (area && area !== dialog) {
        const labels = [...area.querySelectorAll('h1,h2,h3,[role="heading"]')].filter(visible).map(node => node.innerText);
        if (labels.some(label => /^(?:Copyright|Авторские права|Авторські права)$/i.test(label.trim()))
          && labels.some(label => /^(?:Community Guidelines|Правила сообщества|Правила спільноти)$/i.test(label.trim()))
          && !area.querySelector('#title-textarea, #description-textarea')) {
          checksBody = area.innerText; break;
        }
        area = area.parentElement;
      }
    }
    return {
      progressText: texts('#progress-label, .progress-label, #upload-status, #processing-status')
        || texts('ytcp-video-upload-progress, ytcp-video-upload-progress-bar'),
      checksText: [texts('ytcp-video-checks, ytcp-video-checks-section, ytcp-checks-step, #checks-step, #checks-container, #checks-status, #copyright-status, #footer'), checksBody].filter(Boolean).join('\n'),
      errorText: texts('ytcp-video-upload-progress [role="alert"], #upload-error, #error-message, ytcp-uploads-dialog-error')
    };
  });
}

export function requireReadyToPublish(upload, checks, latestSnapshot) {
  const latest = classifyYouTubeStatus(latestSnapshot);
  // On Visibility the full claim explanation may be hidden and only its short
  // footer remains. Preserve the explicitly verified no-impact result, while
  // never overriding a new block, strike or error.
  const unresolvedClaim = latest.contentIssue && !(checks?.harmlessClaim && latest.copyrightClaim && !latest.blocked && !latest.strike);
  if (!upload?.uploadComplete || !checks?.checksComplete || checks.processingPending || checks.contentIssue
      || latest.uploadPending || latest.processingPending || latest.checking || unresolvedClaim || latest.error) {
    throw new Error('YouTube ещё не подтвердил готовность файла и проверки контента. Публикация остановлена.');
  }
}

// Long files are allowed to take hours. A short-lived DOM refresh or 5% upload
// is never treated as successful publication. Injectable clock supports tests
// of stalls and slow progress without real waits or network requests.
export async function waitForYouTubePhase(page, phase, options = {}) {
  const read = options.read || (() => readYouTubeStatus(page));
  const now = options.now || Date.now;
  const sleep = options.sleep || (ms => page.waitForTimeout(ms));
  const report = options.progress || (() => {});
  const timeoutMs = options.timeoutMs ?? 6 * 60 * 60 * 1000;
  const stallMs = options.stallMs ?? 30 * 60 * 1000;
  const started = now();
  let changedAt = started, lastSignature = '', lastReportAt = -Infinity, lastMessage = '';
  for (;;) {
    if (page.isClosed?.()) throw new Error('Окно YouTube закрыто до завершения ' + phase + '. Проверьте Studio перед повтором.');
    const status = classifyYouTubeStatus(await read());
    const signature = [status.progress, status.checks, status.error].join('|');
    if (signature !== lastSignature) { lastSignature = signature; changedAt = now(); }
    const message = (phase === 'upload' ? 'Передача файла: ' : 'Обработка и проверка контента: ')
      + (status.progress || status.checks || 'ожидаем статус YouTube')
      + (phase === 'checks' && status.checks ? ' · ' + status.checks : '');
    if (message !== lastMessage || now() - lastReportAt >= 15000) {
      report(message); lastMessage = message; lastReportAt = now();
    }
    if (status.error) throw new Error('YouTube сообщил об ошибке: ' + status.error);
    if (status.contentIssue) throw new Error('YouTube обнаружил ограничение контента: ' + status.checks
      + '. Публикация остановлена для проверки.');
    if (phase === 'upload' && status.uploadComplete) return status;
    if (phase === 'checks' && status.checksComplete && !status.processingPending) return status;
    if (now() - started >= timeoutMs) {
      throw new Error('Истекло время ожидания YouTube. Последний статус: ' + message + '. Не загружайте дубль без проверки Studio.');
    }
    if (phase === 'upload' && now() - changedAt >= stallMs) {
      throw new Error('Передача файла не менялась 30 минут: ' + status.progress + '. Проверьте соединение и текущую загрузку в браузере.');
    }
    await sleep(2000);
  }
}

export async function setVerifiedYouTubeField(page, locator, value, label, options = {}) {
  const expected = normalizedText(value);
  if (!expected) throw new Error('Пустое обязательное поле: ' + label);
  const now = options.now || Date.now;
  const sleep = options.sleep || (ms => page.waitForTimeout(ms));
  const stableMs = options.stableMs ?? 1500;
  await locator.waitFor({ state: 'visible', timeout: 30000 });
  await locator.scrollIntoViewIfNeeded();
  for (let attempt = 0; attempt < 3; attempt++) {
    await locator.fill(value);
    await locator.press('Tab');
    let stableSince = null;
    const deadline = now() + Math.max(5000, stableMs * 3);
    while (now() < deadline) {
      const actual = normalizedText(await locator.innerText());
      if (actual === expected) {
        if (stableSince === null) stableSince = now();
        if (now() - stableSince >= stableMs) return;
      } else { stableSince = null; }
      await sleep(250);
    }
  }
  throw new Error('YouTube не сохранил поле «' + label + '». Публикация остановлена.');
}

export async function waitEnabled(locator, label, timeoutMs = 30000) {
  await locator.waitFor({ state: 'visible', timeout: timeoutMs });
  // Playwright's locator.click performs the enabled/actionable wait itself.
  await locator.click({ timeout: timeoutMs });
}
