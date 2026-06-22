/**
 * Project registry + path-allowlist guard.
 *
 * `PINCH_PROJECTS` is the allowlist of absolute repo roots the agent may operate
 * in. This is the load-bearing security boundary for "which directory" — every
 * project the watch can select is resolved with path.resolve and verified to sit
 * under one of these roots, so a hostile `select_project` (or a `../` traversal)
 * can never escape the allowlist. Branch/dirty come from shelling out to git.
 */
import { execFile } from "node:child_process";
import { promisify } from "node:util";
import path from "node:path";
import { existsSync, statSync } from "node:fs";
import type { ProjectRef } from "@pinch/protocol";
import { config } from "./config.js";
import { log } from "./log.js";

const execFileP = promisify(execFile);

export interface Project {
  id: string;
  name: string;
  /** Absolute, resolved path. */
  root: string;
}

/** Derive a short stable id from a path (basename, slugified, de-duped). */
function makeId(root: string, taken: Set<string>): string {
  const base = path
    .basename(root)
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  let id = base || "project";
  let n = 1;
  while (taken.has(id)) id = `${base}-${++n}`;
  taken.add(id);
  return id;
}

export class ProjectRegistry {
  private readonly projects: Project[];
  private readonly byId = new Map<string, Project>();

  constructor(roots: string[]) {
    const taken = new Set<string>();
    this.projects = roots
      .map((r) => path.resolve(r))
      .filter((root, i, arr) => {
        if (arr.indexOf(root) !== i) return false; // de-dupe
        if (!existsSync(root) || !statSync(root).isDirectory()) {
          log.warn({ root }, "configured project path does not exist; skipping");
          return false;
        }
        return true;
      })
      .map((root) => ({
        id: makeId(root, taken),
        name: path.basename(root),
        root,
      }));

    for (const p of this.projects) this.byId.set(p.id, p);

    if (this.projects.length === 0 && !config.mock) {
      log.warn("no valid projects configured");
    }
  }

  list(): Project[] {
    return [...this.projects];
  }

  get(id: string): Project | undefined {
    return this.byId.get(id);
  }

  /** First configured project, used as the session default. */
  default(): Project | undefined {
    return this.projects[0];
  }

  /**
   * Guard: a candidate path is allowed only if, once resolved, it sits inside
   * one of the allowlisted roots. Defeats `../` traversal because we compare the
   * resolved absolute path against the resolved root with a trailing separator.
   */
  isPathAllowed(candidate: string): boolean {
    const resolved = path.resolve(candidate);
    return this.projects.some((p) => {
      if (resolved === p.root) return true;
      return resolved.startsWith(p.root + path.sep);
    });
  }

  /** Resolve a ProjectRef (with live git branch/dirty) for the protocol. */
  async toRef(project: Project): Promise<ProjectRef> {
    const { branch, dirty } = await this.gitInfo(project.root);
    return {
      id: project.id,
      name: project.name,
      path: project.root,
      branch,
      dirty,
    };
  }

  async listRefs(): Promise<ProjectRef[]> {
    return Promise.all(this.projects.map((p) => this.toRef(p)));
  }

  /** Best-effort current branch + dirty flag. Never throws. */
  private async gitInfo(
    cwd: string,
  ): Promise<{ branch?: string; dirty?: boolean }> {
    try {
      const [{ stdout: branchOut }, { stdout: statusOut }] = await Promise.all([
        execFileP("git", ["rev-parse", "--abbrev-ref", "HEAD"], { cwd }),
        execFileP("git", ["status", "--porcelain"], { cwd }),
      ]);
      const branch = branchOut.trim() || undefined;
      const dirty = statusOut.trim().length > 0;
      return { branch, dirty };
    } catch (err) {
      log.debug({ cwd, err }, "git info unavailable for project");
      return {};
    }
  }
}

export const projectRegistry = new ProjectRegistry(config.projects);
