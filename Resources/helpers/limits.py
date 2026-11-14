#!/usr/bin/env python3
"""Read Codex account limits using the official app-server protocol. No turns or billing actions."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import json
import os
import math
from pathlib import Path
import queue
import subprocess
import sys
import threading
import time


def number(value):
    return value if isinstance(value, (int, float)) and not isinstance(value, bool) and math.isfinite(value) else None


def sanitize(account, result):
    account = account.get('account') or {}
    buckets = result.get('rateLimitsByLimitId') or {}
    if not buckets and isinstance(result.get('rateLimits'), dict):
        buckets = {'codex': result['rateLimits']}
    clean = []
    for key, bucket in buckets.items():
        if not isinstance(bucket, dict):
            continue
        windows = []
        for kind in ('primary', 'secondary'):
            item = bucket.get(kind)
            if not isinstance(item, dict):
                continue
            used = number(item.get('usedPercent'))
            windows.append({'kind': kind, 'used_percent': used,
                            'remaining_percent': max(0, 100 - used) if used is not None else None,
                            'minutes': number(item.get('windowDurationMins')),
                            'resets_at': number(item.get('resetsAt'))})
        credits = bucket.get('credits')
        if isinstance(credits, dict):
            credits = {k: credits[k] for k in ('hasCredits', 'unlimited', 'balance') if k in credits}
        else:
            credits = None
        clean.append({'name': bucket.get('limitName') or bucket.get('limitId') or key,
                      'plan': bucket.get('planType'), 'windows': windows, 'credits': credits})
    return {'available': True, 'checked_at': time.time(), 'auth': account.get('type'),
            'plan': account.get('planType'), 'limits': clean}


def read_limits(binary, home=None):
    """home — отдельная папка CODEX_HOME (второй аккаунт); None — папка по умолчанию."""
    proc = None
    try:
        proc = subprocess.Popen([binary, 'app-server', '--listen', 'stdio://'],
                                env={**os.environ, 'CODEX_HOME': home} if home else None,
                                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, text=True, bufsize=1)
        incoming = queue.Queue()

        def read():
            for line in proc.stdout:
                try:
                    incoming.put(json.loads(line))
                except ValueError:
                    continue
            incoming.put(None)

        threading.Thread(target=read, daemon=True).start()
        deadline = time.monotonic() + 18

        def send(value):
            proc.stdin.write(json.dumps(value) + '\n')
            proc.stdin.flush()

        def request(identifier, method, params=None):
            value = {'id': identifier, 'method': method}
            if params is not None:
                value['params'] = params
            send(value)
            while True:
                wait = deadline - time.monotonic()
                if wait <= 0:
                    raise TimeoutError()
                response = incoming.get(timeout=wait)
                if response is None:
                    raise RuntimeError('app_server_closed')
                if response.get('id') != identifier:
                    continue
                if 'error' in response:
                    # Do not print raw upstream messages, account identifiers, or auth material.
                    raise RuntimeError('account_limits_unavailable')
                return response.get('result') or {}

        request(1, 'initialize', {'clientInfo': {'name': 'pult_public',
                                                'title': 'Pult limits', 'version': '1.0'}})
        send({'method': 'initialized'})
        account = request(2, 'account/read', {'refreshToken': False})
        if account.get('account') is None:
            return {'available': False, 'error': 'Нет входа в Codex для этого пользователя.'}
        result = request(3, 'account/rateLimits/read')
        return sanitize(account, result)
    except (OSError, RuntimeError, TimeoutError, queue.Empty, ValueError):
        return {'available': False, 'error': 'Лимиты сейчас не получены. Остаток неизвестен.'}
    finally:
        if proc is not None:
            if proc.stdin:
                try:
                    proc.stdin.close()
                except OSError:
                    pass
            if proc.poll() is None:
                proc.terminate()
            try:
                proc.wait(timeout=2)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.wait()


def duration(minutes):
    if minutes is None:
        return 'длительность не предоставлена'
    if minutes > 0 and minutes % 1440 == 0:
        return f'{minutes / 1440:g} дн.'
    if minutes > 0 and minutes % 60 == 0:
        return f'{minutes / 60:g} ч.'
    return f'{minutes:g} мин.'


def render(label, data):
    lines = [label]
    if not data.get('available'):
        return lines + ['  ' + data.get('error', 'Нет данных.')]
    plan = data.get('plan') or next((b['plan'] for b in data['limits'] if b.get('plan')), None)
    lines.append('  План: ' + (plan or 'не предоставлен'))
    if not data['limits']:
        lines.append('  Окна лимитов не предоставлены — это не означает безлимит.')
    for bucket in data['limits']:
        lines.append('  ' + str(bucket['name']))
        if not bucket['windows']:
            lines.append('    Нет данных по окнам.')
        for window in bucket['windows']:
            remaining = window['remaining_percent']
            amount = f'осталось {remaining:g}%, использовано {window["used_percent"]:g}%' if remaining is not None else 'остаток неизвестен'
            reset = 'сброс не предоставлен'
            if window['resets_at'] is not None:
                try:
                    reset = 'сброс ' + datetime.datetime.fromtimestamp(
                        window['resets_at'], datetime.timezone.utc).astimezone().strftime('%d.%m %H:%M') + ' (местное время)'
                except (OverflowError, OSError, ValueError):
                    pass
            lines.append(f'    {duration(window["minutes"])}: {amount}; {reset}')
        credits = bucket.get('credits')
        if credits is not None:
            if credits.get('unlimited') is True:
                lines.append('    Доп. кредиты: провайдер указал unlimited (не обещание безлимита подписки).')
            elif credits.get('balance') is not None:
                lines.append(f'    Баланс доп. кредитов: {credits["balance"]} (не сумма в $).')
            elif credits.get('hasCredits') is False:
                lines.append('    Доп. кредиты: нет.')
    return lines


def mac_accounts():
    path = Path('~/.codex-accounts.json').expanduser()
    if not path.exists():
        return [('Codex', str(Path.home() / '.codex'))]
    rows = json.loads(path.read_text())
    if not isinstance(rows, list) or not rows or len(rows) > 32:
        raise ValueError('Invalid accounts configuration')
    return [(r['name'], os.path.expanduser(r['home'])) for r in rows]

def main():
    import shutil
    parser = argparse.ArgumentParser()
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args()
    binary = next((str(p) for p in [Path.home()/'.local/bin/codex', Path('/opt/homebrew/bin/codex'), Path('/usr/local/bin/codex')] if p.is_file() and os.access(p, os.X_OK)), None) or shutil.which('codex') or 'codex'
    try:
        accounts = mac_accounts()
        with ThreadPoolExecutor(max_workers=min(8, len(accounts))) as pool:
            values = list(pool.map(lambda a: read_limits(binary, a[1]), accounts))
        data = {'accounts': [{'name': name, 'home': home, **value} for (name, home), value in zip(accounts, values)]}
    except (OSError, ValueError, KeyError, TypeError):
        data = {'accounts': [{'name': 'Codex', 'available': False, 'error': 'Не удалось прочитать ~/.codex-accounts.json'}]}
    if args.json:
        print(json.dumps(data, ensure_ascii=False))
    else:
        for a in data['accounts']:
            print('\n'.join(render(a['name'], a)))

if __name__ == '__main__':
    main()
