import { appendFile, writeFile } from 'node:fs/promises';
import { createServer } from 'node:http';
import { spawn } from 'node:child_process';
import process from 'node:process';

const separator = process.argv.indexOf('--');
if (separator < 0 || separator === process.argv.length - 1) {
  throw new Error('usage: node scripts/with-captured-sms-gateway.mjs -- <command> [args...]');
}
const captureFile = process.env.MEDINAG_E2E_SMS_CAPTURE_FILE;
if (!captureFile) throw new Error('MEDINAG_E2E_SMS_CAPTURE_FILE is required.');

const accountSid = 'e2e-account';
const authToken = 'e2e-auth-token';
const fromNumber = '+15555550100';
const expectedAuthorization = `Basic ${Buffer.from(`${accountSid}:${authToken}`).toString('base64')}`;
let sequence = 0;
await writeFile(captureFile, '', { mode: 0o600 });

const server = createServer(async (request, response) => {
  const expectedPath = `/2010-04-01/Accounts/${accountSid}/Messages.json`;
  if (
    request.method !== 'POST'
    || request.url !== expectedPath
    || request.headers.authorization !== expectedAuthorization
    || !request.headers['content-type']?.startsWith('application/x-www-form-urlencoded')
  ) {
    response.writeHead(400, { 'content-type': 'application/json' });
    response.end(JSON.stringify({ message: 'The captured SMS request was not Twilio-compatible.' }));
    return;
  }

  let body = '';
  for await (const chunk of request) body += chunk;
  const fields = new URLSearchParams(body);
  sequence += 1;
  const messageId = `SM-e2e-${String(sequence).padStart(4, '0')}`;
  await appendFile(captureFile, `${JSON.stringify({
    method: request.method,
    path: request.url,
    authenticated: true,
    to: fields.get('To'),
    from: fields.get('From'),
    body: fields.get('Body'),
    providerMessageId: messageId,
    providerState: 'queued'
  })}\n`);
  response.writeHead(201, { 'content-type': 'application/json' });
  response.end(JSON.stringify({ sid: messageId, status: 'queued' }));
});

await new Promise((resolve, reject) => {
  server.once('error', reject);
  server.listen(0, '127.0.0.1', resolve);
});
const address = server.address();
if (!address || typeof address === 'string') throw new Error('Could not bind SMS gateway.');

const [command, ...arguments_] = process.argv.slice(separator + 1);
const child = spawn(command, arguments_, {
  stdio: 'inherit',
  env: {
    ...process.env,
    TWILIO_ACCOUNT_SID: accountSid,
    TWILIO_AUTH_TOKEN: authToken,
    TWILIO_FROM_NUMBER: fromNumber,
    MEDINAG_TWILIO_BASE_URL: `http://127.0.0.1:${address.port}`
  }
});

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => child.kill(signal));
}
const result = await new Promise((resolve, reject) => {
  child.once('error', reject);
  child.once('exit', (code, signal) => resolve({ code, signal }));
});
await new Promise((resolve) => server.close(resolve));
if (result.signal) process.kill(process.pid, result.signal);
process.exitCode = result.code ?? 1;
