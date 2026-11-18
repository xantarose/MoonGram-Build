import { createHash, randomBytes } from 'node:crypto';
import { createServer } from 'node:http';
import { mkdir, readFile, rename, rm, writeFile } from 'node:fs/promises';
import { join } from 'node:path';
import { maximumBytes, validateArchive } from './validation.mjs';

export function tokenHash(token) { return createHash('sha256').update(token).digest('hex'); }

export async function atomicJSON(path, value) {
  const temporary = `${path}.${randomBytes(12).toString('hex')}.tmp`;
  try {
    await writeFile(temporary, JSON.stringify(value), { mode: 0o600, flag: 'wx' });
    await rename(temporary, path);
  } finally { await rm(temporary, { force: true }); }
}

export async function createMoonServer({ directory, accounts, requestsPerMinute = 120 }) {
  await mkdir(directory, { recursive: true, mode: 0o700 });
  const tokens = new Map();
  for (const [id, hash] of Object.entries(accounts)) {
    if (!/^[1-9][0-9]{0,18}$/.test(id) || typeof hash !== 'string' || !/^[0-9a-f]{64}$/.test(hash) || tokens.has(hash)) {
      throw new Error('Invalid account configuration');
    }
    tokens.set(hash, id);
  }
  if (tokens.size > 256) throw new Error('Maximum 256 invited accounts');
  const rates = new Map();
  const writes = new Map();

  async function record(id) {
    try { return JSON.parse(await readFile(join(directory, `${id}.json`), 'utf8')); }
    catch (error) { if (error.code === 'ENOENT') return null; throw error; }
  }

  async function serialize(id, action) {
    const previous = writes.get(id) ?? Promise.resolve();
    const current = previous.catch(() => {}).then(action);
    writes.set(id, current);
    try { return await current; }
    finally { if (writes.get(id) === current) writes.delete(id); }
  }

  const server = createServer(async (request, response) => {
    const send = (status, value, headers = {}) => {
      response.writeHead(status, {
        'Content-Type': 'application/json; charset=utf-8',
        'Cache-Control': 'no-store', 'X-Content-Type-Options': 'nosniff', ...headers
      });
      response.end(JSON.stringify(value));
    };
    try {
      const path = new URL(request.url, 'http://localhost').pathname;
      if (path === '/health' && request.method === 'GET') { send(200, { ok: true }); return; }
      const match = /^\/v1\/profiles\/([1-9][0-9]{0,18})$/.exec(path);
      if (!match) { send(404, { error: 'not_found' }); return; }
      const authorizationCount = request.rawHeaders.filter((_, index) => index % 2 === 0)
        .filter(name => name.toLowerCase() === 'authorization').length;
      const authorization = /^Bearer ([0-9a-f]{64})$/.exec(request.headers.authorization ?? '');
      const actor = authorizationCount === 1 && authorization ? tokens.get(tokenHash(authorization[1])) : null;
      if (!actor) { send(401, { error: 'unauthorized' }); request.resume(); return; }
      const id = match[1];
      const now = Date.now();
      const window = rates.get(actor);
      if (!window || now - window.start >= 60_000) rates.set(actor, { start: now, count: 1 });
      else if (++window.count > requestsPerMinute) { send(429, { error: 'rate_limited' }, { 'Retry-After': '60' }); return; }
      if (request.method === 'GET') {
        const value = await record(id);
        if (!value) { send(404, { error: 'not_found' }); return; }
        if (request.headers['if-none-match'] === value.etag) { response.writeHead(304, { 'Cache-Control': 'no-store', ETag: value.etag }); response.end(); return; }
        send(200, value.archive, { ETag: value.etag });
        return;
      }
      if (!['PUT', 'DELETE'].includes(request.method)) { send(405, { error: 'method_not_allowed' }, { Allow: 'GET, PUT, DELETE' }); return; }
      if (actor !== id) { send(403, { error: 'forbidden' }); request.resume(); return; }
      if (request.method === 'DELETE') {
        await serialize(id, async () => { await rm(join(directory, `${id}.json`), { force: true }); });
        send(200, { ok: true });
        return;
      }
      if ((request.headers['content-type'] ?? '').split(';')[0].trim().toLowerCase() !== 'application/json') {
        send(415, { error: 'json_required' }); request.resume(); return;
      }
      if (Number(request.headers['content-length']) > maximumBytes) { send(413, { error: 'too_large' }); request.resume(); return; }
      const chunks = [];
      let bytes = 0;
      for await (const chunk of request) {
        bytes += chunk.length;
        if (bytes > maximumBytes) { send(413, { error: 'too_large' }); return; }
        chunks.push(chunk);
      }
      let archive;
      try { archive = JSON.parse(Buffer.concat(chunks).toString('utf8')); validateArchive(archive); }
      catch { send(422, { error: 'invalid_archive' }); return; }
      await serialize(id, async () => {
        const previous = await record(id);
        if (request.headers['if-none-match'] === '*') {
          if (previous) { send(412, { error: 'profile_changed' }); return; }
        } else {
          if (!request.headers['if-match']) { send(428, { error: 'precondition_required' }); return; }
          if (!previous || previous.etag !== request.headers['if-match']) { send(412, { error: 'profile_changed' }); return; }
        }
        const etag = `"${randomBytes(16).toString('hex')}"`;
        await atomicJSON(join(directory, `${id}.json`), { etag, archive });
        send(previous ? 200 : 201, { ok: true }, { ETag: etag });
      });
    } catch {
      if (!response.headersSent) send(500, { error: 'internal_error' });
      else response.end();
    }
  });
  server.requestTimeout = 15_000;
  server.headersTimeout = 10_000;
  server.keepAliveTimeout = 5_000;
  server.maxConnections = 128;
  return server;
}
