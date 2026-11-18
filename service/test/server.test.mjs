import assert from 'node:assert/strict';
import { once } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { test } from 'node:test';
import { createMoonServer, tokenHash } from '../src/server.mjs';
import { validateArchive } from '../src/validation.mjs';

const first = 'a'.repeat(64);
const second = 'b'.repeat(64);
const archive = () => ({ format: 'moongram.profile', version: 1, profile: {
  displayName: 'Moon User', username: '', collectibleNumber: '', localPremium: false,
  stars: '9223372036854775807', walletBalance: '123456789012345678.123456789', walletCurrency: 'TON', gifts: []
} });

test('native gift identifiers keep their exact signed Int64 wire representation', () => {
  const value = archive();
  const telegram = { baseGiftID: '9223372036854775807', modelFileID: '-9223372036854775808', patternFileID: '42', backdropID: -2147483648 };
  value.profile.gifts = [{ id: '11111111-1111-1111-1111-111111111111', title: 'Moon', number: '1', model: 'moon',
    modelName: 'Telegram model', pattern: 'stars', backdrop: '14334C', symbolColor: 'B8DDF0', collection: '', telegram }];
  assert.doesNotThrow(() => validateArchive(value));
  for (const invalid of ['0', '-0', '01', '9223372036854775808', 9007199254740992]) {
    telegram.modelFileID = invalid;
    assert.throws(() => validateArchive(value));
  }
});

async function fixture(t, limit = 120) {
  const directory = await mkdtemp(join(tmpdir(), 'moongram-service-'));
  const server = await createMoonServer({ directory, accounts: { '1': tokenHash(first), '2': tokenHash(second) }, requestsPerMinute: limit });
  server.listen(0, '127.0.0.1');
  await once(server, 'listening');
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); await rm(directory, { recursive: true, force: true }); });
  const base = `http://127.0.0.1:${server.address().port}`;
  return (path, options = {}, token = first) => fetch(`${base}${path}`, {
    ...options, headers: { Authorization: `Bearer ${token}`, ...options.headers }
  });
}

test('unknown tokens cannot read or publish profiles', async t => {
  const request = await fixture(t);
  assert.equal((await request('/v1/profiles/1', {}, 'c'.repeat(64))).status, 401);
  assert.equal((await request('/v1/profiles/1', { method: 'PUT', body: '{}' }, 'c'.repeat(64))).status, 401);
});

test('an invite can only edit its bound Telegram ID', async t => {
  const request = await fixture(t);
  for (const method of ['PUT', 'DELETE']) {
    assert.equal((await request('/v1/profiles/2', { method, body: method === 'PUT' ? '{}' : undefined })).status, 403);
  }
});

test('publish, read by a friend, optimistic concurrency and unpublish', async t => {
  const request = await fixture(t);
  const body = JSON.stringify(archive());
  const headers = { 'Content-Type': 'application/json', 'If-None-Match': '*' };
  const created = await request('/v1/profiles/1', { method: 'PUT', headers, body });
  assert.equal(created.status, 201);
  const etag = created.headers.get('etag');
  const read = await request('/v1/profiles/1', {}, second);
  assert.equal(read.status, 200);
  assert.deepEqual(await read.json(), archive());
  assert.equal((await request('/v1/profiles/1', { method: 'PUT', headers, body })).status, 412);
  const updateHeaders = { 'Content-Type': 'application/json', 'If-Match': etag };
  const updates = await Promise.all([
    request('/v1/profiles/1', { method: 'PUT', headers: updateHeaders, body }),
    request('/v1/profiles/1', { method: 'PUT', headers: updateHeaders, body })
  ]);
  assert.deepEqual(updates.map(x => x.status).sort(), [200, 412]);
  assert.equal((await request('/v1/profiles/1', { method: 'DELETE' })).status, 200);
  assert.equal((await request('/v1/profiles/1', {}, second)).status, 404);
});

test('oversized and malicious payloads are rejected', async t => {
  const request = await fixture(t);
  const headers = { 'Content-Type': 'application/json', 'If-None-Match': '*' };
  for (const change of [
    a => { a.profile.displayName = '\u202Eadmin'; },
    a => { a.profile.displayName = '\ud800'; },
    a => { a.ownerID = '2'; },
    a => { a.profile.stars = 9007199254740992; },
    a => { a.profile.walletBalance = '-1'; },
    a => { a.profile.gifts = Array(129).fill({}); }
  ]) {
    const value = archive(); change(value);
    assert.equal((await request('/v1/profiles/1', { method: 'PUT', headers, body: JSON.stringify(value) })).status, 422);
  }
  assert.equal((await request('/v1/profiles/1', { method: 'PUT', headers, body: 'x'.repeat(6_291_457) })).status, 413);
});

test('per-account request limit applies', async t => {
  const request = await fixture(t, 2);
  assert.equal((await request('/v1/profiles/1')).status, 404);
  assert.equal((await request('/v1/profiles/1')).status, 404);
  assert.equal((await request('/v1/profiles/1')).status, 429);
  assert.equal((await request('/v1/profiles/1', {}, second)).status, 404);
});
