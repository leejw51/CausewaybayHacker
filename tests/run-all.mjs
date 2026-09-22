#!/usr/bin/env node
/**
 * Everything, once, with an honest summary.
 *
 *     node tests/run-all.mjs                 # the lot
 *     node tests/run-all.mjs --only smoke    # substring filter on the suite name
 *     node tests/run-all.mjs --skip e2e      # the same, inverted
 *     node tests/run-all.mjs --list          # what it would run, and why not
 *     node tests/run-all.mjs --json          # machine-readable
 *
 * Exit 0 only if every suite that ran passed. Exit 1 if anything failed.
 * **A skip is never a pass**: the summary prints every skipped suite with the
 * reason and the command that would make it runnable, because a suite that
 * hides its skips is how "all green" stops meaning anything.
 *
 * ## What it starts, and where it writes
 *
 * The smoke checker and the browser suite both need a live server. This
 * starts one — with `--home <tmpdir>` (SPEC §1's first precedence) and
 * `--static frontend/dist-e2e`, so:
 *
 * * nothing is written into the developer's own `~/.causewaybayhacker`,
 * * every run starts from an empty database, so "node 1 is open" is true,
 * * the page carries the capture hook, which a plain `dist` build does not.
 *
 * It stops the server afterwards, including on `^C`.
 *
 * ## What it deliberately does not do
 *
 * It does not rebuild the frontend unless asked (`--build`), because several
 * agents share this tree and a build that lands mid-edit is somebody else's
 * afternoon. It says so and skips the browser suite instead.
 */

import { spawn, spawnSync } from "node:child_process";
import { existsSync, mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import process from "node:process";

const ROOT = fileURLToPath(new URL("..", import.meta.url));
const args = process.argv.slice(2);
const has = (f) => args.includes(`--${f}`);
const val = (f) => {
  const i = args.indexOf(`--${f}`);
  return i >= 0 && args[i + 1] && !args[i + 1].startsWith("--") ? args[i + 1] : null;
};

const ONLY = val("only");
const SKIP = val("skip");
const AS_JSON = has("json");
const LIST = has("list");
const BUILD = has("build");
const KEEP = has("keep-home");

const tty = process.stdout.isTTY && !AS_JSON;
const c = (n, s) => (tty ? `\x1b[${n}m${s}\x1b[0m` : s);
const green = (s) => c("32", s);
const red = (s) => c("31", s);
const yellow = (s) => c("33", s);
const dim = (s) => c("2", s);
const bold = (s) => c("1", s);

// ------------------------------------------------------------ what we have

const which = (bin) => spawnSync("command", ["-v", bin], { shell: true }).status === 0;

const WALLET =
  process.env.CWBWALLET ?? join(ROOT, "..", "CausewaybayWallet/rustcli/target/debug/cwbwallet");

const env = {
  cargo: which("cargo"),
  node: true,
  npm: which("npm"),
  python: which("python3"),
  go: which("go"),
  // The C++ land goes through the system driver, whatever it is; the Python
  // land through the same python3 the test scripts already need; and the
  // PyTorch land through that python3 with `torch` importable, which is a
  // question only the interpreter can answer.
  cpp: which("c++"),
  torch:
    which("python3") &&
    spawnSync("python3", ["-I", "-c", "import torch"], { stdio: "ignore" }).status === 0,
  rustc: which("rustc"),
  luajit: which("luajit"),
  love: which("love") || existsSync(join(ROOT, "love2d/build/love.app/Contents/MacOS/love")),
  wallet: existsSync(WALLET),
  e2eBundle: existsSync(join(ROOT, "frontend/dist-e2e/index.html")),
  playwright: existsSync(join(ROOT, "e2e/node_modules/@playwright/test")),
  frontendDeps: existsSync(join(ROOT, "frontend/node_modules")),
  smokeDeps: existsSync(join(ROOT, "tests/smoke/node_modules/ws")),
};

// ------------------------------------------------------------- the suites
//
// `needs` is checked before anything runs, so a missing toolchain is a
// reasoned skip rather than a crash forty seconds in.

// The content suite's arguments, which depend on what is installed.
//
// Sixteen of the twenty packs need only the four compilers; the four pytorch
// ones need `torch` as well, and torch is a package inside an interpreter
// rather than a program on PATH — the one toolchain here that a perfectly
// ordinary machine will not have. Making the whole suite need it would mean
// that a laptop without torch silently stops verifying rust, go, cpp and
// python too, which is the opposite of what a missing optional dependency
// should cost.
//
// `--complete` goes with them. Its question — is every slug in
// docs/concepts.md reachable from some §7.1 mistake kind? — can only be
// answered over the full set, because the twelve tensor slugs live in
// exactly the packs that were dropped. Asking it of sixteen files would fail
// on the twelve every time, so it is asked when it can be answered.
const PACKS_COMPILED = [
  "content/rust/verybasic.toml",
  "content/rust/basic.toml",
  "content/rust/advanced.toml",
  "content/rust/hacker.toml",
  "content/go/verybasic.toml",
  "content/go/basic.toml",
  "content/go/advanced.toml",
  "content/go/hacker.toml",
  "content/cpp/verybasic.toml",
  "content/cpp/basic.toml",
  "content/cpp/advanced.toml",
  "content/cpp/hacker.toml",
  "content/python/verybasic.toml",
  "content/python/basic.toml",
  "content/python/advanced.toml",
  "content/python/hacker.toml",
];
const PACKS_PYTORCH = [
  "content/pytorch/verybasic.toml",
  "content/pytorch/basic.toml",
  "content/pytorch/advanced.toml",
  "content/pytorch/hacker.toml",
];
// PM's two newer gates, both worth having in CI:
//   * a brief's worked example must match a visible case — it caught a quest
//     whose brief showed `1 3` where its test expected `3 1`, unsolvable as
//     written and invisible to every other check;
//   * `--complete` fails on a concept slug no §7.1 mistake kind can reach,
//     so the AI drills cannot be pointed at a dead end.
const CONTENT_ARGS = env.torch
  ? ["--complete", ...PACKS_COMPILED, ...PACKS_PYTORCH]
  : PACKS_COMPILED;

/** @type {{name:string, what:string, cwd:string, cmd:string[], needs:[boolean,string][], server?:boolean, slow?:boolean, note?:string}[]} */
const SUITES = [
  {
    name: "vectors",
    what: "the shared fixtures are what the tools produce (SPEC §9.1, §9.2)",
    cwd: ROOT,
    cmd: ["python3", "tests/vectors/generate.py", "--check"],
    needs: [
      [env.python, "python3 is not on PATH"],
      [env.wallet, `no CausewaybayWallet binary at ${WALLET} — set $CWBWALLET`],
    ],
  },
  {
    name: "mistakes",
    what: "every §7.1 taxonomy fixture still compiles to the code it claims",
    cwd: ROOT,
    cmd: ["python3", "tests/vectors/mistakes/generate.py", "--check"],
    needs: [
      [env.python, "python3 is not on PATH"],
      [env.rustc, "rustc is not on PATH"],
      [env.go, "go is not on PATH"],
      [env.cpp, "c++ is not on PATH"],
    ],
    slow: true,
  },
  {
    name: "backend-unit",
    what: "the Rust workspace: core, runner, server, cli",
    cwd: join(ROOT, "backend"),
    cmd: ["cargo", "test", "--workspace"],
    needs: [
      [env.cargo, "cargo is not on PATH"],
      [env.rustc, "rustc is not on PATH — the runner tests compile real programs"],
      [env.go, "go is not on PATH — the runner tests compile real programs"],
      [env.cpp, "c++ is not on PATH — the runner tests compile real programs"],
    ],
    slow: true,
  },
  {
    name: "frontend-unit",
    what: "vitest over the scenes, the wallet derivation and the wire client",
    cwd: join(ROOT, "frontend"),
    cmd: ["npm", "test", "--silent"],
    needs: [
      [env.npm, "npm is not on PATH"],
      [env.frontendDeps, "frontend/node_modules is missing — run `npm ci` in frontend/"],
    ],
  },
  {
    name: "love2d",
    what: "the LÖVE client's suite, headless",
    cwd: join(ROOT, "love2d"),
    cmd: ["make", "test-headless"],
    needs: [
      [env.luajit, "luajit is not on PATH (`brew install luajit`)"],
      [existsSync(join(ROOT, "love2d/Makefile")), "love2d/ has no Makefile"],
    ],
    // Headless means no `love.graphics`, so the suite skips its own layout
    // tests and says so in its output. `make -C love2d test` runs them under
    // a real LÖVE window — which CI cannot do and a person can.
    note: env.love
      ? "headless: the layout suite is skipped inside it (`make -C love2d test` for those)"
      : "headless: the layout suite is skipped inside it, and LÖVE is not installed to run it",
  },
  {
    name: "content-gate",
    what: "the content gate's own structural rules, on fixtures (no compiler)",
    cwd: ROOT,
    cmd: ["python3", "-m", "unittest", "-q", "tests/content/test_verify_pack.py"],
    needs: [[env.python, "python3 is not on PATH"]],
  },
  {
    name: "content",
    what: "every reference solution is accepted and no starter is (SPEC §9.4, §9.5)",
    cwd: ROOT,
    cmd: ["python3", "tests/content/verify_pack.py", ...CONTENT_ARGS],
    needs: [
      [env.python, "python3 is not on PATH"],
      [env.rustc, "rustc is not on PATH"],
      [env.go, "go is not on PATH"],
      [env.cpp, "c++ is not on PATH"],
    ],
    note: env.torch
      ? undefined
      : "torch is not importable, so the four pytorch packs and --complete were " +
        "left out — the other sixteen ran (python3 -m pip install torch)",
    slow: true,
  },
  {
    name: "smoke-selftest",
    what: "the contract checker catches 19 deliberately-broken servers",
    cwd: join(ROOT, "tests/smoke"),
    cmd: ["node", "selftest.mjs"],
    needs: [
      [env.wallet, `no CausewaybayWallet binary at ${WALLET} — set $CWBWALLET`],
      [env.smokeDeps, "tests/smoke/node_modules is missing — run `npm install` there"],
    ],
    slow: true,
  },
  {
    name: "smoke",
    what: "PROTOCOL.md §8 conformance against the real server",
    cwd: ROOT,
    cmd: ["node", "tests/smoke/contract.mjs"],
    needs: [[env.wallet, `no CausewaybayWallet binary at ${WALLET} — set $CWBWALLET`]],
    server: true,
    // §8.12's default window is six seconds; §1.1's real one is seventy.
    note: "keepalive is checked over 6s, not §1.1's 70s — `node tests/smoke/contract.mjs --slow`",
  },
  {
    name: "e2e",
    what: "the journey in a real browser, both orientations",
    cwd: join(ROOT, "e2e"),
    cmd: ["npx", "playwright", "test"],
    needs: [
      [env.playwright, "e2e/node_modules is missing — run `npm install && npx playwright install chromium` in e2e/"],
      [
        env.e2eBundle || BUILD,
        "frontend/dist-e2e is missing. It is the only build that carries the " +
          "capture hook (VITE_E2E=1). Run `npm run build:e2e` in frontend/, or " +
          "pass --build to have this script do it",
      ],
      [env.wallet, `no CausewaybayWallet binary at ${WALLET} — set $CWBWALLET`],
    ],
    server: true,
    slow: true,
  },
];

// --------------------------------------------------------------- the server

let server = null;
let home = null;

function startServer() {
  home = mkdtempSync(join(tmpdir(), "cwbhacker-testall-"));
  const port = 5400 + Math.floor(Math.random() * 120);
  const child = spawn(
    "cargo",
    [
      "run",
      "-q",
      "-p",
      "cwbhacker",
      "--",
      "serve",
      "--bind",
      `127.0.0.1:${port}`,
      "--home",
      home,
      "--static",
      join(ROOT, "frontend/dist-e2e"),
    ],
    { cwd: join(ROOT, "backend"), stdio: ["ignore", "pipe", "pipe"] },
  );
  const log = [];
  child.stdout.on("data", (d) => log.push(String(d)));
  child.stderr.on("data", (d) => log.push(String(d)));
  server = { child, port, log, url: `http://127.0.0.1:${port}` };
  return server;
}

/**
 * Wait until the server can actually be *used*.
 *
 * An HTTP 200 is not enough. The thing every server-needing suite talks to is
 * the websocket, and there is a window where the static files are served and
 * `/ws` is not yet. A cold start on a fresh `--home` also has to build the
 * workspace and import **126 quests across six packs**, which is minutes, not
 * seconds — so this waits on the handshake and gives it room.
 */
async function waitForServer(seconds = 600) {
  const until = Date.now() + seconds * 1000;
  let lastError = "";
  while (Date.now() < until) {
    if (server.child.exitCode !== null)
      throw new Error(
        `the server exited with ${server.child.exitCode}:\n${server.log.join("").slice(-3000)}`,
      );
    const ok = await new Promise((resolve) => {
      let ws;
      const done = (v, why = "") => {
        lastError = why || lastError;
        try {
          ws?.close();
        } catch {
          /* already gone */
        }
        resolve(v);
      };
      try {
        ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws`);
      } catch (e) {
        return done(false, String(e));
      }
      const timer = setTimeout(() => done(false, "handshake timed out"), 3000);
      ws.addEventListener("open", () => (clearTimeout(timer), done(true)));
      ws.addEventListener("error", () => (clearTimeout(timer), done(false, "refused")));
    });
    if (ok) return;
    await new Promise((r) => setTimeout(r, 1000));
  }
  throw new Error(
    `the websocket at ws://127.0.0.1:${server.port}/ws never opened within ` +
      `${seconds}s (last: ${lastError}). A cold start builds the workspace and ` +
      `imports 126 quests, so this is slow the first time. The server said:\n` +
      server.log.join("").slice(-3000),
  );
}

/** Is it still there? Suites run for minutes; a server that died is not a bug
 *  in the suite that happens to be next. */
async function serverAlive() {
  if (!server || server.child.exitCode !== null) return false;
  return new Promise((resolve) => {
    let ws;
    const done = (v) => {
      try {
        ws?.close();
      } catch {
        /* already gone */
      }
      resolve(v);
    };
    try {
      ws = new WebSocket(`ws://127.0.0.1:${server.port}/ws`);
    } catch {
      return done(false);
    }
    const timer = setTimeout(() => done(false), 5000);
    ws.addEventListener("open", () => (clearTimeout(timer), done(true)));
    ws.addEventListener("error", () => (clearTimeout(timer), done(false)));
  });
}

function stopServer() {
  if (server?.child && server.child.exitCode === null) {
    try {
      server.child.kill("SIGTERM");
    } catch {
      /* already gone */
    }
  }
  if (home && !KEEP) {
    try {
      rmSync(home, { recursive: true, force: true });
    } catch {
      /* best effort */
    }
  }
  server = null;
}
process.on("SIGINT", () => (stopServer(), process.exit(130)));
process.on("SIGTERM", () => (stopServer(), process.exit(143)));
process.on("exit", stopServer);

// ------------------------------------------------------------------- run

function runSuite(suite) {
  const started = Date.now();
  const extra = suite.server
    ? {
        SMOKE_WS_URL: `ws://127.0.0.1:${server.port}/ws`,
        E2E_BASE_URL: server.url,
        CWBHACKER_HOME: home,
      }
    : {};
  const out = spawnSync(suite.cmd[0], suite.cmd.slice(1), {
    cwd: suite.cwd,
    encoding: "utf8",
    env: { ...process.env, CWBWALLET: WALLET, ...extra },
    maxBuffer: 64 * 1024 * 1024,
  });
  return {
    status: out.status === 0 ? "pass" : "fail",
    code: out.status,
    ms: Date.now() - started,
    stdout: out.stdout ?? "",
    stderr: out.stderr ?? "",
  };
}

/** The last few lines that actually say something, for a failure. */
function tail(text, n = 18) {
  return text
    .split("\n")
    .filter((l) => l.trim())
    .slice(-n)
    .join("\n");
}

async function main() {
  // Server-needing suites first. `smoke-selftest` spawns twenty mock servers
  // over about nine minutes, and putting that between starting the server and
  // using it is how `smoke` ended up reporting "nothing answered".
  SUITES.sort((a, b) => Number(!!b.server) - Number(!!a.server));
  let selected = SUITES;
  if (ONLY) selected = selected.filter((s) => s.name.includes(ONLY));
  if (SKIP) selected = selected.filter((s) => !s.name.includes(SKIP));
  if (selected.length === 0) {
    console.error(`no suite matches --only ${ONLY} --skip ${SKIP}`);
    return 2;
  }

  // Every reason to skip is known before anything runs.
  const plan = selected.map((suite) => {
    const missing = suite.needs.filter(([ok]) => !ok).map(([, why]) => why);
    return { suite, skip: missing.length ? missing.join("; ") : null };
  });

  if (LIST) {
    for (const { suite, skip } of plan)
      console.log(
        `${skip ? yellow("skip") : green("run ")}  ${suite.name.padEnd(15)} ${suite.what}` +
          (skip ? `\n      ${dim(skip)}` : ""),
      );
    return 0;
  }

  if (BUILD && plan.some(({ suite, skip }) => suite.name === "e2e" && !skip)) {
    if (!AS_JSON) console.log(dim("building frontend/dist-e2e …"));
    const b = spawnSync("npm", ["run", "build:e2e"], {
      cwd: join(ROOT, "frontend"),
      encoding: "utf8",
    });
    if (b.status !== 0) {
      console.error(red("the e2e build failed:"), tail(b.stdout + b.stderr));
      return 1;
    }
  }

  const needsServer = plan.some(({ suite, skip }) => suite.server && !skip);
  if (needsServer) {
    if (!AS_JSON) console.log(dim("starting a server on a throwaway home …"));
    try {
      startServer();
      await waitForServer();
      if (!AS_JSON) console.log(dim(`  ${server.url}   home ${home}\n`));
    } catch (err) {
      // Not fatal: the suites that do not need it still run, and the ones
      // that do are recorded as skipped with this reason.
      const why = `the server would not start: ${err.message.split("\n")[0]}`;
      for (const row of plan) if (row.suite.server) row.skip = row.skip ?? why;
      stopServer();
    }
  }

  const results = [];
  for (const { suite, skip } of plan) {
    if (skip) {
      results.push({ name: suite.name, what: suite.what, status: "skip", detail: skip });
      if (!AS_JSON) console.log(`${yellow("skip")}  ${suite.name.padEnd(15)} ${dim(skip)}`);
      continue;
    }
    // A suite that needs the server checks it is still there, because the
    // ones before it can run for ten minutes and a dead server is not a bug
    // in whatever happened to be next. `smoke` reporting "nothing answered"
    // and twenty skips is what that looked like.
    if (suite.server && !(await serverAlive())) {
      if (!AS_JSON) console.log(dim(`      the server is gone; starting another …`));
      stopServer();
      try {
        startServer();
        await waitForServer();
      } catch (err) {
        const why = `the server would not start: ${err.message.split("\n")[0]}`;
        results.push({ name: suite.name, what: suite.what, status: "skip", detail: why });
        if (!AS_JSON) console.log(`${yellow("skip")}  ${suite.name.padEnd(15)} ${dim(why)}`);
        continue;
      }
    }
    if (!AS_JSON) process.stdout.write(`${dim("run ")}  ${suite.name.padEnd(15)}`);
    const r = runSuite(suite);
    results.push({ name: suite.name, what: suite.what, note: suite.note, ...r });
    if (!AS_JSON) {
      const mark = r.status === "pass" ? green("pass") : red("FAIL");
      process.stdout.write(`\r${mark}  ${suite.name.padEnd(15)} ${dim(`${(r.ms / 1000).toFixed(1)}s`)}\n`);
      if (r.status === "fail") {
        console.log(dim(`      ${suite.cmd.join(" ")}  (in ${suite.cwd})`));
        for (const line of tail(r.stdout + "\n" + r.stderr).split("\n"))
          console.log(`      ${line}`);
      }
    }
  }

  stopServer();

  const by = (s) => results.filter((r) => r.status === s);
  if (AS_JSON) {
    console.log(
      JSON.stringify(
        {
          pass: by("pass").length,
          fail: by("fail").length,
          skip: by("skip").length,
          results: results.map(({ name, what, status, detail, note, ms }) => ({
            name,
            what,
            status,
            detail,
            note,
            ms,
          })),
        },
        null,
        2,
      ),
    );
  } else {
    console.log(`\n${bold("summary")}`);
    for (const r of results) {
      const mark =
        r.status === "pass" ? green("pass") : r.status === "fail" ? red("FAIL") : yellow("skip");
      console.log(`  ${mark}  ${r.name.padEnd(15)} ${r.what}`);
      if (r.status === "skip") console.log(`        ${dim(`why: ${r.detail}`)}`);
      // A suite that passed while skipping something inside itself is the
      // subtlest way for a green build to be a lie, so it says so here too.
      if (r.status === "pass" && r.note) console.log(`        ${yellow(`note: ${r.note}`)}`);
    }
    const skipped = by("skip");
    console.log(
      `\n${by("pass").length} passed, ` +
        (by("fail").length ? red(`${by("fail").length} failed`) : "0 failed") +
        `, ${skipped.length} skipped`,
    );
    if (skipped.length)
      console.log(
        yellow(
          `\n${skipped.length} suite(s) did not run. This is not a green build — ` +
            `it is a partial one, and the reasons are above.`,
        ),
      );
  }

  return by("fail").length > 0 ? 1 : 0;
}

main().then(
  (code) => process.exit(code),
  (err) => {
    stopServer();
    console.error(red("the runner itself fell over:"), err);
    process.exit(2);
  },
);
