// The whole of Node that a TypeScript Land program can see (SPEC §5.1).
//
// Written into every attempt's directory beside main.ts and checked with it.
// It is not @types/node, on purpose: that package is thirty thousand lines
// whose version would have to be pinned beside tsc's on every machine that
// runs the server, and a quest needs four things from it — standard input,
// standard output, exit, and the timers the event-loop nodes are about. What
// is not declared here is not there, and `tsc` says so as TS2304 before a
// line runs, which is the answer a player should get.
//
// One idiom reads standard input in every quest:
//
//     const input: string = require("fs").readFileSync(0, "utf8");
//
// `import { readFileSync } from "fs"` is the same function and also works.

interface NodeStdout {
  write(chunk: string): boolean;
}

declare const process: {
  readonly stdout: NodeStdout;
  readonly stderr: NodeStdout;
  readonly argv: string[];
  exitCode: number | undefined;
  exit(code?: number): never;
  nextTick(callback: (...args: unknown[]) => void, ...args: unknown[]): void;
};

declare const console: {
  log(...data: unknown[]): void;
  error(...data: unknown[]): void;
};

declare function setTimeout(callback: (...args: any[]) => void, ms?: number, ...args: unknown[]): number;
declare function clearTimeout(id: number | undefined): void;
declare function setInterval(callback: (...args: any[]) => void, ms?: number, ...args: unknown[]): number;
declare function clearInterval(id: number | undefined): void;
declare function setImmediate(callback: (...args: any[]) => void, ...args: unknown[]): number;
declare function queueMicrotask(callback: () => void): void;
declare function structuredClone<T>(value: T): T;

declare module "fs" {
  export function readFileSync(fd: 0 | "/dev/stdin", encoding: "utf8"): string;
}

declare function require(id: "fs"): typeof import("fs");
