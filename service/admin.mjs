import { randomBytes } from 'node:crypto';
import { mkdir, open, readFile, rm } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { atomicJSON, tokenHash } from './src/server.mjs';

const [operation, id, option] = process.argv.slice(2);
if (!['invite', 'revoke'].includes(operation) || !/^[1-9][0-9]{0,18}$/.test(id ?? '')) {
  console.error('Usage: node service/admin.mjs invite TELEGRAM_ID [--rotate] | revoke TELEGRAM_ID');
  process.exit(1);
}
const directory = resolve(process.env.MOONGRAM_DATA_DIRECTORY ?? 'service/data');
await mkdir(directory, { recursive: true, mode: 0o700 });
const file = join(directory, 'accounts.json');
const lockPath = join(directory, 'accounts.lock');
let lock;
try { lock = await open(lockPath, 'wx', 0o600); }
catch (error) {
  if (error.code === 'EEXIST') throw new Error('Another admin operation holds accounts.lock; retry after it finishes.');
  throw error;
}
try {
let accounts = {};
try { accounts = JSON.parse(await readFile(file, 'utf8')); }
catch (error) { if (error.code !== 'ENOENT') throw error; }
if (operation === 'revoke') {
  delete accounts[id];
  await atomicJSON(file, accounts);
  console.log('Invitation revoked. Restart the service to apply.');
} else {
  if (Object.hasOwn(accounts, id) && option !== '--rotate') throw new Error('Already invited; use --rotate explicitly');
  if (!Object.hasOwn(accounts, id) && Object.keys(accounts).length >= 256) throw new Error('Maximum 256 invited accounts');
  const token = randomBytes(32).toString('hex');
  accounts[id] = tokenHash(token);
  await atomicJSON(file, accounts);
  console.log('Verify this Telegram ID with the person before handing over the token.');
  console.log(`Account: ${id}\nToken (shown once): ${token}\nRestart the service to apply.`);
}
} finally {
  await lock.close();
  await rm(lockPath, { force: true });
}
