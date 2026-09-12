# `cwbh` — Causewaybay Hacker from a terminal

The fourth implementation of [`PROTOCOL.md`](../PROTOCOL.md), after the browser
(`frontend/`), the LÖVE desktop client (`love2d/`) and the smoke harness
(`tests/smoke/`). One Rust crate, one binary.

```bash
make build && ./target/debug/cwbh login
```

## The loop

```
cwbh login                       a mnemonic or a private key, read without echo
cwbh maps                        lands and categories, with progress
cwbh map rust basic              one overworld
cwbh quest rust.basic.01.first-light
cwbh edit <id>                   $EDITOR on your file
cwbh run <id>                    visible cases only (PROTOCOL §4.9b)
cwbh submit <id>                 the real thing
cwbh fmt <file>                  rustfmt / gofmt / clang-format (§4.9d)
cwbh play <id>                   edit → run → submit, in a loop
cwbh stats | mistakes | awards | history
cwbh pg run|save|list|load|delete    the playground (§4.9c)
cwbh tui                         a map you can walk, with live compiler output
cwbh doctor                      the store, the server, the session, your editor
```

## The editor loop is the product

A terminal player wants **their** editor, not one written here. So:

* `cwbh edit <id>` writes the starter to
  `~/.causewaybayhackercli/work/<address>/<quest-id>.rs` **only if that file
  does not already exist**, then opens `$VISUAL` or `$EDITOR` on it and waits.
  A second `edit` opens what you wrote. The file is yours.
* `run` and `submit` send that same file. No hidden buffer, no copy.
* `cwbh edit --path <id>` prints the path and exits, so
  `vim "$(cwbh edit --path rust.basic.03.shadowing)"` works too.
* getting the starter back is `cwbh reset <id>`, which asks first. `edit` never
  overwrites anything.
* `$EDITOR="code -w"` works: the command is split on whitespace, so the wait
  flag survives. If your editor returns without waiting, `cwbh` notices the
  file did not change and says so rather than submitting stale source.

## Your key never leaves this process

Derivation is `BIP-39 → BIP-32 m/44'/60'/0'/0/0 → secp256k1`, the same path
`CausewaybayWallet` uses, checked against `tests/vectors/addresses.json` and
`signatures.json` in `make test-vectors`. The phrase is read **without echo**
and never appears in argv — there is no `--mnemonic` flag and there will not
be one, because argv lands in shell history and in `ps`. What crosses the wire
is one EIP-191 signature.

The store is `~/.causewaybayhackercli`, `0700` with `0600` files, append-only
JSONL per SPEC §1.1. It holds the session token, the chosen server, and where
each map was left. No key material, ever.

## Which server

```
--server <URL>  >  $CWBH_SERVER  >  the last one used  >  ws://127.0.0.1:5390/ws
```

`--server` takes `ws://`, `wss://`, `http(s)://` or a bare `host:port`, and
canonicalises all of them to one spelling. **The token is keyed by that
spelling** (SPEC §1.1): a token minted by one server means nothing to another,
so `cwbh --server box:5390 login` and `cwbh login` keep separate sessions and
`cwbh doctor` lists both.

## Watching a run

`run.stage` and `run.log` print as they arrive. `--trace` adds every frame in
both directions with millisecond timings, and a line saying when the first
chunk of each stream landed against when the reply did.

The `compile` stream carries `rustc --error-format=json` — one JSON diagnostic
object per line, not the rendered text PROTOCOL §4.18's example shows. `cwbh`
buffers to line boundaries and prints each diagnostic's own `rendered` field,
which is what `cargo build` would have shown you. `--raw` turns that off.

## Tests

```
make test              everything
make test-vectors      the shared fixtures (SPEC §9) — four implementations, one answer
make test-conformance  PROTOCOL §8, against a mock websocket server
make check             fmt + clippy + tests
```
