#!/usr/bin/env python3
"""Codex на двух аккаунтах: выбирает аккаунт с запасом лимита и переносит диалог между ними.

Аккаунты — отдельные папки CODEX_HOME (вход у каждого свой, auth.json не копируется).
Перенос диалога = копия файла rollout-…-<id>.jsonl в sessions/ другого аккаунта + `codex resume <id>`.
"""
import json
import os
import time
import shutil
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import limits
CODEX = next((str(p) for p in [Path.home()/'.local/bin/codex', Path('/opt/homebrew/bin/codex'), Path('/usr/local/bin/codex')] if p.is_file() and os.access(p, os.X_OK)), None) or shutil.which('codex') or 'codex'
ACCOUNTS = [(name, Path(home)) for name, home in limits.mac_accounts()]
WORKDIR = Path(os.environ.get('PULT_PROJECT', str(Path.home())))


def left(home):
    """Минимальный остаток по окнам, %; None — нет входа/неизвестно."""
    d = limits.read_limits(CODEX, str(home))
    if not d.get('available'):
        return None
    vals = [w['remaining_percent'] for b in d['limits'] for w in b['windows'] if w['remaining_percent'] is not None]
    return min(vals) if vals else None


def sessions(home):
    return list((home / 'sessions').glob('*/*/*/rollout-*.jsonl'))


def thread_id(path):
    return path.stem[-36:]


def last_session():
    files = [f for _, h in ACCOUNTS for f in sessions(h)]
    return max(files, key=lambda f: f.stat().st_mtime) if files else None


def sync(tid, home):
    """Кладёт самую свежую копию диалога tid в sessions/ аккаунта home."""
    copies = [f for _, h in ACCOUNTS for f in sessions(h) if thread_id(f) == tid]
    if not copies:
        return False
    newest = max(copies, key=lambda f: f.stat().st_mtime)
    rel = newest.relative_to(newest.parents[3])           # YYYY/MM/DD/rollout-….jsonl
    target = home / 'sessions' / rel
    if newest != target:
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(newest, target)
    return True


CONTINUE = ('Лимит прошлого аккаунта кончился, тебя переключили на другой аккаунт с этим же диалогом. '
            'Продолжай ровно с того места, где остановился.')


def limit_hit(path, pos):
    """Новые строки файла диалога: True, если ход оборвался на usage_limit_exceeded."""
    try:
        with open(path, 'rb') as f:
            f.seek(pos)
            data = f.read()
    except OSError:
        return False, pos
    end = data.rfind(b'\n') + 1
    hit = False
    for line in data[:end].splitlines():
        if b'usage_limit_exceeded' not in line:
            continue
        try:
            p = json.loads(line).get('payload') or {}
        except ValueError:
            continue
        if (p.get('error') or {}).get('codex_error_info') == 'usage_limit_exceeded':
            hit = True
    return hit, pos + end


def run(name, home, tid=None, prompt=None):
    """Запускает Codex; возвращает (id диалога, кончился ли лимит)."""
    print(f'\n▶ {name}' + (f' · диалог {tid[:8]}…' if tid else ' · новый диалог'), flush=True)
    env = {**os.environ, 'CODEX_HOME': str(home)}
    args = [CODEX, 'resume', tid] if tid else [CODEX]
    args += ['--no-alt-screen'] + ([prompt] if prompt else [])
    started = time.time()
    proc = subprocess.Popen(args, env=env, cwd=WORKDIR)
    watched, pos, hit = None, 0, False
    while proc.poll() is None:
        time.sleep(0.5)
        if watched is None:      # файл этого диалога: известный id или новый, созданный после запуска
            cand = [f for f in sessions(home) if (thread_id(f) == tid if tid else f.stat().st_mtime >= started - 1)]
            if cand:
                watched = max(cand, key=lambda f: f.stat().st_mtime)
                pos = watched.stat().st_size if tid else 0
                tid = thread_id(watched)
            continue
        found, pos = limit_hit(watched, pos)
        if found:
            hit = True
            time.sleep(1.5)       # дать Codex дописать сообщение об ошибке
            proc.terminate()
            try:
                proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                proc.kill()
            subprocess.run(['stty', 'sane'])
    return tid, hit


def main():
    with ThreadPoolExecutor(len(ACCOUNTS)) as pool:
        rest = list(pool.map(lambda a: left(a[1]), ACCOUNTS))
    alive = [i for i, r in enumerate(rest) if r]
    cur = max(alive, key=lambda i: rest[i]) if alive else 0
    print('Лимиты: ' + ', '.join(f'{n} ' + ('?' if r is None else f'{r:g}%') for (n, _), r in zip(ACCOUNTS, rest)))
    tid, prompt, tried = None, None, set()
    while True:
        name, home = ACCOUNTS[cur]
        if tid:
            sync(tid, home)
        tid, hit = run(name, home, tid, prompt)
        if not hit:
            return                # обычный выход из Codex — выходим и мы
        tried.add(cur)
        with ThreadPoolExecutor(len(ACCOUNTS)) as pool:
            now = list(pool.map(lambda a: left(a[1]), ACCOUNTS))
        nxt = sorted((i for i in range(len(ACCOUNTS)) if i not in tried and now[i]), key=lambda i: -now[i])
        if not nxt or not tid:
            print('\nЛимиты кончились на всех аккаунтах. Диалог сохранён — продолжишь после сброса.')
            return
        cur, prompt = nxt[0], CONTINUE
        print(f'\n⚡ Лимит «{name}» кончился → переключаю на «{ACCOUNTS[cur][0]}» и продолжаю диалог…', flush=True)


if __name__ == '__main__':
    main()
