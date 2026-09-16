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
| `CWBH_LOVE2D_HOME` | `~/.causewaybaylove2d` | this client's own store |
| `CWBH_ORIENT` | — | `portrait` or `landscape` to start pinned that way |
| `CWBH_LANG` | — | `en` `ko` `yue` `zh` `ja` `cs` — a launch-time override |
| `CWBH_FULLSCREEN` | `desktop` | `exclusive` for a real display-mode change |
| `CWBH_FFI_LIB` | — | an explicit path to `libcwbh_ffi.dylib` |
| `CWBH_TEST` | — | `1` runs the suite and quits |
| `CWBH_DRIVE` | — | a scripted session (`tests/drive/*.lua`) |

The store's home is resolved the way the rest of this family resolves theirs
(SPEC §1.1): **`--home <PATH>` first, then `CWBH_LOVE2D_HOME`, then
`~/.causewaybaylove2d`**. A flag that lost to an environment variable
somebody exported last month would be a flag that does nothing.

```bash
love . --home ~/somewhere-else       # or --home=~/somewhere-else
```

| key | |
| --- | --- |
| **F** / **F11** | window ⇄ fullscreen — the same binding as `CausewaybayRaiden` |
| **F1** | orientation: landscape → portrait → automatic |
| **F12** | type size: four steps, then back to the first |
| **L** | language: EN → 한국어 → 粵語 → 简体中文 → 日本語 → Čeština |
| **F3** / **F4** | scanlines · sound |
| **F5** / **F10** | in a quest: **RUN** · **SUBMIT** — see below |
| **F2** | in a quest: **FORMAT** (`rustfmt` / `gofmt`, on the server) |
| **F6** … **F9** | in a quest: reset · hint · log · `$EDITOR` |
| **TAB** / **Q** | on the map: switch land · switch category |
| **P** | the playground — Mei's desk, from the map, the land select or the category select; both selects also have it as a button, beside **WEAKEST** on the land select |
| **S** / **T** / **A** | from the map: search · stats · AI mode |
| **TAB** / **ESC** | indent · back |
| **ctrl-]** | in the editor: jump to the matching bracket (shift to select) |

`F` is only a shortcut on screens that are not taking text; in the editor and
the login fields it is the letter. `F11` always works.

### The editor

It is where a player spends most of an evening, so it behaves the way an
editor behaves. Multi-line, UTF-8-aware motion, word motion, smart home, a
goal column, tab stops, block indent and dedent, indent-aware backspace,
brace auto-indent, ctrl-/ to comment, undo that takes back a word rather than
a letter, redo, the system clipboard, and a FORMAT that puts the caret back
between the same two characters after `rustfmt` has re-flowed the file.

**The mouse selects.** Click to place, drag to select, double click for a
word, triple click for a line — and a word or line drag then grows by words
or lines, not by characters. Shift-click extends whatever is already
selected. A drag off the top or bottom of the pane scrolls to follow.

**Brackets are matched, and the unmatched ones are named.** The pair around
the caret is outlined in cyan; a `(`, `[` or `{` that never closed — or a
closer with nothing open — is outlined in red and its line number turns red
with it, so a brace that has scrolled off to the right still says so. An
unbalanced brace is the most common reason a submission does not compile and
it is invisible until the compiler says so.

Only `()`, `[]` and `{}`. `<` and `>` are deliberately left alone: in Rust
they are comparison, `->`, `=>` and generics in roughly equal measure, and a
matcher that guessed would be wrong on `Vec<u8>` more often than it was right.

What is decided to be a bracket comes from the same tokenizer that colours the
pane, so a brace inside a string literal or a comment is text — and a brace
can never be drawn as matched while being coloured as part of a string.

**No search and no multi-cursor.** A quest answer is forty lines; a search box
in a file you can see all of is a key that opens a dialog you then close. If
the playground grows long snippets that changes.

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

### Stats

Where the premise becomes visible: your mistakes are the curriculum.
`cleared_since` — the consecutive clean submits since you last made a given
mistake — is drawn as a five-step track *and* said in words, because "you have
not done this in four submits" is a sentence about a person and "count: 6" is
a row in a table. At five the kind is learned and leaves the drill.

Awards sit on a shelf with empty sockets for the ones you have not earned. No
award is ever invented: earned ones come from `stats.awards`, and a socket is
furniture rather than a guess at a name.

### Search and AI mode

Both are **built against their contracts and render whatever the server
answers**. Today that is `unavailable` with a milestone, so they say which
chapter they open in — in the story's voice, with no retry offered, because
retrying a feature that does not exist never helps (PROTOCOL §3.3:
`unavailable` is deliberately **not** `internal`). The day the endpoints land
these screens show hits and drills with no change here.

Search shows *why* something matched: the fused score and its `bm25` and
`cosine` components, with a missing component drawn as absence rather than as
zero — §5.5 says `null` means the quest was not in that ranking at all, which
is a different fact.

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

### The display controls

Three buttons, in the bottom-right corner of the footer, on **every screen** —
the title card included:

| | shows | does |
| --- | --- | --- |
| ▭ `WINDOW` / `FULL` | a small screen, or a filled one | window ⇄ fullscreen |
| ▯ `LAND` / `PORT` / `AUTO` | the shape you are in; filled when pinned, hollow when the window decides | cycles the three orientation states |
| `A 1/4` | the `A` is drawn at the step it selects | cycles four type sizes |
| 🌐 `KO` | the language's code; the toast says its own name | cycles the six languages |

On a narrow canvas the four drop their words and keep their glyphs — the
screen is inset or filled, the box is wide or tall and hollow or solid, the
`A` is drawn at its own step — because a 720-wide portrait strip cannot spend
520 pixels on four labels and still say anything. The type button keeps its
digit, since "which of four" is the one state no glyph shows.

**Each one says the state it is in, not the state it would move to.** A toggle
whose current value is invisible gets pressed twice: once to find out, once to
put it back. `AUTO` is the one that has to say two things at once — it is a
state the player chose *and* it has resolved to a shape — so the word says
`AUTO` and the glyph draws the shape it landed on, hollow rather than filled.

They are drawn by `App:footer`, which every scene already calls, so a screen
added tomorrow gets them without knowing they exist and cannot forget them —
`tests/test_screens.lua` asserts that every scene does call it. A press is
tested before the scene sees the click and is consumed, so changing the type
size can never also open a quest.

The keys are unchanged and still work: **F**/**F11**, **F1**, **F12**. The
buttons are an addition, because a key nobody can see is not a feature — the
same reasoning that put the land and category switches on the map itself.

### Window and fullscreen

`F`, `F11` or the **WINDOW** button toggles at any time, from any screen,
**without losing your place** — including mid-quest with half-written source
in the editor. The virtual canvas is re-measured across the transition and the
scene is not touched.

Fullscreen is **`desktop`** by default: `exclusive` changes the display mode,
and a game that exits badly while in it leaves the desktop rearranged. Set
`CWBH_FULLSCREEN=exclusive` if you want the real thing — the same override the
sibling spells `GOSET_FULLSCREEN`.

**F1 — and the middle button — cycles three states, not two.** Landscape and portrait are *pins*: you
asked, so the window's shape does not get a vote. The third state is
automatic, where the orientation follows the window — which is usually what
you want in fullscreen, since the shape there is the display's and not yours.
The footer always says which one you are in.

### The type

**Everything is drawn on an 8-pixel grid**, because both faces are: Press
Start 2P is an 8×8 design and GNU Unifont is 8×16. At 9, 10 or 15 px a
one-pixel stem lands on a fraction of a screen pixel and the rasteriser either
smears it grey or drops it — `CausewaybayWallet`'s README says it plainly,
*"at 2.5× a one-pixel line lands on half a screen pixel … and the whole
illusion goes"* — and this client was doing it at every label, because its
authored ladder was 7, 8, 9, 10, 11, 12, 13. `Assets.snap8` rounds every size
this program hands to the rasteriser onto the grid, so no glyph is ever
resampled. Nothing is ever drawn through `love.graphics.scale`.

**And the ladder was doubled.** Measured, not preferred: on the 1080×1920 the
bug report came from, `Layout.scale` is 1 and `MAX_STRETCH` spends every extra
pixel on a bigger canvas rather than bigger furniture, so a 10 px label was
**0.52 % of the frame's height** where the same label on a laptop window was
1.39 %. The canvas grew; the type did not.

| window | before | after |
| --- | --- | --- |
| 1080×1920, the bug report | 10 px (0.52 %) | **24 px (1.25 %)** |
| 1280×720 laptop | 10 px (1.39 %) | **24 px (3.33 %)** |
| 1512×982 MacBook fullscreen | 10 px (1.02 %) | **24 px (2.44 %)** |
| 720×1280 portrait window | 10 px (0.78 %) | **24 px (1.88 %)** |

`Layout.ui` is the one function that does it, and `src/ui.lua` is the only
caller: `text`, `textWidth`, `wrap` and `button` all go through it, because a
paragraph measured at one size and drawn at another wraps wrong in a way
nobody notices until a sentence is cut in half.

**The layout is measured from the type, not from constants.** That is the
other half of the same report: the 1080×1920 screenshot had two 300 px cards
at the top of a 1920 px frame and two thirds of it bare, which reads as small
however big the letters are. Portrait now stacks and *uses the height*, the
map header sizes its buttons from their labels, and every row that used to
advance by a hardcoded 10 or 16 pixels advances by `UI.lineHeight`.

**F12**, or the `A n/4` button, is a preference on top of that — four steps,
a cycle rather than a slider, and it moves the code face *and* the chrome.
`Layout.codeSize` is the one place both code panes ask, because the quest
screen and the playground each used to derive the same expression themselves.
`tests/drive/typesize.lua` drives the largest step through both panes, both
orientations and fullscreen, and asserts the pane still has rows, the caret is
still on screen, the gutter has not eaten the pane and the buffer is byte for
byte what it was.

### Six languages

English, 한국어, 粵語, 简体中文, 日本語, Čeština — **L**, or the globe button.

The mechanism is `CausewaybayGolang/love2d/src/i18n.lua`'s: translations are
keyed by **the English string**, so a call site reads as the sentence it draws
and a string nobody has translated stays English instead of turning into
`lands.title.pick`. Each language is one file under `src/lang/`.

**The interface only.** The 138 quests are content owned by another part of
this repository, and a quest brief is a specification of a program —
mistranslating one would fail a test for a reason the player cannot see. So a
Korean player gets a Korean interface around an English quest, with the quest
title drawn beside its id in the land's tint, as the identifier it is.

**Technical terms stay in English**: borrow checker, ownership, lifetime,
goroutine, channel, trait, mutex. That is what programmers writing these
languages actually write. Where a translation was a guess it is marked
`UNREVIEWED` in the language file — seven entries at present, listed there
with what is uncertain about each.

**Every English string the interface can draw has a translation, and two
tests prove it — one reading the source, one watching the game run.**

`tests/test_i18n.lua` extracts the keys from `src/` itself, including the ones
built by concatenating string literals across three lines, which is how a
sentence longer than a line is written here and which a grep for `I18n.t("`
does not see. It is a hand-written walk rather than a Lua pattern, because a
pattern cannot cross a newline.

`tests/drive/language.lua` wraps `I18n.t` while it walks ten screens and fails
on any key with no entry — the half no source scan can reach, where the key
lives in a module-level table (`I18n.t(BLURB[cat.category])`) and only exists
at run time.

Five names are English on purpose and listed in the test: `CAUSEWAYBAY`,
`HACKER`, `RUST`, `GO`, `TAB`. A proper noun is not a word and a key name is
not a word.

**Cantonese is not Chinese.** `yue` is Hong Kong written Cantonese in
traditional characters — 嘅, 咗, 喺, 冇 — and `zh` is Standard Written Chinese
in simplified. They share a script and are not the same language.

One font draws all six: **GNU Unifont**, 5.1 MB, taken whole from
`CausewaybayOffice/love2d`. 58,909 glyphs, the entire Basic Multilingual
Plane, and it is a *bitmap* face — 8×16 px per cell, 16 px for a double-width
ideograph — so it is pixel art rather than a vector face filtered to
`nearest` and hoped over. Press Start 2P keeps drawing ASCII, so English is
pixel for pixel what it was, and Unifont is attached behind it with
`setFallbacks`. The alternative, a Noto Sans CJK subset, is 11.2 MB and has
**no Czech diacritics** — it would have made the four hard languages work and
quietly broken the easy one. `tests/test_fonts.lua` asserts the advances
(ASCII 8, 中 16, 안 16, ř 8, height 16) and that every glyph every language
can produce is drawable.

Both the fullscreen state, the orientation and the code size are remembered
across restarts,
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

State lives in **`~/.causewaybaylove2d`** (SPEC §1.1), not in LÖVE's save
directory: `0700` directory, `0600` files, append-only JSONL, state derived by
replaying the log. It holds the session token, the chosen server, the
orientation, fullscreen and code-size settings, and where each map was left —
and **no key material, ever**.

**Two migrations have run into this directory, and neither deletes anything.**
An existing LÖVE save is brought across once; and a store at the old default
`~/.causewaybayhackerlove2d` is **copied** across once, byte for byte, the
first time a launch finds the new path empty. The old directory is left
exactly as it was — not deleted, not renamed, not even appended to — so if the
move ever goes wrong the evidence is still sitting there. The gate is simply
"is there already a store at the new path", which is *migrate once*, *do not
migrate twice* and *never overwrite* in a single condition, and the only one
that can be checked without trusting a flag that could only live inside the
file being written.

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
`src/editor.lua`, `src/wallet.lua`, `src/store.lua`, `src/anim.lua`,
`src/clock.lua` and `src/i18n.lua` contain **no reference to `love`**, so a
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
                      ui.lua also owns the three display controls
  editor.lua          the code editor's model — pure, no love
  codepane.lua        the mouse and the bracket overlay, shared by two scenes
  external.lua        the $EDITOR escape hatch
  wallet.lua          the LuaJIT binding to libcwbh_ffi
  i18n.lua            the six languages; LÖVE-free
  lang/               ko yue zh ja cs, keyed by the English string
  store.lua           ~/.causewaybaylove2d: the token, the server, the
                      display settings and the map cursors — and the
                      one-time move out of the old home
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
