# Causewaybay Hacker — the LÖVE client

The desktop half of the same game the browser plays. Same server, same wire
protocol, same account: sign in with the same mnemonic here and in the browser
and you are the same player, because the address is the identity (SPEC §3) and
both clients derive it the same way.

```
    love2d (LuaJIT)                  server (Rust)               host
    ───────────────                  ─────────────               ────
    scenes, layout, editor  ──ws──▶  axum + tokio        ──▶     rustc / cargo
    RFC 6455 in pure Lua      json   sqlite                ──▶    go build
    key derivation (FFI)             ~/.causewaybayhacker
```

## It is a client

The server owns every rule: progress, judging, quests, mistakes, drills. This
program renders what it is told and sends what the player did. Nothing in
`src/` decides whether an answer is correct or which node unlocks next — that
is a websocket message, not Lua. See `docs/decisions.md`, first entry.

This is the one thing that is different from the sibling repos. `Causewaybay
Golang/love2d/src/data*.lua` holds its quest content locally because it has no
server; here the quests come from `world.map` and `quest.get`, and there is no
content file in this directory at all.

## Running it

```bash
make ffi                  # build the key library, once
make love-bin             # fetch LÖVE 11.5 into build/, if you have no `love`
cd ../backend && cargo run -p cwbhacker -- serve   # in another terminal
make run
```

`brew install --cask love` does not work on macOS as of 2026-09-01 — the cask
was disabled for failing the Gatekeeper check. `make love-bin` downloads the
official release from GitHub instead, and `make run` will use a `love` on
`PATH` first if there is one.

| variable | default | |
| --- | --- | --- |
| `CWBH_SERVER` | `ws://127.0.0.1:5390/ws` | where the server is |
| `CWBH_ORIENT` | — | `portrait` to start portrait |
| `CWBH_FFI_LIB` | — | an explicit path to `libcwbh_ffi.dylib` |
| `CWBH_TEST` | — | `1` runs the suite and quits |
| `CWBH_DRIVE` | — | a scripted session (`tests/drive/*.lua`) |

Keys: **F1** orientation · **F3** scanlines · **F4** sound · **F11** fullscreen.
In a quest: **F5** submit · **F6** reset · **F7** hint · **F8** log · **F9**
`$EDITOR` · **TAB** indent · **ESC** back.

## Testing

```bash
make test-headless   # the codec, JSON, editor and key derivation, no window
make test            # the same suite plus layout and every scene, under LÖVE
make ffi-test        # the Rust crate
make test-all        # all three
```

The headless run is the important one: `src/json.lua`, `src/net/**`,
`src/editor.lua` and `src/wallet.lua` contain **no reference to `love`**, so a
bare `luajit` can drive the whole protocol. `make check-layering` asserts that
with a grep, and `T.no_love` asserts it again from inside the suite — if it
ever stops being true, most of this directory stops being testable.

Against a real server:

```bash
make drive SCRIPT=tests/drive/slice.lua   # login → quest → CLEARED
make shots                                # every screen, both orientations
```

Screenshots land in `~/Library/Application Support/LOVE/causewaybay-hacker`.

## What is where

```
main.lua              the LÖVE callbacks, the test/drive switch
conf.lua              window and modules
src/
  app.lua             the shell: one socket, one session, one scene
  layout.lua          the virtual canvas        (ported, see the header)
  theme.lua ease.lua crt.lua                    (ported)
  assets.lua ui.lua sfx.lua                     art, chrome, chip audio
  editor.lua          the code editor's model — pure, no love
  external.lua        the $EDITOR escape hatch
  wallet.lua          the LuaJIT binding to libcwbh_ffi
  store.lua           the session token, and nothing else, on disk
  session.lua         auth, the token, and what a reconnect does
  json.lua            vendored, see the header
  net/
    ws.lua            RFC 6455: handshake strings and the frame codec
    client.lua        envelopes, correlation, keepalive, backoff
    socket.lua        LuaSocket, non-blocking
    runlog.lua        run.log reassembly, by seq, per stream
    errors.lua        §3.3's closed set
    sha1.lua base64.lua bitops.lua
  scenes/             boot login lands categories map quest result
                      search stats ai  (search and ai are milestone 2 stubs)
ffi/                  the Rust cdylib: bip39 + bip32 + secp256k1 + keccak
tests/                the suite, the fake server, the drive scripts
assets/               placeholder art, per docs/art.md
```

## The key

`ffi/` is a small Rust `cdylib` doing BIP-39, BIP-32, secp256k1 and keccak —
the one part of this client that cannot honestly be written in Lua. It follows
`CausewaybayWallet/rustcli/ffi`'s idiom: a C ABI, JSON in and JSON out, one
explicit free, and an ABI number checked before the first real call.

**The mnemonic and the private key never cross the websocket, are never
logged, and are never written to disk.** The only thing that leaves this
machine is a 65-byte signature over the server's own challenge string, signed
byte-for-byte as it was given (PROTOCOL §4.2). `tests/test_wallet.lua` asserts
the derivation and the signatures against `tests/vectors/`, which QA generated
from `CausewaybayWallet` itself — so a drift here fails a test rather than
quietly giving somebody a different account than the browser does.

If the library is missing the client still starts, and the login screen says
`make -C love2d ffi`.
