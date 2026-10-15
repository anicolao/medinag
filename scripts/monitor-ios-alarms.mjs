import { spawn } from 'node:child_process';
import http from 'node:http';
import process from 'node:process';

const simulatorID = process.env.MEDINAG_SIMULATOR_ID;
const port = Number(process.env.MEDINAG_E2E_ALARM_MONITOR_PORT ?? '18181');

if (!simulatorID) {
  throw new Error('MEDINAG_SIMULATOR_ID is required.');
}

const counts = { alert: 0, rendered: 0 };
const waiters = { alert: [], rendered: [] };
const seenAlertIDs = new Set();
let lastRenderedAt = 0;

function release(name) {
  const pending = waiters[name];
  waiters[name] = [];
  for (const waiter of pending) {
    if (counts[name] > waiter.after) {
      waiter.response.writeHead(200, { 'content-type': 'application/json' });
      waiter.response.end(JSON.stringify({ event: name, count: counts[name] }));
    } else {
      waiters[name].push(waiter);
    }
  }
}

function observe(line) {
  const alertID = line.match(/([0-9A-F-]{36}): Requesting alarm alert/)?.[1];
  if (alertID && !seenAlertIDs.has(alertID)) {
    seenAlertIDs.add(alertID);
    counts.alert += 1;
    release('alert');
  }
  const renderedID = line.match(/Setting up expanded view for alarm id ([0-9A-F-]{36})/)?.[1];
  const renderedAt = Date.now();
  // ClockAngel emits a short burst of identical setup messages for one
  // aperture. The same presentation ID can be reused for a later occurrence,
  // so collapse only the burst instead of permanently deduplicating the ID.
  if (renderedID && renderedAt - lastRenderedAt > 500) {
    lastRenderedAt = renderedAt;
    counts.rendered += 1;
    release('rendered');
  }
}

const developerDirectory = process.env.DEVELOPER_DIR
  ?? '/Applications/Xcode.app/Contents/Developer';
const logStream = spawn('/usr/bin/xcrun', [
  'simctl', 'spawn', simulatorID,
  'log', 'stream',
  '--style', 'compact',
  '--level', 'debug',
  '--predicate',
  'process == "mobiletimerd" OR process == "ClockAngel"'
], {
  env: { ...process.env, DEVELOPER_DIR: developerDirectory },
  stdio: ['ignore', 'pipe', 'inherit']
});

let buffered = '';
logStream.stdout.setEncoding('utf8');
logStream.stdout.on('data', (chunk) => {
  buffered += chunk;
  const lines = buffered.split('\n');
  buffered = lines.pop() ?? '';
  for (const line of lines) observe(line);
});

const server = http.createServer((request, response) => {
  const url = new URL(request.url ?? '/', 'http://127.0.0.1');
  if (url.pathname === '/health') {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify(counts));
    return;
  }
  const match = url.pathname.match(/^\/wait\/(alert|rendered)$/);
  if (!match) {
    response.writeHead(404);
    response.end();
    return;
  }
  const name = match[1];
  const after = Number(url.searchParams.get('after') ?? '0');
  if (counts[name] > after) {
    response.writeHead(200, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ event: name, count: counts[name] }));
    return;
  }
  const waiter = { after, response };
  waiters[name].push(waiter);
  request.on('close', () => {
    waiters[name] = waiters[name].filter((candidate) => candidate !== waiter);
  });
});

function shutdown() {
  logStream.kill('SIGTERM');
  server.close(() => process.exit(0));
}

process.on('SIGINT', shutdown);
process.on('SIGTERM', shutdown);
logStream.on('exit', (code) => {
  if (code && code !== 143) process.exitCode = code;
  server.close();
});

server.listen(port, '127.0.0.1');
