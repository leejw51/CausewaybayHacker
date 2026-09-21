# Causewaybay Hacker — Wire Protocol

**This file is the authority for everything that crosses the network.**
`SPEC.md` §6 summarises it; where the two differ, this file is right.

Three clients speak it — the browser (`frontend/`), the LÖVE desktop client
(`love2d/`), and the test harness (`tests/smoke/`) — against one server
(`backend/`). None of them may assume anything not written here.

---

## 1. Transport

| | |
| --- | --- |
| URL | `ws://127.0.0.1:5390/ws` |
| Subprotocol | none |
| Frames | **text**, UTF-8, exactly one JSON object per frame |
| Compression | none (`permessage-deflate` is not negotiated) |
| Max frame | 4 MiB inbound, server closes with 1009 above it |
| Max nesting | 64 levels; a deeper frame is answered `bad_request` (§3.3) and the connection **stays open** |
| Binary frames | not used; a client that sends one is closed with 1003 |

The same HTTP server also serves the built browser frontend at `/` and the art
at `/art/…`, so there is one port and no CORS. The LÖVE client uses the
websocket only.

### 1.1 Keepalive

The server sends a **websocket ping** frame every 30 seconds. A connection that
fails to answer two consecutive pings is closed with 1001.

Clients whose websocket library does not expose ping/pong (this includes a
hand-rolled Lua one that chooses not to implement it) must instead send the
application-level `ping` message (§4.1) every 20 seconds. The server accepts
either. **A client must not rely on the connection staying open through a
laptop sleep** — see reconnection, §6.

### 1.2 Close codes

| code | meaning |
| --- | --- |
| 1000 | normal; the client asked |
| 1001 | server going away, or keepalive missed |
| 1003 | a binary frame, or a frame that is not a JSON object |
| 1009 | frame too large |
| 4001 | session revoked — re-authenticate from scratch |

A close is never the answer to an application error. Application errors are
`*.err` messages (§3.3) and the connection stays open.

`4001` is defined for clients to handle but not yet emitted by this server,
which has no message that revokes a session out from under a connection.

`1003` means what it says. A frame that is a JSON object but nests deeper than
§1's limit is **not** one of these: it is an object, so closing it 1003 would
be telling the client something untrue. It is answered `bad_request`, and it is
correlated — the server recovers the top-level `id` and `type` from a frame its
JSON parser gave up on, precisely so that a client is not left with a request
that never comes back.

---

The server holds at most **64** open sockets across every address. The next
open is accepted and closed at once with **1013** (try again later); a client
should back off as it does for `rate_limited`.

### 1.3 Origin

A browser does not apply the same-origin rule to opening a websocket, so the
server applies one at the upgrade. With no `Origin` header (the LÖVE client,
`cwbh`) the socket opens. With one, its authority has to equal the `Host` the
request came in on — the page the server itself served, at whatever address
it was reached on — or its host has to be loopback (`127.0.0.1`, `localhost`,
`::1`) on any port, which is the vite dev server. Anything else, `null`
included, is answered **403** before the upgrade. Without this any page the
player had open could reach `ws://127.0.0.1:5390` and, login being open
registration (§3), run code on the machine.

## 2. The envelope

**Every frame in both directions is an object with exactly these four keys:**

```json
{ "v": 1, "id": "c-42", "type": "quest.submit", "payload": {} }
```

| key | type | rule |
| --- | --- | --- |
| `v` | integer | protocol version. Currently `1`. Always present. |
| `id` | string \| null | correlation (§2.2). `null` on server-initiated events. |
| `type` | string | dotted lowercase (§2.3). |
| `payload` | object | **always an object**, never a bare value, never absent. Use `{}`. |

No other top-level keys. A frame carrying one is answered `bad_request`; the
server does not silently ignore fields, because a silently ignored field is how
a client ships a bug that looks like it works.

### 2.1 Versioning

A frame whose `v` the server does not know is answered with a `proto_version`
error **and the connection stays open**, so a client can discover it is too old
and say so to the player rather than dying. The error `detail` carries
`{"supported": [1]}`.

Adding an optional field to a payload, or a new message type, is **not** a
version bump. Removing a field, changing its type, or changing the meaning of
an existing one, is.

### 2.2 Correlation

* A client-initiated request carries `id`: a string unique for the life of the
  connection. The convention is `"c-" + a counter` (`c-1`, `c-2`, …). Any
  unique string is legal; the server treats it as opaque.
* The server's reply carries **the same `id`**.
* A server-initiated event carries `id: null`. A client must never try to
  correlate one.
* The server may answer requests **out of order**. A client that assumes
  replies arrive in the order it sent them is wrong — `quest.submit` takes
  seconds and a `ping` sent after it will come back first. Match on `id`.
* Reusing an `id` that is still in flight is `bad_request`.

### 2.3 Type naming

`namespace.verb`, lowercase, dot-separated. A reply is the request type with a
suffix:

```
client →  quest.submit
server ←  quest.submit.ok      on success
server ←  quest.submit.err     on failure
```

Server-initiated events have no suffix and no `.ok`/`.err` form: `run.log`,
`progress.update`.

A client must ignore an unknown `type` rather than erroring or closing. That is
what lets the server add events without breaking an old client.

### 2.4 Conventions inside payloads

* Timestamps: RFC3339 UTC with seconds — `"2026-09-11T04:12:33Z"`.
* Durations: integer milliseconds, key suffixed `_ms`.
* Addresses: **EIP-55 checksummed** on the wire, in both directions. The server
  lowercases internally (SPEC §3.4); clients display what they are given.
* Bytes: lowercase hex, `0x`-prefixed only where it is an Ethereum-style value
  (address, private key, signature). Nonces are bare hex.
* Absent vs. null: an optional field is **omitted**, not sent as `null`, unless
  `null` is a meaningful value (`id`, `time_limit_s`, `code`).

---

## 3. Connection lifecycle

### 3.1 The states

```
        connect
           │
           ▼
     ┌───────────┐  auth.login / auth.resume ok   ┌──────────────┐
     │ ANONYMOUS │ ──────────────────────────────▶│ AUTHENTICATED │
     └───────────┘                                 └──────────────┘
           │                                              │
           │ only ping / auth.challenge /                 │ everything
           │ auth.login / auth.resume allowed             │
           │ (anything else → unauthorized)               │
           ▼                                              ▼
        close                                          close
```

A connection starts **ANONYMOUS**. In that state exactly four messages are
accepted — `ping`, `auth.challenge`, `auth.login`, `auth.resume`. Everything
else is answered `unauthorized` and the connection stays open.

A connection never goes back to ANONYMOUS. To change user, open a new one.

### 3.2 Concurrency

* One **in-flight `quest.submit` per connection**. A second while the first is
  running is answered `busy`. This is per connection, not per user: the same
  wallet open in two windows gets two slots, and the server serialises the
  compiler behind them.
* Every other request may be pipelined freely.
* The server processes requests concurrently and replies as they finish (§2.2).

### 3.3 Errors

An `.err` payload is **always** this shape, with no extra keys:

```json
{
  "code": "locked",
  "message": "rust.basic.04.slices is locked",
  "detail": { "requires": ["rust.basic.03.shadowing"] }
}
```

`message` is English, one line, for a log or a developer — **not** for the
player. A client renders its own text from `code`. `detail` is always present,
`{}` when there is nothing to add.

`code` is a **closed set**. A client may switch on it exhaustively:

| code | meaning | client should |
| --- | --- | --- |
| `proto_version` | `v` not supported | tell the player to update; stop |
| `bad_request` | malformed frame or payload | a bug; log it loudly |
| `unauthorized` | sent before authenticating | go to the login screen |
| `auth_expired` | the challenge's `expires_at` passed | start `auth.challenge` again |
| `auth_nonce_used` | that nonce was already spent | start `auth.challenge` again |
| `auth_bad_signature` | recovery did not match the address | the key is wrong; re-prompt |
| `not_found` | no such quest / drill / attempt | refresh the map |
| `locked` | *(not emitted — every node is playable, §4.7)* | — |
| `rate_limited` | too many requests | back off; `detail.retry_after_ms` |
| `busy` | a submission is already in flight | disable the submit button |
| `unavailable` | real, but not built yet | say so in the story's voice; `detail.milestone` |
| `internal` | the server broke | show a retry; log `detail.trace_id` |

A code not in this table is a server bug. A client encountering one should
treat it as `internal`. That rule is also what makes this set safely
extensible: a code added later degrades in an old client to exactly the
behaviour it has today.

**`unavailable` is not `internal`.** A feature that is real, specified and
merely unbuilt — the GO land before its runner exists, `search.query` before
its index does — answers `unavailable` with `detail.milestone`, and a client
says *"the GO land opens in the next chapter"*. Reporting it as `internal`
tells the player their machine is broken and invites them to retry something
that will never work.

An `unavailable` request must also leave **no trace in the player's record**.
A Go submission the server cannot judge must not write an `attempt` row: an
attempt with a fabricated verdict lands in `mistakes` and then in the AI
drills, and the player is taught to fix a mistake they did not make. The
curriculum is built from this table, so what goes into it has to be true.

---

## 4. Message catalogue

Every message below shows the request payload and the `.ok` payload. Any of
them can also come back as `.err` with §3.3's shape.

### 4.1 `ping`

Allowed in any state. The application-level keepalive and the round-trip timer.

```json
→ { "v":1, "id":"c-1", "type":"ping",    "payload":{} }
← { "v":1, "id":"c-1", "type":"ping.ok", "payload":{ "t":"2026-09-11T04:12:33Z" } }
```

### 4.2 `auth.challenge`

Ask for something to sign. Does not create a user.

```json
→ payload: { "address": "0xAbC1…" }        EIP-55 or any case; server normalises

← payload: {
    "nonce":      "9f3c…64 hex chars",
    "message":    "Causewaybay Hacker login\naddress: 0xAbC1…\nnonce: 9f3c…\nexpires: 2026-09-11T04:14:33Z",
    "expires_at": "2026-09-11T04:14:33Z"
  }
```

**Sign `message` byte-for-byte as given.** Do not reconstruct it from the parts
— a client that rebuilds the string will disagree with the server about a
space and fail signature verification for reasons that take a day to find.

The message is four lines, `\n`-separated, no trailing newline:

```
Causewaybay Hacker login
address: <EIP-55 address>
nonce: <64 lowercase hex>
expires: <RFC3339 UTC>
```

Nonces live in server memory, are single-use, and expire 120 seconds out.
Asking again invalidates nothing: several challenges may be outstanding.

### 4.3 `auth.login`

```json
→ payload: {
    "address":   "0xAbC1…",
    "signature": "0x" + 130 hex,        r || s || v, 65 bytes
    "name":      "ferris",              optional, only used when creating
    "nonce":     "3f1a…"                optional; test harnesses only
  }

There is **no required `nonce` field**: the server matches the newest live
challenge for that address, so the normal flow is one `auth.challenge`, sign,
one `auth.login`. A harness that deliberately holds several challenges open at
once can pin one with the optional `nonce`.

← payload: {
    "token": "base64url, 43 chars",
    "user":  User,                       §5.1
    "formats": ["rust","go"]             the lands whose FORMAT works here
  }
```

The signature is over the **EIP-191 personal-sign digest** of the §4.2 message:

```
digest = keccak256( "\x19Ethereum Signed Message:\n" + len(message) + message )
```

`len` is the byte length in ASCII decimal. `v` is 27 or 28 (0 or 1 is also
accepted and normalised), and the `0x` prefix is optional. The server recovers
the address with secp256k1 and compares it case-insensitively to `address`; a
mismatch is `auth_bad_signature`.

> **Byte order, because it has already cost this project time.** The signature
> is `r || s || v` — 32 bytes, 32 bytes, 1 byte. Several libraries hand you the
> recovery id *first*: `@noble/curves` v2's
> `secp256k1.sign(digest, key, {format: "recovered"})` returns `[recid, r, s]`.
> Concatenating that as-is produces a well-formed signature that recovers a
> completely different address, and the server can only tell you
> `auth_bad_signature`. Move the byte and add 27.

> **The mnemonic and the private key never appear in this protocol.** There is
> no field for them and there will never be one. A client that transmits key
> material is broken, localhost or not.

On first login for an address the user is created. `name` seeds the display
name; if omitted the server assigns `hacker-<first 6 of address>`. Names are
free-form and **not unique** — the address is the identity.

The reply also carries **`position`** — a `Position` (§5.13), or `null` for a
player who has never been anywhere. This is SPEC §1.3: the client keeps the
session and nothing else durable, so the land, category and stage come back
with the login, from whichever client the player used last. `auth.resume`
(§4.4) carries it too, so a reconnect mid-session does not have to be told
again. A client that has been handed `null` chooses for itself; it must not
read that as "rust".

### 4.4 `auth.resume`

Trade a stored session token for an authenticated connection, without touching
the key material. This is what lets a client hold the key in memory only and
forget it on reload.

```json
→ payload: { "token": "…" }
← payload: { "token": "…", "user": User, "formats": ["rust","go"] }
```

`formats` is the set of lands whose FORMAT this server can actually run:
`rustfmt` and `gofmt` ship with their toolchains, while `clang-format` and
`black` are asked of the machine. A client draws the button from this list —
a button that always refuses is worse than no button. An older server omits
the field; then a client may show the button and let the error speak.

The returned token may differ from the one sent — the server rotates on use.
**Store the returned one.** An expired or unknown token is `unauthorized`.

Sessions last 30 days, refreshed on every use.

### 4.5 `profile.update`

```json
→ payload: { "name": "ferris", "settings": { "orientation": "portrait" } }   both optional
← payload: { "user": User }
```

`settings` is an opaque JSON object the server stores and returns untouched.
It is client-owned; the server never reads inside it. A partial `settings`
**replaces** the whole object — read-modify-write.

### 4.6 `world.lands`

The land/category select screen.

```json
→ payload: {}
← payload: {
    "lands": [
      { "land": "rust",
        "categories": [
          { "category": "basic",    "total": 12, "cleared": 3, "stars": 7,  "open": true  },
          { "category": "advanced", "total": 10, "cleared": 0, "stars": 0,  "open": false },
          { "category": "hacker",   "total": 8,  "cleared": 0, "stars": 0,  "open": false }
        ] },
      { "land": "go", "categories": [ … ] }
    ]
  }
```

`open` is false when the category's first node is still locked.

### 4.7 `world.map`

One overworld.

```json
→ payload: { "land": "rust", "category": "basic", "locale": "ko" }     locale optional
← payload: {
    "land": "rust", "category": "basic",
    "nodes": [ MapNode, … ],              §5.2, ordered by node
    "edges": [ ["rust.basic.01.hello", "rust.basic.02.bindings"], … ],
    "cleared": 12, "total": 27,           how far along this road the player is
    "stars": 31, "stars_total": 81        — counted by the server, not the client
  }
```

`edges` are the paths the map draws, derived from `requires`. They are given
explicitly so a client never has to infer the overworld's shape.

`locale` is the client's UI language, and it is optional. Where a translation
of a quest exists in that language (SPEC §12.1) its `MapNode.title` is the
translated one and `MapNode.text_locale` names the language; everywhere else
the title is the English and `text_locale` is `"en"`. It is per node, not per
map, because a translation may cover a pack partially. A `locale` the server
has no packs for — `"xx"`, `"en"`, an empty string — means English, never an
error: a client's language is its own business.

**Every node is playable. Nothing is locked.** `requires` and `edges` describe
the *suggested* route — the order the content was written to be learned in, and
the line the map draws — and a client should still show it, because "where do I
go next" is a real question. But a player may enter any node at any time, and
the server never refuses one on the grounds that an earlier node is unfinished.

This is a trainer, not a platformer. Somebody with an interview on Thursday
needs to open the dynamic-programming street on Tuesday without grinding
through eighteen quests about `&str` first, and somebody who already knows Go
should not have to prove it to reach the concurrency map. The map's shape is
advice; the player decides.

`locked` remains in §3.3's closed set and is no longer emitted. It stays
because removing a code from a closed set is the one change that breaks an
exhaustive client, and because a future mode may want it.

### 4.7b `world.reset`

```json
→ payload: { "land": "go", "category": "verybasic" }
← payload: { "land": "go", "category": "verybasic", "reset": 27,
             "cleared": 0, "total": 27, "stars": 0, "stars_total": 81 }
```

Walk one road again from the start: every quest of that land and category
goes back to untouched for this player — no stamp, no stars, no attempt
count, no clock. `reset` is how many rows were cleared, and the four totals
are the road's progress afterwards, so a client redraws without asking again.

What goes back to untouched includes **what the editor opens on**: every
node of the road loses its undo stack (§4.11c), and `Quest.draft` (§4.8) stops
reporting the attempts from before the reset, so a reset node opens on its
`starter`. A road whose stamps were cleared and whose editors still held the
code that earned them would be a reset in the map's eyes only.

What it does **not** touch is anything that is a record rather than a state:
the attempt log and the mistakes (SPEC §7's training data, which the server
never deletes) and the XP ledger. The attempts from before the reset are still
there, still in `stats.history`, and still the curriculum — the draft is
*gated* on the reset's date, not deleted. A clear after a reset therefore
**pays no XP** — the `clear` row is already in the ledger and the index
refuses the second — while practice grants keep working. Practising is free;
farming is not possible.

Stars are counted from the failures *since* the reset, so a road walked
again can be walked perfectly.

A land or category no pack defines is `not_found`. A player who had never
touched the road gets `reset: 0`, which is not an error. A quest they have
only ever pressed RUN on counts as touched and is reset with the rest — it has
no stamp to clear, but it does have a draft to take back.

### 4.8 `quest.get`

```json
→ payload: { "quest_id": "rust.basic.03.shadowing", "locale": "ko" }   locale optional
← payload: { "quest": Quest }             §5.3
```

`Quest.solution` is **omitted
entirely** unless the player has cleared it — not sent as null, not sent
empty.

**`locale`** works as it does on `world.map`: when a translation of this quest
exists in that language, `title`, `story`, `brief` and the hints `quest.hint`
will hand out are in it, and `Quest.text_locale` says so; otherwise the English
goes out and `text_locale` is `"en"`. The code — `starter`, `solution`,
`tests` — is the same in every language, because the program the player must
write is the same program. A client compares `text_locale` with the language
it is showing and, when they differ, tells the player the brief is in English
rather than letting it read as a translation somebody abandoned. `ai.next`
(§4.16) takes the same field, since it opens the same screen.

**`Quest.draft`** is the source of the player's own most recent attempt at
this quest — a run or a submit, either counts — or `null` on a quest nobody
has touched yet, and on one whose road has been reset since (§4.7b) and not
attempted again. This is not a new save path: SPEC §2.2 already keeps every
attempt's source verbatim, so a draft is a read of data the server already
had, not a second copy of it. A client opens the editor on `draft ?? starter`,
and a player who typed for ten minutes, closed the tab, and came back finds
exactly what they left — without ever having pressed a save button. `null`
under an interview (§4.9e), for the same reason hints and the solution are: a
live screen starts from the starter.

There is **no `tests.cases` field on a `Quest`** — that name belongs to the
content pack (SPEC §12), not to the wire. What a client receives is
`tests.visible`, an array of the cases marked `visible: true` with their
`stdin` and `expect`, plus `tests.hidden_count`, an integer. The hidden cases'
data never crosses the wire in any form. See §5.3 for the exact shape, and
build the quest screen's test list from `tests.visible` — a client that reads
`tests.cases` gets `nil` and renders an empty list, which looks like a quest
with no tests rather than like a bug.

### 4.9 `quest.submit`

The main event.

```json
→ payload: {
    "quest_id": "rust.basic.03.shadowing",
    "lang":     "rust",                   must match the quest's land
    "source":   "fn main() { … }"
  }
← payload: { "attempt": Attempt,          §5.4
             "xp": XpGain }               §5.1b
```

`xp` is what this submit was worth and where it leaves the player: `gained`
is the clear's XP on a **first clear**, a fifth of it (never under 5) on a
**re-clear** — practice, paid at most ten times per quest (`0018_practice.sql`)
— and `0` on a run or a failure; `total`, `level`, `into_level`, `for_next`
and `level_up` are the ledger's reading after the grant, so the screen and the
record cannot disagree. The grant is written to the server's XP ledger in the
same transaction as the clear (SPEC §2; `0016_xp.sql`).

While it runs the server pushes `run.stage` and `run.log` events (§4.17,
§4.18) carrying the same `attempt_id` that the final `Attempt` will have. The
reply arrives when judging is finished, correlated by the request's `id`.

`.err` cases: `busy` (one already in flight), `locked`, `not_found`,
`rate_limited`, `bad_request` (source over 256 KiB, or `lang` disagreeing with
the quest).

A submission is **always recorded**, including a compile error, including a
timeout. That is the curriculum (SPEC §7).

### 4.8b The clock

A `hacker` quest carries `time_limit_s` — the player's clock, not the runner's
(SPEC §12). **The server owns it**, not the client.

The first `quest.get` for a timed quest stamps `opened_at` and returns it with
`deadline_at`. Every later `quest.get` for the same quest returns **the same
pair**, so a reload, a reconnect, or opening the quest in a second window shows
one clock rather than a fresh one. `quest.reset` does not restart it — resetting
the editor is not a new attempt at the interview.

`Attempt` gains `within_limit: boolean | null` — `null` on an untimed quest,
otherwise whether the **submit** arrived before `deadline_at`. A run never
changes it.

**The clock does not block anything.** Time runs out and the quest stays open,
the countdown keeps going, and a submit after the deadline is judged exactly as
one before it — it simply is not `within_limit`. This is a trainer: stopping
someone mid-thought teaches them nothing, and the fact worth recording is
whether they *would* have finished in time, which is exactly what the flag says.

It is server-owned for one reason. A client-side timer cannot support a claim
like "cleared inside the limit" — a page reload would reset it and the claim
would mean nothing. A fact the game asserts about a player has to be one the
game actually knows.

### 4.9b `quest.run`

The same shape as `quest.submit`, and deliberately so — a client should be able
to send either through one code path.

```json
→ payload: { "quest_id": "…", "lang": "rust", "source": "fn main() { … }" }
← payload: { "attempt": Attempt }        with `mode: "run"`
```

**What differs from a submit**, and all of it follows from one idea — *a run is
for the player, a submit is for the record*:

* Only the **visible** cases run. `tests_total` counts those, and
  `hidden_count` is untouched. A run cannot tell you whether the hidden cases
  pass, because that is what submitting is for.
* It **never clears a node**, never awards stars, never unlocks anything.
  `cleared` is always `false` and no `progress.update` follows.
* It does not count against the node's `attempts`, and it is excluded from
  `stats.summary.accuracy` — otherwise iterating honestly would look like
  failing repeatedly.
* `run.stage` and `run.log` stream exactly as they do for a submit.

**What is the same, and this is the part worth getting right:** a run is still
recorded, with `mode: "run"`, and **its mistakes still enter the curriculum**.
A borrow-checker error is the same lesson whether the player pressed RUN or
SUBMIT, and the errors made while iterating are the truest record of what they
are actually struggling with. SPEC §7 builds the drills from that table, so
throwing runs away would mean training on the tidied-up version of the player's
week.

Runs and submits share the one-execution-per-connection rule (§3.2): a second
of either while one is in flight is `busy`.

### 4.9c The playground

A scratchpad. No quest, no tests, no verdict — you write whatever you like in
Rust or Go, run it, and it prints what it prints.

```json
→ playground.run  payload: { "lang": "rust", "source": "fn main(){…}", "stdin": "3\n" }
← payload: { "run": PlaygroundRun }      §5.9
```

`run.stage` and `run.log` stream as they do for a quest, under the same
`attempt_id` field (the id is still minted, so a client can correlate the
stream; it simply is not stored).

**A playground run is not recorded and does not feed the curriculum.** No
`attempts` row, no `mistakes` row, no effect on `progress`, `stars` or
`accuracy`.

This is deliberately the *opposite* of the RUN/SUBMIT rule in §4.9b, and the
difference is worth stating because it looks inconsistent until you see it: a
quest RUN is an attempt at a known problem, so its errors say something about
what the player cannot yet do, and SPEC §7's drills reach them through the
quest's `concepts`. A playground has no quest and therefore no concepts — a
`mistakes` row from it could never be joined to anything and would be dead
weight in the table the whole curriculum is derived from. It is also where
somebody *deliberately* writes something broken to see what the compiler says,
which is the last thing that should be counted against them.

The limits in SPEC §5.3 apply unchanged — the playground is the same runner.

**Snippets** are saved per user, server-side, so the same scratchpad opens in
the browser and in the LÖVE client.

```json
→ playground.save  payload: { "id": "pg_…", "name": "borrow ideas", "lang": "rust", "source": "…" }
← payload: { "snippet": Snippet }
```

`id` omitted creates one; `name` omitted on create is assigned from the date.
`playground.save` is what a client calls on an autosave timer, so it must be
cheap and idempotent: saving identical content returns the same
`updated_at` rather than churning a new version.

**The other three**, documented here because they shipped before this section
described them — a client had to discover their shapes by probing, which is
not how a contract should work:

```json
→ playground.list    { }                  ← { "snippets": [ SnippetBrief, … ] }   newest first
→ playground.load    { "id": "pg_…" }     ← { "snippet": Snippet }
→ playground.delete  { "id": "pg_…" }     ← { }
```

**Another player's snippet id answers `not_found`, never `unauthorized`** —
whether an id exists at all is none of that user's business, and the two codes
together would let someone enumerate what other people have saved.

Caps are per user and both refusals name the limit: **64 snippets, 256 KiB
each** — the same ceiling as a submission, because it is the same question
("a source file this server will take") asked twice.

### 4.9d `code.format`

Run the language's own formatter over the source and hand it back. `rustfmt`
for Rust, `gofmt` for Go, `clang-format` for C++, `black` for Python — the
tools the player's colleagues would use, not a house style invented here.
**All four run on the server**; no client formats anything itself.

Two of them ship with their toolchain and two are asked of the machine:
`clang-format` is looked for on `PATH` and then through `xcrun --find`, which
is where macOS keeps it (Xcode's command line tools ship one, and it is not
on `PATH` — a server that only checked `PATH` reported "no C++ formatter"
while holding one), and `black` is run as `python3 -m black`. Which lands can
be formatted is therefore a fact about the machine: the server prints it at
boot with the command that installs whatever is missing, `cwbhacker doctor`
prints the same list, and `auth.login` / `auth.resume` carry it as `formats`
(§4.3) so a client draws the button only where it works. A `code.format` for
a language this server cannot format is answered with an `.err`, never with
the source handed back untouched as if it had been looked at.

```json
→ payload: { "lang": "rust", "source": "fn main(){let x=1;}" }
← payload: { "source": "fn main() {\n    let x = 1;\n}\n", "changed": true }
```

Usable from a quest screen and from the playground. It is **never recorded** —
no attempt, no mistake, no effect on anything. Formatting is not an attempt at
the problem.

**Source that does not parse is not an error.** A formatter is most often
pressed in the middle of an edit, and half-written code is the normal state of
a text editor, not a fault:

```json
← payload: { "source": "<the original, byte for byte>", "changed": false,
             "problem": "this file contains an unclosed delimiter" }
```

The reply is `.ok`, the source comes back **untouched**, and `problem` carries
the formatter's own one-line complaint. A client shows it quietly and leaves
the buffer alone. It must never return partially formatted text — a formatter
that mangles code it could not parse is worse than no formatter, because the
player then has two problems.

`changed` is false when the source was already formatted, so a client can say
"already tidy" rather than flashing an identical buffer at somebody.

The runner's limits apply: a formatter gets a short timeout of its own, and a
source over the submit cap is refused the same way.

### 4.9f The chatroom

Every playground snippet has a chatroom: the transcript of the AI coder's
conversation about that pad (docs/agent.md). **The model is called from the
browser, with the player's own key; the server never sees a key and never
makes a model call.** What the server keeps is the room — the messages, the
photos and a search index over them — per entry, per user, scoped by the
session's address exactly as the snippet is. Another player's snippet id
answers `not_found` on every one of the four, never `unauthorized`.

```json
→ playground.chat.list    { "id": "pg_…", "limit": 200, "after": 0 }   limit default 200, max 500
← { "messages": [ ChatMessage, … ] }                                oldest first

→ playground.chat.sync    { "after": 1758100000000, "limit": 200 }   limit default 200, max 500
← { "messages": [ ChatMessage, … ], "head": 1758100123456, "more": false }

→ playground.chat.post    { "id": "pg_…", "role": "user", "text": "…",
                            "image_b64": "…", "image_type": "image/png",
                            "provider": "openai", "model": "gpt-4.1" }
← { "message": ChatMessage }

→ playground.chat.edit    { "message_id": 42, "text": "…" }
← { "message": ChatMessage }                                        same id, new timeid, edited: true

→ playground.chat.delete  { "message_id": 42 }
← { "message": ChatMessage }                                        same id, new timeid, deleted: true

→ playground.chat.clear   { "id": "pg_…" }
← { "id": "pg_…", "cleared": 2 }

→ playground.chat.search  { "q": "borrow", "id": "pg_…", "mode": "unified", "limit": 20 }
← { "hits": [ ChatHit, … ], "mode": "unified", "took_ms": 3 }
```

`role` is `user`, `agent` or `tool`. `text`, `provider` and `model` are
optional; a post needs text or an image. `image_b64` present makes the row
`kind: "image"` and `text` is then the prompt that made it; `image_type` must
come with it and is one of `image/png`, `image/jpeg`, `image/webp`. The
decoded image is at most **3 MiB** (the websocket frame is 4 MiB), a message
at most 64 KiB, and a room holds at most **500 messages** — past that a post
is `bad_request` naming the limit, and CLEAR is the remedy. `list` with a
`limit` keeps the *newest* that many, still oldest first.

**Two int64s on every message.** `id` is the identity — SQLite's own, never
reused; it names the row, the photo file and the photo URL. `timeid` is the
sync cursor: milliseconds since the epoch at post time, or one past the last
`timeid` handed out when the clock has not moved on, so it is **strictly
increasing across every room this server has** (two posts in one
millisecond, a clock that stepped back, and a cleared room all still land
past everything any client has seen — the last value lives in its own
`chat_clock` row, not in the messages). 0 is never handed out: it is the "I
have received nothing" cursor. Both stay under 2^53, so a JavaScript client
holds them exactly.

**Sync** is one question: "what came after the last `timeid` I saw?"
`list` takes `after` for one room. `sync` takes it for *every* room of this
player at once — oldest first, at most `limit`, `more` says whether another
page is waiting, `head` is the newest `timeid` they have (0 with none) so a
client that only wants the future can start there. The cursor is exclusive:
a client folds each page, takes `max(cursor, timeid)` over what it received,
and asks again until `more` is false. Messages are folded by `id` (an id
seen twice replaces the copy held), so a page replayed is harmless. A
cleared room sends nothing on its own; a client that was told
`playground.chat.clear` succeeded drops its copy of that room.

**Edit and delete are changes to the same id**, the way a messenger does
them. `edit` keeps the row, replaces its text, sets `edited` and gives it a
new `timeid`, so a client past the original receives it and folds it over
the copy it holds; text rows only, never a tombstone, `bad_request`
otherwise. `delete` keeps the row as a tombstone — `deleted: true`, the
text scrubbed, the photo gone from disk and from the web, the vector gone
— with a new `timeid`, so a client past the original hears about it and
drops its copy. A room read from the start (`after` absent or 0) never
shows a tombstone; a cursor always receives one. Deleting a tombstone again
answers the same tombstone. A message that is not the caller's answers
`not_found`, on both, as everything in the room does.

`search` is BM25 over the messages' text and cosine over their vectors with
the live embedder, fused by RRF exactly as §4.12 does for quests; `mode`
takes the same three values and defaults to `unified`. `id` narrows to one
room; without it, every room of this user. An empty `q` returns no hits.

**Photos are fetched, not pushed.** A picture can be most of a frame, so an
image row carries a `photo_url`:

```
GET /photos/{message_id}/{token}.{ext}
```

served with its own content-type and `Cache-Control: private, max-age=31536000`.
The token is 32 random hex minted at post time and handed only to the owner
over the socket; the file is looked up by message id *and* token, so a wrong
token, a wrong extension and an unknown id are the same `404`. There is no
other HTTP auth in this server (SPEC §3.5 describes a single-trusted-user
trainer), and an unguessable capability URL is the honest fit. Clearing the
room, or deleting the pad, retires every URL under it.

On disk the room is the snippet folder's `chat.jsonl` (one JSON object per
message, appended on post, removed on clear) and `photos/<message_id>.<ext>`
(SPEC §1). Deleting the snippet removes the folder as it always has.

### 4.10 `quest.hint`

```json
→ payload: { "quest_id": "…", "index": 0, "locale": "ko" }      0-based; locale optional
← payload: { "hint": "…", "index": 0, "total": 2, "hints_used": 1 }
```

Taking a hint costs stars (SPEC §6.3) and is permanent. Re-requesting a hint
already taken does not cost again. `not_found` when `index` is past `total`.

`locale` selects the language of `hint`, on the same terms as §4.8. It is the
same `index` into an array of the same length — the importer refuses a
translation whose hint count differs from the English — so a hint paid for in
one language is the same hint, free, in another.

### 4.11b `quest.solve`

The whole answer, for a player who wants to read a worked example rather than
keep guessing. Priced like the largest hint there is, because it is at least
that much help:

```json
→ payload: { "quest_id": "…" }
← payload: { "source": "fn main() { … }", "hints_used": 2 }
```

`source` is the quest's own reference solution — the same text that would be
attached to `Quest.solution` if the player cleared it honestly. Calling this
sets `hints_used` to at least one (in practice, to the quest's own hint count),
so **a submission of the revealed answer can never earn a perfect, three-star
clear** — SPEC §6.3's star cascade only ever checks whether any hint was used,
and this counts as the biggest one there is.

**Nothing is recorded by asking.** Unlike `quest.hint`, this does not append to
`stats.history` — there is no attempt here, because reading an answer is not a
run of one. Only a later, real `quest.submit` writes anything to the record,
and it writes what actually happened: the player's own keystrokes, whatever
they turned out to be, with the diminished stars this call already priced in.

`not_found` under an interview, for the same reason `quest.hint` is: a live
screen does not come with an answer key.

### 4.9e Interview mode

The point of this project, in one screen: **a live coding screen, simulated.**
Everything else in the game teaches a topic. This rehearses the hour.

A live screen is not "solve a problem". It is: read a statement under time
pressure, **say what you are going to do and why before you do it**, write it
while somebody watches, and answer for the result. The game has had the clock
since §4.8b and the problems since the content packs. What it has never had is
the half that is not typing — and that is the half that fails most candidates.

```json
→ interview.start     { "land": "rust", "category": "hacker" }
← payload: { "session": InterviewSession }
```

The server picks a quest the player has **not cleared**, starts the clock, and
withholds `solution` and `hints` **for the whole session** — even if the player
cleared it long ago, and even after time runs out. A screen does not come with
hints.

```json
→ interview.approach  { "session_id": "int_…", "text": "sort by end, greedy…" }
← payload: { "session": InterviewSession }    with `approach_at` stamped
```

**The approach is written before the editor unlocks, and it is the feature.**
A few sentences: what you are going to do, and what it costs. It is kept, it is
**never graded by the server**, and it comes back at the end beside what the
reference answer actually does, so the player can see whether they said the
thing they then wrote. Rehearsing that sentence is the point; scoring it would
be inventing a judgement the server cannot make.

```json
→ interview.finish    { "session_id": "int_…" }
← payload: { "report": InterviewReport }
```

**The rules that make it an interview rather than a quest wearing a hat:**

* **No hints, for the session.** Not rate-limited — absent.
* **RUN still works.** Candidates run code on a real screen. What they do not
  get is the hidden cases, and they do not get them here either.
* **The clock does not stop you** (§4.8b) — it records. Running out is
  information, not a wall; a trainer that locks you out at the buzzer teaches
  panic rather than finishing.
* **`interview.finish` is the only way to end it**, and the report is the
  product: time against the limit, the approach you wrote, what the reference
  does, your attempts, and the mistakes you made getting there.
* One live session per player. Starting another finishes the first.

Sessions write ordinary `attempts` rows (`mode: "submit"`), so everything in
SPEC §7 still learns from them. An interview you walked out of is still a thing
that happened.

### 4.11 `quest.reset`

```json
→ payload: { "quest_id": "…" }
← payload: { "starter": "fn main() { … }" }
```

Gives back the starter code. **Does not** touch progress, attempts, stars or
hints — it is an editor convenience, not an undo.

### 4.11c The edit stack

`quest.reset` above says plainly that it is not an undo. This is the undo: one
stack per `(player, quest)`, held on the server, so it survives a reload and is
the same stack in the browser and in the LÖVE client. Five messages, all
requiring auth, all naming a quest:

| type | payload | `.ok` payload |
| --- | --- | --- |
| `edit.state` | `{quest_id}` | `EditState` — §5.12 |
| `edit.push` | `{quest_id, source}` | `EditState` |
| `edit.undo` | `{quest_id}` | `EditState` |
| `edit.redo` | `{quest_id}` | `EditState` |
| `edit.clear` | `{quest_id}` | `EditState` |

```json
→ edit.push  payload: { "quest_id":"rust.basic.03.shadowing", "source":"fn main(){ … }" }
← payload: { "quest_id":"rust.basic.03.shadowing", "source":"fn main(){ … }",
             "cursor":4, "depth":4, "can_undo":true, "can_redo":false }

→ edit.undo  payload: { "quest_id":"rust.basic.03.shadowing" }
← payload: { "quest_id":"rust.basic.03.shadowing", "source":"<the text before that push>",
             "cursor":3, "depth":4, "can_undo":true, "can_redo":true }
```

**The reply payload *is* the `EditState`**, not a wrapper around one, and all
five return the whole of it as it stands after the operation. A client
therefore never keeps a model of the stack that it could be wrong about — it
renders what it is told. The state names its own `quest_id` as a convenience
rather than as the correlation mechanism — that is the envelope's `id` (§2.2) —
so a client holding two open editors can route a reply without consulting its
own table of requests in flight.

**It is one list with a cursor, not an undo stack and a redo stack.**

```
entries:  [e1, e2, e3, e4, e5]      depth 5
cursor:             ^ 3             source = e3, can_undo, can_redo
```

`cursor` is how many entries are applied, the current source is
`entries[cursor - 1]`, and `cursor == 0` is the quest's starter — which is why
`source` is nullable rather than carrying a copy of the starter the client
already has. Undo and redo move the cursor and touch nothing else. Two stacks
would mean shifting entries from one to the other on every operation, and an
invariant the code has to keep; one list and an integer is a row order plus a
number, which is exactly the pair that survives a restart — restored, not
approximated.

**A push after an undo drops the redo tail.** `edit.push` truncates everything
above the cursor before it appends, which is what every editor the player has
ever used does. The reason is worth stating rather than assuming: an entry
above the cursor describes a future that the new edit has just replaced, and
keeping it would let a later `edit.redo` silently throw away what the player
just typed and call that a redo.

**A push of the text already at the cursor is a no-op** — the same state comes
back and `depth` does not move. Clients push on an idle timer (below), so
without this the stack would fill with copies of one text and UNDO would appear
to do nothing several times before it did something.

**Undo at the bottom, redo at the top, and `edit.clear` on an empty stack are
`.ok`, not errors.** They return the state unchanged. `can_undo` and `can_redo`
already told the client what was possible, and a held-down key or a second open
window must not be able to turn that race into an error the player sees.

**The stack is capped at 100 entries per quest.** A push beyond the cap drops
the oldest entry from the bottom and leaves the cursor on the same text. A
trainer that grows without bound inside the player's home directory is a bug,
and SPEC §2.3 says what the cap actually costs on disk, which is very little.
The consequence a client author should expect: once entries have been dropped,
undoing all the way down goes from the oldest *surviving* entry straight to
`cursor: 0` and `source: null` — the starter. History past the cap is gone,
not hidden, and `can_undo` says so honestly rather than pretending.

**`edit.clear` drops every entry and leaves the editor alone.** `depth` and
`cursor` go to zero and `source` comes back `null`, but the text on screen is
the player's work and throwing the history away is not an edit to it. This is
the one reply whose `source` is not an instruction to replace the buffer.

**When to push, so two clients agree.** The server never pushes on a player's
behalf; the stack holds exactly what a client put in it, and clients that
choose different moments hand the same player two different histories. Push
where the draft is already being saved — around `quest.run` and `quest.submit`
— and on a debounced idle of about 1.5 s after typing stops. A step on this
stack should be a thought rather than a keystroke; the editor's own local
history is the fine-grained one and stays in the editor.

**`Quest.draft` and `EditState.source` can disagree, and the stack wins.**
`draft` (§4.8) is a read of the last attempt's source, so it moves only when
the player runs or submits, while the stack also moves on undo and redo. A
client opening a quest asks for both and shows the stack's `source` whenever
`depth > 0`; `draft ?? starter` is the fallback for a quest with no stack yet,
which is every quest before its first push.

**`world.reset` empties the stacks of the road it resets** (§4.7b), and it is
the only message other than `edit.clear` that ever does. The stack is state —
it is what the screen opens on — and a road going back to untouched takes it
with it, or the reset node would still open on the code that cleared it. A
client that has the quest screen open when the reset lands learns this the
next time it asks, as it does for every other change here.

**Nothing is broadcast when the stack changes.** Unlike `progress.update`
(§4.19), there is no server-initiated event here: two windows open on the same
quest do not stay in step live, and each learns the truth the next time it
asks. That is deliberate. A cleared node is a fact about the world and belongs
in both windows at once; an editor buffer is not, and a window that replaced
the text under somebody's cursor because another window pressed UNDO would be
destroying work rather than syncing it. Send `edit.state` when the quest screen
opens and trust the replies after that.

The stack works during an interview (§4.9e). It is an editor convenience, like
`quest.reset`, and it reveals nothing — no hint, no solution, only what the
candidate themselves typed. A live screen with no undo is a worse simulation of
one, not a stricter one.

`.err` cases: `unauthorized` (all five need a session), `not_found` (no such
quest), and `bad_request` for a `source` over 256 KiB — the same ceiling
`quest.submit` and the playground use, because it is the same question ("a
source file this server will take") asked a third time. There is no `busy`:
nothing here compiles anything.

### 4.12 `search.query`

```json
→ payload: {
    "q":       "borrow checker",
    "mode":    "unified",              "bm25" | "semantic" | "unified"; default "unified"
    "filters": { "land": "rust", "category": "basic", "state": "cleared" },   all optional
    "limit":   20                      default 20, max 100
  }
← payload: { "hits": [ SearchHit, … ], "mode": "unified", "took_ms": 4 }
```

Hits are ordered best-first. `SearchHit` (§5.5) carries the component scores as
well as the fused one, so a search screen can show *why* something matched.
An empty `q` returns no hits rather than everything. `q` is at most **1024
bytes**; longer is `bad_request` (§3.3). The same cap applies to
`playground.chat.search`.

### 4.13 `stats.summary`

```json
→ payload: {}
← payload: {
    "cleared": 14, "total": 60, "attempts": 97, "accuracy": 0.42,
    "streak_days": 3, "stars": 31,
    "by_land": [ { "land":"rust", "cleared":11, "total":30 }, … ]
  }
```

`accuracy` is accepted attempts over all attempts, 0..1.

### 4.14 `stats.mistakes`

The heart of the training loop.

```json
→ payload: { "limit": 10 }                 default 10, max 50
← payload: { "mistakes": [ MistakeStat, … ] }    §5.6, most frequent first
```

Only kinds with `cleared_since < 5` are returned by default; pass
`"include_learned": true` for all of them.

### 4.14c `stats.weakest`

What to practise, when the player would rather be told than choose.

```json
→ payload: { "limit": 10 }                 default 10, max 50
← payload: { "weakest": [ Weak, … ] }      §5.6b, weakest first
```

`Weak` carries `quest_id`, `land`, `category`, `node`, `title`, `failures`,
`submits`, `failure_rate`, `hints_used`, `cleared` and `reason`.

The ranking is SPEC §1.2's, and it is the server's on purpose: it is the same
list `progress.json` holds, and two clients agreeing on which quest is hardest
is worth more than either of them computing it. `reason` is `"stuck"` (failed
submits, not cleared) or `"costly"` (cleared, but it took failures); every
`stuck` entry precedes every `costly` one.

**An empty list is the normal answer, not an error.** A player who has failed
nothing has no weakest quest, and a client that treats `[]` as a fault will
show a broken button to the only people who have earned it.

### 4.14b `stats.awards`

The shelf, as opposed to the fanfare.

```json
→ payload: {}
← payload: { "awards": [ Award, … ] }    newest first
```

`award` (§4.20) announces one as it happens; this lists what the player has.
Both carry the same `id`, `title` and `detail`, and the live event reaches the
player's other windows the way `progress.update` does.

**`kind: "stamp"` is the exception and is never in this list.** The per-clear
stamp fires every time a node turns gold; it is a moment, not something a
player *has*. Everything else is stored, and a `UNIQUE (address, kind, id)`
index is what makes "never awarded twice" a property of the database rather
than something the code has to remember to check.

Nothing is awarded for something that did not happen. Every rule is a query
against the record, and a badge that fires on the wrong thing is worse than one
that does not exist — it makes every other badge mean nothing.

### 4.15 `stats.history`

```json
→ payload: { "quest_id": "…", "limit": 20 }      quest_id optional
← payload: { "attempts": [ AttemptBrief, … ] }   §5.7, newest first
```

### 4.16 `ai.plan` / `ai.next` / `ai.finish`

```json
→ ai.plan   payload: { "mode": "weakness", "land": "rust", "size": 5 }
                     mode: "repeat" | "weakness" | "spaced"
← ai.plan.ok payload: { "drill": Drill }         §5.8

→ ai.next   payload: { "drill_id": "drl_…", "locale": "ko" }       locale optional, as §4.8
← ai.next.ok payload: { "quest": Quest, "position": 2, "total": 5,
                        "why": "you hit borrow-after-move 6 times" }
```

**`position` and `Drill.cursor` are 0-based**, and count how many quests of the
plan are already behind you — so the first `ai.next` returns `position: 0`, and
a client showing "quest N of M" prints `position + 1`. Stated because it cannot
be inferred from one observation, and a client that guesses 1-based is wrong by
one for the whole drill with nothing on the wire to reveal it.

**`plan` may legitimately be empty.** `weakness` on a player with no mistakes
is the ordinary case, not an error: the answer is `.ok` with an empty plan, and
the client says which kind of empty it is (§7.3).

```json

→ ai.finish payload: { "drill_id": "drl_…" }
← ai.finish.ok payload: { "summary": { "attempted": 5, "cleared": 4,
                                       "kinds_improved": ["borrow-after-move"] } }
```

The plan is a fixed ordered list fixed at creation, so a reconnect resumes the
same session. `ai.next` past the end returns `not_found`; call `ai.finish`.

`why` is the server's one-line explanation of why this quest is next — it is
generated from the mistake tables, not from a language model, and it is the
thing that makes the mode feel like a coach rather than a shuffle.

---

### Server-initiated events

These arrive with `id: null`, unsolicited, only on an AUTHENTICATED
connection. **A client must tolerate any of them arriving at any time**,
including after the request they relate to has already been answered.

### 4.17 `run.stage`

```json
{ "v":1, "id":null, "type":"run.stage",
  "payload": { "attempt_id":"att_…", "stage":"compiling",
               "queued":0, "elapsed_ms":812 } }
```

`stage` ∈ `queued` | `compiling` | `running` | `judging`. Strictly ordered, each
sent once. `queued` carries how many attempts are ahead in `queued`.

### 4.18 `run.log`

```json
{ "v":1, "id":null, "type":"run.log",
  "payload": { "attempt_id":"att_…", "stream":"compile",
               "chunk":"error[E0382]: borrow of moved value: `s`\n", "seq":3 } }
```

`stream` ∈ `compile` | `stdout` | `stderr`. `seq` counts from 0 **per stream**
per attempt, so a client can detect a gap. Chunks are UTF-8 and may split
anywhere, including mid-line; a client must buffer rather than assume lines.

The server caps total streamed bytes per attempt at 256 KiB and then sends one
final chunk `"\n…output truncated\n"`. The full text is on disk (SPEC §1) and
the truncated-to-64-KiB copy is in the `Attempt`.

### 4.19 `progress.update`

```json
{ "v":1, "id":null, "type":"progress.update",
  "payload": { "quest_id":"…", "state":"cleared", "stars":3,
               "cleared_total":15, "unlocked":["rust.basic.04.slices"],
               "practised": 0, "xp": XpGain } }
```

Sent when a clear changes the map, including the nodes it unlocked, so a client
updates the overworld without refetching it — and on a **re-clear** too, with
`practised` (§5.2) counting it, so the stamp's colour and the level move in
every window. `xp` is the same reading the
`quest.submit.ok` carried (§4.9, §5.1b), so the other window's level moves
with this one. Also sent to **the same user's
other open connections**, which is how two windows stay in step.

### 4.20 `award`

```json
{ "v":1, "id":null, "type":"award",
  "payload": { "kind":"badge", "id":"first-clear",
               "title":"FIRST LIGHT", "detail":{ "land":"rust" } } }
```

`kind` ∈ `badge` | `stamp` | `level` | `streak`. Purely presentational — the
client plays the fanfare. A client that does not know a `kind` ignores it.

### 4.21 `server.bye`

```json
{ "v":1, "id":null, "type":"server.bye", "payload": { "reason":"shutdown" } }
```

Sent immediately before the server closes the connection. `reason` ∈
`shutdown` | `revoked` | `replaced`. A client should reconnect (§6) on
`shutdown`, and go to the login screen on `revoked`. `revoked` and `replaced`
are defined for clients to handle but not yet emitted by this server, which has
no message that ends another connection's session.

---

### 4.22 `playground.updated`

```json
{ "v":1, "id":null, "type":"playground.updated",
  "payload": { "snippet": Snippet } }
```

A pad was saved (§4.9) on one of the user's connections; this goes to **the
same user's other open connections** and not to the one that saved. `Snippet`
is §5.9 in full — id, name, lang, source, stdin — so a window with that pad
open can take it without a `playground.load`. A window with a different pad
open ignores it (the list, if shown, is worth refreshing). Whether to replace
what is on screen is the client's call: the reference clients apply it when
their editor has nothing unsaved, and only say so when it has.

### 4.23 `playground.chat.updated`

```json
{ "v":1, "id":null, "type":"playground.chat.updated",
  "payload": { "id":"pg_…", "message": ChatMessage } }
{ "v":1, "id":null, "type":"playground.chat.updated",
  "payload": { "id":"pg_…", "cleared": true } }
```

A room changed (§4.9f: a post, an edit, a delete) on one of the user's
connections. The other connections get the row as recorded — with its `id`
and new `timeid`, a tombstone for a delete — and fold it exactly as a page of
`playground.chat.list`. `cleared: true` is `playground.chat.clear`: the room
is empty. Neither is sent to the connection that made the change; it has
the reply.

## 5. Shared shapes

Given as TypeScript for precision. A Lua or Rust client implements the same
fields.

### 5.1 `User`

```ts
type User = {
  address: string;          // EIP-55 checksummed
  name: string;             // free-form, not unique
  created_at: string;
  last_seen_at: string;
  settings: object;         // opaque, client-owned
  level: number;            // from `xp`, on the triangular curve
  xp: number;               // the XP ledger's sum
  xp_into_level: number;
  xp_for_next: number;
};
```

### 5.1b `XpGain`

```ts
type XpGain = {
  gained: number;           // this submit's grant; 0 unless it was a first clear
  total: number;            // the ledger's sum after it
  level: number;
  into_level: number;       // XP past the level's start
  for_next: number;         // XP the level spans
  level_up: boolean;        // `level` is higher than before the grant
};
```

XP is recorded, not recomputed: every first clear writes one row to the
server's ledger — `25 × stars × difficulty × category weight` (`basic` 1,
`advanced` 2, `hacker` 3) — and `User.xp` is what the rows add up to. A quest
leaving the content pack does not take the XP it gave.

### 5.2 `MapNode`

```ts
type MapNode = {
  quest_id: string;
  node: number;                          // 1-based, contiguous within a map
  title: string;
  difficulty: 1|2|3|4|5;
  state: "open" | "cleared";             // never "locked" — see §4.7
  stars: 0|1|2|3;
  practised: number;                     // accepted submits beyond the clearing one
  x: number; y: number;                  // 0..1 of the map image
  kind: "quest" | "boss" | "gate";
  requires: string[];                    // quest ids
  attempts: number;
  text_locale: "en" | "ko" | "yue" | "zh" | "ja" | "cs";   // the language `title` is in (§4.7)
};
```

### 5.3 `Quest`

```ts
type Quest = {
  id: string; land: "rust"|"go"|"cpp"|"python"; category: "verybasic"|"basic"|"advanced"|"hacker";
  node: number; title: string; brief: string; story: string;
  /** §4.8 — the language of title, story, brief and the hints. "en" unless a
   *  translation (SPEC §12.1) was substituted for the `locale` the client
   *  asked with. The code fields are never translated. */
  text_locale: "en" | "ko" | "yue" | "zh" | "ja" | "cs";
  difficulty: 1|2|3|4|5;
  time_limit_s: number | null;           // null = untimed
  opened_at: string | null;              // §4.8b — server time the clock started
  deadline_at: string | null;            // opened_at + time_limit_s
  starter: string;
  /** §4.8's own field: the source of the player's most recent run or submit
   *  on this quest, or null on a first visit. `null` (not omitted) under an
   *  interview (§4.9e) — a live screen starts from the starter. */
  draft: string | null;
  concepts: string[];
  hints_total: number;                   // the text comes from quest.hint
  hints_used: number;
  state: "open" | "cleared";
  stars: 0|1|2|3;
  tests: {
    match: "exact"|"trim"|"tokens"|string;   // "float:1e-6"
    timeout_ms: number;
    visible: { name: string; stdin: string; expect: string }[];
    hidden_count: number;                    // count only, never the data
  };
  solution?: string;                     // present only once cleared
  quiz?: { choices: string[]; answer: number };  // VERY BASIC only: four lines,
                                                  // `answer` the index of the one to type
};
```

### 5.4 `Attempt`

```ts
type Attempt = {
  id: string;                            // "att_" + 16 hex
  quest_id: string;
  mode: "run" | "submit";                // §4.9b — a run never clears
  verdict: "accepted" | "wrong_answer" | "compile_error" | "runtime_error"
         | "timeout" | "output_limit" | "internal_error";
  tests_passed: number; tests_total: number;
  compile_ms: number; run_ms: number;
  exit_code: number | null;
  stderr: string;                        // ≤ 64 KiB, truncation marked
  cases: {
    name: string; passed: boolean; visible: boolean;
    stdin?: string; expect?: string; got?: string;   // only when visible
  }[];
  within_limit: boolean | null;          // §4.8b — null when untimed
  mistakes: {
    kind: string;                        // SPEC §7.1 taxonomy slug
    code: string | null;                 // "E0382", "go:undefined", null
    message: string;
    line: number | null; col: number | null;
  }[];
  stars: 0|1|2|3;
  cleared: boolean;                      // true only on the first clear
  created_at: string;
};
```

`cleared` answers "did this submission just clear the node", not "is the node
cleared" — re-solving a cleared quest reports `verdict: "accepted"` with
`cleared: false`.

### 5.9 `PlaygroundRun` and `Snippet`

```ts
type PlaygroundRun = {
  attempt_id: string;                    // for correlating the stream only
  lang: "rust" | "go" | "cpp" | "python";
  outcome: "ok" | "compile_error" | "runtime_error" | "timeout" | "output_limit";
  compile_ms: number; run_ms: number;
  exit_code: number | null;
  stdout: string;                        // what it printed, capped
  stderr: string;                        // capped, truncation marked
  diagnostics: {                         // shown, never stored
    kind: string; code: string | null; message: string;
    line: number | null; col: number | null;
  }[];
};

type Snippet = {
  id: string;                            // "pg_" + 16 hex
  name: string; lang: "rust" | "go" | "cpp" | "python"; source: string;
  created_at: string; updated_at: string;
};
type SnippetBrief = Omit<Snippet, "source"> & { bytes: number };
```

### 5.5 `SearchHit`

```ts
type SearchHit = {
  quest_id: string; title: string; land: string; category: string;
  snippet: string;                       // FTS5 snippet(), may contain <b>…</b>
  score: number;                         // the fused RRF score, higher is better
  bm25: number | null;                   // SQLite bm25(): **more negative is better**
                                         // null = absent from that ranking entirely,
                                         // which is not the same as scoring zero
  cosine: number | null;
  state: "open" | "cleared";
};
```

### 5.11 `InterviewSession` and `InterviewReport`

```ts
type InterviewSession = {
  id: string;                            // "int_" + 16 hex
  quest: Quest;                          // solution and hints withheld
  opened_at: string; deadline_at: string | null;
  approach: string | null;               // null until written
  approach_at: string | null;            // the editor unlocks after this
  finished_at: string | null;
};

type InterviewReport = {
  session_id: string; quest_id: string;
  cleared: boolean; within_limit: boolean | null;
  took_ms: number; limit_ms: number | null;
  approach: string | null;
  reference_summary: string;             // what the reference answer does
  attempts: AttemptBrief[];
  mistakes: { kind: string; label: string; count: number }[];
};
```

### 5.10 `Award`

```ts
type Award = {
  kind: "badge" | "level" | "streak";   // "stamp" is live-only, never listed
  id: string;                            // "first-clear", "level-4",
                                         // "tamed-borrow-after-move"
  title: string;                         // "FIRST CLEAR"
  detail: object;                        // whatever the rule counted
  created_at: string;
};
```

### 5.6 `MistakeStat`

```ts
type MistakeStat = {
  kind: string;                          // "borrow-after-move"
  label: string;                         // "Used a value after moving it"
  count: number;
  last_at: string;
  cleared_since: number;                 // consecutive clean attempts since
  example_quest_id: string | null;
  concepts: string[];                    // what to drill to fix it
};
```

### 5.7 `AttemptBrief`

```ts
type AttemptBrief = {
  id: string; quest_id: string; verdict: string;
  mode: "run" | "submit";                // §4.9b — history returns both
  tests_passed: number; tests_total: number;
  created_at: string; kinds: string[];
};
```

### 5.8 `Drill`

```ts
type Drill = {
  id: string;                            // "drl_" + 16 hex
  mode: "repeat" | "weakness" | "spaced";
  plan: string[];                        // quest ids, in order, fixed
  cursor: number;
  reason: string;                        // why this plan, in one line
  created_at: string;
};
```

### 5.12 `EditState`

```ts
type EditState = {
  quest_id: string;
  source: string | null;                 // the text at the cursor; null is the
                                         // quest's starter, which is what an
                                         // empty stack and cursor 0 both mean
  cursor: number;                        // 0..depth — how many entries apply
  depth: number;                         // entries on the stack, 0..100
  can_undo: boolean;                     // cursor > 0
  can_redo: boolean;                     // cursor < depth
};
```

`can_undo` and `can_redo` follow from `cursor` and `depth` and are sent anyway:
they are exactly what the two buttons are enabled by, and a client that derives
them is a client that can derive them differently. §4.11c has the model.

---

## 6. Reconnection

The connection is expected to drop — a laptop sleeps, the server restarts
during development. **Nothing in the game lives in a client**, so a drop costs
nothing but the reconnect.

The rule for every client:

1. Keep the session `token` (and only the token) in durable storage. Never the
   mnemonic or the private key.
2. On drop, reconnect with exponential backoff: 0.5 s, 1 s, 2 s, 4 s, 8 s,
   then every 8 s, each with ±20% jitter. Do not hammer.
3. On connect, send `auth.resume` with the stored token. Store the token it
   returns.
4. On `unauthorized`, drop to the login screen and ask for the key again.
5. Refetch `world.map` for the screen the player is on. Do not trust a map
   cached across a disconnect — a `progress.update` may have been missed.
   The same goes for a pad: a `playground.updated` or
   `playground.chat.updated` (§4.22, §4.23) sent while the socket was down
   is not replayed, so a client with a pad open re-reads it, or its room
   from its cursor, on reconnect.
6. A `quest.submit` that was in flight when the connection dropped **is still
   running on the server**, and its result is durable. After resuming, call
   `stats.history` with the quest id and look at the newest attempt rather than
   resubmitting. Resubmitting is not harmful, only wasteful and confusing.

---

## 7. Worked example

A whole session, first login through a clear. `→` is client to server.

```jsonc
→ {"v":1,"id":"c-1","type":"auth.challenge","payload":{"address":"0x9858EfFD232B4033E47d90003D41EC34EcaEda94"}}
← {"v":1,"id":"c-1","type":"auth.challenge.ok","payload":{
     "nonce":"3f1a…","expires_at":"2026-09-11T04:14:33Z",
     "message":"Causewaybay Hacker login\naddress: 0x9858EfFD232B4033E47d90003D41EC34EcaEda94\nnonce: 3f1a…\nexpires: 2026-09-11T04:14:33Z"}}

// client signs message locally; the key never moves
→ {"v":1,"id":"c-2","type":"auth.login","payload":{
     "address":"0x9858EfFD232B4033E47d90003D41EC34EcaEda94","signature":"0x…","name":"ferris"}}
← {"v":1,"id":"c-2","type":"auth.login.ok","payload":{"token":"kR3…","user":{…}}}

→ {"v":1,"id":"c-3","type":"world.map","payload":{"land":"rust","category":"basic"}}
← {"v":1,"id":"c-3","type":"world.map.ok","payload":{"nodes":[…],"edges":[…]}}

→ {"v":1,"id":"c-4","type":"quest.get","payload":{"quest_id":"rust.basic.03.shadowing"}}
← {"v":1,"id":"c-4","type":"quest.get.ok","payload":{"quest":{…}}}   // no `solution`

→ {"v":1,"id":"c-5","type":"quest.submit","payload":{"quest_id":"rust.basic.03.shadowing","lang":"rust","source":"fn main(){…}"}}
← {"v":1,"id":null,"type":"run.stage","payload":{"attempt_id":"att_91c…","stage":"compiling","elapsed_ms":12}}
← {"v":1,"id":null,"type":"run.log","payload":{"attempt_id":"att_91c…","stream":"compile","chunk":"error[E0382]: …","seq":0}}
← {"v":1,"id":null,"type":"run.stage","payload":{"attempt_id":"att_91c…","stage":"judging","elapsed_ms":640}}
← {"v":1,"id":"c-5","type":"quest.submit.ok","payload":{"attempt":{
     "id":"att_91c…","verdict":"compile_error","tests_passed":0,"tests_total":3,
     "mistakes":[{"kind":"borrow-after-move","code":"E0382","message":"borrow of moved value: `s`","line":4,"col":20}],
     "cleared":false,"stars":0}}}

// player fixes it
→ {"v":1,"id":"c-6","type":"quest.submit","payload":{…}}
← {"v":1,"id":null,"type":"run.stage","payload":{"attempt_id":"att_a20…","stage":"running","elapsed_ms":410}}
← {"v":1,"id":"c-6","type":"quest.submit.ok","payload":{"attempt":{"verdict":"accepted","tests_passed":3,"tests_total":3,"cleared":true,"stars":2}}}
← {"v":1,"id":null,"type":"progress.update","payload":{"quest_id":"rust.basic.03.shadowing","state":"cleared","stars":2,"cleared_total":3,"unlocked":["rust.basic.04.slices"]}}
← {"v":1,"id":null,"type":"award","payload":{"kind":"stamp","id":"cleared","title":"CLEARED","detail":{}}}
```

---

## 8. Conformance checklist

A client is conformant when all of these hold. `tests/smoke/` checks them
against a running server; each client's own suite should check its half.

1. Every frame it sends has exactly `v`, `id`, `type`, `payload`, with
   `payload` an object.
2. It matches replies by `id` and tolerates out-of-order replies.
3. It ignores unknown `type` values without erroring or closing.
4. It handles every `code` in §3.3, and treats an unknown one as `internal`.
5. It never sends a mnemonic or private key, in any field, ever.
6. It signs `auth.challenge`'s `message` byte-for-byte rather than rebuilding
   it.
7. It stores the token returned by `auth.resume`, not the one it sent.
8. It buffers `run.log` chunks rather than assuming line boundaries, and
   notices a `seq` gap.
9. It reconnects with backoff and resumes with the token, refetching the map.
10. It does not send a second `quest.submit` while one is in flight.
11. It survives a `server.bye` followed by a close, and a close without one.
12. It sends `ping` every 20 s if it does not answer websocket pings.

### 5.13 `Position`

```json
{ "land": "rust", "category": "basic",
  "quest_id": "rust.basic.02.sum", "updated_at": "2026-09-13T00:00:00Z" }
```

`category` and `quest_id` are `null` when the player was in a lobby rather than
on a stage — a real place, and not the same as never having played. A bookmark
onto a quest that no longer exists comes back with `quest_id: null` and its
land and category intact, rather than pointing at something the client cannot
open.

The server keeps it from the navigation it already receives (SPEC §1.3); there
is no message for setting it, and a client that wants to be somewhere goes
there in the ordinary way.

### 5.14 `ChatMessage` and `ChatHit`

```ts
type ChatMessage = {
  id: number;                            // int64: the identity, never reused
  timeid: number;                        // int64: ms since the epoch, strictly increasing
                                         // across every room — the sync cursor
  snippet_id: string;
  role: "user" | "agent" | "tool";
  kind: "text" | "image";
  text: string;                          // the message, or an image's prompt
  photo_url: string | null;              // "/photos/<message_id>/<token>.<ext>", image rows
  provider: string | null;               // "openai" | "anthropic" | "grok" | null
  model: string | null;
  created_at: string;                    // when it was said; an edit does not move it
  edited: boolean;                       // the text changed after it was said
  deleted: boolean;                      // a tombstone: text and photo gone, timeid moved
};
type ChatHit = {
  message: ChatMessage;
  snippet_name: string;                  // the pad it was said in
  score: number;                         // the fused RRF score, higher is better
  bm25: number | null;                   // as SearchHit's, §5.5
  cosine: number | null;
  snippet: string;                       // FTS5 snippet() with <b>…</b>, or an excerpt
};
```

