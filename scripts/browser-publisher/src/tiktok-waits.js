// Each Studio check has its own lifecycle. A usable Post button is not evidence
// that either check finished; descriptions are never used as status evidence.
export const MUSIC_HEADING = /^(?:(?:run a |automatic )?(?:sound|music)(?: copyright)? check|(?:run a )?copyright check|проверка (?:авторских прав(?: на (?:музыку|звук))?|музыки)|перевірка (?:авторських прав(?: на (?:музику|звук))?|музики))$/i;
export const CONTENT_HEADING = /^(?:(?:run a |automatic |quick |fast )?(?:video )?content check|(?:быстрая )?проверка (?:контента|содержимого|видео)|(?:швидка )?перевірка (?:контенту|вмісту|відео))$/i;
const pending = /\b(?:checking|processing|scanning|in progress|queued|pending|uploading)\b|проверяется|проверяем|выполняется|ид[её]т проверка|загружается|обрабатывается|перевіряється|триває|очікування|завантажується/i;
const clean = /no (?:copyright )?(?:issues|violations|problems)(?: (?:found|detected))?|check(?:s)? (?:complete|completed|passed)|\bpassed\b|(?:нарушений|проблем) не (?:найдено|обнаружено|выявлено)|проверка (?:завершена|пройдена)|(?:порушень|проблем) не виявлено|перевірку (?:завершено|пройдено)/i;
const problem = /(?:copyright|content|community guidelines?) (?:issue|violation|problem|infringement)s? (?:found|detected)|(?:issues?|violations?|problems?) (?:found|detected)|\b(?:blocked|failed|restricted)\b|(?:обнаружены|найдены|выявлены) (?:нарушения|проблемы)|заблокирован|не пройдена|виявлено (?:порушення|проблеми)|заблоковано/i;

export function classifyTikTokCheck(value) {
  const text = String(value || '').replace(/\s+/g, ' ').trim();
  if (!text) return 'unknown';
  if (pending.test(text)) return 'pending';
  // Remove explicit clean phrases before looking for positive findings.
  // "No issues found" must not match "issues found" below.
  if (problem.test(text.replace(new RegExp(clean.source, 'ig'), ''))) return 'failed';
  return clean.test(text) ? 'passed' : 'unknown';
}

export async function readTikTokChecks(surface) {
  return surface.evaluate(({ musicPattern, contentPattern, statusPattern }) => {
    const music = new RegExp(musicPattern, 'i'), content = new RegExp(contentPattern, 'i');
    const status = new RegExp(statusPattern, 'i');
    const visible = node => node.getClientRects().length && getComputedStyle(node).visibility !== 'hidden';
    const headings = [...document.querySelectorAll('h1,h2,h3,h4,label,p,span,div,[role="heading"]')]
      .filter(node => visible(node) && node.children.length < 4);
    function section(pattern) {
      const matches = headings.filter(node => pattern.test((node.innerText || '').trim()));
      for (const heading of matches) {
        let area = heading.parentElement;
        for (let depth = 0; area && area !== document.body && depth < 6; depth++, area = area.parentElement) {
          if (area.querySelector('[contenteditable="true"],textarea,input[type="file"]')) break;
          const text = (area.innerText || '').trim();
          // A parent encompassing both checks could incorrectly give the pending
          // music check the content check's success, or the reverse.
          const other = pattern === music ? content : music;
          const containsOther = [...area.querySelectorAll('h1,h2,h3,h4,label,p,span,div')]
            .some(node => other.test((node.innerText || '').trim()));
          if (containsOther || text.length > 2000) break;
          if (status.test(text)) return text;
        }
      }
      return '';
    }
    return { musicText: section(music), contentText: section(content) };
  }, { musicPattern: MUSIC_HEADING.source, contentPattern: CONTENT_HEADING.source,
    statusPattern: `${pending.source}|${clean.source}|${problem.source}` });
}

export async function enableTikTokChecks(surface) {
  for (const pattern of [MUSIC_HEADING, CONTENT_HEADING]) {
    const label = surface.getByText(pattern, { exact: true }).first();
    if (!await label.isVisible().catch(() => false)) continue;
    let area = label;
    for (let depth = 0; depth < 5; depth++) {
      area = area.locator('..');
      const toggle = area.locator('[role="switch"],input[type="checkbox"]').first();
      if (await toggle.count()) {
        const state = await toggle.getAttribute('aria-checked');
        const checked = state === null ? await toggle.isChecked() : state === 'true';
        if (!checked) await toggle.click({ timeout: 30000 });
        break;
      }
    }
  }
}

export async function waitForTikTokChecks(surface, options = {}) {
  const read = options.read || (() => readTikTokChecks(surface));
  const now = options.now || Date.now;
  const sleep = options.sleep || (ms => surface.waitForTimeout(ms));
  const progress = options.progress || (() => {});
  const started = now(), timeoutMs = options.timeoutMs ?? 30 * 60 * 1000;
  let previous = '', lastReport = -Infinity;
  for (;;) {
    const snapshot = await read();
    const music = classifyTikTokCheck(snapshot.musicText), content = classifyTikTokCheck(snapshot.contentText);
    const labels = { unknown: "ожидаем статус", pending: "проверяется", passed: "пройдена", failed: "обнаружена проблема" };
    const message = `Проверка TikTok: музыка — ${labels[music]}; контент — ${labels[content]}. ${snapshot.musicText || ''} ${snapshot.contentText || ''}`;
    if (message !== previous || now() - lastReport >= 15000) { progress(message); previous = message; lastReport = now(); }
    if (music === 'failed' || content === 'failed') throw new Error('TikTok сообщил о нарушении: ' + message);
    if (music === 'passed' && content === 'passed') return snapshot;
    if (now() - started >= timeoutMs) throw new Error('TikTok не завершил отдельные проверки музыки и контента. ' + message);
    await sleep(2000);
  }
}

export function requireTikTokChecksPassed(snapshot) {
  if (classifyTikTokCheck(snapshot.musicText) !== 'passed' || classifyTikTokCheck(snapshot.contentText) !== 'passed') {
    throw new Error('Перед публикацией TikTok ещё не подтвердил обе проверки музыки и контента.');
  }
}
