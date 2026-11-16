import { spawnSync } from 'node:child_process';
const result = spawnSync(process.execPath, ['node_modules/@playwright/test/cli.js', 'test', 'tests/team.spec.js', '--grep', 'two real WebRTC peers'], { stdio: 'inherit', env: { ...process.env, PULT_RTC_NATIVE_NETWORK: '1' } });
process.exit(result.status ?? 1);
