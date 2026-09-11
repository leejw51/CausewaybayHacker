# Test plan

What is tested, by what, and what state it is actually in today —
**2026-09-11**, milestone 1.

The spine is SPEC §9, "Tests that are not optional", eight items. Each is
expanded below into concrete cases: what is set up, what is done, what is
asserted, which suite owns it, and its status. Then §9.9 onward: the things
§9 does not list that a player hits on their first evening.

Read the status column as literally as it is written. A test that is `red`
or `blocked` here is worth more than one that is quietly green because it
asserts nothing — which is the failure mode this file exists to prevent.

```
tests/
├── PLAN.md              this file
├── run-all.mjs          every suite, one command, an honest summary
├── vectors/             the shared fixtures (SPEC §9.1, §9.2, §9.7)
├── content/             the pack verifier and the packs it must refuse (§9.4, §9.5)
└── smoke/               the PROTOCOL.md §8 contract checker (§9.8 and most of §6)
e2e/                     playwright: the journey, both orientations
backend/runner/tests/limits.rs        SPEC §9.6, the rows nothing else covers
backend/server/tests/integration.rs   behaviour over time, over the wire
```

## One command

```bash
node tests/run-all.mjs          # everything
node tests/run-all.mjs --list   # what would run, and why anything would not
node tests/run-all.mjs --json   # machine-readable
```

It starts a server on a **throwaway home** (`--home <tmpdir>`, SPEC §1's
first precedence) serving `frontend/dist-e2e`, runs the suites that need one
against it, and stops it — including on `^C`. Nothing touches the
developer's own `~/.causewaybayhacker`, and every run starts from an empty
database, which is what makes "node 1 is open" true twice in a row.

Exit 0 only if every suite that ran passed. **A skip is never a pass**: the
summary names every skipped suite, the reason, and the command that would
make it runnable — and a suite that passed while skipping something *inside*
itself says so too (the LÖVE layout tests need a real window; §8.12's
keepalive check runs over 6 s rather than §1.1's 70 s unless `--slow`).

## Status at a glance

| suite | runs today | green | note |
| --- | --- | --- | --- | 
| `tests/vectors/` | yes | yes | 3 fixture files, all generated from real tools |
| `tests/vectors/mistakes/` | yes | 33/33 verified | 1 documented gap (go `unhandled-error`) |
| `backend` (`cargo test --workspace`) | yes | yes | 70 of BE's own + **13 of QA's** (7 runner limits, 6+1 integration) |
| `frontend` (`vitest`) | yes | yes | FE's own; QA does not write there |
| `love2d` (`make test-headless`) | yes | 136 cases, 827 assertions | reads QA's `addresses.json` and `signatures.json`; its layout suite needs a real window |
| `tests/content/verify_pack.py` | yes | **60/60 quests** | every solution passes, every starter rejected |
| `tests/smoke/selftest.mjs` | yes | 20/20 | proves the checker catches 19 injected faults |
| `tests/smoke/contract.mjs` | yes, against the real backend | **12/12** | BE fixed the §8.1 divergence |
| `e2e/` | yes | **6 of 9 green** | the three that submit are **red**: SUBMIT is a canvas button with no shortcut and a confirm dialogue, and the scan cannot press it |

Nothing above is green by assumption. `verify_pack.py` really compiled 60
quests; the mistake fixtures really ran `rustc` and `go`; the smoke checker
really caught 19 deliberately-broken servers and now scores 12/12 against
BE's real server; the browser suite really clicks through a real game against
a real backend and checks the answer **on the wire**.

### What the first real run found

`node tests/smoke/contract.mjs` against `cargo run -p cwbhacker -- serve`:
**18 passed, 1 failed, §8 conformance 11/12.** Three divergences, in
descending order of how much they matter:

1. **An absent `payload` is accepted as `{}`** — the one failure. PROTOCOL.md
   §2 says a frame "is an object with **exactly** these four keys" and that
   `payload` is "never absent. Use `{}`". A three-key frame is not a
   conformant frame, and §2's own justification for strictness ("a silently
   ignored field is how a client ships a bug that looks like it works")
   applies exactly as well to a silently defaulted one. BE is being generous.
   A payload that is present but bare (`7`) or an array is correctly refused.
   Raised in `docs/decisions.md`; PM's call whether §2 or the server moves.

2. **A rejected signature burns the nonce, and the retry says `auth_expired`.**
   SPEC §3.2 step 4 orders it recover → compare → check the nonce → burn, so
   a failed comparison should leave the challenge alive. Two separate
   things: the burn itself is arguably a hardening choice, but `auth_expired`
   is the wrong code for it — §3.3 defines that as "the challenge's
   `expires_at` passed", which is false. `auth_nonce_used` says what
   happened. Benign in effect (the client's prescribed reaction to both is
   "start `auth.challenge` again") and misleading in a log.

3. **A second `auth.login` on an authenticated connection is `bad_request`,**
   with the message "this connection is already authenticated; open a new one
   to change user". That is **correct and desirable** — it is §3.1's "a
   connection never goes back to ANONYMOUS", enforced — and it is not written
   down anywhere. It was also a bug in this checker, which used to reuse one
   connection for several login attempts; every login attempt now gets its
   own.

Everything else the checker asserts, BE already does: the envelope, the
closed error set, `proto_version` with `detail.supported`, `locked` with
`detail.requires`, the four-line challenge, `v` as 27/28 *and* 0/1, token
rotation with the old token dying, `run.log` seq from 0 with no gaps, stages
strictly ordered and each sent once, `busy` per connection and not per user,
`progress.update` reaching the same user's second window, and full multi-user
isolation including a spoofed payload address.

---

## SPEC §9.1 — Address conformance

> A table of mnemonics → addresses, generated from `CausewaybayWallet`'s own
> output, asserted in the frontend's unit tests. If this fails, users lose
> their accounts.

**Fixture:** `tests/vectors/addresses.json` — **done, real**. Three
well-known mnemonics × up to five indices on `m/44'/60'/0'/0/i`, generated by
`cwbwallet 1.0.4 utils derive`, and cross-checked row by row against
`CausewaybayWallet/testvectors/derivation.json`, which came from
`eth-account`. Ten rows have two independent sources agreeing. Regenerate
with `python3 tests/vectors/generate.py`; `--check` fails if it drifts.

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.1.a | derivation matches the wallet | load the fixture → derive each row with `@scure/bip39` + `@scure/bip32` + `@noble/curves` → `address` equals the fixture's EIP-55 string, character for character | **FE vitest** | **not written — FE owns `frontend/**`** |
| 9.1.b | the same, in the LÖVE client | load the fixture → derive through the Rust cdylib → same | **L2D** | not written — L2D owns `love2d/**` |
| 9.1.c | the same, server-side | load the fixture → derive/checksum in `backend/core` → same | **BE** | not written — BE owns `backend/**` |
| 9.1.d | lowercase is the key, EIP-55 is the display | for each row, `address_lower` is `address.toLowerCase()` and 42 chars | any | fixture carries both, so it is one line wherever it lands |
| 9.1.e | two spellings are one player | log in as `0xAbC…` then as `0xabc…` → one `users` row, one directory | **BE** | not written |
| 9.1.f | the fixture has not drifted | `python3 tests/vectors/generate.py --check` | **CI** | **green today** |

**Blunt note.** QA cannot write 9.1.a–c. SPEC §11 gives QA `backend/*/tests/**`,
but the working instruction for this milestone is that QA does not write under
`backend/` or `frontend/` at all. So the deliverable here is the fixture plus
this row of the plan, and the assertion is owed by three other agents. Raised
in `docs/decisions.md`.

## SPEC §9.2 — Signature round trip

> A known private key signs the exact §3.2 message; the Rust verifier recovers
> the exact address. Run in both `backend` and `frontend` suites against the
> same fixture vector in `tests/vectors/`.

**Fixture:** `tests/vectors/signatures.json` — **done, real**. Two signers,
the exact PROTOCOL.md §4.2 message with a frozen nonce and expiry, the
EIP-191 digest, the 65-byte `r||s||v`, both `v` spellings, and four
signatures that must be **rejected**. Generated three ways through
`cwbwallet 1.0.4` — sign, hash, recover — and the digest assembly was itself
checked against the wallet's published `eip191.json`, which came from
`eth-account`: all four of its vectors reproduce byte for byte, empty string
and non-ASCII included.

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.2.a | the digest is the digest | fixture `message_hex` + `message_len` → keccak256(prefix ‖ len ‖ msg) → equals `eip191_digest` | BE, FE, L2D | not written |
| 9.2.b | signing reproduces the fixture | `private_key` + `message` → 65-byte signature equals `signature` | FE, L2D | not written |
| 9.2.c | recovery reproduces the address | `message` + `signature` → recovered address equals `address` | **BE** | not written |
| 9.2.d | `v` is understood both ways | feed `v = 27/28` and `v = 0/1` → both recover the same address | **BE** | not written |
| 9.2.e | each `must_reject` entry fails | four bad signatures → `auth_bad_signature`, never a panic | **BE** | not written |
| 9.2.f | the message is signed, not rebuilt | server's `message` + a trailing `\n` → refused | **smoke §8.6** | **written, green vs the mock** |
| 9.2.g | the message's exact four lines | the server's own challenge → four lines, EIP-55 address, 64 lowercase hex nonce, RFC3339 expiry 120 s out | **smoke §8.6** | **written, green vs the mock** |

**The one that will bite.** `v` in the fixture is 27/28, the Ethereum
convention. `k256::ecdsa::RecoveryId` is 0/1. A verifier that passes 27
straight through fails *every* login. Both spellings are in every vector for
exactly this reason, and PROTOCOL.md §4.3 requires both to be accepted.

## SPEC §9.3 — FTS5 present

> A startup assertion, not a hope.

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.3.a | the bundled SQLite has FTS5 | open the store → `CREATE VIRTUAL TABLE … USING fts5` in a temp DB → succeeds, and the server refuses to start if it does not | **BE** | not written — inside `backend/`, QA cannot reach it |
| 9.3.b | it is the *bundled* one | `select sqlite_version()` at startup, logged → matches the amalgamation `rusqlite` vendored, not the host's 3.51.2 | **BE** | not written |
| 9.3.c | the failure is legible | force the feature off → the startup error names FTS5 and the cargo feature, not "no such module" | **BE** | not written |

**Untestable from here, as written.** §9.3 is a startup assertion in a process
QA does not own. The honest QA-side version is 9.3.d below, and it is weak.

| 9.3.d | search works at all | `search.query` with a word from a quest title → at least one hit, `bm25` non-null | **smoke** | **not written** — `search.query` is milestone 2 (PLAN.md); the smoke checker asserts only that it is `unauthorized` before login |

## SPEC §9.4 — Every reference solution is accepted

> The whole content pack goes through the real runner in CI. A quest whose own
> answer fails is a broken quest, and there is no other way to find out.

**Owner:** `tests/content/verify_pack.py`. Written by PM, lifted into `tests/`
so there is one implementation rather than two; its absolute paths were made
relative and its scratch moved under `$CAUSEWAYBAY_HACKER_HOME/build` (or the
system temp dir), honouring SPEC §1.

```bash
python3 tests/content/verify_pack.py content/rust/*.toml content/go/*.toml
```

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.4.a | every solution compiles | each quest's `solution` → SPEC §5.1's exact command → exit 0 | content CI | **green: 60/60** |
| 9.4.b | every solution passes every case | run it against all cases under the declared `match` | content CI | **green: 60/60** |
| 9.4.c | the structural rules hold | id shape, node contiguity, requires chain, map layout, visible case, concept vocabulary | content CI | **green, 6/6 packs** |
| 9.4.d | no expectation is empty after `match` | normalise each `expect` → non-empty | content CI | **green** |
| 9.4.e | hacker ⇔ `time_limit_s` ⇔ a hidden case | both directions | content CI | **green** |
| 9.4.f | a broken pack is refused | `tests/content/invalid-packs/solution-fails.toml` → non-zero exit | content CI | fixture written; **needs the importer to run it against** |
| 9.4.g | it runs in CI, not just here | a make target and a workflow | — | **not wired** — `make test` does not call it yet, and the Makefile is not QA's |

Running time is about 65 seconds for all six packs on this machine, cold.
Worth its own target rather than a `make test` tax on every run.

## SPEC §9.5 — Every starter is *not* accepted

> Otherwise the map clears itself.

Same tool, same run. **Green: all 60 starters rejected.** The verdicts are
worth reading: 53 are `wrong_answer`, and **six are `compile_error`** — those
six are real teaching material and now feed §9.7 (below).

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.5.a | no starter is accepted | each `starter` → the runner → not (`accepted` and all cases passed) | content CI | **green: 60/60** |
| 9.5.b | a freebie pack is refused | `invalid-packs/starter-accepted.toml` (starter ≡ solution) → refused | content CI | fixture written; needs the importer |
| 9.5.c | an empty expectation cannot be gamed | `invalid-packs/empty-expect.toml` → refused | content CI | fixture written |

## SPEC §9.6 — Runner limits

> Infinite loop → `timeout`. Huge output → `output_limit`. Fork bomb →
> killed, server alive. `GOPROXY=off` → a quest that tries to fetch fails
> cleanly.

**No longer blocked.** The runner exists, BE covered three of the nine rows
in `backend/runner/tests/rust_runner.rs`, and QA wrote the rest into
`backend/runner/tests/limits.rs` and `backend/server/tests/integration.rs`.

The point of this table is that **no row is counted twice**: each names the
one test that owns it.

| # | case | owner | status |
| --- | --- | --- | --- |
| 9.6.a | infinite loop → `timeout` | **BE** `rust_runner.rs::an_infinite_loop_times_out_and_does_not_hang_the_runner` | green |
| 9.6.b | huge output → `output_limit` | **BE** `rust_runner.rs::too_much_output_is_an_output_limit_not_a_full_disk` | green |
| 9.6.c (half) | a child dies with the process group | **BE** `rust_runner.rs::a_child_that_outlives_the_parent_dies_with_the_process_group` | green |
| 9.6.c (half) | **and the runner is still alive afterwards** | **QA** `limits.rs::the_runner_still_works_after_every_limit_has_fired` | green |
| 9.6.d | `GOPROXY=off` | — | **not writable, and not faked** |
| 9.6.e | `RLIMIT_AS` 1 GiB | **QA** `limits.rs::a_program_that_wants_more_memory_than_the_limit_dies_rather_than_the_host` | green |
| 9.6.f | `RLIMIT_FSIZE` 64 MiB | **QA** `limits.rs::a_program_that_writes_a_huge_file_is_stopped_by_the_file_size_limit` | green |
| 9.6.g | nothing outside the home | **QA** three tests, see below | green, with a correction |
| 9.6.h | a timeout is still recorded | **QA** `limits.rs::a_timeout_is_a_verdict_and_not_a_lost_attempt` (runner) + `integration.rs::a_submission_that_times_out_is_still_recorded` (server) | green |
| 9.6.i | the server survives all of it | **QA** `limits.rs::the_runner_still_works_after_every_limit_has_fired` | green |

### 9.6.d cannot be written, and will not be faked

It wants `GOPROXY=off` to make a Go quest that fetches the internet fail
cleanly. There is no Go runner in this build —
`cwbhacker_runner::unsupported("go", …)` returns a reason instead of a
judgement, and a Go submission comes back `unavailable` with
`detail.milestone: 2`. A test pointed at it today would pass **because Go is
unsupported**, not because the proxy was off. That is a test that goes green
for the wrong reason, which is worse than no test.

### 9.6.g was written wrong first, and the correction is the finding

The obvious test — "a submission cannot write outside the home" — **fails**,
and it should. SPEC §5.3 says so in as many words: *"This is not a sandbox.
Causewaybay Hacker compiles and runs code you typed, on your machine, as
you."* A submission using an absolute path or `..` reaches anywhere the
person running the server can reach. That was confirmed, not assumed: the
first version of this test wrote to a sibling directory and succeeded.

SPEC §1's flat sentence — *"**Nothing outside the home is written.** No
`/tmp`, no project directory"* — reads as a containment promise and is not
one. It describes **the runner**, not the code the runner runs. So the row is
three tests, each asserting something true:

* `the_runner_itself_writes_only_under_the_home_it_was_given` — the runner's
  own footprint. Catches a `CARGO_HOME` left unset, which would warm the
  *developer's* `~/.cargo` and make one machine's run differ from another's
  invisibly.
* `a_submission_runs_in_a_stripped_environment_pointed_at_the_build_dir` —
  SPEC §5.3's environment. This is the half that **is** enforceable without a
  sandbox: ordinary code doing ordinary things lands somewhere harmless, and
  whatever secrets the shell that started the server was carrying are not
  readable by every submission.
* `it_is_not_a_sandbox_and_this_test_says_so_out_loud` — asserts the *weak*
  thing on purpose, and fails loudly the day somebody adds a real sandbox,
  with instructions to rewrite it into the assertion everyone would prefer.
  A test claiming containment that does not exist would be the most dangerous
  file in the repository.

Raised in `docs/decisions.md`.

## SPEC §9.7 — Mistake classification

> Fixture sources → expected `kind`, one per row of the §7.1 table.

**Fixture:** `tests/vectors/mistakes/` — **done, real, 33 cases, 0
unverified.** Every `code` was read off `rustc 1.97.1 --error-format=json` or
`go1.27.1 build` on this machine, and the genuine compiler output is captured
beside each source so BE's classifier can be unit-tested **with no toolchain
installed**.

* **27 synthetic** sources, one or more per taxonomy row.
* **6 real starters** from the shipped content, compiled from `content/**`
  rather than copied (a copy would drift). These are the exact bytes a
  player's editor opens with, so they are the classifier's first real input.

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.7.a | each source produces its kind | fixture source → classifier → `kind` and `code` from `expected.json` | **BE** | fixture ready, assertion not written |
| 9.7.b | the classifier reads captured output | `rust/*.rustc.json` (no compiler running) → same answer | **BE** | fixture ready |
| 9.7.c | warnings are read, not only errors | `rust/unused.rs` **compiles and runs**; the diagnostic is a *warning* | **BE** | fixture ready — a classifier reading only the error stream fails this |
| 9.7.d | runtime panics are classified | `index-range`, `nil-deref`, `deadlock` → from the program's stderr, not the compiler's | **BE** | fixture ready |
| 9.7.e | an unknown code is kept, not dropped | `rust/other-unmatched.rs` (E0384) → `kind: "other"`, `code: "E0384"` | **BE** | fixture ready |
| 9.7.f | E0277 is disambiguated | `missing-trait.rs` and `unhandled-error.rs` are **the same code** → different kinds | **BE** | fixture ready; the code alone cannot decide |
| 9.7.g | the fixture has not drifted | `python3 tests/vectors/mistakes/generate.py --check` | **CI** | **green today** |
| 9.7.h | the rollup follows §7.2 | two attempts, one kind → `count` 2, `cleared_since` 0; a clean attempt after → `cleared_since` 1 | **BE** | not written |
| 9.7.i | `cleared_since ≥ 5` drops out of the plan | five clean attempts → the kind leaves the AI priority list without being deleted | **BE** | not written (milestone 2) |

### Coverage, honestly

15 of 17 taxonomy kinds have a verified fixture. The three that do not:

* **`unhandled-error` (go) — no fixture.** SPEC §7.1 maps it to "`err`
  assigned and not checked (vet)". Plain `go vet` says nothing about a
  discarded error; that is `errcheck`, a separate tool that is not part of the
  Go distribution. The captured `go vet` output — exit 0, empty — is kept as
  the evidence. Either BE vendors `errcheck` or the row loses its Go half.
* **`wrong-answer` — N/A here.** A verdict, not a compiler identity. §9.6's
  territory.
* **`timeout` — N/A here.** Also a verdict. §9.6.a.

And two findings BE should read before writing the classifier:

* **`rust:E0277` maps to two kinds.** Both fixtures are present so the
  disambiguation has something to be tested against.
* **`E0373` is in no row of §7.1** — and it is the code a *shipped quest's own
  starter* (`rust.advanced.02.move`) produces. Filed under `other` on day one,
  which is legal but a poor first impression. Proposed to PM.
* **`data-race` is a sampling detector.** `go run -race` caught it 3 of 3 runs
  here and `race_detected_runs` records that, but the detector reports what it
  observed. Advisory in CI, never a gate.

### A note on running it twice

The server persists. `~/.causewaybayhacker/hacker.db` remembers that an
address cleared node 1 on the last run, so a checker pinned to five fixed
fixture addresses sees a different map every time and is only honest against
a wiped database.

So every state-changing check derives a **fresh account per run**: index
`1000 + random` off the same published BIP-39 all-zero mnemonic. Still a
published phrase, still holds nothing, and nobody browses index 1000+. That
is the difference between a checker you can run twice and one that needs the
database deleted first.

## SPEC §9.8 — Multi-user isolation

> Two sessions, two addresses, interleaved submissions: neither sees the
> other's progress, attempts or mistakes.

**Owner:** `tests/smoke/contract.mjs`, "beyond: two users never see each
other's progress or attempts". **Written, and green against the real
server** — two fresh addresses, overlapping submissions, and neither side's
history, mistakes, progress or summary crosses.

| # | case | setup → action → assertion | suite | status |
| --- | --- | --- | --- | --- |
| 9.8.a | interleaved submissions | two sessions, `Promise.all` of one right and one wrong submit → different attempt ids, different verdicts | **smoke** | **written** |
| 9.8.b | history does not cross | each `stats.history` → own attempt present, the other's absent, **both directions** | **smoke** | **written** |
| 9.8.c | progress does not cross | alice clears → alice's node `cleared`, bob's not | **smoke** | **written** |
| 9.8.d | mistakes do not cross | bob's wrong answer → a row in bob's `stats.mistakes` and not alice's | **smoke** | **written** |
| 9.8.e | summaries do not cross | `stats.summary.cleared` differs | **smoke** | **written** |
| 9.8.f | a payload address is ignored | bob sends `{address: alice}` → identical answer to `{}` (SPEC §3.5) | **smoke** | **green vs the real server** |
| 9.8.g | on-disk isolation | `users/<address>/attempts/` — alice's directory holds only alice's | **BE** | not written — the filesystem is not reachable over the wire |
| 9.8.h | a second connection is the same user | the same wallet twice → one identity, and `progress.update` reaches both | **smoke** | **written** (PROTOCOL.md §4.19) |

---

# Beyond SPEC §9

## PROTOCOL.md §8 — the twelve-point conformance checklist

`PROTOCOL.md` landed after SPEC §9 was written and is now the authority for
the wire. Its §8 is the shared definition of "the client works" for three
clients — the browser, the LÖVE desktop client, and this checker — so it is
the spine of `tests/smoke/contract.mjs`: one named case per point, reported
by number.

```bash
node tests/smoke/contract.mjs            # against :5390
node tests/smoke/contract.mjs --only 8.6 # one point
node tests/smoke/selftest.mjs            # prove the checker catches things
```

| point | the rule | what the case actually does | status |
| --- | --- | --- | --- |
| §8.1 | exactly `v`/`id`/`type`/`payload` | sends a frame with an extra key → `bad_request`; payload absent, bare and array → `bad_request`; then audits its own frames | **RED vs the real server** — absent payload accepted as `{}` |
| §8.2 | match by `id`, tolerate out-of-order | a slow `quest.submit` and a `ping` in flight together → the ping comes back first, both correlated; a reused in-flight `id` → `bad_request` | **green vs the real server** |
| §8.3 | ignore an unknown `type` | an unknown type on an **authenticated** connection → an error from the closed set, socket alive; then injects an unknown event into its own receive path and requires it to be dropped, not thrown | **green vs the real server** |
| §8.4 | handle every `code` | provokes 8 of the 11 codes and asserts `proto_version` carries `detail.supported` and `locked` carries `detail.requires` | **green vs the real server** |
| §8.5 | never send key material | audits **every frame every connection sent** for the five private keys and three mnemonics it holds, and for the field names | **green vs the real server** |
| §8.6 | sign byte-for-byte | a signature over `message + "\n"` → `auth_bad_signature`; over `message` → ok; `v` as 0/1 → also ok | **green vs the real server** |
| §8.7 | store the returned token | resumes, uses the returned token, and requires the rotated-away one to be **dead** | **green vs the real server** |
| §8.8 | buffer `run.log`, notice a `seq` gap | asserts `seq` starts at 0 per stream with no gaps, stages strictly ordered and each sent once, and reassembles a chunk split mid-line | **green vs the real server** |
| §8.9 | reconnect with backoff, resume, refetch | drops the socket, checks §6.2's schedule as code, resumes with the token, refetches the map | **green vs the real server** |
| §8.10 | no second submit in flight | second on one connection → `busy`; second **connection** of the same user → **not** busy (§3.2 is per connection) | **green vs the real server** |
| §8.11 | survive `server.bye`, and a close without one | an abrupt close drains the pending map; an injected `server.bye` is a known event with a valid `reason` | **green vs the real server** |
| §8.12 | keepalive | an idle connection survives, sending §1.1's application-level `ping`. 6 s by default, 70 s with `--slow` | **green vs mock, weak** |

**§8.12 was the weakest of the twelve, and has now been run properly.**
`--slow --only 8.12` against the real server: **pass, 70.1 s**, which is past
§1.1's two-missed-ping window. Node answers websocket pongs itself, so what
that proves is that the server does not drop a connection whose only traffic
is keepalive — including the application-level `ping` that §1.1 requires of a
client whose library cannot pong, which is the LÖVE client's case. It still
does not prove the server *enforces* the two-missed-ping rule, which needs a
client that deliberately stops answering; that one is not written.

### Does the checker catch anything?

`tests/smoke/selftest.mjs` starts `mock-server.mjs` — a minimal, deliberately
non-authoritative PROTOCOL.md server — and requires:

1. a **correct** mock to score 12/12 and pass all 18 checks, then
2. each of **19 injected faults** to be caught by **the §8 point that owns
   that rule**, not merely to fail somewhere.

**20/20 today.** The faults are real bugs: silently ignoring an extra key,
replying with a fresh id, closing on an unknown type, inventing an error
code, `proto_version` without `detail.supported`, a reusable nonce, a
trailing newline in the challenge, accepting a rebuilt message, a token that
rotates but stays alive, a `seq` gap, `seq` from 1, an event with a
correlation id, no `busy`, `busy` keyed per user instead of per connection,
`world.lands` before login, a leaked `solution`, a payload address that is
honoured, cross-user history, and a `progress.update` that never reaches the
second window.

This is the same idea as `CausewaybayWallet/scripts/check-vector-coverage.py`:
corrupt one thing and require the suite to notice. A suite that stays green is
not reading the file, whatever it claims.

The mock recovers signatures with `cwbwallet verify` and takes its EIP-55
spellings from `addresses.json` rather than owning a keccak, because a second
implementation of that in the test tree is the drift §9.1 exists to prevent.

## The end-to-end journey — `e2e/`

**Off the ground, and currently 6 of 9 green.** It ran 18/18 earlier today;
three tests went red when `quest.run` landed, and the cause is understood.

### The three that are red, and exactly why

`a wrong answer…`, `the right answer…` and `logout, then a second wallet…`
all need to press **SUBMIT**, and SUBMIT can no longer be pressed by this
suite:

* `Ctrl/Cmd+Enter` used to submit. §4.9b gave that key to **RUN**, on
  purpose — *"Submitting is a decision and it is made with a button, not with
  the shortcut somebody's hands press without looking"*
  (`frontend/src/scenes/quest.ts`). A run stays on the quest screen, so the
  suite waited three minutes for a result screen that was never coming.
* SUBMIT is therefore a **canvas-drawn button with no keyboard binding**, and
  it raises a **confirmation dialogue** before anything happens. A geometric
  scan over the whole bottom half of the plate, clicking and answering Enter,
  does not reach the result screen.

This is the third time a canvas-only control has cost a full run — the
category rows twice, the submit button now. **The fix is not more scanning.**
It is the hit-test hook already requested in `docs/decisions.md`: even
`__cwbCapture.buttons()` returning `{id, rect}[]` would delete all of it and
the whole class of failures with it. Until then these three stay red, and
they are red for a reason that is written down rather than a mystery.

The six that pass are not trivial: boot, the address conformance, **the seed
never crossing the wire**, the playable map, the canvas filling both
orientations with matching layers, and the mid-session orientation flips.

```
login → train → logout → login as a second wallet
→ that wallet's own progress, and nothing of the first's
```

### The hook that landed was the other half, and it was the better half

QA asked FE for a *driving* API — `view()`, `login()`, `setSource()`,
`submit()`. What landed was `frontend/src/dev/capture.ts`: a
**freeze-and-capture** hook built for screenshots, giving `scene()` (the six
screen names, exactly), `settle()`, `step()`, `freeze()`, `orient()` and
`png()`.

That turned out to be the half worth having. `settle()` runs the game at a
fixed 1/60 step until every transition finishes — so a canvas game becomes
**deterministic**, which is the thing a browser test genuinely cannot do for
itself. The driving half was not needed: the seed field is a real
`<textarea class="cwb-field">`, the editor is CodeMirror with real DOM lines,
and every screen is reachable by keyboard or a click.

So the suite **drives the game the way a person does, and verifies on the
wire** — a second websocket session, opened as the same wallet, asks the
server what it actually believes. That is a stronger assertion than any view
model FE could have exposed: a frontend that draws CLEARED over a server that
never heard about it fails here and passes every unit test on both sides.

### Two things that cost real time, written down so nobody pays twice

* **`settle()` freezes the loop.** Reading the scene with it and then
  carrying on leaves the app frozen for ever, so the `quest.get` reply is
  never drawn and the editor stays `hidden` — which surfaces thirty seconds
  later as a locator timeout on `.cm-content`. `scene()` settles, reads, then
  `resume()`s. The one test that wants a still frame settles without
  resuming, on purpose.
* **Category selection is pointer-only and canvas-drawn.** `lands.key()`
  handles the land toggle and nothing else, so there is no selector and no
  key. `pickFirstCategory` scans down the right-hand panel. It originally
  started at 28% of the canvas height, which is *inside the ADVANCED row* —
  so the browser silently trained on `rust.advanced.01.threads` while the
  test asserted against `rust.basic.01.first-light`, and the symptom was
  "expected cleared, got open" on a quest the UI never opened. The rows begin
  at ≈18%, measured. There is now an assertion that names this failure when
  it recurs.

### The tests

| test | asserts | verified by |
| --- | --- | --- |
| boots to login | the seed field is there and empty | DOM |
| a seed logs in | the address is the one `CausewaybayWallet` derives (SPEC §9.1) | fixture + wire |
| **the seed never crosses the wire** | every sent frame and `localStorage` scanned for the key, the phrase, and the field names; the field is emptied on submit | websocket frames |
| RUST × BASIC | node 1 open, the rest locked | wire |
| a wrong answer | recorded, node stays open, 0 stars | wire |
| the right answer | cleared, **3 stars**, and still cleared after a reload without re-asking for the seed | wire |
| **logout → second wallet** | the first wallet's address is gone from storage, the second's map is untouched, the second's history is empty, the first's is intact, and a reload does not resume as the first | wire, both wallets |
| the screen fills the viewport | canvas ≥ 90% of each axis, **and the WebGL layer and the pixel layer are the same size** (the bug that shows up as parallax sliding out from under the art); PNG attached for a human | capture hook |
| both orientations | flipping mid-session three times keeps the screen, the virtual size follows, and the game still works afterwards | capture hook |

Every account is **freshly derived per test** (index 2,000,000+ off the
published BIP-39 all-zero mnemonic), because the server persists and this
suite runs twice per invocation against one database.

## Content CI — `tests/content/`

| what | command | status |
| --- | --- | --- |
| every solution and starter, six packs | `python3 tests/content/verify_pack.py content/rust/*.toml content/go/*.toml` | **green, 60/60, ~65 s cold** |
| packs the importer must refuse | `tests/content/invalid-packs/` — 9 fixtures + `expected.json` | written; **needs the importer** |

The invalid packs all parse as valid TOML on purpose. A fixture that is merely
malformed tests the TOML parser and nothing else.

One of them, `basic-escapes.toml`, is worth singling out: it uses `"""` for
`starter` instead of SPEC §12's `'''`, and the damage is demonstrable —
`tomllib` turns the two characters written `\n` inside the quest's own comment
into a real newline before the compiler ever sees them. The quest is *about*
printing a literal backslash-n, so the corruption destroys the lesson silently.
**A TOML parser cannot report which quote style a string used**, so an importer
has to scan the raw bytes for `starter =`/`solution =` followed by `"""`.

---

# Integration — behaviour over time

`tests/smoke/contract.mjs` proves the *protocol*. `ws_flow.rs` proves the
slice runs once. Neither can show what happens across several submissions,
several sessions and a restart — and that is where the rules a player
actually feels live.

**Audited first, written second.** BE already had most of the coordinator's
list, and the names overstate what some of them assert, so each row below
says what was already there and what was genuinely missing.

`backend/server/tests/integration.rs`, 7 tests, all green:

| what | already covered | what was missing, and is now written |
| --- | --- | --- |
| **the star cascade** (SPEC §6.3) | `store.rs::stars_follow_the_spec_and_never_regress` asserts `stars_for(failures, hints)` as a **function** and `record_clear` as a **store call** | the arithmetic driven through a real compiler: 3 for a clean clear, **2 for exactly two failures** (the ≤2 boundary, where an off-by-one in either direction lives), 1 for three. Plus: a re-clear reports `cleared: false` and does not restamp — neither downward *nor upward*, which would let a player farm three stars by resubmitting the answer they were shown — and `stats.summary.stars` agrees with the map |
| **a hint costs a star** | `stars_for(9, 2) == 2` in `store.rs`; `ws_flow.rs` takes a hint and reads its text | nothing connected `quest.hint` to the stamp. Now: a hint on an *otherwise perfect* clear yields 2, re-reading hint 0 does not charge twice, the count survives, and an index past the end is `not_found` rather than a blank box |
| **a restart** | `store.rs::a_clear_survives_a_restart_and_a_reimport`, at the store level | the server really torn down (graceful shutdown, joined) and brought back on the same home: the map still says cleared with the same stars, the unlock survives, **both** attempts are still on record, the mistake is still there, and `auth.resume` works across the process boundary so the player is not asked for their seed every time the server restarts |
| **the unlock cascade** | `store.rs::locked_nodes_open_as_their_requirements_clear` | the **event**: `progress.update.unlocked` names node 2 and *only* node 2, and the map fetched afterwards agrees with the event the server just sent — two different code paths that a client trusts equally. Plus `locked` carrying `detail.requires` |
| **two users, one quest** | `store.rs::two_users_do_not_leak_into_each_other` (queries); `contract.mjs` (over the wire, sequential) | genuine **concurrency** — both submissions in the compiler at once via `tokio::join!`, which is where a shared workdir or a binary cached by quest rather than by attempt would show up. And the half the wire cannot see: `users/<address>/attempts/<id>/` on disk, neither directory holding the other's work |
| **§9.6.h** | — | a timeout and a compile error both reach `stats.history`, and the compile error carries a classified mistake (PROTOCOL.md §4.9: "always recorded. That is the curriculum") |
| **the address spelling** | — | `auth.login`, `auth.resume` in-process, `profile.update` and `auth.resume` **after a restart** all spell the address the same way. The last one is the interesting case: that is when the server stops having the string the client sent and must read it back out of `users`, whose primary key is the *lowercase* form (SPEC §3.4). It passes — the server is right |

**Not repeated here** because they are already covered and duplicating them
would mean two tests to update and two places to be wrong:
`a_clear_reaches_the_users_other_window` (protocol.rs), the store-level
cascade and isolation (store.rs), the first-clear slice (ws_flow.rs).

### One thing this round proved about the tests themselves

The restart test failed on its first run with *"the resumed session is the
same player: expected `0x9d8A62…`, got `0x9d8a62…`"* — which looks exactly
like a server bug and is not one. The helper returned the address it had
**claimed** (`eth::address_from_pubkey`, the lowercase storage form) rather
than the one the server **echoed** (EIP-55, per PROTOCOL.md §2.4). The test
was asserting its own helper. It now returns the server's spelling, and the
reason is a comment on the function.

# What §9 does not list, and should

Each of these is a thing a player hits on a first evening, and none of them is
in SPEC §9's eight.

| # | case | what it asserts | suite | status |
| --- | --- | --- | --- | --- |
| X.1 | **reconnect resumes the session** | a socket dies under an open page → `auth.resume` restores it, same address, same quest, no mnemonic prompt | e2e + smoke §8.9 | **written, both** |
| X.2 | **`quest.submit` while one is in flight** | `busy`, the first still finishes, and `busy` is **per connection** not per user | smoke §8.10 + e2e | **written, both** |
| X.3 | **an unknown `v` does not kill the connection** | `proto_version` with `detail.supported`, socket alive, next request works | smoke §8.4 + e2e | **written, both** |
| X.4 | **both orientations, every screen** | two Playwright projects over the whole journey; the canvas fills ≥90% of each viewport | e2e | **written, skipping** |
| X.5 | **locked → open → cleared** | node 1 open and the rest locked at the start; clearing 1 unlocks 2; a cleared node never goes back | e2e + smoke | **written** |
| X.6 | **a reload loses nothing** | clear → reload → still cleared, still logged in | e2e | **written, skipping** |
| X.7 | **`progress.update` reaches a second window** | same wallet, two connections, one clears → both see it (PROTOCOL.md §4.19) | smoke | **written** |
| X.8 | **the solution is withheld** | `quest.get` on an uncleared quest omits `solution` **entirely** — not null, not empty — and leaks no hidden case data | smoke | **written** |
| X.9 | **the four ANONYMOUS messages** | exactly `ping`, `auth.challenge`, `auth.login`, `auth.resume`; all 14 others → `unauthorized`, socket alive | smoke | **written** |
| X.10 | **a bad signature does not burn the nonce** | one bad signature then the good one → the good one still works | smoke §8.4 | **written** |
| X.11 | **a wrong-key signature is refused** | bob signs alice's challenge → `auth_bad_signature` | smoke | **written** |
| X.12 | map edges are given, not inferred | every `requires` appears in `edges` (PROTOCOL.md §4.7) | smoke | **written** |
| X.13 | node numbering is contiguous | 1..n with no gap, ordered | smoke + content CI | **written, both** |
| X.14 | a quest's own answer is never in `quest.get` | already X.8, plus: the fixture-composed answer must come from the **visible case**, not from a leaked solution | smoke | **written** |
| X.15 | `hacker` quests have a clock and a hidden case | in both directions | content CI | **green** |
| X.16 | timestamps are RFC3339 UTC with seconds | every `_at` field on the wire | smoke | **partial** — asserted on `expires_at` only |
| X.17 | an attempt is recorded even when it fails | compile error, timeout, anything → a row in `stats.history` | smoke | **not written** — needs a runner |
| X.18 | `stars` is the server's, not the client's | clear after a failed attempt → at most 2 stars | e2e | **written, skipping** |
| X.19 | **`run.log` paints before the verdict** | a slow compile → console text before `data-state="result"` | e2e | **written, skipping** — the hole FE could not close from inside |
| X.20 | a declared M2 gap reads as a gap | a Go submission → not a crash report | e2e + smoke | **written**; smoke green, e2e skipping |
| X.21 | M2 endpoints declare themselves | `search.query`, `ai.*` → `not_found` with `detail.milestone: 2` | smoke | **green vs the real server** |
| X.22 | `Quest` carries no `cases` key | PROTOCOL.md §4.8 named one before it was corrected; a client reading it renders an empty test list, which looks like a quest with no tests rather than a bug | smoke | **green vs the real server** |
| X.23 | the signature byte order is `r‖s‖v` | `s‖r‖v` and `v‖r‖s` must both be refused — noble v2 hands back `[recid, r, s]`, so assembling them in the order given produces exactly the second one | smoke §8.6 | **green vs the real server** |

---

# How to run everything

```bash
# fixtures — fast, no server, no toolchain beyond rustc/go for the mistakes
python3 tests/vectors/generate.py --check
python3 tests/vectors/mistakes/generate.py --check

# content CI — ~65 s cold, needs rustc and go
python3 tests/content/verify_pack.py content/rust/*.toml content/go/*.toml

# does the contract checker catch anything? — needs cwbwallet, ~2 min
node tests/smoke/selftest.mjs

# the contract itself — needs a server on :5390
node tests/smoke/contract.mjs

# the journey — needs a frontend on :5291 and a backend on :5390
cd e2e && npm install && npx playwright install chromium && npx playwright test
```

`$CWBWALLET` overrides the path to `CausewaybayWallet`'s binary, which the
vector generator, the smoke checker and the mock all shell out to rather than
reimplementing secp256k1.

# Coverage, stated as holes rather than as a number

A percentage would be a worse answer than this list. These are the things a
reader of this suite should not assume are covered.

## Not tested at all

| what | why it is not, and what it would take |
| --- | --- |
| **SPEC §9.6.d — `GOPROXY=off`** | Writable now that Go runs, and **not yet written**. The pack fixtures are all `stdio` with no imports, so a quest that tries to fetch has to be constructed. One test, in `backend/runner/tests/limits.rs`, importing `github.com/…` and asserting a clean `compile_error` naming the proxy rather than a hang |
| **§7.2's rollup over time** | `mistakes.rs` has `the_rollup_counts_clean_attempts`. Nothing drives five consecutive clean attempts through the wire and asserts a kind leaves the AI priority list at `cleared_since >= 5` without being deleted. That is the mechanism the whole training loop rests on |
| **`search.query`, `ai.*`** | Milestone 2. The only assertion is that they declare themselves `unavailable` with `detail.milestone` — which starts failing the day either ships, and that is the signal |
| **The two-missed-ping rule** | `--slow` proves the server does **not** drop a keepalive-only connection (70.1 s, passed). Proving it *does* drop a silent one needs a client that deliberately stops answering pongs |
| **`rate_limited`** | In §3.3's closed set, never provoked. Nothing in the suite knows what the limit is |
| **`server.bye` for real** | The frame is injected and handled correctly, but no test makes a server actually shut down and say goodbye first |
| **The LÖVE client's layout** | Its own suite skips those without `love.graphics`; `make -C love2d test` runs them under a window, which CI cannot do |
| **Anything visual** | The e2e suite attaches a PNG per orientation and asserts the canvas fills the viewport and that the two layers agree in size. Nobody has *looked*. A sprite drawn off-screen in portrait passes everything here |
| **Concurrency beyond two** | Two users, two windows, two submissions. Nothing tests ten |
| **The database under corruption** | No test opens a truncated `hacker.db`, a WAL from a killed process, or a schema from a future version |

## Tested, but weakly

* **The lands scan.** `pickFirstCategory` clicks its way across a canvas
  because the category rows are canvas-drawn and pointer-only. It has broken
  three times — wrong column, wrong y range, wrong land — each time silently
  selecting something and each time costing a full run to diagnose. A
  `__cwbCapture.buttons()` returning `{id, rect}[]` would delete it and a
  whole class of failures with it. **Requested from FE in `docs/decisions.md`;
  until it lands, treat an e2e failure in `enterRustQuest` as "the panel
  moved" before believing it is a product bug.**
* **The mid-run streaming console.** SPEC §5.4 exists so the player watches
  `rustc` think. The text is canvas-drawn: no DOM, no view model. FE could
  not confirm it from inside (headless RAF starvation) and this suite cannot
  read it either. The nearest honest check — two `png()` captures during one
  compile, asserting the images differ while the screen is still `quest` — is
  **not written**. It is coarse and it is more than nothing.
* **The e2e suite against a moving bundle.** It passed 18/18 twice against a
  stable `dist-e2e`. It fails intermittently while FE is rebuilding
  underneath it, which is a true statement about the tree and not about the
  product. `node tests/run-all.mjs --build` rebuilds first, which is the
  reliable way to run it.
* **`--slow` and the content CI are not in anybody's habit.** Both are in
  `test-all`; `--slow` is not.

## Tested well enough to rely on

The address and signature vectors (three independent implementations agree),
the §7.1 taxonomy against real compiler output, all 116 reference solutions
and starters through the real runner, PROTOCOL.md §8 at 12/12 with a selftest
that proves the checker catches 19 real faults, the runner's limits, the
importer against content that changed shape, and the journey a player
actually takes.

# Known gaps, stated plainly

1. **§9.1, §9.2 and §9.3 have no assertion QA can write.** They live inside
   `frontend/` and `backend/`, which QA does not touch this milestone. The
   fixtures are done and proven; the assertions are owed by BE, FE and L2D.
2. **§9.6 is entirely blocked** on a runner that does not exist. Nine cases
   specified, none written.
3. **`tests/content/verify_pack.py` is not in `make test`.** The Makefile is
   not QA's file. Proposed.
4. **The go `unhandled-error` taxonomy row has no fixture** and will not get
   one without `errcheck`.
5. **`e2e/` is 24 skipping tests.** That is the correct state today, verified
   against the real built frontend, and it is worth nothing until the hooks in
   `docs/decisions.md` land. The two highest-value ones — the mid-run console
   and the Go-gap message — are exactly the ones nobody has been able to
   check from inside a unit test.
6. **The smoke checker has now met the real server, and 11 of 12 §8 points
   pass.** The one that does not, and the two softer divergences beside it,
   are written up above and in `docs/decisions.md`. That is the first run;
   there will be more when the runner limits and search land.
7. **The two-missed-ping rule is untested.** `--slow` now passes against the
   real server (70.1 s idle, connection alive), which proves the server does
   not drop a keepalive-only connection. Proving it *does* drop a silent one
   needs a client that deliberately stops answering pongs — not written.
