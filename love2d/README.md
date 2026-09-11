# Causewaybay Hacker — the LÖVE client

The desktop half of the same game the browser plays. Same server, same wire
protocol, same account: sign in with the same mnemonic here and in the browser
and you are the same player, because the address is the identity (SPEC §3) and
both clients derive it the same way.

**No wallet yet?** The login screen's **NEW WALLET** button makes one: twelve
words from the operating system's CSPRNG, generated offline inside
`love2d/ffi`, shown once with the address they derive. **I HAVE WRITTEN IT
DOWN** signs you in; **ESC** backs out and nothing is created. Nothing about
it touches the network, and the phrase is dropped from memory the moment you
leave the screen — it is written down or it is gone.

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
| `CWBH_SERVER` | — | a launch-time override; wins for that run |
| `CWBH_LOVE2D_HOME` | `~/.causewaybayhackerlove2d` | this client's own store |
| `CWBH_ORIENT` | — | `portrait` or `landscape` to start pinned that way |
| `CWBH_FULLSCREEN` | `desktop` | `exclusive` for a real display-mode change |
| `CWBH_FFI_LIB` | — | an explicit path to `libcwbh_ffi.dylib` |
| `CWBH_TEST` | — | `1` runs the suite and quits |
| `CWBH_DRIVE` | — | a scripted session (`tests/drive/*.lua`) |

| key | |
| --- | --- |
| **F** / **F11** | window ⇄ fullscreen — the same binding as `CausewaybayRaiden` |
| **F1** | orientation: landscape → portrait → automatic |
| **F3** / **F4** | scanlines · sound |
| **F5** / **F10** | in a quest: **RUN** · **SUBMIT** — see below |
| **F2** | in a quest: **FORMAT** (`rustfmt` / `gofmt`, on the server) |
| **F6** … **F9** | in a quest: reset · hint · log · `$EDITOR` |
| **TAB** / **Q** | on the map: switch land · switch category |
| **P** | the playground — Mei's desk, from the map or the land select |
| **TAB** / **ESC** | indent · back |

`F` is only a shortcut on screens that are not taking text; in the editor and
the login fields it is the letter. `F11` always works.

### RUN and SUBMIT

**RUN** (F5, or ctrl-Enter) compiles and runs the **visible** sample cases. It
is the reflex button — press it constantly. **SUBMIT** (F10, or
ctrl-shift-Enter) runs everything including the hidden cases, and is the only
one that can clear the node. They sit at opposite ends of the button row and
five keys apart, because reaching for RUN must never land on SUBMIT.

A passing run says **SAMPLE PASSES**, in cyan — never `ACCEPTED`, never the
green this game uses for a clear. It means "the sample works, now submit". If
a run said *done*, SUBMIT would contradict the player a second later, which
teaches them not to trust the screen.

A run **does not count against the node's attempts** and is out of your
accuracy, so iterating honestly does not look like failing repeatedly. It
**is** still recorded, and the mistakes in it still feed your drills —
deliberately, because the errors made while iterating are the truest record of
what you are actually struggling with (PROTOCOL §4.9b, SPEC §7).

Runs and submits share one execution slot: while either is in flight both
buttons are disabled, and the client refuses the second locally rather than
making you wait for a round trip to learn it.

### The playground

**P**, from the map or the land select. A scratchpad: no quest, no tests, no
verdict — write whatever you like in Rust or Go, run it, and it prints what it
prints. Snippets are saved **server-side**, so the same scratchpad opens in the
browser and here; autosave is on a four-second timer and `playground.save` is
idempotent by contract.

Nothing here is scored, and the screen says so by how it looks: no red, no
banner, no verdict colours, no rejection chime, and the outcome line describes
what the program did — `ran`, `did not compile`, `stopped early` — rather than
judging it. That is not decoration. PROTOCOL §4.9c makes a playground run
deliberately unrecorded *because* this is where somebody writes something
broken on purpose to see what the compiler says; a screen that scolded them
for it would be arguing with its own contract.

### The clock

A `hacker` quest carries a time limit, and **the server owns it** (PROTOCOL
§4.8b) — the client reads `deadline_at` against the wall clock rather than
running a counter, so a reconnect shows one clock and alt-tabbing away to read
documentation does not stop it.

It is **calm for most of its life**: a number that changes once a second and
does nothing else, because it sits on the screen you are concentrating on code
in. The motion is saved for the three moments that mean something — arriving
with the quest, crossing a threshold, and running out. Overtime counts **up**,
in red, with a sign.

It blocks nothing. Time runs out, the quest stays open, and a late clear still
counts; the attempt simply records `within_limit: false`.

### The map

**Nothing is locked.** Every node is playable from the start (PROTOCOL §4.7).
The paths and the node order are the *suggested* route — the order the content
was written to be learned in — so the map still draws them and the node card
still says `SUGGESTED AFTER …`, but it is advice and the player decides.

**Switch land and category from the map itself** — **TAB** for the land,
**Q** for the category, or click the two land buttons and the three category
tabs in the header. A land switch **keeps the category**, so comparing how
Rust and Go do concurrency lands you on the concurrency map rather than at the
top of GO BASIC. Each map remembers the node you left it on, and switching is
one `world.map` call, so looking costs nothing and is entirely reversible.

The keys are the sibling's: `CausewaybayGolang` switches its three language
tracks with TAB and its quests with Q, and a player who has used it already
knows them.

Picking a node walks **Mei** there along the drawn path, on an exponential
ease-in-out: almost still, then fast, then almost still. It is capped at
0.85 s however far the jump, and **any key lands her immediately** — a player
who picked a node wants the quest, not the animation.

### Window and fullscreen

`F` or `F11` toggles at any time, from any screen, **without losing your
place** — including mid-quest with half-written source in the editor. The
virtual canvas is re-measured across the transition and the scene is not
touched.

Fullscreen is **`desktop`** by default: `exclusive` changes the display mode,
and a game that exits badly while in it leaves the desktop rearranged. Set
`CWBH_FULLSCREEN=exclusive` if you want the real thing — the same override the
sibling spells `GOSET_FULLSCREEN`.

**F1 cycles three states, not two.** Landscape and portrait are *pins*: you
asked, so the window's shape does not get a vote. The third state is
automatic, where the orientation follows the window — which is usually what
you want in fullscreen, since the shape there is the display's and not yours.
The footer always says which one you are in.

Both the fullscreen state and the orientation are remembered across restarts,
**including whether the orientation was a pin**. A mode that was merely
inferred from last week's window comes back as a starting guess and is
re-derived; a mode you pressed F1 for comes back as a pin. Those are different
things and storing them as the same thing is a real bug — see
`tests/test_display.lua`.

## The server, and where state lives

There is a **SERVER** field on the login screen — the backend can run on
`0.0.0.0` so a phone on the same tailnet can reach it, and an environment
variable is not discoverable from inside a game. Type an address, press
ENTER: it is validated, saved, and the client drops its connection and comes
back on the new one. A bad address says what is wrong (`needs a port`,
`wss:// needs TLS, which this client does not have`) rather than failing to
connect for unexplained reasons.

**Precedence:** `CWBH_SERVER` is a launch-time override and wins for that
run; otherwise the saved field; otherwise `ws://127.0.0.1:5390/ws`. Editing
the field always saves — and when an override is active the screen says so,
rather than pretending to apply something it will not.

State lives in **`~/.causewaybayhackerlove2d`** (SPEC §1.1), not in LÖVE's
save directory: `0700` directory, `0600` files, append-only JSONL, state
derived by replaying the log. It holds the session token, the chosen server,
the orientation and fullscreen pins, and where each map was left — and **no
key material, ever**. An existing LÖVE save is migrated across once.

**The token is stored per server.** A token minted by one server means
nothing to another, so pointing the client at a new address asks you to sign
in rather than sending a stranger's credential and getting an `unauthorized`
you cannot explain. Switching away and back leaves you signed in to both.

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

## The art

`art/`, at the root of this repository, holds the 32 generated assets and
`art/manifest.json` in `CausewaybayGolang`'s shape, with a measured `box` on
every sprite so a character stands on her feet. `src/assets.lua` reads that
manifest — `love.filesystem` first, then the real path beside the game — and
**does not** run those files through the magenta knockout: they already carry
binary alpha, and flooding a correctly-cut sprite would eat the padlock off
`node_locked`.

`love2d/assets/` keeps the handful of placeholders `art/` does not carry
(`fx_star`, `fx_confetti`, `ui_coin`, `sprite_clerk`, `bg_flat`, and the old
overworld as a fallback). Those are magenta-screen JPEGs and those *do* go
through the knockout.

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
