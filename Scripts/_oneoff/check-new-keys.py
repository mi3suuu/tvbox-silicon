import re, glob, sys

NEW = ["App/SourceSpeedLab.swift"]
cands = glob.glob("Sources/TVCore/Resources/*.lproj/Localizable.strings")
en = [c for c in cands if "/en.lproj/" in c]
if not en:
    print("no en.lproj table")
    sys.exit(1)
table = open(en[0], encoding="utf-8").read()

pattern = re.compile(r'L10n\.text\("([^"]+)"')
keys = set()
for path in NEW:
    keys.update(pattern.findall(open(path, encoding="utf-8").read()))
print("keys in new file:", len(keys))
missing = sorted(k for k in keys if ('"' + k + '"') not in table)
print("missing from en:", len(missing))
for k in missing:
    print("  MISSING", k)
