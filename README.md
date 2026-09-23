# CAUSEWAYBAY HACKER

**A 16-bit coding dojo. Take your craft back from Skynet.**

In Causeway Bay, a Rust coder wakes up and cannot write a `for` loop. The
vibe-coding was never a convenience — it was Skynet's long game, and it worked.
Every skill is still in there somewhere. You get them back one street at a time,
in Rust, in Go, in C++, in Python, in PyTorch and in TypeScript, and then you
go and fight the thing that took them — which, in PyTorch Land, you build a
small one of yourself.

Six lands — **RUST LAND**, **GO LAND**, **C++ LAND**, **PYTHON LAND**,
**PYTORCH LAND** and **TYPESCRIPT LAND**. Four roads through each:

| | |
| --- | --- |
| **VERY BASIC** | the quiz: types, containers, a thread, a mutex, a heap, a stack, a struct — the grammar a live coding test leans on, asked as a question first. Four lines, one right; pick it, then type it; untimed |
| **BASIC** | grammar activation, not a quiz: each node shows one construct — integer widths and a 32-byte value, floats, strings, slicing/copy/append of strings, arrays and bytes, a loop, a function, a struct, an enum, a vector, a linked list, an ordered map and a hash table, a set, a stack and a queue (each practised as add, remove, edit and sort), sorting and reversing, a closure, a lambda, a thread, a binary tree — with the exact line to type, in the brief and again as an `ANSWER:` comment at the hole; you type it, it compiles, the idiom is back in the fingers; untimed |
| **ADVANCED** | simple coding quizzes that use the basic grammar — ownership, slices, errors, traits/interfaces, pointers, iterators, generics — and then the lunch rush: threads, channels, mutexes, lifetimes, goroutines, `select`, async, RAII, generators |
| **HACKER** | the live interview: timed HackerRank-shaped quests, hidden tests, the same 34 problems in every land — TypeScript's included — except PyTorch Land, whose interview is the machine-learning one: write softmax so it does not overflow, write cross-entropy so it matches the library, write Adam so it matches the library, mask a padded batch, cache the keys and values, build a transformer block that agrees with a reference to 1e-5 |

Each road is a Super Mario World overworld. Clear a node, it is stamped
`CLEARED`, for good.

**The code is really compiled.** Rust goes through `rustc`/`cargo`, Go through
`go build`/`go test`, C++ through the system `c++` (clang or gcc, `-std=c++20`),
Python through `py_compile` and then `python3 -I`, TypeScript through a strict
`tsc` and then `node`, on your machine, against hidden tests. There is no
pretend-verdict — and no running a TypeScript program `tsc` has rejected.

**Your mistakes are the curriculum.** Every attempt is kept — the source, the
verdict, the compiler's own error codes. `E0382` five times in a week is not a
vague feeling, it is a row in a table, and **AI MODE** builds a drill from it:
repeat what you failed, attack the concept you keep missing, or come back to a
cleared quest on a spaced-repetition clock.

**You are your wallet.** A mnemonic or a private key, derived in your browser
on `m/44'/60'/0'/0/0` — the same address `CausewaybayWallet` shows you. The key
never leaves the tab; the server sees a signature. Pick any name you like, it
is decoration. Many players, one server.

**The Rust coder flies beside you.** On the playground and on every quest's
CODE page there is an AI agent — a small pixel coder on a flying keyboard,
borrowed from CausewaybayRaiden — that watches what you type, drops a tip now
and then, says what the construct under your caret is, finishes the line in
grey for TAB to take — **all of that with no key and no network**, off the
same grammar the editor colours your code with — and, when you press AGENT,
chats about the file, reviews it, or
writes the program itself: typed into the editor one character at a time at a
person's speed, then run, then fixed until the compiler is quiet. It speaks
OpenAI, Anthropic, Grok or OpenRouter with **your own API key, kept on your own
machine and sent to nobody but the provider**, or Ollama on your own computer
with no key at all; the server never calls a model. Every
scratchpad has its own chatroom — messages and generated pictures — kept in
the pad's folder and searchable by keyword and by meaning. It calls a model
only when you press something. **The desktop client has the same coder**, the
same five providers and the same room, over a streaming HTTP client in the key
library (LÖVE brings no TLS of its own). See `docs/agent.md`.

Everything lives in `~/.causewaybayhacker`: your code, your attempts, the
database, the build caches.

## Run

```bash
make dev        # server on :5390, frontend with hot reload
make start      # server on :5390, serving the built frontend, reachable from your devices
make remote     # the addresses a phone can use
make test       # everything
make help       # the rest
```

Needs **Rust, Go, a C++ compiler, Python 3, Anaconda, Node** — one per land,
and Node twice, because the browser client is built with it too. `make doctor`
says which of them it cannot find, and the server prints the same list on the
way up with the command that installs whatever is missing.

PyTorch Land is the odd one out, and worth a line of its own: its toolchain is
not a program on PATH but a **package inside an interpreter**, so a machine can
have a perfectly good `python3` and still not be able to run a single one of
its 122 nodes. It also cannot be a `pip install torch` into the system
interpreter — macOS's own python3 and any PEP 668 distribution refuse to
install into themselves, and the `--user` they suggest is the one place the
runner's isolated `python3 -I` will not look (SPEC §5.1). So PyTorch Land gets
an environment of its own:

```bash
conda create -n cwbhacker python=3.13 -y
conda run -n cwbhacker pip install torch numpy black
```

`make` finds that env by name and puts it first on PATH for everything it
starts — the server, `doctor`, the content gate — so there is nothing to
remember and nothing to activate. A venv at `~/.causewaybayhacker/venv` is
picked up the same way if you would rather not have conda, and
`GAME_PY_BIN=/path/to/bin` overrides both. Python 3.10+ (SPEC §5.1); `numpy`
is imported by no quest and installed anyway, because torch without it writes
a warning to stderr on every single run.

TypeScript Land needs `tsc` beside that Node, and usually nothing more:

```bash
npm install -g typescript prettier
```

— or not even that. The browser client already pins `tsc` and `prettier` in
`frontend/`, and once `npm ci` has run there, `make` appends
`frontend/node_modules/.bin` to PATH for everything it starts. *Appends*: a
global `tsc` still wins where there is one. The land compiles against its own
`node.d.ts` rather than `@types/node`, so there is no third version to keep in
step (SPEC §5.1).

The formatters are part of the same list: `rustfmt` and `gofmt` ship with their
toolchains, `clang-format` comes from Xcode or your package manager,
Python's and PyTorch's `black` is in the conda line above, and TypeScript's
`prettier` is in the npm one. A land whose formatter is missing simply has no
`fmt` button.

**From a phone, use port 5390 — not the dev server's 5291.** The page and the
websocket have to share an origin: the built bundle derives the socket from the
address it was loaded from, so it works from anywhere. The vite dev server is
pinned to `127.0.0.1`, which on a phone means the *phone's* own loopback, and
fails. `make start` builds `frontend/dist` if it is missing, so the
one-origin path is always the one on offer, and prints the addresses on the way
up. `make remote` prints them again.

> ⚠️ **This is a single-trusted-user trainer, not a sandbox.** It compiles and
> runs the code that is typed into it, on this machine, as you, with a timeout
> and an output cap and not much else. Since you asked to play it on your phone,
> it listens on every interface — so anything that can reach port 5390 can run
> code here. A tailnet is your own devices and that is the point. A café
> network, a hotel, a shared office VLAN is not: `make start LOCAL=1` pins it
> back to loopback, and `make start` and `make remote` both print exactly which
> addresses are live so you never have to guess. And do not paste in code you
> would not run in your own shell — the trainer will run it.
>
> What loopback does *not* protect against on its own is your browser: a
> page from any site can open a websocket to `127.0.0.1`. So the server checks
> the `Origin` of every socket (PROTOCOL §1.3) and only its own page, at
> whatever address you reached it on, gets in. The desktop and terminal clients
> send no `Origin` and are unaffected.

## Release

```bash
make package          # every release binary into dist/
make package-server   # the server tarball: cwbhacker + web client + content packs + cwbh
make package-gui      # the LÖVE client as a signed macOS .app, and a .love (macOS only)
make version          # the version, once all four manifests agree on it
```

The server tarball unpacks to a directory with `run.sh` in it, which starts
`cwbhacker` with its own web client and content beside it — nothing else is
needed on the machine. Both halves check themselves on the way out: the staged
server is started from outside the checkout and has to serve the page and
import every pack; the app bundle is started and has to find its own key
library.

CI (`.github/workflows/ci.yml`) runs the backend, CLI, frontend, LÖVE and
content suites on every push and pull request, and dry-runs the packaging.
Pushing a tag `vX.Y.Z` that matches `make version` runs the release workflow,
which builds the server for Linux (x86_64, aarch64) and macOS, signs and
notarises the app when the Apple secrets are set, and attaches everything to a
GitHub release with checksums.

## The parts

| | |
| --- | --- |
| [`SPEC.md`](SPEC.md) | the contract: storage, wire format, schema, runner, search |
| [`PLAN.md`](PLAN.md) | what gets built, in what order, by whom |
| [`backend/`](backend/) | Rust: axum, tokio, SQLite (FTS5 + vectors), the runner |
| [`frontend/`](frontend/) | TypeScript, Vite, three.js, the 16-bit engine |
| [`content/`](content/) | the quests, one directory per land, and `content/i18n/` for their translations |

Art and engine lineage: [`CausewaybayRaiden`](../CausewaybayRaiden) for the
sprite look and the chip audio, [`CausewaybayGolang`](../CausewaybayGolang) for
the trainer loop and the virtual canvas, [`CausewaybayWallet`](../CausewaybayWallet)
for the key derivation.
