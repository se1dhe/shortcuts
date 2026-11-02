#!/usr/bin/env python3
"""Build five static, indexable landing pages from one template and checked dictionaries."""
import html
import json
import re
from pathlib import Path
ROOT = Path(__file__).resolve().parent.parent
SITE = ROOT / 'site'
LANGS = {'uk': 'Українська', 'en': 'English', 'ru': 'Русский', 'pl': 'Polski', 'de': 'Deutsch'}
FLAGS = {'uk': '🇺🇦', 'en': '🇬🇧', 'ru': '🇷🇺', 'pl': '🇵🇱', 'de': '🇩🇪'}
URL = 'https://se1dhe.github.io/shortcuts/'
template = (SITE / 'templates/index.html').read_text()
for lang in LANGS:
    data = json.loads((SITE / f'locales/{lang}.json').read_text())
    def text(match):
        raw = match[1]
        value = html.unescape(raw).strip()
        if not value:
            return match[0]
        if value not in data['texts']:
            raise ValueError(f'{lang}: missing text {value!r}')
        return '>' + raw.replace(raw.strip(), html.escape(data['texts'][value], quote=False)) + '<'
    page = re.sub(r'>([^<>]+)<', text, template)
    def attribute(match):
        key, value = match[1], html.unescape(match[2])
        if value in data['attributes']:
            value = data['attributes'][value]
        return key + '="' + html.escape(value, quote=True) + '"'
    page = re.sub(r'(aria-label|alt)="([^"]*)"', attribute, page)
    page = page.replace('lang="uk"', f'lang="{lang}"', 1)
    metadata = data['meta']
    page = re.sub(r'(<meta name="description" content=")[^"]*',lambda m:m[1]+html.escape(metadata[0],quote=True),page)
    page = re.sub(r'(<meta property="og:description" content=")[^"]*',lambda m:m[1]+html.escape(metadata[1],quote=True),page)
    page = re.sub(r'(<meta property="og:title" content=")[^"]*',lambda m:m[1]+html.escape('КАДР & СЕНС · '+metadata[2],quote=True),page)
    filename = 'index.html' if lang == 'uk' else f'{lang}.html'
    page = page.replace('content="'+URL+'"','content="'+URL+('' if lang=='uk' else filename)+'"')
    links = ''.join(f'<link rel="alternate" hreflang="{code}" href="{URL}{"" if code=="uk" else code+".html"}">' for code in LANGS)
    page = page.replace('</head>', f'<link rel="canonical" href="{URL}{"" if lang=="uk" else filename}">{links}<link rel="alternate" hreflang="x-default" href="{URL}en.html"></head>')
    label={'uk':'Мова сайту','en':'Website language','ru':'Язык сайта','pl':'Język strony','de':'Sprache der Website'}[lang]
    choices = ''.join(
        f'<a href="{"index" if code=="uk" else code}.html" lang="{code}" hreflang="{code}"'
        f'{" aria-current=\"page\"" if code==lang else ""}>'
        f'<span class="language-flag" aria-hidden="true">{FLAGS[code]}</span>'
        f'<span>{name}</span><small>{code.upper()}</small></a>'
        for code,name in LANGS.items()
    )
    picker = (
        f'<details class="language-picker"><summary aria-label="{label}: {LANGS[lang]}">'
        f'<span class="language-flag" aria-hidden="true">{FLAGS[lang]}</span><span>{lang.upper()}</span>'
        '<svg viewBox="0 0 12 12" width="12" height="12" aria-hidden="true"><path d="m3 4.5 3 3 3-3"/></svg>'
        f'</summary><nav class="language-menu" aria-label="{label}">{choices}</nav></details>'
    )
    page=page.replace('<nav aria-label=',picker+'<nav aria-label=',1)
    # Inline JSON is data only; interaction code remains shared by every locale.
    payload=json.dumps(data['steps'],ensure_ascii=False).replace('<','\\u003c')
    page=page.replace('<script src="app.js" defer></script>',f'<script id="workflow-data" type="application/json">{payload}</script><script src="app.js" defer></script>')
    for key in ('src','data-lightbox'):
        # Screens are switched to matching app language once captures are available.
        app_lang=lang if lang in ('uk','ru') else 'en'
        page=re.sub(rf'{key}="assets/screenshots/([^/\"]+)"',lambda m:f'{key}="assets/screenshots/{app_lang}/{m[1]}"' if (SITE/f'assets/screenshots/{app_lang}/{m[1]}').exists() else m[0],page)
    if lang in ('en', 'pl', 'de') and (SITE/'assets/screenshots/en/home.jpg').exists():
        page=page.replace('src="assets/screenshots/en/essay-timeline.jpg"','src="assets/screenshots/en/home.jpg"',1)
        page=page.replace('data-lightbox="assets/screenshots/en/essay-timeline.jpg"','data-lightbox="assets/screenshots/en/home.jpg"',1)
        if (SITE/'assets/screenshots/en/timeline-detail.jpg').exists():
            page=page.replace('src="assets/screenshots/en/essay-timeline.jpg"','src="assets/screenshots/en/timeline-detail.jpg"',1)
    (SITE/filename).write_text(page)
print('Built:', ', '.join(LANGS))
