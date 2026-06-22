/**
 * HTTP + WebSocket server.
 *
 * Uses `noServer:true` so we own the `upgrade` handshake: we authenticate at the
 * earliest possible point (the bearer header, if present) and reject bad paths /
 * tokens before a WebSocket even exists — unauthenticated traffic shouldn't get
 * a socket. Browsers can't set WS headers, so header-less upgrades are accepted
 * and deferred to first-frame `auth` (handled in Connection).
 */
import { createServer, type IncomingMessage, type Server } from "node:http";
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, type WebSocket } from "ws";
import type { Socket } from "node:net";
import { CloseCode } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { Connection } from "./connection.js";

const WS_PATH = "/ws";

/** Constant-time bearer check used at the upgrade boundary. */
function bearerMatches(header: string | undefined): boolean {
  if (!header) return false;
  const m = /^Bearer\s+(.+)$/i.exec(header.trim());
  if (!m || !m[1]) return false;
  const provided = Buffer.from(m[1]);
  const expected = Buffer.from(config.token);
  if (provided.length !== expected.length) {
    timingSafeEqual(provided, provided);
    return false;
  }
  return timingSafeEqual(provided, expected);
}

/** Reject an upgrade before the WS exists (HTTP-level). */
function rejectUpgrade(socket: Socket, code: number, message: string): void {
  socket.write(
    `HTTP/1.1 ${code} ${message}\r\n` +
      "Connection: close\r\n" +
      "Content-Length: 0\r\n\r\n",
  );
  socket.destroy();
}

export interface PinchServer {
  http: Server;
  wss: WebSocketServer;
  close(): Promise<void>;
}

export function createPinchServer(): PinchServer {
  const wss = new WebSocketServer({ noServer: true });

  const http = createServer((req, res) => {
    // Tiny health endpoint for tunnels/load balancers.
    if (req.url === "/health" || req.url === "/healthz") {
      res.writeHead(200, { "content-type": "application/json" });
      res.end(JSON.stringify({ ok: true, mock: config.mock }));
      return;
    }
    res.writeHead(426, { "content-type": "text/plain" });
    res.end("Upgrade Required");
  });

  http.on("upgrade", (req: IncomingMessage, socket: Socket, head: Buffer) => {
    let pathname = "/";
    try {
      pathname = new URL(req.url ?? "/", "http://localhost").pathname;
    } catch {
      /* fall through to 404 below */
    }
    if (pathname !== WS_PATH) {
      rejectUpgrade(socket, 404, "Not Found");
      return;
    }

    // Header auth is preferred; header-less upgrades defer to first-frame auth.
    const authHeader = req.headers["authorization"];
    const preAuthed = bearerMatches(
      Array.isArray(authHeader) ? authHeader[0] : authHeader,
    );
    if (authHeader && !preAuthed) {
      // A header was provided but it's wrong → reject outright (4401-equivalent).
      log.warn("upgrade rejected: bad bearer header");
      rejectUpgrade(socket, CloseCode.AUTH_FAILED, "Unauthorized");
      return;
    }

    wss.handleUpgrade(req, socket, head, (ws: WebSocket) => {
      log.info({ preAuthed }, "ws connection upgraded");
      new Connection({ ws, preAuthed });
    });
  });

  return {
    http,
    wss,
    close: () =>
      new Promise<void>((resolve) => {
        for (const client of wss.clients) {
          try {
            client.close(1001, "server shutting down");
          } catch {
            client.terminate();
          }
        }
        wss.close(() => http.close(() => resolve()));
      }),
  };
}
