# Fill the Russian column of Localizable.xcstrings from ru_en.py (+ EXTRA for strings added later).
import json, re, sys
sys.path.insert(0, 'scripts/l10n')
from ru_en import RU_EN

EXTRA = {  # english source -> russian
    "Language": "Язык",
    "Match System": "Как в системе",
}
NO_TRANSLATE = {"L", "W%lld", "⌥⇧V"}  # badges / shortcuts
SPEC = re.compile(r'%(?:\d+\$)?(?:lld|ld|d|@|lf|f|llu|lu)')

def interp_split(s):
    """Split a Swift literal body into text and \\( … ) segments."""
    parts, i, buf = [], 0, ''
    while i < len(s):
        if s.startswith('\\(', i):
            depth, j = 1, i + 2
            while depth:
                if s[j] == '(': depth += 1
                elif s[j] == ')': depth -= 1
                elif s[j] == '"': j = s.find('"', j + 1)
                j += 1
            parts.append(buf); buf = ''; i = j; continue
        buf += s[i]; i += 1
    parts.append(buf)
    return parts  # text pieces; placeholders sit between them

def norm_src(s): return '\x00'.join(interp_split(s))
def norm_key(k): return SPEC.sub('\x00', k).replace('%%', '%')

pairs = {norm_src(en): ru for ru, en in RU_EN.items()}
pairs.update({en: ru for en, ru in EXTRA.items()})
path = 'Isle/Resources/Localizable.xcstrings'
cat = json.load(open(path))
missing = []
for key, entry in cat['strings'].items():
    if key in NO_TRANSLATE or not re.search('[A-Za-z]', SPEC.sub('', key)):
        entry['shouldTranslate'] = False
        continue
    ru_src = pairs.get(norm_key(key))
    if ru_src is None:
        missing.append(key); continue
    specs = SPEC.findall(key)
    pieces = interp_split(ru_src)
    if specs:
        pieces = [p.replace('%', '%%') for p in pieces]
    if len(pieces) - 1 != len(specs):
        missing.append(key + '  (placeholder count)'); continue
    value = pieces[0] + ''.join(sp + p for sp, p in zip(specs, pieces[1:]))
    entry.setdefault('localizations', {})['ru'] = {'stringUnit': {'state': 'translated', 'value': value}}
json.dump(cat, open(path, 'w'), ensure_ascii=False, indent=2, sort_keys=True)
open(path, 'a').write('\n')
print('missing:', missing)
