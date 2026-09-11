#!/usr/bin/env node
/**
 * Does the contract checker actually catch anything?
 *
 * `contract.mjs` has no server to run against until BE ships one, and a test
 * tool that has only ever printed "skipped" is indistinguishable from one
 * that would print "passed" at everything. So: start `mock-server.mjs`,
 * which implements enough of SPEC §6 to be correct, and require the checker
 * to go green. Then start it again, broken in one specific way, and require
 * the checker to go red **on the check that owns that rule** — not merely to
 * fail somewhere.
 *
 *     node tests/smoke/selftest.mjs
 *     node tests/smoke/selftest.mjs --only cross-user
 *
 * This is the same idea as `CausewaybayWallet/scripts/check-vector-coverage.py`,
 * which corrupts one value per fixture and requires every suite to notice. A
 * suite that stays green is not reading the file, whatever it claims.
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import process from "node:process";

const HERE = fileURLToPath(new URL(".", import.meta.url));
const ROOT = fileURLToPath(new URL("../..", import.meta.url));
const WALLET =
  process.env.CWBWALLET ?? `${ROOT}/../CausewaybayWallet/rustcli/target/debug/cwbwallet`;

const args = process.argv.slice(2);
const only = args.includes("--only") ? args[args.indexOf("--only") + 1] : null;

const tty = process.stdout.isTTY;
const c = (n, s) => (tty ? `\x1b[${n}m${s}\x1b[0m` : s);
const green = (s) => c("32", s);
const red = (s) => c("31", s);
const dim = (s) => c("2", s);

/**
 * fault → the PROTOCOL.md §8 point (or the check name) that must catch it.
 *
 * The mapping is the point. "Something failed" would pass even if the
 * checker only ever managed to notice the socket was different; naming the
 * owning check proves the rule is tested by the thing that claims to test it.
 */
const FAULTS = [
  ["extra-key-ok", "8.1"],
  ["correlation", "8.2"],
  ["unknown-closes", "8.3"],
  ["error-code", "8.4"],
  ["no-supported", "8.4"],
  ["nonce-reuse", "8.4"],
  ["trailing-newline", "8.6"],
  ["accepts-rebuilt", "8.6"],
  ["token-static", "8.7"],
  ["seq-gap", "8.8"],
  ["seq-from-one", "8.8"],
  ["event-id", "8.8"],
  ["no-busy", "8.10"],
  ["busy-per-user", "8.10"],
  ["anon-leak", "ANONYMOUS"],
  ["solution-leak", "§5"],
  ["trust-payload", "never trusted"],
  ["cross-user", "never see each other"],
  ["no-broadcast", "other connection"],
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

let port = 5399;
async function withMock(fault, fn) {
  const p = ++port;
  const argv = ["mock-server.mjs", "--port", String(p)];
  if (fault) argv.push("--break", fault);
  const child = spawn(process.execPath, argv, {
    cwd: HERE,
    stdio: ["ignore", "pipe", "pipe"],
  });
  const log = [];
  child.stdout.on("data", (d) => log.push(String(d)));
  child.stderr.on("data", (d) => log.push(String(d)));
  try {
    for (let i = 0; i < 60; i++) {
      if (log.join("").includes("mock PROTOCOL.md server")) break;
      await sleep(100);
    }
    return await fn(`ws://127.0.0.1:${p}/ws`, log);
  } finally {
    child.kill("SIGKILL");
  }
}

function runChecker(url) {
  const out = spawnSync(
    process.execPath,
    ["contract.mjs", "--url", url, "--json", "--timeout", "20000"],
    { cwd: HERE, encoding: "utf8", maxBuffer: 32 * 1024 * 1024 },
  );
  try {
    return JSON.parse(out.stdout);
  } catch {
    throw new Error(
      `the checker produced no JSON (exit ${out.status}):\n${out.stdout}\n${out.stderr}`,
    );
  }
}

const results = [];
function record(name, ok, detail = "") {
  results.push({ name, ok, detail });
  console.log(`${ok ? green("pass") : red("FAIL")}  ${name}${detail ? `\n      ${detail}` : ""}`);
}

async function main() {
  if (!existsSync(WALLET)) {
    console.error(
      `no signer at ${WALLET}.\n` +
        `The mock recovers signatures with CausewaybayWallet, so the selftest ` +
        `cannot run without it. Build it (\`make -C ../CausewaybayWallet build\`) ` +
        `or set $CWBWALLET.`,
    );
    return 2;
  }

  // ---- 1. a correct server must go green -------------------------------
  let baseline = null;
  if (!only) {
    baseline = await withMock(null, (url) => runChecker(url));
    const failed = baseline.results.filter((r) => r.status === "fail");
    record(
      "a correct mock passes every check",
      failed.length === 0 && baseline.pass > 0,
      failed.length
        ? `${failed.length} failed against a server that is supposed to be right:\n      ` +
            failed.map((f) => `${f.name}: ${f.detail}`).join("\n      ")
        : `${baseline.pass} checks green`,
    );
    if (failed.length) {
      // Either the mock or the checker is wrong, and until that is settled
      // every fault below would be noise.
      return 1;
    }
  }

  // ---- 2. each fault must break its own check ---------------------------
  const faults = only ? FAULTS.filter(([f]) => f === only) : FAULTS;
  for (const [fault, mustBreak] of faults) {
    const out = await withMock(fault, (url) => runChecker(url));
    const failed = out.results.filter((r) => r.status === "fail");
    const named = failed.filter(
      (r) =>
        r.point === mustBreak ||
        r.name.includes(mustBreak) ||
        (r.detail ?? "").includes(mustBreak),
    );
    record(
      `--break ${fault} is caught by ${mustBreak}`,
      named.length > 0,
      named.length > 0
        ? dim(named[0].detail.split("\n")[0].slice(0, 140))
        : failed.length
          ? `it failed, but on the wrong check(s): ${failed.map((f) => f.name).join(", ")}`
          : "the checker stayed green against a server that is broken on purpose",
    );
  }

  const bad = results.filter((r) => !r.ok).length;
  console.log(
    `\n${results.length - bad} passed, ${bad > 0 ? red(`${bad} failed`) : "0 failed"}`,
  );
  return bad > 0 ? 1 : 0;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    console.error(red("selftest fell over:"), err);
    process.exit(2);
  },
);
