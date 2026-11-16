import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import { resolve } from 'node:path';
const child = spawn(resolve(process.argv[2] || `target/debug/pult${process.platform === 'win32' ? '.exe' : ''}`), ['--mcp-computer'], { stdio: ['pipe', 'pipe', 'pipe'] });
let stdout = '', stderr = '';
child.stdout.on('data', data => stdout += data);
child.stderr.on('data', data => stderr += data);
const timeout = setTimeout(() => { child.kill(); process.stderr.write('MCP process timed out\n'); process.exitCode = 1; }, 20000);
child.on('error', e => { clearTimeout(timeout); throw e; });
const messages = [
  { jsonrpc: '2.0', id: 1, method: 'initialize', params: { protocolVersion: '2025-06-18', capabilities: {}, clientInfo: { name: 'pult-test', version: '1' } } },
  { jsonrpc: '2.0', method: 'notifications/initialized' },
  { jsonrpc: '2.0', id: 2, method: 'tools/list' },
  { jsonrpc: '2.0', id: 3, method: 'tools/call', params: { name: 'computer', arguments: { action: 'screenshot' } } },
];
child.stdin.end(messages.map(m => JSON.stringify(m) + '\n').join(''));
child.on('close', code => {
  clearTimeout(timeout);
  assert.equal(code, 0, stderr);
  const replies = stdout.trim().split('\n').map(line => JSON.parse(line));
  assert.equal(replies.length, 3);
  assert.equal(replies[0].result.serverInfo.name, 'pult-computer');
  if (process.platform === 'win32') assert.equal(replies[1].result.tools[0].name, 'computer');
  else assert.deepEqual(replies[1].result.tools, []);
  assert.equal(replies[2].result.isError, true);
  assert.match(replies[2].result.content[0].text, /выключен/);
  assert.ok(!replies.some(r => JSON.stringify(r).includes('image/png')));
  process.stdout.write('Native MCP stdio: initialize, tools/list, gated screenshot passed\n');
});
