#!/usr/bin/env node
// pinch-watchdog — periodic health check + self-heal for the always-on agents.
//
// Run every couple of minutes by com.pinch.watchdog (StartInterval). This is the
// belt-and-suspenders layer ON TOP of launchd's KeepAlive:
//
//   KeepAlive restarts a process that EXITED. It cannot see a process that is
//   still alive but wedged (backend stuck not answering, ngrok up but discon-
//   nected) or an agent that got booted out. This probes real health — an HTTP
//   round-trip locally, and the public URL end-to-end — and re-kicks or re-
//   bootstraps whatever isn't right. The only way to truly stop pinch is
//   uninstall-launchd.sh (npm run down).
//
// Written in Node, not bash, on purpose: macOS TCC blocks launchd-spawned
// /bin/bash from executing scripts under ~/Desktop ("Operation not permitted"),
// while node reading its own script there is allowed — same as the backend.
//
// Conservative: each check retries before acting, so a transient blip or a
// mid-restart moment won't make it flap.
//
// Env (set by the rendered plist; safe defaults here for manual runs):
//   PINCH_PORT        local backend port             (default 8787)
//   PINCH_PUBLIC_URL  public URL to probe end-to-end (default: skip public check)
//   LOG_DIR           where to append watchdog.log    (default ~/Library/Logs/pinch)

import { execFileSync } from 'node:child_process';
import { appendFileSync, mkdirSync, existsSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

const uid = process.getuid();
const GUI = `gui/${uid}`;
const LA_DIR = join(homedir(), 'Library/LaunchAgents');
const PORT = process.env.PINCH_PORT || '8787';
const PUBLIC_URL = process.env.PINCH_PUBLIC_URL || '';
const LOG_DIR = process.env.LOG_DIR || join(homedir(), 'Library/Logs/pinch');
const LOG = join(LOG_DIR, 'watchdog.log');

mkdirSync(LOG_DIR, { recursive: true });
const ts = () => new Date().toISOString().replace('T', ' ').slice(0, 19);
const say = (m) => { try { appendFileSync(LOG, `[${ts()}] ${m}\n`); } catch {} };

// Run a launchctl subcommand; return true on exit 0.
function lc(args) {
  try {
    execFileSync('launchctl', args, { stdio: ['ignore', 'ignore', 'ignore'] });
    return true;
  } catch {
    return false;
  }
}
const isLoaded = (label) => lc(['print', `${GUI}/${label}`]);

function ensureLoaded(label) {
  if (isLoaded(label)) return;
  const plist = join(LA_DIR, `${label}.plist`);
  if (existsSync(plist)) {
    say(`${label} not loaded -> bootstrap`);
    if (!lc(['bootstrap', GUI, plist])) say('  bootstrap failed');
  } else {
    say(`${label} not loaded and no plist at ${plist} -> cannot recover`);
  }
}

function kick(label, why) {
  say(`${label} ${why} -> kickstart -k`);
  if (!lc(['kickstart', '-k', `${GUI}/${label}`])) say('  kickstart failed');
}

// Return the HTTP status code, or null if no response (refused/timeout). Any
// status counts as "reached" — a WS endpoint answers a plain GET with 426; we
// just need to know the request got through to a real server. Retries to absorb
// blips and mid-restart windows.
async function httpStatus(url, tries = 3, timeoutMs = 5000) {
  for (let i = 0; i < tries; i++) {
    const ctrl = new AbortController();
    const t = setTimeout(() => ctrl.abort(), timeoutMs);
    try {
      const res = await fetch(url, { signal: ctrl.signal, redirect: 'manual' });
      clearTimeout(t);
      return res.status;
    } catch {
      clearTimeout(t);
    }
    if (i < tries - 1) await new Promise((r) => setTimeout(r, 2000));
  }
  return null;
}

// 1. Both service agents must be loaded (re-bootstrap a booted-out one).
ensureLoaded('com.pinch.server');
ensureLoaded('com.pinch.tunnel');

// 2. Backend must actually answer locally.
const localStatus = await httpStatus(`http://127.0.0.1:${PORT}/`);
if (localStatus === null) {
  kick('com.pinch.server', `unhealthy on :${PORT}`);
}

// 3. Public URL must reach the SAME backend end-to-end. Comparing against the
//    local status (not just "got a response") catches a down tunnel: a reserved
//    ngrok domain with no live agent still serves ngrok's own error page, which
//    would otherwise look healthy. Skip if the backend is already known down, or
//    if no public URL is configured (e.g. cloudflared without a parsed host).
if (PUBLIC_URL && localStatus !== null) {
  const publicStatus = await httpStatus(PUBLIC_URL, 3, 8000);
  if (publicStatus !== localStatus) {
    kick('com.pinch.tunnel', `public URL ${PUBLIC_URL} returned ${publicStatus ?? 'no response'} (backend gives ${localStatus})`);
  }
}

process.exit(0);
