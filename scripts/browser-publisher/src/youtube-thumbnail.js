export async function thumbnailState(editor) {
  return editor.evaluate(element => {
    const visible = node => node.getClientRects().length > 0 && getComputedStyle(node).visibility !== 'hidden';
    const images = [...element.querySelectorAll('img')].filter(visible)
      .filter(img => img.complete && img.naturalWidth > 0).map(img => img.currentSrc || img.src);
    const busy = [...element.querySelectorAll('[role="progressbar"], [aria-busy="true"], .uploading')].some(visible)
      || /(?:^|\n)\s*(?:Uploading|Загрузка|Завантаження)\s*(?:\.{3}|…|\d+\s*%)?\s*(?:$|\n)/i.test(element.innerText);
    const error = [...element.querySelectorAll('[role="alert"], #error-message')].filter(visible)
      .map(node => node.innerText || '').join(' ').trim();
    return { images, busy, error };
  });
}

export async function waitForThumbnailPreview(editor, previous, { timeoutMs = 120000, now = Date.now,
  sleep = ms => editor.page().waitForTimeout(ms), read = () => thumbnailState(editor) } = {}) {
  const deadline = now() + timeoutMs;
  while (now() < deadline) {
    const state = await read();
    if (state.error) throw new Error('Ошибка обложки YouTube: ' + state.error);
    if (!state.busy && state.images.some(src => src && !previous.includes(src))) return;
    await sleep(250);
  }
  throw new Error('YouTube не подтвердил готовность новой обложки. Проверьте текущую загрузку в браузере.');
}
