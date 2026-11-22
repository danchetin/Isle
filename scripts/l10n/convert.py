# One-off: replace Russian UI literals with English ones (see ru_en.py).
import re, glob, sys
sys.path.insert(0, 'scripts/l10n')
from ru_en import RU_EN
cyr = re.compile('[А-Яа-яЁё]')
KEY_CTX = re.compile(r'(?:\bText|\bButton|\bTextField|\.help|\bLabel|\bToggle)\(\s*$')

def literals(src):
    i, n = 0, len(src)
    while i < n:
        if src.startswith('//', i):
            j = src.find('\n', i); i = n if j < 0 else j; continue
        if src.startswith('/*', i):
            j = src.find('*/', i); i = n if j < 0 else j + 2; continue
        if src.startswith('#"', i):
            j = src.find('"#', i + 2); i = j + 2; continue
        if src[i] == '"':
            j, depth = i + 1, 0
            while j < n:
                if src[j] == '\\' and src[j + 1] == '(':
                    depth += 1; j += 2; continue
                if depth:
                    if src[j] == '(': depth += 1
                    elif src[j] == ')': depth -= 1
                    elif src[j] == '"':
                        j = src.find('"', j + 1) + 1; continue
                    j += 1; continue
                if src[j] == '\\': j += 2; continue
                if src[j] == '"': break
                j += 1
            yield i, j + 1, src[i + 1:j]
            i = j + 1; continue
        i += 1

unknown = []
for f in sorted(glob.glob('Isle/**/*.swift', recursive=True)):
    if '/Debug/' in f: continue
    src = open(f).read()
    out, last, changed = [], 0, 0
    for a, b, lit in literals(src):
        if not cyr.search(lit): continue
        if lit not in RU_EN:
            unknown.append((f, lit)); continue
        en = RU_EN[lit]
        key = KEY_CTX.search(src[max(0, a - 40):a]) is not None
        rep = f'"{en}"' if key else f'String(localized: "{en}")'
        out.append(src[last:a]); out.append(rep); last = b; changed += 1
    if changed:
        out.append(src[last:])
        open(f, 'w').write(''.join(out))
        print(f'{changed:3} {f}')
print('not converted:', sorted(set(l for _, l in unknown)))
