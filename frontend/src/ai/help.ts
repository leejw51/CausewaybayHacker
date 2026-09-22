/**
 * What the coder says about the code the caret is *sitting in*.
 *
 * The other half of the agent's offline voice. `tips.ts` talks about the
 * language; this talks about the line. It is the same deal as everything
 * else in docs/agent.md §1: no key, no network, no model — the grammar is
 * already in the tab, because CodeMirror parses Rust, Go, C++ and Python
 * with Lezer to colour them, and a parse tree that is good enough to
 * highlight a `match` arm is good enough to name it.
 *
 * `ui/editor.ts#contextAt` hands over a `CodeContext`: the caret, the word
 * it is on, the line so far, and the chain of node names from the innermost
 * node outward. `helpAt` reads that chain and answers one sentence, or
 * nothing. Two layers, most specific first:
 *
 *   1. **the word** — `unwrap`, `defer`, `enumerate`, `move`: a name the
 *      caret is actually on says more than the statement around it;
 *   2. **the construct** — walk the node chain outward past the anonymous
 *      nodes (`Block`, `Body`, a bare `{`) and past the error nodes a
 *      half-typed line leaves behind, and name the first thing known.
 *
 * Every answer has a stable `id`, like `tips.Advice`, so the controller can
 * say each one once and not nag. Pure, and `tests/help.test.ts` pins it
 * against real syntax trees rather than against a guess at the node names —
 * they differ per grammar, and a table written from memory would be wrong.
 *
 * English, on purpose, for the reason `tips.ts` gives: the catalogue is the
 * agent's own voice, and translating it is a job for a translator.
 */
import type { Land } from "../net/protocol";

/** What the editor knows about the caret, with no CodeMirror in the type. */
export interface CodeContext {
  /** Character offset of the caret in the document. */
  pos: number;
  /** Node names at the caret, innermost first, up to the root. */
  path: readonly string[];
  /** The identifier the caret is at the end of, or `""`. */
  word: string;
  /** The caret's line, up to the caret. */
  before: string;
  /** The whole document, for anything that needs more than the line. */
  source: string;
}

export interface Help {
  /** Stable, so the coder says each one once per pad. */
  id: string;
  text: string;
}

/**
 * Nodes that mean "the caret is in prose, not in code".
 *
 * Help inside a comment or a string is noise: the player is writing English,
 * and the grammar under the words is an accident of where the quotes are.
 */
const QUIET = new Set([
  "LineComment",
  "BlockComment",
  "Comment",
  "String",
  "RawString",
  "SystemLibString",
  "ContinuedString",
  "FormatString",
  "Char",
  "CharLiteral",
  "Rune",
]);

/**
 * The construct catalogue, per land, keyed by the Lezer node's own name.
 *
 * The names come from the four grammars themselves (`@lezer/rust`, `go`,
 * `cpp`, `python`) and the chains come from resolving a caret in a real
 * document — see the fixtures in `tests/help.test.ts`. Anything not in here
 * is transparent: the walk goes outward through it, which is how `Block`
 * under a `ForExpression` reports the loop rather than the braces.
 */
const NODES_BY_LAND = {
  rust: {
    MatchExpression:
      "`match` must cover every case. A `_ => …` arm is the catch-all, and the compiler counts the rest for you.",
    MatchArm: "A match arm is `pattern => value,`. Add `if cond` after the pattern to guard it.",
    ForExpression:
      "`for x in xs` consumes `xs`. `&xs` to borrow each item, `&mut xs` to change them, `xs.iter().enumerate()` for the index.",
    WhileExpression:
      "`while cond {}` — and `while let Some(x) = it.next() {}` loops until a pattern stops matching.",
    LoopExpression:
      "`loop {}` never ends on its own. `break value` leaves it, and the value is the loop's.",
    ClosureExpression:
      "`|a, b| expr` is a closure. It borrows what it uses; `move |…|` takes ownership, which is what a thread needs.",
    TryExpression:
      "`?` returns the error to the caller. It needs a function that returns `Result` or `Option`.",
    AwaitExpression: "`.await` yields to the runtime. Only inside an `async fn` or `async` block.",
    LetDeclaration:
      "`let` binds; `let mut` binds something you may change. Re-using the name is shadowing, not mutation.",
    IfExpression:
      "`if` is an expression: both branches give a value, and it is the value of the `if`.",
    FunctionItem:
      "`fn name(arg: T) -> R`. No return type means `()`. The last expression, with no `;`, is the answer.",
    StructItem: "A `struct` is the data; the behaviour goes in an `impl` block beside it.",
    EnumItem:
      "An `enum` is one of several shapes, each with its own fields. `match` is how you take it apart.",
    ImplItem:
      "`impl Type` holds inherent methods; `impl Trait for Type` implements someone else's contract.",
    TraitItem:
      "A `trait` is the interface. A method with a body in it is a default anyone may override.",
    UseDeclaration: "`use` only shortens a name. `use a::{b, c};` for two, `as` to rename a clash.",
    FieldDeclaration: "A struct field is `name: Type,` — and private until `pub` says otherwise.",
    Parameter:
      "Take `&str`, `&[T]` and `&T` to read; take the owned type when you need to keep it. `&mut` to change the caller's value.",
    ReferenceType:
      "`&T` borrows, `&mut T` borrows exclusively. The compiler allows many of the first or one of the second.",
    PointerType: "`*const T`/`*mut T` is a raw pointer — only dereferenced inside `unsafe`.",
    Lifetime:
      "`'a` names how long a reference is good for. It describes what is already true; it cannot extend anything.",
    MacroInvocation:
      "A `!` is a macro: it runs at compile time and its arguments are not ordinary expressions.",
    UnsafeBlock:
      "`unsafe` turns off five checks, not the borrow checker. Keep the block as small as the one line that needs it.",
    AsyncBlock: "`async {}` makes a future. Nothing in it runs until something awaits it.",
    ReturnExpression:
      "An early `return` is fine; the last expression without a `;` returns too, and reads better.",
    TypeCastExpression:
      "`as` is a narrowing cast and it can silently lose bits. `try_into()` says when it would.",
    RangeExpression: "`0..n` stops before `n`; `0..=n` includes it.",
    WhereClause:
      "A `where` clause is the same bounds, moved off the signature so the signature stays readable.",
    IndexExpression:
      "`xs[i]` panics when `i` is past the end. `xs.get(i)` gives an `Option` instead.",
    StructExpression:
      "`Point { x, y }` — a bare name is `x: x`, and `..other` fills the fields you left out.",
  },
  go: {
    RangeClause:
      "`for i, v := range xs` — one variable is the index (the key, for a map), two are index and value. `_` drops one.",
    ForStatement:
      "Go has one loop word. `for {}` is forever, `for cond {}` is a while, `for i := …; …; … {}` is the C one.",
    IfStatement:
      "`if v, err := f(); err != nil {}` scopes `v` and `err` to the `if`. There is no ternary; write the `else`.",
    DeferStatement:
      "`defer` runs at return, in reverse order, even on a panic. Its arguments are evaluated now, not then.",
    GoStatement:
      "`go f()` starts a goroutine and returns at once. Nobody waits for it unless you make them.",
    SelectStatement:
      "`select` takes whichever channel is ready. A `default` makes it non-blocking; none makes it wait.",
    SelectBlock:
      "Each `case` is one channel operation. Two ready at once is settled at random, on purpose.",
    SwitchStatement:
      "Go's `switch` does not fall through. Cases may be expressions, and `switch {}` with none is an if-chain.",
    SwitchBlock:
      "A case body ends at the next `case`; say `fallthrough` on its own line if you truly want the next one.",
    TypeSwitchStatement: "`switch v := x.(type)` gives `v` the case's own type inside each arm.",
    StructType:
      "A struct is its fields. Embed a type with no field name and its methods come along.",
    FieldDecl:
      "`Name Type` — capitalised is exported. A back-quoted tag after the type is metadata for encoders.",
    InterfaceType:
      "An interface is a list of methods. Any type with those methods satisfies it; nothing is declared.",
    MethodElem: "A method in an interface is `Name(args) results` — no body, no receiver.",
    FunctionDecl:
      "`func f(a, b int) (int, error)`. Two results is the idiom, and the error is the last of them.",
    MethodDecl:
      "The receiver goes before the name: `func (s *S) M()`. Pointer receiver to change `s` or to avoid a copy.",
    FunctionLiteral:
      "An anonymous `func` closes over the variables it names — not over copies of them.",
    MapType:
      "`map[K]V` — reading a missing key gives the zero value; `v, ok := m[k]` tells you which. Writing to a nil map panics.",
    SliceType:
      "`[]T` is a window on an array. `append` may return a new one, so always assign the result back.",
    ChannelType:
      "`chan T` both ways, `<-chan T` to receive, `chan<- T` to send. The arrow says which end you are given.",
    SendStatement:
      "`ch <- v` blocks until somebody receives, unless the channel is buffered and has room.",
    ReceiveStatement: "`v, ok := <-ch` — `ok` is false once the channel is closed and drained.",
    TypeAssertion:
      "`x.(T)` panics when it is not a `T`. `v, ok := x.(T)` asks instead of insisting.",
    ReturnStatement:
      "Named results may be returned bare, but naming them only to `return` is a habit worth skipping.",
    PointerType:
      "`*T`. No pointer arithmetic, and `nil` is the zero value — check before you dereference.",
    LabeledStatement: "A label is what `break` and `continue` use to leave the *outer* loop.",
    ImportDecl:
      "The path is the import; the last element is the package name unless a name is written before it.",
    VarDecl:
      "`var x T` gives the zero value; `x := v` infers the type and only works inside a function.",
    ConstDecl:
      "Constants are untyped until used, which is why `const big = 1 << 40` compiles on a 32-bit int.",
    TypeParams:
      "`[T any]` — generics. Constrain with an interface, and `comparable` is the one for map keys.",
  },
  cpp: {
    ForRangeLoop:
      "`for (const auto& x : xs)` reads without copying; `auto&` to change them. The index cannot be wrong because there is none.",
    ForStatement:
      "`for (init; cond; step)`. The counter's type is `size_t` when it is comparing against `.size()`.",
    WhileStatement: "`while (cond)` tests first; `do … while (cond);` runs once before it tests.",
    DoStatement: "`do { … } while (cond);` — and the semicolon at the end is required.",
    IfStatement:
      "`if (auto it = m.find(k); it != m.end())` scopes `it` to the `if`. `if constexpr` decides at compile time.",
    SwitchStatement:
      "Cases fall through unless you `break`. Say `[[fallthrough]];` when you meant it.",
    CaseStatement: "A `case` needs a constant. Declaring a variable in one needs its own braces.",
    TryStatement:
      "`try { … } catch (const std::exception& e)` — catch by `const&`, never by value.",
    CatchClause:
      "Catch by `const&`; `catch (...)` catches everything and can only rethrow usefully.",
    ThrowStatement: "`throw` unwinds and runs every destructor on the way. Never throw from one.",
    LambdaExpression:
      "`[capture](args) { … }` — `[&]` by reference, `[=]` by copy, `mutable` to change a copy.",
    LambdaCaptureSpecifier:
      "`[&]` borrows the enclosing frame: safe while it lives, dangling after it returns.",
    ClassSpecifier: "A `class` is private by default, a `struct` public. Nothing else differs.",
    StructSpecifier:
      "A `struct` is a class with public members. Give it no destructor and the compiler's rules stay simple.",
    UnionSpecifier:
      "A union holds one member at a time. `std::variant` remembers which; a union does not.",
    EnumSpecifier:
      "`enum class E` scopes the names and refuses to convert to `int` by accident. Prefer it.",
    TemplateDeclaration:
      "A template is compiled once per type it is used with, so it lives in the header.",
    TemplateParameterList:
      "`typename T` and `class T` mean the same thing here. `auto` is a value parameter.",
    NamespaceDefinition:
      "A namespace keeps names apart. An unnamed one is this file's own private scope.",
    UsingDeclaration:
      "`using std::string;` brings one name. `using namespace` in a header brings all of them, to everyone.",
    FieldDeclaration:
      "A member. Give it a default right here (`int n = 0;`) and every constructor inherits it.",
    FieldInitializerList:
      "The `: a(x), b(y)` list initialises; assigning in the body default-constructs first and then overwrites.",
    NewExpression:
      "A bare `new` needs a `delete` on every path out. `std::make_unique<T>(…)` needs none.",
    DeleteExpression:
      "If you are writing `delete`, ask who owns the thing — a `unique_ptr` would have said.",
    PointerDeclarator:
      "`T*` says nothing about ownership. `unique_ptr`, `shared_ptr` and `T&` all say something.",
    ReferenceDeclarator:
      "`T&` cannot be null and cannot be reseated. `const T&` to read a big object without copying.",
    FunctionDefinition:
      "Take `const&` for big parameters, by value for what you would copy anyway, and mark it `const` if it reads.",
    ParameterDeclaration:
      "By value copies. `const T&` to read, `T&` to write through, `T&&` to take.",
    PreprocDirective:
      "The preprocessor is text substitution before the compiler sees anything. Prefer `constexpr` to `#define`.",
    CastExpression:
      "`static_cast<T>` for the ones that make sense, `dynamic_cast` for a downcast that may fail. Never the C cast.",
    SizeofExpression:
      "`sizeof` is the compile-time size in bytes; `std::size(xs)` is the element count.",
    CoAwaitExpression: "`co_await` makes this function a coroutine — its return type must say so.",
  },
  python: {
    ForStatement:
      "`for x in xs`. `enumerate(xs)` when you want the index, `zip(a, b)` for pairs, `range(n)` for plain counting.",
    WhileStatement:
      "`while cond:` — and the `else:` after a loop runs when it ended without a `break`.",
    IfStatement:
      "`elif`, not `else if`. An empty list, string, dict or `0` is all falsey; `is None` for the None test.",
    TryStatement:
      "`except ValueError as e:` names what you expect. `finally:` runs either way; `else:` runs when nothing raised.",
    WithStatement:
      "`with` closes the thing at the end of the block, exception or not. Several on one line, comma-separated.",
    FunctionDefinition:
      "`def f(a, b=1, *args, **kw):`. A default is evaluated once, at definition — never a list or a dict.",
    ClassDefinition:
      "`__init__` is the constructor; `self` is explicit. Methods live in the class body, at one indent.",
    LambdaExpression:
      "`lambda x: expr` is one expression, no statements. Anything longer wants a `def`.",
    ArrayComprehensionExpression:
      "`[f(x) for x in xs if cond]` builds a list. Two `for`s nest left to right.",
    DictionaryComprehensionExpression: "`{k: v for k, v in pairs}` builds a dict. Later keys win.",
    SetComprehensionExpression: "`{x for x in xs}` builds a set — unordered, no duplicates.",
    ComprehensionExpression:
      "`(f(x) for x in xs)` is a generator: nothing runs until it is iterated, and it runs once.",
    YieldStatement:
      "`yield` makes the function a generator. It resumes where it left off, holding one value at a time.",
    YieldExpression:
      "`yield from it` delegates to another iterable; a bare `yield` as a value receives from `.send()`.",
    AwaitExpression:
      "`await` only inside `async def`, and only on something awaitable. Blocking calls still block the loop.",
    Decorator:
      "`@d` is `f = d(f)`. Use `functools.wraps` inside one so the name and docstring survive.",
    DecoratedStatement: "The decorators run bottom-up at definition time, not per call.",
    MatchStatement:
      "`match x:` with `case` patterns — structural, not a switch. A bare name in a case *binds*, it does not compare.",
    MatchClause: '`case [a, b]:`, `case {"k": v}:`, `case Point(x=0):`. `case _:` is the default.',
    ImportStatement:
      "`from x import y` binds `y` here. A module is executed once, the first time anyone imports it.",
    AssertStatement:
      "`assert` disappears under `python -O`. Never put a check you actually need in one.",
    RaiseStatement:
      "`raise E(msg) from err` keeps the original in the traceback. Bare `raise` inside `except` re-raises.",
    ScopeStatement:
      "`global` and `nonlocal` say which scope a name is assigned in. Passing and returning usually reads better.",
    DeleteStatement: "`del` removes the name, and the object goes when the last name to it does.",
    DictionaryExpression:
      "Dicts keep insertion order. `d.get(k, default)` never raises; `d[k]` raises `KeyError`.",
    SetExpression: "`{1, 2}` is a set; `{}` is an empty dict. `set()` is the empty set.",
    TupleExpression: "A tuple is fixed and hashable; the comma makes it, not the brackets.",
    NamedExpression:
      "`:=` assigns inside an expression — `if (n := len(xs)) > 3:`. Worth it only when it saves a line.",
    ConditionalExpression:
      "`a if cond else b` — the value-shaped `if`. Keep it to one line's worth.",
    ParamList:
      "`*` alone makes everything after it keyword-only; `/` makes everything before it positional-only.",
    ArgList:
      "Keyword arguments may come in any order. `*xs` spreads a list, `**kw` spreads a dict.",
  },
};

/**
 * PyTorch Land is parsed by the same `@lezer/python` grammar, so a `for` is a
 * `ForStatement` in both and the construct help is the same sentence. The
 * *words* differ, and those are the catalogue below.
 */
const NODES: Record<Land, Record<string, string>> = {
  ...NODES_BY_LAND,
  pytorch: NODES_BY_LAND.python,
};

/**
 * The word catalogue: names worth a sentence when the caret is on one.
 *
 * Checked before the construct, because "you are on `unwrap`" is more use
 * than "you are in a let declaration" — the caret picked the word out.
 */
const WORDS: Record<Land, Record<string, string>> = {
  rust: {
    unwrap:
      '`unwrap()` is a crash with no message. `?` hands the error up, `unwrap_or(d)` picks a value, `expect("why")` at least says what broke.',
    expect:
      '`expect("…")` is an `unwrap` that tells the reader what was supposed to be true. Write the sentence.',
    clone:
      "`clone()` copies the whole thing. Ask whether a `&` borrow would do, especially inside a loop.",
    collect: "`collect()` needs to know the target: `collect::<Vec<_>>()` or a `let v: Vec<_> =`.",
    iter: "`iter()` borrows, `iter_mut()` lends, `into_iter()` consumes. That is the whole difference.",
    move: "`move` makes the closure own what it captures — required for a thread, and for anything outliving the frame.",
    mut: "`mut` on a binding means you may change it; `&mut` on a reference means you have the only one.",
    dyn: "`dyn Trait` is a vtable at runtime; `impl Trait` is one concrete type chosen at compile time.",
    Box: "`Box<T>` puts one value on the heap. `Box<dyn Trait>` is how a trait object gets a size.",
    Rc: "`Rc<T>` is shared ownership on one thread; `Arc<T>` across threads. Neither lets you mutate — pair with `RefCell`/`Mutex`.",
    RefCell:
      "`RefCell` moves the borrow check to runtime: two `borrow_mut()`s alive at once is a panic, not an error.",
    Arc: "`Arc<T>` is a thread-safe `Rc`. `Arc<Mutex<T>>` is the usual pair for shared mutable state.",
    Mutex:
      "`lock()` gives a guard; the lock is released when the guard drops. Hold it for as few lines as possible.",
    Option:
      "`Option<T>` is a checked null. `if let`, `match`, `unwrap_or`, `map` — anything but `unwrap()`.",
    Result: "`Result<T, E>` is a value or a reason. `?` is the short way to pass the reason up.",
    Some: "`Some(x)` in a pattern binds `x` only when there is one. `None` is the other arm and the compiler counts them.",
    Ok: "`Ok(v)` and `Err(e)` are the two arms. Returning `Ok(())` is how a `fn` that only does work reports success.",
    Err: "`Err(e)` is a returned value, not a thrown thing. `?` is what makes it read like an exception.",
    impl: "`impl Type` for your own methods, `impl Trait for Type` for somebody else's. Both may exist for one type.",
    derive:
      "`#[derive(Debug, Clone, PartialEq)]` writes the obvious implementation. `Debug` first — it is what `{:?}` needs.",
    unsafe:
      "`unsafe` promises *you* checked. It turns off five specific checks and none of the borrow rules.",
    println:
      '`println!("{}", x)` needs `Display`; `{:?}` needs `Debug`; `{x}` reads the variable by name.',
    matches:
      "`matches!(v, Pattern)` is a `match` that answers a bool — the short way to ask about one shape.",
    as_ref:
      "`as_ref()` turns `&Option<T>` into `Option<&T>`, which is what lets you look without moving.",
    to_string:
      "`to_string()` allocates. Inside a signature, take `&str` and let the caller decide.",
    Vec: "`Vec<T>` grows on the heap. `with_capacity(n)` when you know the count; `&[T]` in a signature.",
    String: "`String` owns, `&str` borrows. Parameters take `&str`, returns give `String`.",
  },
  go: {
    defer:
      "`defer` runs at return, in reverse. Its arguments are evaluated at the `defer`, not at the return.",
    panic:
      "`panic` ends the program unless a `recover` in a deferred function catches it. Return an error instead.",
    recover:
      "`recover()` only works inside a deferred function, and only in the goroutine that panicked.",
    append:
      "`xs = append(xs, v)` — it may return a new backing array, so the assignment is not optional.",
    make: "`make` is for slices, maps and channels; it initialises. `new` gives a zeroed pointer and is rarely what you want.",
    range: "`range` over a map is randomised on purpose. Sort the keys when the order matters.",
    chan: "An unbuffered channel is a handshake. `make(chan T, n)` buffers `n` before the sender waits.",
    close:
      "Close from the sender, once. Receiving from a closed channel gives the zero value and `ok == false`.",
    select: "`select` waits on several channels; with a `default` it does not wait at all.",
    go: "`go f(x)` evaluates `x` now and runs `f` later. Nothing waits for it — use a `WaitGroup` or a channel.",
    err: '`if err != nil { return err }`. Wrap to add context: `fmt.Errorf("reading %s: %w", name, err)`.',
    nil: "A nil slice appends and ranges fine. A nil map reads fine and panics on write. A nil pointer panics on both.",
    interface:
      "`interface{}` (or `any`) holds anything and tells you nothing. Assert or type-switch to get it back.",
    context:
      "`ctx context.Context` is the first parameter. Cancelling it is the only polite way to stop work.",
    sync: "`sync.Mutex` zero value is ready to use. Never copy a struct that contains one.",
    WaitGroup:
      "`Add` before the `go`, `Done` in a `defer` inside it, `Wait` after. `Add` inside the goroutine races.",
    Sprintf: "`Sprintf` builds a string; in a loop, a `strings.Builder` avoids a copy per turn.",
    Errorf:
      "`%w` in `fmt.Errorf` keeps the original error reachable by `errors.Is` and `errors.As`.",
    struct: "`struct{}{}` is the zero-byte value — the idiomatic element for a set built on a map.",
    map: "`m[k]` on a missing key gives the zero value. `v, ok := m[k]` is how you tell missing from zero.",
    string:
      "Indexing a string gives bytes; `range` over it gives runes. `[]rune(s)` when you need characters.",
  },
  cpp: {
    new: "A bare `new` needs a `delete` on every path out, including the one an exception takes. `make_unique` needs none.",
    delete: "If you wrote `delete`, something owns this and did not say so in the type.",
    auto: "`auto` keeps the type and saves the typing. `auto&` to bind a reference; plain `auto` copies.",
    const:
      "`const` on a member function promises it does not change the object. Put it on everything that reads.",
    constexpr: "`constexpr` may run at compile time; `consteval` must. Both beat a `#define`.",
    static:
      "Three meanings: file-local, class-wide, and function-local-but-persistent. Which one depends on where it is.",
    virtual:
      "A `virtual` function dispatches at runtime. A base class with any of them needs a virtual destructor.",
    override:
      "Write `override` — without it, a changed signature silently becomes a new function instead of an error.",
    unique_ptr:
      "`std::unique_ptr` costs nothing at runtime and says who owns the thing. Move it to hand it over.",
    shared_ptr:
      "`shared_ptr` counts references; a cycle never reaches zero. `weak_ptr` breaks the cycle.",
    move: "`std::move` moves nothing — it casts, so the callee is allowed to. The moved-from object is valid but unspecified.",
    forward:
      "`std::forward<T>(x)` preserves the caller's value category. Only inside a template with a `T&&` parameter.",
    vector:
      "`std::vector` first, always. `reserve(n)` when you know the count; `emplace_back` to build in place.",
    string_view:
      "`string_view` looks at characters it does not own. Never return one pointing at a local.",
    endl: "`std::endl` is `'\\n'` plus a flush. In a loop, the flush is the slow part — use `'\\n'`.",
    namespace:
      "`using namespace std;` in a header pollutes everyone downstream. `std::` is three characters.",
    template:
      "A template is checked properly only when instantiated, which is why the error arrives at the call site.",
    noexcept:
      "`noexcept` is a promise; break it and the program terminates. Move constructors want it.",
    nullptr: "`nullptr` has a type; `NULL` and `0` do not, and pick the wrong overload.",
    size_t:
      "`size()` returns unsigned. Compare an `int` against it and the `int` converts — which is how `i < size()` surprises you.",
    emplace_back:
      "`emplace_back` constructs in place from the arguments; `push_back` takes a built object.",
  },
  python: {
    enumerate: "`for i, x in enumerate(xs)` — and `start=1` when you are numbering for a human.",
    zip: "`zip(a, b)` stops at the shorter. `strict=True` raises instead, which is usually what you meant.",
    range:
      "`range(n)` stops before `n`. It is lazy — `list(range(n))` if you actually need the list.",
    yield: "`yield` makes a generator: it produces one value at a time and remembers where it was.",
    lambda:
      "`lambda` holds one expression. If you are reaching for a statement, it wants to be a `def`.",
    self: "`self` is the instance, passed explicitly. It is a convention, but breaking it confuses every reader and tool.",
    None: "`is None`, not `== None`. A function with no `return` returns `None`.",
    global:
      "`global` says this name is assigned at module level. Passing it in and returning it out is almost always better.",
    nonlocal:
      "`nonlocal` reaches the enclosing function's binding — the one thing a closure cannot otherwise assign.",
    assert:
      "`assert` vanishes under `python -O`. Use it for what cannot happen, `raise` for what can.",
    open: "`with open(path) as f:` — closed at the end of the block, exception or not. Pass `encoding=` explicitly.",
    print:
      '`print(*xs, sep=", ")` and `end=""`. `file=sys.stderr` when it is a diagnostic, not output.',
    format: 'f-strings read better: `f"{x:>8.2f}"`, and `f"{x=}"` prints the name with the value.',
    sorted:
      "`sorted(xs, key=…)` returns a new list; `xs.sort()` sorts in place and returns `None`.",
    len: "`len(xs)` on a generator is an error — generators have no length until you consume them.",
    dict: "`dict.get(k, default)` never raises. `setdefault` and `collections.defaultdict` for the accumulate pattern.",
    set: "A set has no order and needs hashable members. `{}` is a dict; `set()` is the empty set.",
    isinstance:
      "`isinstance(x, (int, float))` takes a tuple. Prefer asking whether it can do the thing over what it is.",
    super:
      "`super().__init__(…)` follows the MRO, which is why it is right even with multiple inheritance.",
    staticmethod:
      "`@staticmethod` takes no `self`; `@classmethod` takes `cls` and is how you write a second constructor.",
    property:
      "`@property` makes a method read like an attribute. Keep it cheap — callers will treat it as one.",
    async:
      "`async def` makes a coroutine; nothing in it runs until awaited or scheduled on a loop.",
    await: "`await` yields the loop to other work. A blocking call inside one stops everything.",
    except: "Name the exception. A bare `except:` also catches Ctrl-C and `SystemExit`.",
    finally:
      "`finally` runs on the way out, including through a `return`. A `return` inside one swallows the exception.",
    import:
      "Import at the top, absolute paths. A circular import usually means the two modules are one.",
  },
  pytorch: {
    tensor:
      "`torch.tensor(data)` copies the data and infers the dtype: a list of ints gives `int64`, a list with a `.` in it gives `float32`.",
    shape:
      "`x.shape` is a `torch.Size`, which is a tuple. Print it before anything else — most PyTorch bugs are a shape you assumed.",
    reshape:
      "`reshape` copies when it has to, so it works on a transposed tensor. `view` refuses one. `-1` means work this axis out from the others.",
    view: "`view` needs the memory already laid out that way. After a `transpose` it raises; `reshape` or `.contiguous().view(…)` is the fix.",
    backward:
      "`loss.backward()` is called on the end of the graph, never on a parameter, and it **adds** into `.grad` rather than replacing it.",
    grad: "`.grad` is `None` until a backward pass has run, and keeps accumulating after that. `zero_grad()` is what clears it.",
    zero_grad:
      "Clear, compute, apply: `opt.zero_grad()`, `loss.backward()`, `opt.step()`. Any other order applies a gradient from last time.",
    step: "`opt.step()` is the line that actually moves the parameters. Without it the gradient is computed and thrown away.",
    no_grad:
      "`with torch.no_grad():` stops the graph being recorded. It does **not** turn dropout off — that is `model.eval()`.",
    eval: "`model.eval()` switches dropout off and batch-norm to its running statistics. Serving a model still in `train()` is the classic bug.",
    detach:
      "`detach()` leaves the graph and shares the memory. `clone()` copies and stays in it. For a snapshot you want `detach().clone()`.",
    item: "`.item()` pulls the Python number out of a one-element tensor. Log that, not the tensor — the tensor keeps its whole graph alive.",
    softmax:
      "`torch.softmax(x, dim=…)` needs the axis. On `(batch, classes)` it is `dim=1`; `dim=0` makes the batch sum to one, which means nothing.",
    CrossEntropyLoss:
      "Takes **raw logits** and **integer** labels. The softmax is inside it, so softmaxing first applies it twice and training stalls.",
    Linear:
      "`nn.Linear(in_features, out_features)` — in first, out second. The weight is stored as `(out, in)`, which is why the forward pass transposes it.",
    Module:
      "Assign layers to `self` in `__init__` so they register as parameters, and call `super().__init__()` first. A layer in a plain list never trains.",
    forward:
      "Call the model, not `model.forward(x)` — calling it runs the hooks that `forward` alone skips.",
    parameters:
      "`model.parameters()` yields the learnable tensors. `sum(p.numel() for p in …)` is the parameter count; `len(…)` is the tensor count.",
    keepdim:
      "`keepdim=True` leaves the reduced axis in as size 1, so the result still broadcasts back against the original.",
    masked_fill:
      "Mask the **scores** with `-inf` before the softmax. Zeroing probabilities afterwards leaves a row that sums to less than one.",
    manual_seed:
      "`torch.manual_seed` fixes one global stream, so anything else that draws from it shifts your numbers. A `torch.Generator` is a stream of its own.",
  },
};

/** Nodes with no teaching value of their own: the walk goes straight past. */
const THROUGH =
  /^(⚠|Block|Body|SourceFile|Script|Program|StatementGroup|SpecList|DeclarationList)$/;

/**
 * One sentence about where the caret is, or nothing.
 *
 * Nothing is a perfectly good answer: in a comment, in a string, on a blank
 * document, or in a construct the catalogue has no opinion about, the coder
 * has better things to say.
 */
/** Whether the caret is inside a comment or a string. */
export function inProse(path: readonly string[]): boolean {
  for (const name of path) if (QUIET.has(name)) return true;
  return false;
}

export function helpAt(lang: Land, ctx: CodeContext): Help | null {
  if (inProse(ctx.path)) return null;
  const word = WORDS[lang][ctx.word];
  if (word) return { id: `${lang}.w.${ctx.word}`, text: word };
  const table = NODES[lang];
  for (const name of ctx.path) {
    if (THROUGH.test(name)) continue;
    const text = table[name];
    if (text) return { id: `${lang}.n.${name}`, text };
  }
  return null;
}

/** Every id the catalogue can produce, for the test that keeps them short. */
export function catalogue(): Help[] {
  const out: Help[] = [];
  for (const lang of Object.keys(NODES) as Land[]) {
    for (const [k, text] of Object.entries(WORDS[lang])) out.push({ id: `${lang}.w.${k}`, text });
    for (const [k, text] of Object.entries(NODES[lang])) out.push({ id: `${lang}.n.${k}`, text });
  }
  return out;
}
