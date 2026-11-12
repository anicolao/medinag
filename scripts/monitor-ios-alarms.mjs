import { spawn } from 'node:child_process';
import http from 'node:http';
import process from 'node:process';

const simulatorID = process.env.MEDINAG_SIMULATOR_ID;
const port = Number(process.env.MEDINAG_E2E_ALARM_MONITOR_PORT ?? '18181');

if (!simulatorID) {
  throw new Error('MEDINAG_SIMULATOR_ID is required.');
}

const counts = { alert: 0, response_saved: 0, response_synced: 0, response_reconciled: 0 };
const waiters = { alert: [], response_saved: [], response_synced: [], response_reconciled: [] };
const seenAlertIDs = new Set();

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
  for (const [milestone, event] of Object.entries({
    response_saved_locally: 'response_saved', response_synchronized: 'response_synced',
    response_locally_reconciled: 'response_reconciled'
  })) {
    if (line.includes(`Local alert evidence: ${milestone}`)) {
      counts[event] += 1;
      release(event);
    }
  }
  const alertID = line.match(/([0-9A-F-]{36}): Requesting alarm alert/)?.[1];
  if (alertID && !seenAlertIDs.has(alertID)) {
    seenAlertIDs.add(alertID);
    counts.alert += 1;
    release('alert');
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
  'process == "mobiletimerd" OR process == "MediNag"'
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
  const match = url.pathname.match(/^\/wait\/(alert|response_saved|response_synced|response_reconciled)$/);
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
