import { spawn } from 'node:child_process';
import process from 'node:process';
import { createServer } from 'vite';

const separator = process.argv.indexOf('--');
if (separator < 0 || separator === process.argv.length - 1) {
  throw new Error('usage: node scripts/with-web-server.mjs -- <command> [args...]');
}

const server = await createServer({
  configFile: 'web/vite.config.ts',
  server: { host: '127.0.0.1', port: 5174, strictPort: true }
});
await server.listen();

const [command, ...arguments_] = process.argv.slice(separator + 1);
const child = spawn(command, arguments_, {
  stdio: 'inherit',
  env: { ...process.env, MEDINAG_E2E_EXTERNAL_WEB_SERVER: 'true' }
});
for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => child.kill(signal));
}
const result = await new Promise((resolve, reject) => {
  child.once('error', reject);
  child.once('exit', (code, signal) => resolve({ code, signal }));
});
await server.close();
if (result.signal) process.kill(process.pid, result.signal);
process.exitCode = result.code ?? 1;
