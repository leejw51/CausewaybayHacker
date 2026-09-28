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

## 3. The nine lands

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

### TYPESCRIPT LAND — the screens

Causeway Bay after dark, when the screens come on. The big screen over Times
Square, the LED wall on Hysan Place, the tram-stop arrival boards on Yee Wo
Street, the Lee Garden shopping app on every phone in the queue, and the
signage control room on the thirtieth floor that feeds all of them from one
JSON file. Everything here is **a contract**: a type that says what will
arrive, checked once, before anything runs — and then erased. At runtime the
screen gets whatever the feed actually sent. The question is always "what did
the type promise, and what came down the wire".

Colour: TypeScript blue, brighter and colder than C++'s — LED blue off wet
tarmac. Time: 19:00 into midnight, the rain just stopped and every surface
reflecting a screen.

### REMIX LAND — the café on Sugar Street

A cha chaan teng at three in the afternoon, tea time: cream tiles, jade-green
stools, a ceiling fan, a glass cabinet of egg tarts, and one round table
where the three regulars sit — Gogo, Ferris and the python — and order the
same dish three ways. The drink is yuenyeung, coffee and tea in one cup, and
that is the whole land: **one program, three languages**, every concept a
trio of nodes, Go then Rust then Python, always in that order, with the same
tests. Nothing here is new grammar; it is the grammar of three other lands
laid side by side so the hand that just typed `for _, x := range` types `for
x in &xs` next and `for x in xs:` after that. Where a language has no such
construct — a lifetime in Go, a comprehension in Rust, ownership in Python —
the trio keeps its shape and the brief says what stands in. The land adds no
toolchain: each quest is judged by its own language's, and says which in its
`lang` (SPEC §12).

Two roads, the two grammar roads. On VERY BASIC the four lines on the napkin
are the line in the right language, the same line in the other two, and one
that is wrong in this one; on BASIC Mei types it. The boss is **THE
YUENYEUNG**: one hatch between the kitchen and the pass, three runners taking
whatever comes through it, and the hatch has to be closed when the kitchen
is done or the runners wait forever — a producer and many consumers, in a
channel, in an `mpsc` behind an `Arc<Mutex>`, and in a `queue.Queue` with a
sentinel per runner.

Colour: milk tea with the coffee in it, a caramel warmer and greyer than
Rust's orange. Time: 15:00, honey light through the front window.

### ZIG LAND — the toll plaza

The Causeway Bay portal of the Cross-Harbour Tunnel at first light: the toll
plaza, its row of booths with their coin trays, the axle counters, the Canal
Road flyover overhead with the villain-hitters already at work under it,
beating a paper Skynet with a slipper. Everything here is **explicit**: no
hidden control flow, no hidden allocation. Every toll is counted by hand,
every byte is paid for up front and handed back on the way out, every error
is a value in a return and is either handled or named. The question is always
"who pays for this, and who gives it back".

Nothing hides: a `?T` has to be unwrapped before it is read, an `!T` has to
be `try`'d or caught, an integer that overflows says so and stops, an index
past the end says so and stops. The land is built out of those checks, so
its programs are built in `-O Debug`, where every one of them is on.

Colour: Zig amber off wet concrete — a deeper, yellower orange than
Ferris's, under sodium lamps that have not been switched off yet. Time:
06:00, the first tram over the flyover, the last of the night traffic paying
its way out.

### LUA LAND — the fire dragon

Tai Hang on the fifteenth night of the eighth month: the Mid-Autumn fire
dragon, sixty-seven metres of straw and incense carried through the lanes by
three hundred people, the lanterns in Victoria Park, and the full moon over
all of it. *Lua* is the moon. Everything here is **a table**: the dragon is a
table of segments and the segments start at 1, the lanterns are a table of
tables, a function is a value that lives in one, and behind every object that
seems to be something more there is a metatable saying how. The question is
always "what is at this key, and what does the table do when nothing is".

The runtime is LuaJIT, the same one the LÖVE client runs on, so a program
that works on the desk works on the dragon. It is the one land whose whole
grammar fits on a napkin, and the one land where a missing key is not an
error until it is followed.

Colour: moon indigo — a lantern-lit violet-blue night, warmer than
TypeScript's LED blue and nothing like C++'s noon navy. Time: 21:00, the
drums starting, the incense lit, the moon just clear of the ridge.

The player picks a land. The others are still there, unchanged, and can be
started at any time. None of them is a sequel to another, and the hacker road
asks the same thirty-four questions in seven of them, so the interview can be
sat in whichever language the player is taking back. PyTorch Land's hacker
road is the exception and is meant to be: it is the machine-learning
interview, and its thirty-four questions are that interview's.

---

## 4. What the four roads mean in-world

| road | in-world | what the player is doing |
| --- | --- | --- |
| **VERY BASIC** | the first coffee | Before the walk: a question on a napkin. Four lines, one of them the real grammar — a type, a container, a thread, a mutex, a heap, a stack, a struct. Mei points at one, then writes it. The napkin is the road; nothing is timed. |
| **BASIC** | the morning walk | Re-learning to read, one line at a time. Every node is a shopfront, a kiosk or a till whose code is whole but for one to four lines. The node says what the construct is and shows the exact line; Mei types it and it compiles. Grammar activation, not a quiz, and untimed: the syntax, back in the fingers. On the street it is Rust's own grammar — who owns the receipt and who is only looking, two tills swapping drawers, how long a borrow is good for, four tills at once, and one hatch between the kitchen and the pass. |
| **ADVANCED** | the walk into the lunch rush | The live coding test, untimed: a brief, a whole program, hidden cases. Simple problems that use the grammar BASIC activated — ownership, slices, errors, traits and interfaces, pointers, iterators, generics: the road the game opened with, kept whole. Then 12:30. Two tills on one counter, riders on shared bikes, an MTR interchange. Nothing fails because it is hard; it fails because two of it happened at the same time. |
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
| `remix.verybasic` | 57 | **THE YUENYEUNG** | The same hatch, asked as a question first: four lines that close a channel, one Go's, one Rust's, one Python's, and one that closes nothing. Pick the one this file speaks. |
| `remix.basic` | 57 | **THE YUENYEUNG** | One hatch, three runners, and the hatch must be closed when the kitchen is done: `close(ch)`, `drop(tx)`, a `None` per runner. The same program, three ways, and the third is the boss. |
| `typescript.verybasic` | 27 | **ANY** | The feed arrives typed `any`, every check passes, and the Times Square screen shows `undefined` in forty-foot letters. One annotation would have caught it. |
| `typescript.basic` | 27 | **UNDEFINED** | `Cannot read properties of undefined (reading 'left')`: the tree of screen ids has a branch that is not there yet, and the insert has to look before it walks. |
| `typescript.advanced` | 34 | **THE EVENT LOOP** | The signage control room, one thread for every screen on the island. One callback never yields, and every board from Tin Hau to Hysan freezes on the same frame. |
| `typescript.hacker` | 34 | **THE ERASURE** | The sixth interview, Room 7-32. The types are gone at runtime and the clock is not. |
| `zig.verybasic` | 27 | **THE OVERFLOW** | Booth 3's axle counter is a `u8`. The two-hundred-and-fifty-sixth axle of the morning is not zero, it is `panic: integer overflow`, and the barrier stays down. One wider type would have carried it. |
| `zig.basic` | 27 | **THE NULL** | `panic: attempt to use null value`: an optional child, unwrapped with `.?` before anyone looked. The tree of toll receipts has a branch that is not there yet, and the insert has to look before it walks. |
| `zig.advanced` | 34 | **THE UNREACHABLE** | The flyover's lane model marks one branch `unreachable`, and at 07:59 the traffic reaches it. `panic: reached unreachable code`, and every lane closes at once. |
| `zig.hacker` | 34 | **THE TOLL** | The seventh interview, Room 7-32. Every allocation paid for, every error handled or named, and the clock. |
| `lua.verybasic` | 27 | **THE ZERO** | The dragon's segments are numbered from 1. `segments[0]` is `nil`, the head is nowhere, and the dance starts from the second lantern. |
| `lua.basic` | 27 | **NIL** | `attempt to index a nil value (field 'left')`: a child that is `nil`, followed. The tree of lantern numbers has a branch that is not there yet, and the insert has to look before it walks. |
| `lua.advanced` | 34 | **THE COROUTINE** | The incense runners along the dragon are coroutines, one per segment. One never yields, and the whole dragon stops on one segment with the drums still going. |
| `lua.hacker` | 34 | **THE MOON** | The eighth interview, Room 7-32, under the full moon. One table type for every structure, and the clock. |

On the merged ADVANCED road the four old BASIC bosses keep their stories but
lose the `boss` mark and their titles, so the name and the art belong to one
node per map: the last one.

A boss node is a quest like any other — harder, `difficulty` 4–5, and the story
line is the only thing that says it is a boss. There is no separate boss
mechanic in milestone 2; the stamp is just louder.

---

## 6. The ending

All six hacker roads cleared, Mei walks up to HKU. The thing is in the basement of
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
