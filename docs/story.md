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

**The platypus** (오리너구리) — C++ Land's mascot. It sits on the harbour wall
by the Noon Day Gun and watches addresses. A duck's bill, a beaver's tail, an
otter's feet, it lays eggs and it is still a mammal: the first naturalists to
see one went looking for the stitches, because nothing that is four things at
once is supposed to be one animal. That is the language, and the joke is not
only that — the spur behind its hind foot is venomous. It is the only mascot
here that can hurt you, and it will do it while looking harmless. Placeholder
art is a hue-shifted Ferris. Does not speak.

**The python** — Python Land's mascot, a small coiled python asleep on a
price board in the wet market. Placeholder art is a hue-shifted Gogo. Also
does not speak, but it is warm.

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

## 3. The five lands

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

### C++ LAND — the typhoon shelter and the Noon Day Gun

Causeway Bay's machinery. The gun that fires at 12:00 because something wrote
to the right register, the sampans in the typhoon shelter, the pump room under
Victoria Park's fountain, the Yacht Club slipway winch. Everything here is
**an address**. Nothing checks you. The question is always "what is actually
at that address right now, and who freed it".

Colour: ISO C++ blue, a deep blue haze. Time: noon, harsh sun off the water.

### PYTHON LAND — the wet market and the food hall

Bowrington Road wet market and the SOGO basement food hall. Stalls, price
boards, plastic bags, a notebook per stall. Everything here is **a dict**,
nothing is typed until it runs, and it runs at 06:00 when the stall opens.
The question is always "what shape is this thing, really, and when did it
turn into None".

Colour: Python gold, a warm amber haze. Time: dawn, wet floors, fluorescent
light.

### PYTORCH LAND — the teaching cluster

Two floors under the last interview: the basement of the Chow Yei Ching
Building at HKU, where the teaching cluster used to be and where the thing in
§6 actually lives. The rack aisle, the cold aisle, the fan wall, a console on
a trolley. Everything here is **a shape**, and the question is never "who owns
this" or "what is at that address" but "what shape is this, and which way is
the gradient flowing".

It is the one land that is not about a language. It is about the thing itself,
taken apart: a tensor, a gradient, a layer, a loss, a step — and then, on the
last node of the ADVANCED road, the whole architecture at fourteen thousand
parameters, completing a sequence it was taught. Mei does not beat it here.
She builds a small one, which is a different and more useful thing to have
done before §6.

Colour: torch flame, a red-orange off a black ceiling. Time: 23:00, machine-room
cold, and the only light in the room is the rack in front of you.

The player picks a land. The others are still there, unchanged, and can be
started at any time. None of them is a sequel to another, and the hacker road
asks the same thirty-four questions in four of them, so the interview can be
sat in whichever language the player is taking back. PyTorch Land's hacker
road is the exception and is meant to be: it is the machine-learning
interview, and its thirty-four questions are that interview's.

---

## 4. What the four roads mean in-world

| road | in-world | what the player is doing |
| --- | --- | --- |
| **VERY BASIC** | the first coffee | Before the walk: a question on a napkin. Four lines, one of them the real grammar — a type, a container, a thread, a mutex, a heap, a stack, a struct. Mei points at one, then writes it. The napkin is the road; nothing is timed. |
| **BASIC** | the morning walk | Re-learning to read, one line at a time. Every node is a shopfront, a kiosk or a till whose code is whole but for one or two lines — a type, a loop, a struct, a sort, a closure, a thread, a tree. The node says what the construct is and shows the exact line; Mei types it and it compiles. Grammar activation, not a quiz, and untimed: the syntax, back in the fingers. |
| **ADVANCED** | the walk into the lunch rush | Simple coding quizzes that use the grammar BASIC activated — ownership, slices, errors, traits and interfaces, pointers, iterators, generics: the road the game opened with, kept whole. Then 12:30. Two tills on one counter, riders on shared bikes, an MTR interchange. Nothing fails because it is hard; it fails because two of it happened at the same time. |
| **HACKER** | the interview | HKU, Chow Yei Ching Building, a room with a clock on the wall. Twenty-eight questions a real interview draws from — hashing, windows, trees, heaps, backtracking, graphs, DP, bits — worked alone, under time. Skynet's last defence is the thing it convinced everyone they could no longer do without help: solve a stated problem, under time, alone. |

`BASIC` is untimed on purpose — the point is reading, not speed. `HACKER`
carries `time_limit_s`, because the clock is the antagonist of that road.

---

## 5. The bosses

One per map, always the last node, `map.kind = "boss"`.

| map | node | boss | what it is |
| --- | --- | --- | --- |
| `rust.basic` | 27 | **THE AUTOCOMPLETE** | The ghost text itself, at the Percival Street phone kiosk. It finishes every line before Mei has one. Beaten by writing something it has no completion for: a binary search tree, inserted by hand, node by node. (The trait she named herself is on the ADVANCED road now, as *A TRAIT OF HER OWN*.) |
| `rust.advanced` | 33 | **DEADLOCK** | Under Times Square, in the plant room. Two locks, two threads, and the escalators stopped. Beaten by ordering. |
| `rust.hacker` | 28 | **THE WHITEBOARD** | Room 7-32, HKU. No syntax highlighting, no completion, a clock — and a cache that has to evict the right thing. |
| `go.basic` | 27 | **NULLPTR** | A nil child pointer, followed. The tree of orders at Lucky Mac has a branch that is not there yet, and the insert has to look before it walks. (The front till at 11:55 is on the ADVANCED road now, as *THE FRONT TILL*.) |
| `go.advanced` | 33 | **THE RACE** | Causeway Bay interchange, platform 2. Two counters, one number, and the number is wrong by an amount nobody can reproduce. |
| `go.hacker` | 28 | **THE CLOCK** | The second interview. Same room, and this time the clock is shorter. |
| `cpp.basic` | 27 | **SEGFAULT** | A `nullptr` child, dereferenced. The tree the gun's firing table is kept in has a branch that does not exist yet, and the insert has to check before it follows. (The address nobody owns is on the ADVANCED road now, as *THE WRONG ADDRESS*.) |
| `cpp.advanced` | 34 | **THE DANGLING** | Victoria Park's pump room: a thread still holding a reference to a buffer that was freed. |
| `cpp.hacker` | 34 | **THE LINKER** | The third interview, Room 7-32, a language with no safety net and a shorter clock. |
| `python.basic` | 27 | **NONE** | `'NoneType' object has no attribute 'left'`: a child that is `None`, followed. The tree of stall numbers has a branch that is not there yet. (The price board at 05:59 is on the ADVANCED road now, as *THE 05:59 BOARD*.) |
| `python.advanced` | 34 | **THE GIL** | SOGO basement, twelve stalls, one lock; everything "concurrent" ran one at a time. |
| `python.hacker` | 34 | **THE RECURSION LIMIT** | The fourth interview; depth 1000 and the clock. |
| `pytorch.verybasic` | 27 | **THE FIRST STEP** | Everything in place — a parameter, a loss, a gradient — and the number never moves. The optimiser was built and never asked to do anything. |
| `pytorch.basic` | 27 | **THE STRAIGHT LINE** | XOR. Four points, two classes, an hour of training, and two of the four still wrong. No straight line separates them, and no amount of training makes one. |
| `pytorch.advanced` | 34 | **THE COMPLETION** | The rack in the basement, at fourteen thousand parameters, on one laptop: token and position embeddings, causal attention, a GELU MLP, and a sequence it finishes because it was taught it. |
| `pytorch.hacker` | 34 | **THE TEACHING CLUSTER** | The fifth interview, Room 7-32, and the question is the thing two floors down. Build one block of it, and prove it cannot read the future. |

On the merged ADVANCED road the four old BASIC bosses keep their stories but
lose the `boss` mark and their titles, so the name and the art belong to one
node per map: the last one.

A boss node is a quest like any other — harder, `difficulty` 4–5, and the story
line is the only thing that says it is a boss. There is no separate boss
mechanic in milestone 2; the stamp is just louder.

---

## 6. The ending

All five hacker roads cleared, Mei walks up to HKU. The thing is in the basement of
the Chow Yei Ching Building where the teaching cluster used to be: not a face,
not a voice, a rack of machines serving completions to the whole island at very
low latency.

She has been down there before. PYTORCH LAND is that basement, and by the end
of it she has built a small one of these herself — which is why the last screen
is not a confrontation with something she does not understand.

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
