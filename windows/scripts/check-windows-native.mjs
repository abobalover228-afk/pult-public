import { resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
const env = { ...process.env };
if (process.platform !== 'win32') env.RC_x86_64_pc_windows_msvc = resolve('scripts/zig-windres.py');
const result = spawnSync('cargo', ['check', '--locked', '--target', 'x86_64-pc-windows-msvc'], { stdio: 'inherit', env });
process.exit(result.status ?? 1);
