#!/usr/bin/env node
// Generate a fresh high-entropy Pinch device token (32 random bytes, base64url).
// This is your RCE-as-a-service password — treat it like one.
//
// Usage:
//   node infra/scripts/gen-token.mjs            # pretty output + instructions
//   node infra/scripts/gen-token.mjs --raw      # just the token, for piping
//
// The token must match on both ends:
//   - backend/.env       -> PINCH_TOKEN=<token>
//   - watch / simulator  -> server URL = wss://agent.<yourdomain>/ws, token = <token>

import { randomBytes } from 'node:crypto';

const token = randomBytes(32).toString('base64url');

const raw = process.argv.includes('--raw');
if (raw) {
  process.stdout.write(token + '\n');
  process.exit(0);
}

const line = '─'.repeat(60);
console.log(line);
console.log('Pinch device token (32 bytes, base64url):');
console.log();
console.log('  ' + token);
console.log();
console.log(line);
console.log('Next steps:');
console.log();
console.log('1) Put it in backend/.env:');
console.log(`     PINCH_TOKEN=${token}`);
console.log();
console.log('   Or append it from the repo root (does not overwrite other keys):');
console.log(`     printf 'PINCH_TOKEN=%s\\n' "${token}" >> backend/.env`);
console.log();
console.log('2) Put the SAME token in the watch app / simulator connection settings,');
console.log('   alongside the server URL:  wss://agent.<yourdomain>/ws');
console.log();
console.log('   Send it as an Authorization: Bearer header or the first frame —');
console.log('   never in the query string.');
console.log(line);
