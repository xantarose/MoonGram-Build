import { readFile } from 'node:fs/promises';
import { resolve, join } from 'node:path';
import { createMoonServer } from './server.mjs';

const root = resolve(process.env.MOONGRAM_DATA_DIRECTORY ?? 'service/data');
const accounts = JSON.parse(await readFile(join(root, 'accounts.json'), 'utf8'));
const port = Number(process.env.MOONGRAM_PORT ?? '8787');
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
const server = await createMoonServer({ directory: join(root, 'profiles'), accounts });
server.listen(port, '127.0.0.1', () => { console.log(`MoonGram profiles: listening on 127.0.0.1:${port}`); });
