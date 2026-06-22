/**
 * Pinch backend entrypoint.
 *
 * Boots the WS server, logs the resolved config (without secrets), and wires
 * graceful shutdown on SIGINT/SIGTERM so in-flight sockets get a clean 1001.
 */
import { PROTOCOL_VERSION } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";
import { projectRegistry } from "./projects.js";
import { createPinchServer } from "./wsServer.js";

function main(): void {
  const server = createPinchServer();

  server.http.listen(config.port, () => {
    log.info(
      {
        port: config.port,
        path: "/ws",
        protocolVersion: PROTOCOL_VERSION,
        mock: config.mock,
        model: config.model,
        projects: projectRegistry.list().map((p) => p.id),
      },
      `Pinch backend listening on :${config.port}/ws${config.mock ? " (MOCK)" : ""}`,
    );
  });

  server.http.on("error", (err) => {
    log.fatal({ err }, "http server error");
    process.exit(1);
  });

  let shuttingDown = false;
  const shutdown = (signal: string) => {
    if (shuttingDown) return;
    shuttingDown = true;
    log.info({ signal }, "shutting down");
    const force = setTimeout(() => {
      log.warn("forced exit after shutdown timeout");
      process.exit(1);
    }, 5_000);
    force.unref();
    void server.close().then(() => {
      log.info("closed cleanly");
      process.exit(0);
    });
  };

  process.on("SIGINT", () => shutdown("SIGINT"));
  process.on("SIGTERM", () => shutdown("SIGTERM"));
  process.on("uncaughtException", (err) => {
    log.error({ err }, "uncaught exception");
  });
  process.on("unhandledRejection", (err) => {
    log.error({ err }, "unhandled rejection");
  });
}

main();
