# CAUSEWAYBAY HACKER

**A 16-bit coding dojo. Take your craft back from Skynet.**

In Causeway Bay, a Rust coder wakes up and cannot write a `for` loop. The
vibe-coding was never a convenience — it was Skynet's long game, and it worked.
Every skill is still in there somewhere. You get them back one street at a time,
in Rust and in Go, and then you go and fight the thing that took them.

Two lands — **RUST LAND** and **GO LAND**. Three roads through each:

| | |
| --- | --- |
| **BASIC** | the grammar: bindings, shadowing, slices, errors, structs, traits/interfaces |
| **ADVANCED** | threads, channels, mutexes, lifetimes, goroutines, `select`, async |
| **HACKER** | the live interview: timed HackerRank-shaped quests, hidden tests |

Each road is a Super Mario World overworld. Clear a node, it is stamped
`CLEARED`, for good.

**The code is really compiled.** Rust goes through `rustc`/`cargo`, Go through
`go build`/`go test`, on your machine, against hidden tests. There is no
pretend-verdict.

**Your mistakes are the curriculum.** Every attempt is kept — the source, the
verdict, the compiler's own error codes. `E0382` five times in a week is not a
vague feeling, it is a row in a table, and **AI MODE** builds a drill from it:
repeat what you failed, attack the concept you keep missing, or come back to a
cleared quest on a spaced-repetition clock.

**You are your wallet.** A mnemonic or a private key, derived in your browser
on `m/44'/60'/0'/0/0` — the same address `CausewaybayWallet` shows you. The key
never leaves the tab; the server sees a signature. Pick any name you like, it
is decoration. Many players, one server.

Everything lives in `~/.causewaybayhacker`: your code, your attempts, the
database, the build caches.

## Run

```bash
make dev        # server on :5390, frontend with hot reload
make test       # everything
make help       # the rest
```

Needs Rust, Go and Node. `make doctor` says which of them it cannot find.

> ⚠️ **This is a local, single-trusted-user trainer, not a sandbox.** It
> compiles and runs the code you type, on your machine, as you, with a timeout
> and an output cap and not much else. Do not expose the port to a network, and
> do not paste in code you would not run in your own shell.

## The parts

| | |
| --- | --- |
| [`SPEC.md`](SPEC.md) | the contract: storage, wire format, schema, runner, search |
| [`PLAN.md`](PLAN.md) | what gets built, in what order, by whom |
| [`backend/`](backend/) | Rust: axum, tokio, SQLite (FTS5 + vectors), the runner |
| [`frontend/`](frontend/) | TypeScript, Vite, three.js, the 16-bit engine |
| [`content/`](content/) | the quests |

Art and engine lineage: [`CausewaybayRaiden`](../CausewaybayRaiden) for the
sprite look and the chip audio, [`CausewaybayGolang`](../CausewaybayGolang) for
the trainer loop and the virtual canvas, [`CausewaybayWallet`](../CausewaybayWallet)
for the key derivation.
