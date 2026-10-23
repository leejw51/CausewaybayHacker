# Causewaybay Hacker — the LÖVE client

The desktop half of the same game the browser plays. Same server, same wire
protocol, same account: sign in with the same mnemonic here and in the browser
and you are the same player, because the address is the identity (SPEC §3) and
both clients derive it the same way.

**No wallet yet?** The login screen's **NEW WALLET** button (or **N**) makes
one: twelve words from the operating system's CSPRNG, generated offline inside
`love2d/ffi`, shown once on a sheet over the card with the address they
derive. **I HAVE WRITTEN IT DOWN** signs you in; **ESC** backs out and nothing
is created. Nothing about it touches the network, and the phrase is dropped
from memory the moment you leave the screen — it is written down or it is
gone.

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
| `CWBH_UI_FACE` | — | `game` `dos` `dunggeunmo` `galmuri` `comic` — the interface face for that run; otherwise the one F8 last chose, otherwise `dunggeunmo` |
| `CWBH_FULLSCREEN` | `desktop` | `exclusive` for a real display-mode change |
| `CWBH_FFI_LIB` | — | an explicit path to `libcwbh_ffi.dylib` |
| `GROK_API_KEY` etc. | — | only read by `tests/drive/agent.lua`; the game itself asks in SETUP |
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
| **F12** | type size: ×0.75 → ×1.0 → ×1.5 → ×2.0, then back to the first; it starts on ×1.0 and moves the code and the reading face only |
| **F8** | interface face: Neo둥근모 → Galmuri → Comic → ARCADE (Press Start 2P) → DOS → … |
| **F9** / **⚙** | the settings sheet — window, orientation, type size, language, both faces, sound, the account, LOG OUT. ESC or F9 closes it |
| **L** | language: EN → 한국어 → 粵語 → 简体中文 → 日本語 → Čeština |
| **F3** / **F4** | scanlines · sound |
| **1** … **4** | in a quest: pick that line — the keypad's digits too |
| **F7** | in a quest: a hint, when the quest has one |
| **F5** / **F2** | in the playground: **RUN** · **FORMAT** (`rustfmt` / `gofmt`, on the server) |
| **ctrl-S** | in the playground: save the snippet now, ahead of the autosave |
| **TAB** / **Q** | on the map: switch land · switch category |
| **P** | the playground — Mei's desk, from the map, the land select or the category select; both selects also have it as a button, beside **WEAKEST** on the land select |
| **S** / **T** / **A** | from the map: search · stats · AI mode |
| **TAB** / **ESC** | indent · back |
| **ctrl-]** | in the editor: jump to the matching bracket (shift to select) |
| **alt-↑** / **alt-↓** | in the editor: move the line — or the selected lines — up or down |
| **shift-alt-↑** / **shift-alt-↓** | in the editor: copy the line(s) above or below, the caret on the copy |
| **ctrl-shift-K** / **⌘-shift-K** | in the editor: delete the line(s) |
| **alt-⌫** / **ctrl-⌫** | in the editor: delete the word behind (**delete** for the word ahead); **⌘-⌫** to the start of the line, **⌘-delete** to its end |
| **ctrl-/** | in the editor: toggle the language's own line comment — `//`, `#` for Python, `--` for Lua |
| **ENTER** | in the playground, with AUTO-RUN on: a newline, and a run |

`F` and `L` are only shortcuts on screens that are not taking text; in the
editor, the search box and the login fields they are letters. `F11` always
works. **On a quiz every function key but F7 is refused** with the locked
sound — F2/F5/F6/F8/F9/F10 were the editor's on that screen, and a key that
quietly started doing something else would be worse than one screen where
the settings are a button away — so there the ⚙ is the way in and the
interface face is a row on the sheet. The playground takes neither F8 nor
F9, and both work.

### The quest: four choices

**Every road is picked, not typed** (SPEC §0). A quest is a program with a
hole in it and four lines that could fill it, one right; the pick is the
submission's `source` and the server judges it. `src/quiz.lua` says only what
a pick *means* on this screen — right, wrong, or ignored because that row is
already dead — how the program is cut to a window around the hole, and where
a choice may take a tap. It is pure and `tests/test_quiz.lua` runs it under
a bare luajit. Press **1–4**, or click the row.

**A wrong pick stays wrong.** The row goes red, its code is struck through,
`−1 ★` sits at its right, and its key does nothing for the rest of the
attempt. The row shakes, shards fly, a red vignette runs round the edge of
the screen for a beat — never a wash over the code — and the heading reads
NOT THAT ONE — n LEFT for a moment. **The right pick** goes green, the others
dim and settle, the answer is typed into the hole a character at a time,
stars and confetti burst from the row, and the verdict screen waits 1.1 s
(`Quiz.HOLD`) for it, because a client that went straight to the result was
playing its celebration on a screen nobody was looking at any more. There is
no CLEARED toast: the clear is the quiz's own right state.

The stars a clear would earn are shown before you pick, from the same rule as
the server's `stars_for`: three with no miss and no hint, two with a hint or
up to two misses, one otherwise. **F7** takes a hint when the quest has one
authored; the HINT button and the footer's `F7 hint` appear on exactly that
condition, and the hint lands in the brief card.

**Streak and combo.** First-try picks in a row on one road — a land and a
category — this session. The card's heading says `STREAK ×n`, gold, pink
from five; from two, `×n COMBO` zooms in over the row that was right. A miss
breaks it, and a right pick after a miss starts again at nothing. The count
lives in `src/quiz.lua` at module level rather than on the scene, because the
next node is a new scene and the streak is the same streak; signing out
forgets it.

In landscape the screen is two columns inside the bounded content box: the
quiz card on the left — the question, the code well with the hole lit, PICK
THE RIGHT LINE and the four rows with their keycaps — and the brief card on
the right with the story, the CONCEPTS chips, any hint taken, and the STARS /
DIFFICULTY / HINTS card under it. Upright it is one column, scrolled as a
whole. A program quiz shows a window of the program round its hole, as many
lines as the card has room for, so the hole and the four answers are always
seen together — the hole used to be twenty lines below the fold. When the
four would not fit at the chosen code size the card steps the code down to a
12 px floor before it scrolls. `tests/drive/quiz.lua` walks a sheet question
and a program quiz through a wrong pick and the right one, both orientations,
on the real server.

The editor screen, **RUN** (F5) and **SUBMIT** (F10) are still in
`src/scenes/quest.lua` for a quest the server sends without a `quiz`, with
the rules they had — a run is for the player and does not count against the
node, a submit is for the record — but no road sends one today.
`tests/drive/answer.lua` and `solve.lua` went with the editor they drove.

### The editor

It is the playground's now, and it is where a player writing their own
programs spends the evening, so it behaves the way an editor behaves.
Multi-line, UTF-8-aware motion, word motion, smart home, a goal column, tab
stops, block indent and dedent, indent-aware backspace, brace auto-indent,
ctrl-/ to comment in the language's own mark, undo that takes back a word
rather than a letter, redo, the system clipboard, and a FORMAT that puts the
caret back between the same two characters after `rustfmt` has re-flowed the
file.

**The line commands are CodeMirror's**, so hands trained in the browser work
here: alt-↑/↓ moves the line or the selected lines, shift-alt-↑/↓ copies
them with the caret on the copy, ctrl-shift-K (⌘ on a Mac) deletes them, and
alt-backspace takes a word — ctrl off a Mac, ⌘ to the edge of the line. The
word and line deletes extend a selection and press the ordinary key, so the
undo step, the rubble and the pair rules are the ordinary ones, and one undo
brings the word back with its selection. A selection that ends at column one
does not take that line, as in every editor.

**The mouse selects.** Click to place, drag to select, double click for a
word, triple click for a line — and a word or line drag then grows by words
or lines, not by characters. Shift-click extends whatever is already
selected. A drag off the top or bottom of the pane scrolls to follow.

**Brackets are matched, and the unmatched ones are named.** The pair around
the caret is outlined in cyan; a `(`, `[` or `{` that never closed — or a
closer with nothing open — is outlined in red and its line number turns red
with it, so a brace that has scrolled off to the right still says so. An
unbalanced brace is the most common reason a program does not compile and
it is invisible until the compiler says so.

Only `()`, `[]` and `{}`. `<` and `>` are deliberately left alone: in Rust
they are comparison, `->`, `=>` and generics in roughly equal measure, and a
matcher that guessed would be wrong on `Vec<u8>` more often than it was right.

What is decided to be a bracket comes from the same tokenizer that colours the
pane, so a brace inside a string literal or a comment is text — and a brace
can never be drawn as matched while being coloured as part of a string.

**No search and no multi-cursor.** A scratchpad snippet is forty lines; a
search box in a file you can see all of is a key that opens a dialog you then
close. If the snippets grow long that changes.

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
verdict — write whatever you like in any of the eight languages (Rust, Go,
C++, Python, PyTorch, TypeScript, Zig, Lua; the language button in CODE walks
them), run it, and it prints what it prints. Snippets are saved
**server-side**, so the same scratchpad opens in the browser and here — the
SNIPPETS panel lists them (on top in portrait, the browser's way, with NEW,
RENAME and DELETE at its foot; a click opens one); autosave is on a
four-second timer and `playground.save` is idempotent by contract.

Nothing here is scored, and the screen says so by how it looks: no red, no
banner, no verdict colours, no rejection chime, and the outcome line describes
what the program did — `ran`, `did not compile`, `stopped early` — rather than
judging it. That is not decoration. PROTOCOL §4.9c makes a playground run
deliberately unrecorded *because* this is where somebody writes something
broken on purpose to see what the compiler says; a screen that scolded them
for it would be arguing with its own contract.

**The toolbar is every button the browser's playground has**, in its order,
on the bench and in CODE alike. A filter box heads the first row — type a
word and only the buttons that match stay — and the buttons wrap by
measurement into as many rows as they need, grouped with a wider gap between
groups than inside one:

| group | buttons |
| --- | --- |
| run | **RUN** (F5) · **AUTO-RUN ON / OFF** · **STDERR ON / OFF** · **FORMAT** (F2) |
| edit | **AGENT** · **UNDO** · **REDO** · **SAVE** · **NEW** · **RENAME** |
| clipboard | **COPY CODE** · **PASTE** · **COPY OUTPUT** · **COPY INPUT** · **PASTE INPUT** |
| tools | **POSTER** · **DISK READER** |
| look | **A-** · **A+** · the code face · **FONT** *interface face* · **DARK / LIGHT** · the computer |
| view | **CODE** on the bench; the language in CODE |

**Every button is as wide as the widest label it can wear**, measured in the
face it is drawn in, so nothing is ever cut to `…` and a toggle does not
reflow the row when it flips. Every toggle says the state it is **in**.

**AUTO-RUN** is on unless you turn it off, as in the browser: ENTER in the
editor runs the pad, so the answer on screen follows the code a line at a
time. A run already out is not interrupted; one more follows it, for the code
as it is by then. **STDERR** is off unless you turn it on: the output is then
what the program printed, and the compiler's words appear only when the build
failed, where they are the whole answer — warnings, panics' backtraces and
the compiler's progress chatter stay out of the way. Both are remembered
across launches (`pgprefs.set`, below).

**A-** and **A+** are F12's cycle as two buttons, for a screen with no
F-keys, and go grey at either end of the ladder. The code-face button cycles
the fifteen faces and says which it is in; **FONT** is F8's interface face,
here for the person who asked for "font change" and should not have to find
the settings sheet for it. **DARK / LIGHT** is the code pane's paper and
nothing else — and it is dim on an old computer, because the machine brings
its own.

**The three old computers.** The last button walks NORMAL → **APPLE ][** →
**MSX** → **AMIGA** (`src/computer.lua`, ported from the browser's
`ui/computer.ts`). Each machine is four things at once: its paper (the code
pane's palette), its face (PR Number 3, the MSX1 cell, the A500's Topaz — set
as the code face, and still yours to change on the button beside it), its
tube, and its room. The tube is `src/retroscreen.lua`, after cool-retro-term:
scanline gaps, an aperture grille, grain, a rolling sync bar, a vignette,
rounded glass and a glare, drawn as one quad over the editor — **the code is
never pushed through the shader**, because bending the glyphs somebody is
reading their own program in is the one thing a pane read for an hour must
not do. The boot screen *is* drawn on the tube and gets the full treatment,
barrel distortion and bloom included: `]` and a beep, MSX BASIC's banner,
Workbench's title bar, painted at the machine's own resolution and scaled up
nearest-neighbour. `src/retromonitor.lua` is the plastic round the glass — the
1084's vents, the two knobs of the television an MSX was plugged into.
Switching plays the power-on. The quest screen never sees a machine: a Guru
Meditation over a failed quest would be a joke at the player's expense, and
the scratchpad is where breaking things is the point. The choice is kept
(`computer.set`); `tests/drive/computer.lua` walks the cycle on the real
server and checks that the quest palette was never touched.

### The Rust coder

**AGENT**, in the toolbar's edit group next to UNDO (or Ctrl-Shift-A). A
small pixel-art character on a flying keyboard that lives on the code screen:
ask it about the program, or say what to write and watch it type the answer
into the editor one character at a time. It reads the file, edits or rewrites
it, runs it, reads what the compiler said, fixes it and runs again — up to ten
rounds — and then says in a sentence what it did. Every one of those steps
happens on this machine.

Five providers: Anthropic, OpenAI, xAI (Grok), OpenRouter, and Ollama on your
own computer. Press SETUP, choose one, paste its key — for Ollama, the host it
listens on — and press MODELS to see what that key can reach. The key is kept
in `agent.json` in this client's own store, `0600`, and is sent to the provider
that issued it and to nobody else. **It never goes to the game server**, which
is storage: the conversation is kept there, one room per scratchpad, so the
same room opens in the browser (PROTOCOL §4.9f).

LÖVE ships LuaSocket and no TLS, so the call itself goes through the key
library — `ffi/src/http.rs`, ABI 5 — which streams the reply back in pieces
that `love.update` collects without ever blocking a frame. `docs/agent.md` is
the contract, and it is one contract for both clients.

The character can be put away (SETUP → CODER: OFF) without losing the room,
and AUTO — off unless you turn it on — lets it review your code by itself now
and then, which is the only thing here that spends a call nobody pressed for.

### The clock

A `hacker` quest carries a time limit, and **the server owns it** (PROTOCOL
§4.8b) — the client reads `deadline_at` against the wall clock rather than
running a counter, so a reconnect shows one clock and alt-tabbing away to read
documentation does not stop it. It has a slot of its own in the quest header.

It is **calm for most of its life**: a number that changes once a second and
does nothing else, because it sits on the screen you are concentrating on.
The motion is saved for the three moments that mean something — arriving
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

### The look

`src/theme.lua` is the tokens, `src/ui.lua` the components, `src/juice.lua`
the motion and `src/fx.lua` the particles; `docs/love2d-ui.md` is the
contract and holds the numbers. The idiom is Balatro's, adapted to a coding
game: a calm dark felt, rounded cards and buttons with a **solid same-hue
shadow** so everything has depth, very little chrome, and four accents that
each mean one thing — **gold acts and rewards, blue runs, red is wrong, green
is right**. Land colours are strips and badges only, never text (C++'s blue
on navy was 2:1). Code is the hero; chrome recedes. A `primary` button is
gold and there is one per screen; `hot` is the keyboard cursor as much as the
pointer, and it changes colour, not only motion, so a selection is visible
without a mouse. A button never shrinks or ellipsises its label: a box too
small for it grows. The frames round the quiz card, its choices and the
plaque are nine-sliced from `art/` by `src/artframe.lua`, so a frame of any
size keeps chunky corners instead of smeared ones.

**Motion** has rules rather than moments. Hover lifts, a press pushes in and
springs back, cards deal in from 24 px below with a 40 ms stagger in reading
order, a scene change is a 120 ms fade up from the felt and never a wipe, the
footer's XP counts up over 600 ms. `Juice` is pure — no `love`, in
`make check-layering`'s list, tested under luajit — and honours `Anim.freeze`,
so while a drive script has the clock pinned every tween completes at once
and a screenshot never catches a card halfway in. **Particles** are LÖVE's
own `ParticleSystem` in presets that each mean one thing: `stars` a right
pick, `confetti` a clear, `sparks` a button press, `smoke` and `shards` a
wrong pick, `coins` a node cleared on the map, `embers` a verdict that burned;
`dust` drifts behind the title and the land picker. Bursts are drawn after
the scene so they are always over the thing they came from, and the module
loads with no `love` at all, because the headless suite has to get past
`require("src.fx")`.

**One interface face: Neo둥근모** (`dunggeunmo`), at exactly 16 / 32 / 48 —
label, title, display — with Galmuri11 at 24 for paragraphs and the code face
for code. It is half the width of Press Start 2P, so titles stop wrapping,
and it carries Hangul itself. **F8** cycles the others behind it: Galmuri11,
Comic Mono, ARCADE (Press Start 2P, which stays on the logo whatever is
chosen) and IBM's VGA 8×16. Each is set at its measured multiple of the size
asked for, the web's `UI_FACE_SPEC` number for number, so a swap keeps a
label's height rather than looking like a mistake; Press Start 2P stands
behind whichever is chosen for a glyph it lacks — DOS VGA has no `č`, Comic
Mono no Hangul — and Unifont behind both.

**Fifteen code faces**, the web's, in the web's order: VT323, Iosevka (the
default — VT323's `0` and `O` are the same shape, and this is a game about
reading code), JetBrains Mono, DOS, Neo둥근모 Code, Galmuri Mono, Comic Mono,
Courier New Bold, the three home computers (Apple II's PR Number 3, MSX1,
Amiga Topaz), Victor Mono and its cursive italic, Fantasque Sans Mono and
Monaspace Radon. Each is drawn at the size that matches VT323's apparent size
— measured from cap height and advance, not judged by eye — so a swap never
loses columns. Courier New is the one system face: read from where macOS
keeps it, never shipped, VT323 standing in on a machine without it. LÖVE
reads neither WOFF nor WOFF2, so `assets/fonts/` carries each as TrueType or
OpenType, converted with fontTools and subset to what a code pane holds;
`assets/fonts/CREDITS.txt` says what was subset, what was shipped as it came,
and under which licence. `tests/test_faces.lua` holds both tables to the
web's, number for number, and every face file to a credit beside a licence
that is in the folder; `test_faces_render.lua` opens every file, `.otf`
included, and proves the Courier pane is still a pane on a machine without
Courier New; `test_fonts.lua` draws every language in every face.

### The footer and the settings sheet

**One line, always**: 48 px, 64 upright, drawn by `App:footer`, which every
scene already calls — `tests/test_screens.lua` asserts that every scene does,
so a screen added tomorrow gets it without knowing it exists. Left, `LV n`,
an XP bar and the count (landscape only). Middle, the scene's keys as keycap
and verb, **the longest prefix that fits** — at most four, three upright —
so each scene hands them over in priority order and the key somebody needs
most is first. Right, the connection dot, green when open and red with
OFFLINE otherwise, and the **⚙**. The title card has only the ⚙. **Never in
the footer:** the name, the address, the display controls. What used to be
there — three display buttons, and the name, the address and the level
wrapped onto a second row when they did not fit — was three rows of chrome
on every screen.

The ⚙, or **F9**, opens the settings sheet: WINDOW · ORIENTATION · TYPE SIZE
· LANGUAGE · INTERFACE FACE · CODE FACE · SOUND, and while signed in ACCOUNT
— the name, the short address and COPY — and LOG OUT, in the danger colour.
**Each row says the state it is in, not the state it would move to.** A
toggle whose current value is invisible gets pressed twice: once to find out,
once to put it back. So the rows read `FULL` or `WINDOW`, `LAND`, `PORT` or
`AUTO`, `A 2/4`, `KO`, `DUNGGEUNMO`, `IOSEVKA`, `ON`. Each one does exactly
what its key does — the same `Layout` call, the same toast — so the two
paths cannot drift into meaning different things; the keys are not replaced,
because a key nobody can see is not a feature.

The sheet is drawn from `App:draw` over every scene and hit-tested in
`App:mousepressed` **before** the scene, so a press on it is consumed and
changing the type size can never also open a quest. It takes every key while
it is up; ESC or F9, the close button or a click anywhere outside puts it
away. `tests/drive/typesize.lua` opens and closes it round every click.

### Window and fullscreen

`F`, `F11` or the sheet's **WINDOW** row toggles at any time, from any screen,
**without losing your place** — including mid-snippet with half-written source
in the editor. The virtual canvas is re-measured across the transition and the
scene is not touched.

Fullscreen is **`desktop`** by default: `exclusive` changes the display mode,
and a game that exits badly while in it leaves the desktop rearranged. Set
`CWBH_FULLSCREEN=exclusive` if you want the real thing — the same override the
sibling spells `GOSET_FULLSCREEN`.

**F1 — and the ORIENTATION row — cycles three states, not two.** Landscape
and portrait are *pins*: you asked, so the window's shape does not get a
vote. The third state is automatic, where the orientation follows the window
— which is usually what you want in fullscreen, since the shape there is the
display's and not yours. The sheet always says which one you are in.

### The type

**Roles, in pixels, and the roles never move with F12.** `Theme.type` is
label 16, title 32, display 48, read 24, code 16; `UI.font(role)` is the
interface face at that size whatever F8 chose, and `UI.label` / `UI.read`
draw in it. A header or footer built on roles cannot overprint itself at the
largest step, which is what the old chrome did. **F12 moves two things**:
`UI.readFont()` — Galmuri11 at 24, stepped onto its own 12-pixel grid — and
`Layout.codeSize`, the one place every code pane asks. Four steps, ×0.75,
×1.0, ×1.5 and ×2.0, a cycle rather than a slider, starting on ×1.0 — 24 px
for an authored 10 in every landscape window, and a *tall* canvas grows it
through `Layout.growth` rather than through a bigger default. The ladder
used to be ×1.0 … ×2.5: 2.5 went because it was the step that printed `PICK
A LAND` wider than a portrait canvas, and 0.75 came in under for a player
who wants more on the screen still — the one quarter-step that still lands
on the grid. The store reads an old record's step for what it meant then
(see `display.set`, below).

**The 8-pixel grid is kept where the face is on it.** Press Start 2P is an
8×8 design and GNU Unifont is 8×16; at 9, 10 or 15 px a one-pixel stem lands
on a fraction of a screen pixel and the rasteriser either smears it grey or
drops it — `CausewaybayWallet`'s README says it plainly, *"at 2.5× a
one-pixel line lands on half a screen pixel … and the whole illusion goes"*.
So in ARCADE, and for Unifont behind every face, `Assets.snap8` rounds every
size handed to the rasteriser onto the grid. Another interface face is set at
its measured multiple of the size asked for (`UI_FACE_SPEC.pixel`: 1.25 for
Neo둥근모 and DOS, 1.2 for Comic Mono, 1 for Galmuri), in whole pixels, as the
web does it — snapping that onto Press Start 2P's grid as well would undo the
measurement. Nothing is ever drawn through `love.graphics.scale`.

**The layout is measured from the type, not from constants.** `UI.buttonSize`
sizes every button from its label and its keycap — the label face on a canvas
under 1600 wide, Galmuri at 24 on a wider one — and a button never shrinks
its label, so a row sized from a 16-px label cannot overflow on a 1920
canvas where the label is 24. Content lays out inside `UI.bounded()`, which
centres it past `Theme.maxContentW`; a 1920 canvas gets the same layout
centred, not stretched. Rows are measured with the active face, never with
a constant. `tests/drive/typesize.lua` drives the largest step through the playground's
pane in both orientations and fullscreen and asserts the pane still has rows,
the caret is still on screen, the gutter has not eaten the pane and the
buffer is byte for byte what it was; `typesweep.lua` does the same to the
quiz's four choices.

### Six languages

English, 한국어, 粵語, 简体中文, 日本語, Čeština — **L**, or the LANGUAGE row
of the settings sheet.

The mechanism is `CausewaybayGolang/love2d/src/i18n.lua`'s: translations are
keyed by **the English string**, so a call site reads as the sentence it draws
and a string nobody has translated stays English instead of turning into
`lands.title.pick`. Each language is one file under `src/lang/`.

**The interface only.** The quests are content owned by another part of
this repository, and a quest brief is a specification of a program —
mistranslating one would fail a test for a reason the player cannot see. So a
Korean player gets a Korean interface around an English quest, with the quest
title drawn beside its id in the land's tint, as the identifier it is.

**Technical terms stay in English**: borrow checker, ownership, lifetime,
goroutine, channel, trait, mutex. That is what programmers writing these
languages actually write. Where a translation was a guess it is marked
`UNREVIEWED` in the language file, with what is uncertain about each.

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

Korean is drawn by the interface face itself when it carries Hangul —
Neo둥근모 and Galmuri do, subset to Latin and the 2,350 syllables of
KS X 1001. Everything else, and Korean under DOS or Comic, comes out of
**GNU Unifont**, 5.1 MB, taken whole from `CausewaybayOffice/love2d`: 58,909
glyphs, the entire Basic Multilingual Plane, and a *bitmap* face — 8×16 px
per cell, 16 px for a double-width ideograph — so it is pixel art rather than
a vector face filtered to `nearest` and hoped over. The fallback is per glyph
and the chain is always the chosen face, then Press Start 2P, then Unifont,
attached with `setFallbacks`; Czech comes from the first face in that chain
that has `č ř š ž ů ě`, which keeps a Czech sentence looking like the rest
of the game rather than like a fallback. The alternative, a Noto Sans CJK
subset, is 11.2 MB and has **no Czech diacritics** — it would have made the
four hard languages work and quietly broken the easy one.
`tests/test_fonts.lua` asserts Unifont's advances (ASCII 8, 中 16, 안 16, ř
8, height 16) and that every face, interface and code, can draw every glyph
every language can produce.

Both the fullscreen state, the orientation and the type step are remembered
across restarts, **including whether the orientation was a pin**. A mode
that was merely inferred from last week's window comes back as a starting
guess and is re-derived; a mode you pressed F1 for comes back as a pin. Those
are different things and storing them as the same thing is a real bug — see
`tests/test_display.lua`.

## The server, and where state lives

The server is behind a **SERVER** chip on the login card — TAB onto it, or
click it, and the field opens under it — because the backend can run on
`0.0.0.0` so a phone on the same tailnet can reach it, and an environment
variable is not discoverable from inside a game. Type an address, press
ENTER: it is validated, saved, and the client drops its connection and comes
back on the new one. A bad address says what is wrong (`needs a port`,
`wss:// needs TLS, which this client does not have`) in a red-ruled card
under the phrase, never a toast, rather than failing to connect for
unexplained reasons.

**Precedence:** `CWBH_SERVER` is a launch-time override and wins for that
run; otherwise the saved field; otherwise `ws://127.0.0.1:5390/ws`. Editing
the field always saves — and when an override is active the screen says so,
rather than pretending to apply something it will not.

State lives in **`~/.causewaybaylove2d`** (SPEC §1.1), not in LÖVE's save
directory: `0700` directory, `0600` files, append-only JSONL, state derived by
replaying the log. It holds the session token, the chosen server, where each
map was left, and every choice about how the game looks — and **no key
material, ever**. Each choice is its own record kind, because they are
separate choices and one must not rewrite another:

| record | holds |
| --- | --- |
| `display.set` | orientation, whether it was a pin, fullscreen, the type step — one record, because they are one setting, "how this window is set up" |
| `lang.set` | the language |
| `uiface.set` | the interface face (F8) |
| `face.set` · `theme.set` | the code face, and the code pane's light or dark |
| `computer.set` | the playground's old computer |
| `pgprefs.set` | AUTO-RUN and STDERR, one record for the pair |

`display.set` is written at **`v = 3`**, and the version is bumped when what
a stored number *means* changes, so an old record is read for what it meant
then. v2 moved the default step; v3 moved the whole ladder from
`{ 1.0, 1.5, 2.0, 2.5 }` to `{ 0.75, 1.0, 1.5, 2.0 }`, so a v2 index comes
forward one place to the **same multiplier**, and 2.5 — which no longer
exists — comes back as 2.0, the nearest thing to what was chosen. A record
from before there was a version that says step 2 was almost always nobody's
choice: step 2 was the default, and `Layout.save` wrote the step on every
orientation press whether or not anyone had touched it, so those come
forward to the new default. `pgprefs.set` keeps a stored `false` as `false`
and not as "unset", because AUTO-RUN's whole point is that off is a choice.
`tests/test_store.lua` replays all of it.

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
**LOG OUT** is in the settings sheet, drawn only while signed in: the socket
is closed first, then the token is forgotten here and on disk, then a fresh
anonymous connection is opened for whoever signs in next.

## Testing

```bash
make test-headless   # the codec, JSON, editor, quiz, store and key derivation, no window
make test            # the same suite plus layout, fonts and every scene, under LÖVE
make ffi-test        # the Rust crate
make test-all        # all three
```

The headless run is the important one: `src/json.lua`, `src/net/**`,
`src/editor.lua`, `src/quiz.lua`, `src/computer.lua`, `src/juice.lua`,
`src/wallet.lua`, `src/store.lua`, `src/anim.lua`, `src/clock.lua`,
`src/i18n.lua` and the agent's pure half contain **no reference to `love`**,
so a bare `luajit` can drive the whole protocol, every pick a quiz can take,
every machine's palette, and a hover to rest. `make check-layering` asserts
that with a grep (`LAYERED` in the Makefile is the list), and `T.no_love`
asserts it again from inside the suite — if it ever stops being true, most
of this directory stops being testable. `src/fx.lua` is deliberately *not*
on the list: it may touch `love`, it just must not need it to be required.

This round added `test_quiz`, `test_faces`, `test_juice` and
`test_playground_retro` to the pure half, and `test_artframe`,
`test_faces_render`, `test_header` and `test_quest_ui` to the half that
needs a window.

Against a real server:

```bash
make drive SCRIPT=tests/drive/slice.lua      # milestone 1 end to end: login → quest → clear
make drive SCRIPT=tests/drive/quiz.lua       # the quiz card, before, after a miss, after the right pick
make drive SCRIPT=tests/drive/computer.lua   # the three machines, booting and settled
make drive SCRIPT=tests/drive/loginui.lua    # the login card in every state it has
make shots                                   # every screen, both orientations
```

Each wants `ARGS="--home $(mktemp -d)"`: a token left by an earlier run
resumes a different player, and `quiz.lua`'s wrong pick costs a star on
whichever account it opens. `tests/drive/answer.lua` and `solve.lua` are
gone with the quest editor they drove. Screenshots land in
`~/Library/Application Support/LOVE/causewaybay-hacker`.

## What is where

```
main.lua              the LÖVE callbacks, the global keys, the test/drive switch
conf.lua              window and modules
src/
  app.lua             the shell: one socket, one session, one scene — and the
                      footer, the settings sheet, F8 and F9
  layout.lua          the virtual canvas and the type steps (ported, see the header)
  theme.lua           the tokens: the palette by role, spacing, radius, type, motion
  ui.lua              the components: cards, buttons, chips, keycaps, hints,
                      the modal, the toasts, the footer and the settings sheet
  juice.lua           tweens, springs and the immediate-mode motion — pure
  fx.lua              particles, in presets; loads without love
  artframe.lua        nine-slice frames from art/
  ease.lua crt.lua                              (ported)
  assets.lua sfx.lua  art, the faces, chip audio
  editor.lua          the code editor's model — pure, no love
  codepane.lua        the mouse and the bracket overlay
  quiz.lua            what a pick means, the hole, the streak — pure
  computer.lua        the playground's old computers — pure
  retroscreen.lua     the tube over the editor; retromonitor.lua, the plastic round it
  external.lua        the $EDITOR escape hatch
  wallet.lua          the LuaJIT binding to libcwbh_ffi
  i18n.lua            the six languages; LÖVE-free
  lang/               ko yue zh ja cs, keyed by the English string
  store.lua           ~/.causewaybaylove2d: the token, the server, every look
                      setting and the map cursors — and the one-time move
                      out of the old home
  session.lua         auth, the token, and what a reconnect does
  agent/              the Rust coder; its pure half is in LAYERED
  json.lua            vendored, see the header
  net/
    ws.lua            RFC 6455: handshake strings and the frame codec
    client.lua        envelopes, correlation, keepalive, backoff
    socket.lua        LuaSocket, non-blocking
    runlog.lua        run.log reassembly, by seq, per stream
    errors.lua        §3.3's closed set
    sha1.lua base64.lua bitops.lua
  scenes/             boot title story login lands categories map quest result
                      playground search stats ai  (search and ai are milestone 2 stubs)
ffi/                  the Rust cdylib: bip39 + bip32 + secp256k1 + keccak
tests/                the suite, the fake server, the drive scripts
assets/               placeholder art, per docs/art.md; assets/fonts/ with CREDITS.txt
```

## The art

`art/`, at the root of this repository, holds the generated assets and
`art/manifest.json` in `CausewaybayGolang`'s shape, with a measured `box` on
every sprite so a character stands on her feet. This round added the three
frames (`ui_quiz_card`, `ui_quiz_choice`, `ui_plaque`), the stats and night
backdrops, `bg_flat` and `sprite_clerk` to it. `src/assets.lua` reads that
manifest — `love.filesystem` first, then the real path beside the game — and
**never** runs those files through the magenta knockout: they already carry
binary alpha, and flooding a correctly-cut sprite would eat the padlock off
`node_locked`.

`love2d/assets/` still holds a few files, but the only ones the client
reads from there are the old overworld, `map_bg` and `map_bg_p`, as the
fallback for a land with no map of its own; everything else now comes from
`art/`, cut to alpha. The knockout list is empty and kept on purpose, as the
one place a magenta-screen placeholder would be named, so `knockout` can
never be run on `art/` by accident.

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
