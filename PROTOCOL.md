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

---

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
| `locked` | the quest's `requires` are not cleared | show the lock, name the blocker |
| `rate_limited` | too many requests | back off; `detail.retry_after_ms` |
| `busy` | a submission is already in flight | disable the submit button |
| `internal` | the server broke | show a retry; log `detail.trace_id` |

A code not in this table is a server bug. A client encountering one should
treat it as `internal`.

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
    "user":  User                        §5.1
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

### 4.4 `auth.resume`

Trade a stored session token for an authenticated connection, without touching
the key material. This is what lets a client hold the key in memory only and
forget it on reload.

```json
→ payload: { "token": "…" }
← payload: { "token": "…", "user": User }
```

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
→ payload: { "land": "rust", "category": "basic" }
← payload: {
    "land": "rust", "category": "basic",
    "nodes": [ MapNode, … ],              §5.2, ordered by node
    "edges": [ ["rust.basic.01.hello", "rust.basic.02.bindings"], … ]
  }
```

`edges` are the paths the map draws, derived from `requires`. They are given
explicitly so a client never has to infer the overworld's shape.

### 4.8 `quest.get`

```json
→ payload: { "quest_id": "rust.basic.03.shadowing" }
← payload: { "quest": Quest }             §5.3
```

`locked` if the node's requirements are not met. `Quest.solution` is **omitted
entirely** unless the player has cleared it — not sent as null, not sent
empty.

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
← payload: { "attempt": Attempt }         §5.4
```

While it runs the server pushes `run.stage` and `run.log` events (§4.17,
§4.18) carrying the same `attempt_id` that the final `Attempt` will have. The
reply arrives when judging is finished, correlated by the request's `id`.

`.err` cases: `busy` (one already in flight), `locked`, `not_found`,
`rate_limited`, `bad_request` (source over 256 KiB, or `lang` disagreeing with
the quest).

A submission is **always recorded**, including a compile error, including a
timeout. That is the curriculum (SPEC §7).

### 4.10 `quest.hint`

```json
→ payload: { "quest_id": "…", "index": 0 }      0-based
← payload: { "hint": "…", "index": 0, "total": 2, "hints_used": 1 }
```

Taking a hint costs stars (SPEC §6.3) and is permanent. Re-requesting a hint
already taken does not cost again. `not_found` when `index` is past `total`.

### 4.11 `quest.reset`

```json
→ payload: { "quest_id": "…" }
← payload: { "starter": "fn main() { … }" }
```

Gives back the starter code. **Does not** touch progress, attempts, stars or
hints — it is an editor convenience, not an undo.

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
An empty `q` returns no hits rather than everything.

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

→ ai.next   payload: { "drill_id": "drl_…" }
← ai.next.ok payload: { "quest": Quest, "position": 2, "total": 5,
                        "why": "you hit borrow-after-move 6 times" }

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
               "cleared_total":15, "unlocked":["rust.basic.04.slices"] } }
```

Sent when a clear changes the map, including the nodes it unlocked, so a client
updates the overworld without refetching it. Also sent to **the same user's
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
`shutdown`, and go to the login screen on `revoked`.

---

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
  level: number;            // derived from stars
  xp: number;
};
```

### 5.2 `MapNode`

```ts
type MapNode = {
  quest_id: string;
  node: number;                          // 1-based, contiguous within a map
  title: string;
  difficulty: 1|2|3|4|5;
  state: "locked" | "open" | "cleared";
  stars: 0|1|2|3;
  x: number; y: number;                  // 0..1 of the map image
  kind: "quest" | "boss" | "gate";
  requires: string[];                    // quest ids
  attempts: number;
};
```

### 5.3 `Quest`

```ts
type Quest = {
  id: string; land: "rust"|"go"; category: "basic"|"advanced"|"hacker";
  node: number; title: string; brief: string; story: string;
  difficulty: 1|2|3|4|5;
  time_limit_s: number | null;           // null = untimed
  starter: string;
  concepts: string[];
  hints_total: number;                   // the text comes from quest.hint
  hints_used: number;
  state: "locked" | "open" | "cleared";
  stars: 0|1|2|3;
  tests: {
    match: "exact"|"trim"|"tokens"|string;   // "float:1e-6"
    timeout_ms: number;
    visible: { name: string; stdin: string; expect: string }[];
    hidden_count: number;                    // count only, never the data
  };
  solution?: string;                     // present only once cleared
};
```

### 5.4 `Attempt`

```ts
type Attempt = {
  id: string;                            // "att_" + 16 hex
  quest_id: string;
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

### 5.5 `SearchHit`

```ts
type SearchHit = {
  quest_id: string; title: string; land: string; category: string;
  snippet: string;                       // FTS5 snippet(), may contain <b>…</b>
  score: number;                         // the fused RRF score
  bm25: number | null;                   // component, null if not in that ranking
  cosine: number | null;
  state: "locked" | "open" | "cleared";
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
