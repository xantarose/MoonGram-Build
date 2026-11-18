export const maximumBytes = 6_291_456;

export function validateArchive(archive) {
  object(archive, ['format', 'version', 'profile']);
  if (archive.format !== 'moongram.profile' || archive.version !== 1) invalid();
  const p = archive.profile;
  object(p, ['displayName', 'username', 'collectibleNumber', 'localPremium', 'stars', 'walletBalance', 'walletCurrency', 'gifts'],
    ['stars', 'walletBalance']);
  for (const key of ['displayName', 'username']) text(p[key], 64);
  text(p.collectibleNumber, 48);
  text(p.walletCurrency, 12, true);
  if (typeof p.localPremium !== 'boolean') invalid();
  // The wire format uses decimal strings to preserve the entire Swift Int64 range.
  if (p.stars !== undefined && p.stars !== null && (typeof p.stars !== 'string' ||
      !/^(0|[1-9][0-9]{0,18})$/.test(p.stars) || BigInt(p.stars) > 9223372036854775807n)) invalid();
  if (p.walletBalance !== undefined && p.walletBalance !== null &&
      (typeof p.walletBalance !== 'string' || !/^(0|[1-9][0-9]{0,17})(\.[0-9]{1,9})?$/.test(p.walletBalance))) invalid();
  if (!Array.isArray(p.gifts) || p.gifts.length > 128) invalid();
  const ids = new Set();
  let artworkBytes = 0;
  for (const g of p.gifts) {
    object(g, ['id', 'title', 'number', 'model', 'modelName', 'pattern', 'backdrop', 'symbolColor', 'collection', 'artwork', 'telegram'], ['artwork', 'telegram']);
    if (typeof g.id !== 'string' || !/^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(g.id) || ids.has(g.id.toLowerCase())) invalid();
    ids.add(g.id.toLowerCase());
    text(g.title, 64, true);
    text(g.number, 32, true);
    text(g.modelName, 64, true);
    text(g.collection, 64);
    if (g.telegram !== undefined && g.telegram !== null) {
      object(g.telegram, ['baseGiftID', 'modelFileID', 'patternFileID', 'backdropID']);
      for (const key of ['baseGiftID', 'modelFileID', 'patternFileID']) {
        const id = g.telegram[key];
        if (typeof id !== 'string' || !/^-?[1-9][0-9]{0,18}$/.test(id) ||
            BigInt(id) < -9223372036854775808n || BigInt(id) > 9223372036854775807n) invalid();
      }
      if (!Number.isInteger(g.telegram.backdropID) || g.telegram.backdropID < -2147483648 || g.telegram.backdropID > 2147483647) invalid();
    }
    if (!['moon', 'star', 'diamond', 'crown', 'heart', 'bear', 'sparkles', 'gift'].includes(g.model) ||
        !['moons', 'stars', 'diamonds', 'dots', 'none'].includes(g.pattern)) invalid();
    for (const key of ['backdrop', 'symbolColor']) if (typeof g[key] !== 'string' || !/^[0-9a-f]{6}$/i.test(g[key])) invalid();
    if (g.artwork !== undefined && g.artwork !== null) {
      if (typeof g.artwork !== 'string' || g.artwork.length > 174_764 ||
          !/^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/.test(g.artwork)) invalid();
      const data = Buffer.from(g.artwork, 'base64');
      const png = data.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]));
      const jpeg = data.subarray(0, 3).equals(Buffer.from([255, 216, 255]));
      if (data.length > 131_072 || (!png && !jpeg)) invalid();
      artworkBytes += data.length;
    }
  }
  if (artworkBytes > 4_194_304) invalid();
}

function object(value, allowed, optional = []) {
  if (value === null || typeof value !== 'object' || Array.isArray(value) ||
      Object.keys(value).some(key => !allowed.includes(key)) ||
      allowed.some(key => !optional.includes(key) && !Object.hasOwn(value, key))) invalid();
}

function text(value, maximum, required = false) {
  if (typeof value !== 'string' || [...value].length > maximum || Buffer.byteLength(value) > maximum * 8 ||
      (required && !value.trim()) || /[\p{Cc}\u202A-\u202E\u2066-\u2069]/u.test(value) || !value.isWellFormed()) invalid();
}

function invalid() { throw new Error('invalid_archive'); }
