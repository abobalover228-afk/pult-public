#!/usr/bin/python3
"""Read the supported Claude Code statusLine payload; never query private OAuth endpoints."""
import json, math, os, sys, tempfile, time
from pathlib import Path

def sanitize(payload, now=None):
    rate = payload.get('rate_limits')
    if not isinstance(rate, dict): return None
    clean = {}
    for key in ('five_hour', 'seven_day'):
        row = rate.get(key)
        if not isinstance(row, dict): continue
        used = row.get('used_percentage')
        if isinstance(used, bool) or not isinstance(used, (int,float)) or not math.isfinite(used) or not 0 <= used <= 100: continue
        item = {'used_percentage': used}
        reset = row.get('resets_at')
        if isinstance(reset,(int,float)) and not isinstance(reset,bool) and math.isfinite(reset): item['resets_at']=reset
        clean[key]=item
    if not clean: return None
    return {'saved_at': time.time() if now is None else now, 'source':'claude-code-statusline', 'rate_limits':clean}

def main():
    try: payload=json.load(sys.stdin)
    except (ValueError, OSError): return
    clean=sanitize(payload)
    if clean:
        directory=Path.home()/'.claude';directory.mkdir(mode=0o700,exist_ok=True)
        fd,path=tempfile.mkstemp(prefix='.limits-cache-',dir=directory)
        try:
            with os.fdopen(fd,'w') as out: json.dump(clean,out)
            os.replace(path,directory/'limits-cache.json')
        finally:
            if os.path.exists(path): os.unlink(path)
    # Missing quota does not refresh a previous success timestamp.
    parts=[]
    if clean:
        for key,name in [('five_hour','5ч'),('seven_day','нед')]:
            if key in clean['rate_limits']: parts.append(f"{name} {clean['rate_limits'][key]['used_percentage']:.0f}%")
    print(' · '.join(parts) or 'Квота Claude недоступна')
if __name__=='__main__': main()
