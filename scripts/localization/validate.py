#!/usr/bin/env python3
"""Check locale parity, interpolation safety and separation of UI from protocol data."""
import json,re
from pathlib import Path
ROOT=Path(__file__).resolve().parents[2]
cat=json.loads((ROOT/'Shortcast/Resources/Localizable.xcstrings').read_text())
for key,item in cat['strings'].items():
 for lang in ('en','uk','ru'):
  assert lang in item.get('localizations',{}),(key,lang)
  unit=item['localizations'][lang].get('stringUnit')
  if unit:
   # Normalize old catalog format keys and modern, explicit positional placeholders.
   slots=lambda s: sorted(int(x) for x in re.findall(r'%(\d+)\$@',s))
   if slots(key):assert slots(key)==slots(unit['value']),(key,lang,'placeholder mismatch')
for path in (ROOT/'Shortcast/Views').rglob('*.swift'):
 text=path.read_text()
 assert not re.search(r'(?:==|!=)\s*L10n\.tr\(',text),(path,'localized machine identifier')
 assert 'ctaText: L10n.tr(' not in text,(path,'localized rendered CTA')
keys=None
for lang in ('uk','en','ru','pl','de'):
 data=json.loads((ROOT/f'site/locales/{lang}.json').read_text())
 if keys is None:keys=set(data['texts'])
 assert set(data['texts'])==keys,(lang,'missing website keys')
 assert len(data['steps'])==4 and all(len(s['points'])==3 for s in data['steps'])
 filename='index.html' if lang=='uk' else lang+'.html'
 page=(ROOT/'site'/filename).read_text()
 assert f'lang="{lang}"' in page
 assert page.count('hreflang=')>=10
 for match in re.finditer(r'(?:src|href|data-lightbox)="([^\"]+)"',page):
  target=match[1].split('?',1)[0]
  if target and not target.startswith(('http','#','mailto:')):assert (ROOT/'site'/target).is_file(),(lang,target)
print(f'Validated {len(cat["strings"])} app keys in 3 languages and 5 complete website locales.')
