#!/usr/bin/env python3
"""Translate embed-resource's windres arguments to Zig's real COFF resource compiler."""
import os
import shutil
import subprocess
import sys

args = sys.argv[1:]
if '-V' in args or '/?' in args:
    print('GNU windres compatible Pult Zig resource compiler bridge')
    raise SystemExit(0)
zig = os.environ.get('PULT_ZIG') or shutil.which('zig')
if not zig:
    raise SystemExit('Set PULT_ZIG to a Zig executable, or install Zig in PATH')
out = [zig, 'rc', '/:output-format', 'coff', '/:target', 'X64']
source = None
while args:
    arg = args.pop(0)
    if arg == '--input':
        source = args.pop(0)
    elif arg in ('--output', '--include-dir', '-I', '-D'):
        out += [{'--output': '/fo', '--include-dir': '/i', '-I': '/i', '-D': '/d'}[arg], args.pop(0)]
    elif arg.startswith('-D'):
        out += ['/d', arg[2:]]
    elif not arg.startswith('--output-format'):
        raise SystemExit('Unsupported resource argument: ' + arg)
if not source:
    raise SystemExit('Missing RC source')
raise SystemExit(subprocess.call(out + ['--', source]))
