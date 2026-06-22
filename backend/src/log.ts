/**
 * Single pino logger for the whole process. Pretty-prints in dev (via the
 * pino-pretty transport), plain JSON in production for log shipping.
 */
import pino, { type Logger } from "pino";
import { config } from "./config.js";

export const log: Logger = pino({
  level: config.logLevel,
  ...(config.isDev
    ? {
        transport: {
          target: "pino-pretty",
          options: {
            colorize: true,
            translateTime: "HH:MM:ss.l",
            ignore: "pid,hostname",
          },
        },
      }
    : {}),
});
