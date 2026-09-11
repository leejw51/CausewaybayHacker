# smoke — the contract checker

The thing that says "BE and FE disagree" without needing a browser.

```bash
node tests/smoke/contract.mjs                      # against :5390
node tests/smoke/contract.mjs --only 8.6           # one §8 point
node tests/smoke/contract.mjs --only beyond        # the supplementary checks
node tests/smoke/contract.mjs --json               # machine-readable
node tests/smoke/contract.mjs --slow               # the real 70 s keepalive window
node tests/smoke/selftest.mjs                      # does the checker catch anything?
```

Exit `0` all green, `1` something failed, `2` it could not start — nothing
listening, or no signer. It says which, in one line, with the command that
fixes it.

## PROTOCOL.md §8, one case per point

§8 is a twelve-point conformance checklist and it is the shared definition of
"the client works" for three clients now: the browser, the LÖVE desktop
client, and this. So the twelve are the spine of the file — one named case
each, reported by number, with a `12/12` score line that nothing else is
allowed to obscure. Supplementary checks run afterwards under "beyond the
checklist" and are scored separately.

Several of the twelve are rules about the *client*. This checker is a client,
so it asserts them against itself: every frame it sends is kept and audited
(§8.1's envelope shape, §8.5's "no key material, ever" — it holds five
private keys and signs with them, so that assertion has something real to be
wrong about), and frames are injected through its own receive path to prove
it ignores an unknown event type (§8.3) and reassembles a chunk split
mid-line (§8.8). **A conformance suite that only ever audits the other side
is half a suite.**

## No dependencies, one exception

Node has had a global `WebSocket` since 22, so the checker itself needs
nothing from npm. The one thing it cannot do is produce a recoverable
secp256k1 signature over a nonce the server invented a moment ago — a fixture
cannot cover that, the nonce is fresh every time — so it shells out to
`CausewaybayWallet`'s `cwbwallet utils sign`, the same binary that generated
`tests/vectors/signatures.json`. `$CWBWALLET` overrides the path. Without it
the checker skips with an explanation rather than pretending.

Read-only checks use the accounts in `tests/vectors/addresses.json`; every
check that changes state derives its **own fresh account** (see "Running it
twice" below). Sharing an account across checks makes the suite
order-dependent, and an order-dependent contract checker is the thing you
stop trusting the first time it disagrees with itself.

## Does it catch anything?

`selftest.mjs` is the answer, and it is the most important file here.

It starts `mock-server.mjs` — a deliberately minimal, explicitly
non-authoritative PROTOCOL.md server — and requires two things:

1. a **correct** mock scores 12/12 and passes all 18 checks;
2. each of **19 injected faults** is caught by **the §8 point that owns that
   rule**, not merely by something failing somewhere.

**20/20 today**, with `ws` as its only dependency (needed for the mock; Node
has no websocket *server*).

The faults are bugs somebody actually ships:

| fault | the bug | caught by |
| --- | --- | --- |
| `extra-key-ok` | silently ignores an unknown top-level key | §8.1 |
| `correlation` | replies with a fresh id instead of echoing | §8.2 |
| `unknown-closes` | closes the connection on an unknown type | §8.3 |
| `error-code` | invents `not_authorized`, outside the closed set | §8.4 |
| `no-supported` | `proto_version` without `detail.supported` | §8.4 |
| `nonce-reuse` | accepts the same nonce twice | §8.4 |
| `trailing-newline` | ends the challenge message with a newline | §8.6 |
| `accepts-rebuilt` | accepts a signature over a reconstruction | §8.6 |
| `token-static` | rotates the token but leaves the old one alive | §8.7 |
| `seq-gap` | `run.log` seq skips a number | §8.8 |
| `seq-from-one` | `run.log` seq starts at 1 | §8.8 |
| `event-id` | gives a server-initiated event a correlation id | §8.8 |
| `no-busy` | queues a second submit instead of refusing it | §8.10 |
| `busy-per-user` | refuses the user's *second connection* as busy | §8.10 |
| `anon-leak` | serves `world.lands` before login | ANONYMOUS |
| `solution-leak` | sends `solution` on `quest.get` | §5 shapes |
| `trust-payload` | filters stats by an address in the payload | never trusted |
| `cross-user` | shows every user's attempts to everyone | isolation |
| `no-broadcast` | never tells the user's other connection | §4.19 |

This is the same idea as
`CausewaybayWallet/scripts/check-vector-coverage.py`: corrupt one thing and
require the suite to notice. A suite that stays green is not reading the
file, whatever its coverage report says.

## About the mock

**It is not a second implementation of the game and must never become one.**
It exists so the checker can be tested. Two things it deliberately does not
own:

* **keccak** — its EIP-55 spellings come from `addresses.json` first and
  `cwbwallet utils checksum` for anything else, never from a checksum it
  computed itself.
* **secp256k1** — recovery is `cwbwallet verify`.

A second, subtly different implementation of either, living in the test tree,
is exactly the drift SPEC §9.1 exists to prevent.

Its judging is a regex for `println!("…")`. That is enough to exercise the
*protocol*; it is not a runner and does not pretend to be one.

## Against the real server

It has run. `cargo run -p cwbhacker -- serve` on :5390:
**18 passed, 1 failed, §8 conformance 11/12.**

The one failure is real: an **absent `payload` is accepted as `{}`**, where
PROTOCOL.md §2 says a frame has exactly four keys and `payload` is "never
absent". Two softer divergences beside it — a rejected signature burns the
nonce and reports `auth_expired` rather than `auth_nonce_used`, and a second
`auth.login` on an authenticated connection is `bad_request` (correct, and
undocumented). All three are written up in `docs/decisions.md` and
`tests/PLAN.md`.

Everything else BE already does first time: the envelope, the closed error
set, `proto_version` with `detail.supported`, `locked` with
`detail.requires`, the four-line challenge byte-for-byte, `v` as both 27/28
and 0/1, token rotation with the old one dying, `run.log` seq from 0 with no
gaps, `busy` per connection, `progress.update` to the second window, and full
multi-user isolation.

### Running it twice

The server persists. Every state-changing check derives a **fresh account per
run** — index `1000 + random` off the published BIP-39 all-zero mnemonic — so
the checker does not need the database wiped between runs. A checker pinned to
five fixed addresses sees a different map every time and is only honest once.

## What this does not cover

* **The two-missed-ping rule.** `--slow --only 8.12` has been run against the
  real server: pass at 70.1 s, past §1.1's window, so the server does not
  drop a connection whose only traffic is keepalive. Proving it *does* drop a
  silent one needs a client that deliberately stops answering pongs, which is
  not written.
* **The runner.** SPEC §9.6's limits — timeout, output cap, fork bomb,
  `GOPROXY=off` — need a real runner. `tests/PLAN.md` §9.6 has the cases.
* **`search.query`, `ai.*`.** Milestone 2. There is a pending check that
  asserts they *declare* the gap — `not_found` with `detail: {"milestone":
  2}` — and that starts failing the day either ships, which is the signal to
  write the real one.
