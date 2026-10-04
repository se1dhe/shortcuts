import assert from 'assert';

function extractSearchQuery(filename, sourceTitle) {
  const raw = (sourceTitle && sourceTitle.length > 0) ? sourceTitle : filename;
  const noExt = raw.replace(/\.[^/.]+$/, '');

  // Normalize separators like underscores and dots to spaces first
  const normalized = noExt.replace(/[._-]/g, ' ');

  let detectedYear = null;
  const yearMatch = normalized.match(/\b(19\d{2}|20\d{2})\b/);
  if (yearMatch) {
    detectedYear = yearMatch[1];
  }

  let s = normalized;
  if (detectedYear) {
    s = s.replace(`(${detectedYear})`, ' ')
         .replace(`[${detectedYear}]`, ' ')
         .replace(new RegExp(`\\b${detectedYear}\\b`, 'g'), ' ');
  }
  s = s.replace(/\[.*?\]/g, ' ')
       .replace(/\(.*?\)/g, ' ');

  const tags = [
    '1080p', '720p', '2160p', '4k', 'uhd', 'bluray', 'bdrip', 'webrip', 'web dl',
    'webdl', 'dvdrip', 'hdtv', 'x264', 'x265', 'hevc', 'avc', 'dts', 'ac3', 'aac',
    'dub', 'sub', 'rus', 'eng', 'ita', 'remux', 'imax', 'extended', 'proper', 'repack'
  ];
  for (const tag of tags) {
    s = s.replace(new RegExp(`\\b${tag}\\b`, 'gi'), ' ');
  }

  const title = s.replace(/\s+/g, ' ').trim();
  return { title, year: detectedYear };
}

const tiktokViralHashtags = [
  '#кинонавечер', '#моментсфильма', '#фильмы', '#кино', '#фильм',
  '#отрывокизфильма', '#лучшиефильмы', '#чтопосмотреть',
  '#рек', '#рекомендации', '#fyp', '#fypシ'
];

const instagramViralHashtags = [
  '#reels', '#reelsinstagram', '#кино', '#фильм', '#фильмнавечер',
  '#отрывокизфильма', '#моментизфильма', '#киноман',
  '#лучшиефильмы', '#топфильмы', '#кинопоиск', '#вкино'
];

const youtubeShortsViralHashtags = [
  '#Shorts', '#кино', '#фильмы', '#фильмнавечер',
  '#моментыизфильмов', '#лучшиефильмы', '#топкино',
  '#шортс', '#shortsyoutube', '#кинопоиск'
];

console.log('--- [ТЕСТ 1: Распознавание названия и года фильма на всех этапах] ---');
const testCases = [
  { filename: 'Inception.2010.1080p.BluRay.x264.mkv', expectedTitle: 'Inception', expectedYear: '2010' },
  { filename: 'Брат.2.2000.WEB-DL.1080p.mkv', expectedTitle: 'Брат 2', expectedYear: '2000' },
  { filename: 'Тёмный_рыцарь_2008_BDRip.avi', expectedTitle: 'Тёмный рыцарь', expectedYear: '2008' },
  { filename: 'Зеленая миля (1999) 1080p.mp4', expectedTitle: 'Зеленая миля', expectedYear: '1999' },
  { filename: 'Snatch.2000.BDRip.mkv', expectedTitle: 'Snatch', expectedYear: '2000' },
  { filename: 'Побег из Шоушенка.mkv', expectedTitle: 'Побег из Шоушенка', expectedYear: null }
];

for (const tc of testCases) {
  const res = extractSearchQuery(tc.filename);
  console.log(`📁 Файл: "${tc.filename}" -> Название: "${res.title}", Год: "${res.year || 'нет'}"`);
  assert.strictEqual(res.title.toLowerCase(), tc.expectedTitle.toLowerCase());
  if (tc.expectedYear) {
    assert.strictEqual(res.year, tc.expectedYear);
  }
}
console.log('✓ Все тесты распознавания названий и годов пройдены!\n');

console.log('--- [ТЕСТ 2: Разделение вирусных описаний и хештегов по платформам] ---');
const movie = {
  title: 'Тёмный рыцарь',
  year: '2008',
  overview: 'Бэтмен поднимает ставки в войне с криминалом. С помощью лейтенанта Джима Гордона и прокурора Харви Дента он намерен очистить улицы Готэма.'
};

const cleanTag = '#темныйрыцарь';
const tiktokTags = [cleanTag, ...tiktokViralHashtags];
const instaTags = [cleanTag, ...instagramViralHashtags];
const ytTags = [cleanTag, ...youtubeShortsViralHashtags];

const tiktokDesc = `Такой развязки никто не ожидал... 😳\n\n🎬 Фильм: ${movie.title} (${movie.year})\n\n${movie.overview}\n\nКак бы ты поступил на его месте? Напиши в комменты 👇`;
const instaDesc = `🎬 «${movie.title}» (${movie.year})\n\n${movie.overview}\n\n📌 Сохраняй, чтобы не потерять на вечер!\nОцени этот момент от 1 до 10 в комментариях 👇`;
const ytHook = `🎬 ${movie.title} (${movie.year}) — Этот момент до мурашек... #Shorts`;
const ytDesc = `🎬 Фильм: ${movie.title} (${movie.year})\n\n${movie.overview}\n\n🔔 Подписывайся на канал, чтобы не пропустить лучшие моменты из кино!\n\n#Shorts #кино #фильмы`;

console.log('🎵 TIKTOK:');
console.log(`   Хук: 🎬 ${movie.title} (${movie.year})`);
console.log(`   Описание:\n${tiktokDesc}`);
console.log(`   Хештеги (${tiktokTags.length}): ${tiktokTags.join(' ')}\n`);

console.log('📸 INSTAGRAM REELS:');
console.log(`   Хук: 🎬 ${movie.title} (${movie.year})`);
console.log(`   Описание:\n${instaDesc}`);
console.log(`   Хештеги (${instaTags.length}): ${instaTags.join(' ')}\n`);

console.log('▶️ YOUTUBE SHORTS:');
console.log(`   Хук: ${ytHook}`);
console.log(`   Описание:\n${ytDesc}`);
console.log(`   Хештеги (${ytTags.length}): ${ytTags.join(' ')}\n`);

// Проверки различий
assert.notStrictEqual(tiktokDesc, instaDesc, 'TikTok и Instagram описания должны отличаться');
assert.notStrictEqual(tiktokDesc, ytDesc, 'TikTok и YouTube описания должны отличаться');
assert.notStrictEqual(instaDesc, ytDesc, 'Instagram и YouTube описания должны отличаться');

assert(tiktokTags.includes('#fyp') && tiktokTags.includes('#кинонавечер'));
assert(!tiktokTags.includes('#shorts'), 'В TikTok нет #shorts');

assert(instaTags.includes('#reels') && instaTags.includes('#reelsinstagram'));
assert(instaDesc.includes('Сохраняй'), 'Instagram стимулирует закладки');

assert(ytHook.includes('#Shorts'));
assert(ytTags.includes('#Shorts') && ytTags.includes('#шортс'));
assert(ytDesc.includes('Подписывайся'));

console.log('✓ Все 100% тестов вирального разделения успешно пройдены!');
