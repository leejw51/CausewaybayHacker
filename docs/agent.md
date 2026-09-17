# The Rust coder — the AI agent on the code screens

An AI agent that lives on the two screens where a person writes: the quest
screen's CODE mode and the playground. It is drawn as a sprite — the coder
on the flying keyboard from CausewaybayRaiden — that flies around the editor,
watches what is being typed, drops tips, and, when asked, writes code into
the editor one character at a time at a human's speed.

This document is the plan and the contract. PROTOCOL §4.9f and SPEC §2.1 carry
the wire and the schema once they land.

## 1. The rules that shape everything

1. **The model is called only when a person presses something.** ASK, WRITE,
   REVIEW and IMAGE each cost one round trip. Everything the agent does on its
   own — flying, peeking at the caret, the tips, "you have four `unwrap()`s in
   here" — is local logic with no network in it. An optional AUTO toggle lets
   the agent review on its own; it is off by default and, when on, fires at
   most once per three minutes, only after 25 s of idle, and only if the text
   changed materially since the last review.
2. **API keys never leave the browser except to the provider that owns them.**
   They are kept in `localStorage` under `cwbhacker.ai.*` (`ui/prefs.ts`), so
   they survive reloads and sessions. The server never sees a key and never
   makes a model call.
3. **Every model call and every tool call runs in the browser.** The tools the
   model may call (read the code, write the code, run it, search the notes,
   make a picture) are executed by the client against the editor and the
   websocket. The server is storage: it keeps the chatroom, the photos and
   the index, per entry, on disk and in SQLite.
4. **One entry, one folder.** `users/<address>/snippets/<id>/` already holds
   the pad's source and `snippet.json`; it grows `chat.jsonl` (every message,
   one per line) and `photos/<message_id>.<ext>`. The database holds the same
   messages for listing and search; the folder is the human-readable mirror.

## 2. Providers and models

| provider | chat | tools | images | how |
| --- | --- | --- | --- | --- |
| `anthropic` | Messages API, streamed | yes | no | `@anthropic-ai/sdk`, `dangerouslyAllowBrowser` |
| `openai` | Chat Completions, streamed | yes | `gpt-image-1` | `openai` SDK, `dangerouslyAllowBrowser` |
| `grok` | Chat Completions (xAI, OpenAI-compatible), streamed | yes | `grok-2-image` | `openai` SDK with `baseURL: https://api.x.ai/v1` |

Defaults: `claude-opus-5`, `gpt-4.1`, `grok-4`. The model field is editable and
SETUP has a FETCH MODELS button that lists what the key can reach (`/v1/models`
on all three), because a hard-coded model name is the first thing to rot.

Both SDKs are imported on demand (`await import(...)`) from the AGENT panel,
the way `ui/poster.ts` is, so nobody pays for them on the way into the room.

## 3. The tools the model can call

Defined once in `ai/tools.ts` as JSON schema, rendered into each provider's
shape by its adapter, executed by the scene through a `Bench` interface:

| tool | does | returns |
| --- | --- | --- |
| `read_code` | the editor's text, language and file name | text |
| `write_code {source}` | **replaces** the editor's text, typed at human speed | "typed N chars" |
| `insert_code {text}` | types at the caret | "typed N chars" |
| `run_code {stdin?}` | RUN, as the button does (playground only) | outcome + stdout + stderr |
| `search_notes {q}` | `playground.chat.search` over this user's chatrooms | hits |
| `make_image {prompt}` | image generation on openai/grok; refused on anthropic | "posted photo" |

`write_code` and `insert_code` go through `ai/typist.ts`: 35–70 ms a
character with jitter, ~180 ms at a newline, bursts on long identifiers, so it
reads as somebody typing rather than a paste. The sprite hovers at the caret
while it types. STOP aborts the typist and the stream together.

## 4. The sprite

`agent_coder` (the Raiden player ship: a coder with a crab on the shirt, on a
flying keyboard) and three companions, `agent_bot_anthropic`,
`agent_bot_openai`, `agent_bot_grok` (Raiden's agent bots), processed by
`art/tools/process.py` from `CausewaybayRaiden/love2d/assets/` into 64×64
cells. The companion drawn beside the coder says which provider is wired up.

States (`ui/agent/sprite.ts`, pure enough to test):

* **wander** — a slow Lissajous drift inside the editor's rectangle, bobbing,
  flipped to face the way it moves, engine flame flickering;
* **peek** — every 12–25 s, fly to the caret, hover a beat, and either say a
  tip or nothing; back to wander;
* **typing** — pinned a cell right of the caret while the typist runs;
* **thinking** — a small orbit while a request is in flight;
* **speaking** — a speech bubble beside the sprite, four lines at most; a
  longer reply goes to the chat panel and the bubble shows its first line.

Drawn on its own transparent 2D canvas inside `#overlay`, after the editor and
after the effects layer, so it is painted over both; `pointer-events: none`,
like `.cwb-sparks`. Reduced motion: no wander, the sprite sits in a corner and
only the bubble moves.

## 5. Tips and advice with no model in them

`ai/tips.ts`:

* a catalogue of one-line tips per language (Rust, Go, C++, Python), shown in
  idle time, never the same one twice in a row;
* `advise(lang, source)`: regex heuristics over the text — Rust: `.unwrap()`
  count, `.clone()` inside a loop, `&String` parameters, `println!` left in;
  Go: `err` assigned and not checked, `fmt.Println` in a loop; C++:
  `using namespace std`, a bare `new`; Python: bare `except:`, a mutable
  default argument. Each yields one sentence. Checked on a 4 s idle after a
  change, and said at most once per finding per pad.

## 6. The chatroom (backend)

Per entry, per user. Every message row and every photo belongs to one snippet
and is scoped by the session's address exactly as snippets are — another
player's id answers `not_found`.

### Schema (migration `0013_snippet_chat.sql`)

```sql
CREATE TABLE snippet_messages (
  id          TEXT PRIMARY KEY,               -- 'msg_' + 16 hex
  snippet_id  TEXT NOT NULL REFERENCES snippets(id) ON DELETE CASCADE,
  address     TEXT NOT NULL,
  role        TEXT NOT NULL CHECK (role IN ('user','agent','tool')),
  kind        TEXT NOT NULL CHECK (kind IN ('text','image')),
  text        TEXT NOT NULL DEFAULT '',        -- the message, or the image's prompt
  photo       TEXT,                            -- file name under photos/, image rows only
  photo_token TEXT,                            -- 32 hex; the capability that fetches it
  provider    TEXT,                            -- 'openai' | 'anthropic' | 'grok' | null
  model       TEXT,
  created_at  TEXT NOT NULL
);
CREATE INDEX snippet_messages_by_snippet ON snippet_messages(snippet_id, created_at);
CREATE VIRTUAL TABLE snippet_message_fts USING fts5(text, content='snippet_messages', content_rowid='rowid');
-- plus the three external-content triggers, as quest_fts has
CREATE TABLE snippet_message_vec (
  message_id TEXT PRIMARY KEY REFERENCES snippet_messages(id) ON DELETE CASCADE,
  dim INTEGER NOT NULL, model TEXT NOT NULL, vec BLOB NOT NULL
);
```

### Messages (PROTOCOL §4.9f)

```
→ playground.chat.list    { id, limit?=200 }
← { messages: [ChatMessage, …] }                   oldest first

→ playground.chat.post    { id, role, text?, image_b64?, image_type?, provider?, model? }
← { message: ChatMessage }
   image_b64 present ⇒ kind 'image'; text is then the prompt. ≤ 3 MiB decoded,
   image/png | image/jpeg | image/webp. Refused past 500 messages per entry.

→ playground.chat.clear   { id }                   every message and photo of one entry
← { id, cleared: N }

→ playground.chat.search  { q, id?, mode?='unified', limit?=20 }
← { hits: [ChatHit, …], mode, took_ms }
   BM25 over snippet_message_fts, cosine over snippet_message_vec with the
   live embedder, fused by RRF exactly as search.rs does for quests. `id`
   narrows to one entry; without it, every entry of this user.
```

```ts
type ChatMessage = {
  id: string; snippet_id: string;
  role: "user" | "agent" | "tool"; kind: "text" | "image";
  text: string;
  photo_url: string | null;        // "/photos/<message_id>/<token>.<ext>", image rows
  provider: string | null; model: string | null;
  created_at: string;
};
type ChatHit = { message: ChatMessage; snippet_name: string; score: number;
                 bm25: number | null; cosine: number | null; snippet: string };
```

### Photos over HTTP

The websocket carries a 4 MiB frame and a photo can be most of that, so photos
are **fetched, not pushed**: `GET /photos/{message_id}/{token}.{ext}` serves
the file when the token matches the row. The token is 32 random hex, minted
at post time and handed only to the owner over the socket. There is no other
HTTP auth in this server and SPEC calls it a single-trusted-user trainer; an
unguessable capability URL is the honest fit.

### On disk

`users/<address>/snippets/<id>/chat.jsonl` — one JSON object per message,
appended on post, rewritten on clear. `photos/<message_id>.<ext>` — the bytes
as posted. Deleting the snippet removes the folder as it does today.

## 7. The panel

AGENT is a button on the CODE strip of both screens (and on the framed
playground bench, where it opens CODE with the panel up). The panel takes the
right 38 % of the window in landscape and the bottom 45 % in portrait; the
editor keeps the rest.

Inside: provider tabs (`OPENAI` `ANTHROPIC` `GROK`, the one with a key lit),
SETUP (key field, masked; model field; FETCH MODELS; the AUTO toggle), the
messages (scrollable, photos as thumbnails, the streaming reply growing in
place), and the row: the message field, SEND, WRITE, REVIEW, IMAGE, STOP,
CLEAR.

* SEND — a chat turn with the tools available; a reply that decides to write
  code writes it.
* WRITE — "write the program this pad is for": the message field's text is
  the brief, the model is instructed to call `write_code`.
* REVIEW — one round trip on the current text; the reply is spoken in the
  bubble and posted to the room.
* IMAGE — `make_image` on the field's text; refused with a sentence on
  anthropic.

The quest screen has the same panel with no persistence: a quest has no
folder, so the room lives for the visit. It gets `read_code`, `write_code`,
`insert_code`; not `run_code` (a quest RUN is an attempt and counts), and not
`make_image` or `search_notes`.

## 8. Files

Frontend (`frontend/src/`):

* `ai/prefs.ts` — provider, keys, models, AUTO, in `localStorage`.
* `ai/providers.ts` — the three adapters behind one `chat(stream)` and one
  `image()` interface; SDKs loaded on demand.
* `ai/tools.ts` — the tool catalogue and the `Bench` interface.
* `ai/session.ts` — the loop: messages → stream → tool calls → results, with
  an `AbortController`, and a context builder that prepends the code.
* `ai/typist.ts` — the human-speed schedule (pure) and the editor driver.
* `ai/tips.ts` — the catalogue and `advise()` (pure).
* `ui/agent/sprite.ts` — the flight state machine (pure) and its drawing.
* `ui/agent/layer.ts` — the overlay canvas.
* `ui/agent/panel.ts` — the chat/setup panel: drawing, its `Buttons`, its DOM
  fields, wheel scrolling.
* `ui/agent/coder.ts` — the controller that owns all of the above for one
  screen: `mount(editor, lang)`, `update(dt)`, `draw(g, editorRect)`,
  `pointer`, `key`, `leave`.
* `ui/editor.ts` — `typeAt(text)`, `clearAll()`, `caretVirtual()`.
* `net/protocol.ts` — the four messages and two shapes.
* `i18n/*.ts` — `agent.*` keys, six catalogues.
* `scenes/playground.ts`, `scenes/quest.ts` — mount, the AGENT button, the
  panel's share of CODE mode.

Backend (`backend/`):

* `core/migrations/0013_snippet_chat.sql`
* `core/src/chat.rs` — list, post, clear, search, the disk mirror, the photo
  path; `Home::snippet_photo_dir`.
* `server/src/playground.rs` — the four handlers; `server/src/lib.rs` — the
  `/photos/{id}/{file}` route; `server/src/ws.rs` — dispatch.
* `core/tests/chat.rs`, `server/tests/chat.rs`.

Art: `art/agent_coder.png`, `art/agent_bot_{anthropic,openai,grok}.png`,
`art/tools/manifest.py` ORDER, `art/prompts.toml` provenance notes.

Docs: `PROTOCOL.md` §4.9f and §5.14, `SPEC.md` §2.1.

## 9. Tests

* `tests/tips.test.ts` — `advise()` finds what it should and nothing else.
* `tests/typist.test.ts` — the schedule: never faster than the floor, pauses
  at newlines, total time bounded.
* `tests/agent-sprite.test.ts` — the state machine: wander stays inside the
  rect, peek reaches the caret, reduced motion pins it.
* `tests/agent-prefs.test.ts` — keys round-trip through `localStorage` and a
  blocked store is survivable.
* `tests/i18n.test.ts` — unchanged, and it is what forces the five
  translations.
* Rust: post/list/clear scoped by owner; search finds a posted message by a
  word and by a near word; the photo route serves the right bytes to the
  right token and 404s a wrong one; the snippet delete removes the room.
