const audienceHeading = /^(?:Who can (?:watch|view|see) (?:this video|this post)|Кто может (?:видеть эту публикацию|смотреть это видео)|Хто може (?:бачити цей допис|дивитися це відео))$/i;
const publicAudience = /^(?:Everyone|Public|Все|Усі|Всі)$/i;

export async function ensureTikTokPublic(surface) {
  const label = surface.getByText(audienceHeading, { exact: true }).first();
  if (!await label.isVisible().catch(() => false)) throw new Error('Не найдена настройка аудитории TikTok. Публичность не подтверждена; публикация не выполнялась.');
  let area = label;
  for (let depth = 0; depth < 5; depth++) {
    area = area.locator('..');
    const select = area.locator('[role="combobox"]').first();
    if (!await select.count()) continue;
    const read = async () => (await select.innerText()).replace(/\s+/g, ' ').trim();
    if (publicAudience.test(await read())) return;
    await select.click();
    const option = surface.getByRole('option', { name: publicAudience }).first();
    if (await option.isVisible().catch(() => false)) await option.click();
    else await surface.getByText(publicAudience, { exact: true }).last().click();
    if (publicAudience.test(await read())) return;
    throw new Error('TikTok не подтвердил аудиторию «Все». Публикация не выполнялась.');
  }
  throw new Error('Не найден выбор аудитории TikTok. Публикация не выполнялась.');
}
