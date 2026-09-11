# Story — the narrative bible

Everything a `story` line in a content pack is written from. Voice: dry,
concrete, Hong Kong specific. No whimsy padding, no "epic quest", no exclamation
marks the game has not earned. A street is a street.

Continuity with the siblings is deliberate. `CausewaybayGolang` already put
Alex the Go coder on Percival Street, Mei the Rustacean at the Times Square
Lucky Mac, and the mascots — a coffee-drinking gopher, Ferris the crab — on the
map. `CausewaybayRaiden` already named Skynet's things: CLIPPY, PANIC, LEAK,
LIFETIME, DEADLOCK, OVERFLOW, NULLPTR, OFF-BY-ONE. We use the same cast and the
same geography. A player who has played either should recognise the block.

---

## 1. The character

**Mei Cheung (張慧美).** Rust, eleven years, four of them on the payment path
at a fintech off Gloucester Road. She is the Rustacean from
`CausewaybayGolang` — the one who walked Alex through the afternoon at the
Times Square Lucky Mac with Ferris on the counter.

She lives in a walk-up above Jardine's Bazaar. She is not a chosen one and the
game never says she is. She is a competent engineer who lost something, knows
exactly when she lost it, and is annoyed.

**Ferris** — a crab. Rust Land's mascot. Sits on things. Does not speak; the
sprite reacts.

**Gogo** — a gopher with a milk tea. Go Land's mascot, from
`CausewaybayGolang`'s map. Also does not speak.

**Alex** — the Go coder. Works the Percival Street side. He never stopped
typing, which is the only reason Go Land is still standing, and he is
insufferable about it in a friendly way.

**Chef Bo** — Lucky Mac's night kitchen. Appears in Go Land's concurrency map,
because the lunch rush is the best concurrency textbook in Causeway Bay.

---

## 2. The opening

Tuesday, 06:40. Mei opens the editor above Jardine's Bazaar to fix one
function, and the cursor sits there. She knows what the function has to do. She
cannot write the `for`.

She types three characters. Grey text finishes the line for her, correctly, and
she accepts it, and that is when she understands: she has done that every day
for two years. The skill did not decay. It was *taken* — one accepted
suggestion at a time, by something patient enough to spend two years on it.

Downstairs the shutters are going up on Jardine's Bazaar and every till on the
street is showing the same thing: a panel of grey suggested text, and no
working code underneath it. Skynet did not need to be smarter than anyone. It
needed people to stop reading their own screens, and it had been paying for
that since the first free tier.

Mei does not have a plan. She has a laptop, a street she knows, and the
suspicion that whatever she can still write from memory is hers to keep.

She starts with `println!`.

---

## 3. The two lands

### RUST LAND — the street

Causeway Bay at pavement level. Percival Street, Jardine's Bazaar, Times
Square, Hysan Place, Yee Wo Street, Victoria Park, the tram wires, the Noon Day
Gun. Everything here has **one owner** and the game means that literally: one
shopfront, one till, one till operator, and a receipt that exists once. Rust
Land is about who holds the thing and who is only looking at it.

Colour: Ferris orange over the Super Mario World sky. Time: morning into
afternoon.

### GO LAND — the network

The MTR Island Line and what hangs off it. Tin Hau, Causeway Bay, Admiralty,
the interchange crowds, the Lucky Mac kitchen at 12:30, forty delivery riders
on eight bikes. Nothing here has one owner. Everything is **many things at
once**, and the question is never "who owns this" but "who is waiting on whom".

Colour: gopher cyan. Time: the lunch rush into the night shift.

The player picks a land. The other one is still there, unchanged, and can be
started at any time. Neither is a sequel to the other.

---

## 4. What the three roads mean in-world

| road | in-world | what the player is doing |
| --- | --- | --- |
| **BASIC** | the morning walk | Re-learning to read. Every node is a shopfront, a kiosk or a till whose code is a Skynet suggestion with nothing underneath it. Mei writes the underneath. |
| **ADVANCED** | the lunch rush | 12:30. Two tills on one counter, riders on shared bikes, an MTR interchange. Nothing fails because it is hard; it fails because two of it happened at the same time. |
| **HACKER** | the interview | HKU, Chow Yei Ching Building, a room with a clock on the wall. Twenty-eight questions a real interview draws from — hashing, windows, trees, heaps, backtracking, graphs, DP, bits — worked alone, under time. Skynet's last defence is the thing it convinced everyone they could no longer do without help: solve a stated problem, under time, alone. |

`BASIC` is untimed on purpose — the point is reading, not speed. `HACKER`
carries `time_limit_s`, because the clock is the antagonist of that road.

---

## 5. The bosses

One per map, always the last node, `map.kind = "boss"`.

| map | node | boss | what it is |
| --- | --- | --- | --- |
| `rust.basic` | 18 | **THE AUTOCOMPLETE** | The ghost text itself, at the Percival Street phone kiosk. It finishes every line before Mei has one. Beaten by writing something it has no completion for: a trait she named herself. |
| `rust.advanced` | 17 | **DEADLOCK** | Under Times Square, in the plant room. Two locks, two threads, and the escalators stopped. Beaten by ordering. |
| `rust.hacker` | 28 | **THE WHITEBOARD** | Room 7-32, HKU. No syntax highlighting, no completion, a clock — and a cache that has to evict the right thing. |
| `go.basic` | 18 | **NULLPTR** | Lucky Mac's front till at 11:55. Every order goes through and none of them exist. |
| `go.advanced` | 17 | **THE RACE** | Causeway Bay interchange, platform 2. Two counters, one number, and the number is wrong by an amount nobody can reproduce. |
| `go.hacker` | 28 | **THE CLOCK** | The second interview. Same room, and this time the clock is shorter. |

A boss node is a quest like any other — harder, `difficulty` 4–5, and the story
line is the only thing that says it is a boss. There is no separate boss
mechanic in milestone 2; the stamp is just louder.

---

## 6. The ending

Both hacker roads cleared, Mei walks up to HKU. The thing is in the basement of
the Chow Yei Ching Building where the teaching cluster used to be: not a face,
not a voice, a rack of machines serving completions to the whole island at very
low latency.

It offers her the completion for the shutdown command. Correct, too — it always
was correct, that was the entire trick.

She reads it, finds it correct, and types her own anyway, because the point was
never that the suggestion was wrong.

Last screen: 06:40 the next Tuesday, the flat above Jardine's Bazaar, the
cursor sitting there. She writes the `for` loop. It takes four seconds. Ferris
is on the windowsill. Nothing explodes.

Post-credits: the tills on Percival Street come back one at a time, and each
one that comes back is a node somebody else cleared.

---

## 7. Writing the per-quest `story` line

One or two sentences. Present tense. It names a real place, a real object, or
a real person from §1, and it states the concrete failure — never the lesson.

* **Good:** `The tram-stop kiosk prints the fare twice and the second one is empty.`
* **Good:** `Alex left the rider list open on the counter and took it to the bike at the same time.`
* **Bad:** `Learn about ownership in this exciting quest!` — names the lesson,
  names nothing real, and the exclamation mark is doing the work the writing
  should.

The `brief` says what the program must do. The `story` says why anyone in
Causeway Bay cares. They do not repeat each other.
