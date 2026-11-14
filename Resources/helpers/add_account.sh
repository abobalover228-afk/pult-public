#!/bin/zsh
set -eu
SCRIPT_DIR="${0:A:h}"
export PATH="/Library/Frameworks/Python.framework/Versions/Current/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
ACCOUNT_HOME=$(python3 - <<'PY'
import json, os
from pathlib import Path
p=Path.home()/'.codex-accounts.json'
rows=json.loads(p.read_text()) if p.exists() else [{'name':'Codex','home':'~/.codex'}]
if not isinstance(rows,list) or any(not isinstance(r,dict) or not all(isinstance(r.get(k),str) for k in ('name','home')) for r in rows):
    raise SystemExit('Некорректный файл аккаунтов')
i=2
while (Path.home()/f'.codex-{i}').exists(): i+=1
h=Path.home()/f'.codex-{i}'
h.mkdir(mode=0o700)
rows.append({'name':f'Codex {i}', 'home':str(h)})
tmp=p.with_suffix('.json.tmp')
fd=os.open(tmp,os.O_WRONLY|os.O_CREAT|os.O_TRUNC,0o600)
with os.fdopen(fd,'w') as f: json.dump(rows,f,ensure_ascii=False,indent=2)
tmp.replace(p)
print(h)
PY
)
exec "$SCRIPT_DIR/open_codex.sh" "$ACCOUNT_HOME" "Codex"
