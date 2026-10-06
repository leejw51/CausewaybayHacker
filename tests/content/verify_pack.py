#!/usr/bin/env python3
"""Verify a Causewaybay Hacker content pack against SPEC.md §5 and §12.

Usage: verify_pack.py content/rust/basic.toml [more.toml ...]
       verify_pack.py --i18n content/rust/basic.toml [more.toml ...]

`--i18n` checks the translations of the given English packs instead (SPEC
§12.1). For every locale in ko yue zh ja cs, a file
`content/i18n/<locale>/<pack>.toml` that exists must keep every rule: cover
only real quest ids, keep each quest's hint count, use ''' for
`brief`/`story`, and carry the English brief's fenced code blocks verbatim.
Breaking a rule fails; not having started a language does not — coverage is
printed per locale, and `--require-complete` makes it a failure for the
final sweep. Nothing is compiled in this mode.

For every quest it:
  * checks the structural rules of SPEC §12 (id shape, node contiguity,
    requires chain, map layout, visible case, concept vocabulary)
  * compiles and runs `solution` with the real toolchain against every case
    and compares under the declared `match` mode
  * compiles and runs `starter` and asserts it does NOT pass (SPEC §9.5)
"""
import os, re, shutil, subprocess, sys, tomllib, tempfile, pathlib, json

# Written by PM and lifted into tests/ by QA so SPEC §9.4 and §9.5 have one
# implementation rather than two. Re-lifted 2026-09-11 to pick up the brief
# worked-example gate and `--complete`. The only local change is the paths,
# which were absolute in the original; they are derived now, so the script
# runs from a checkout anywhere and CI does not have to be this machine.
#
#   REPO    the checkout this file lives in
#   SCRATCH per-run build directories, wiped on every run
#   CACHE   the toolchain caches, kept between runs — the first Go build is
#           the slow one and there is no reason for it to be the slow one twice
#
# Both land under $CAUSEWAYBAY_HACKER_HOME/build when that is set, honouring
# SPEC §1's "nothing outside the home is written"; otherwise under the
# system temp directory, never in the project tree.
REPO = pathlib.Path(__file__).resolve().parents[2]
_home = os.environ.get("CAUSEWAYBAY_HACKER_HOME")
_root = (
    pathlib.Path(_home) / "build" / "content-ci"
    if _home
    else pathlib.Path(tempfile.gettempdir()) / "cwbhacker-content-ci"
)
#
# SCRATCH is **per process**. It used to default to one fixed path that the
# script `rmtree`s at startup, which is fine alone and a race the moment two
# agents run packs at the same time: the second run's wipe deletes the first
# run's build directory mid-compile, and the first dies with a
# `FileNotFoundError` that looks like nothing to do with content. That
# happened. The PID keeps runs out of each other's way without needing a lock.
#
# CACHE is deliberately **shared**: it is the toolchain cache, the first Go
# build is the slow one, and there is no reason for it to be the slow one
# once per process. `go` and `cargo` both lock their own caches, so sharing
# it is safe in a way that sharing a scratch directory is not.
SCRATCH = pathlib.Path(
    os.environ.get("CWBHACKER_CI_SCRATCH", _root / f"run-{os.getpid()}")
)
CACHE = pathlib.Path(os.environ.get("CWBHACKER_CI_CACHE", _root / "cache"))

ID_RE = re.compile(r"^(rust|go|cpp|python|pytorch|typescript|remix|zig|lua)\.(verybasic|basic|advanced|hacker|frameworks)\.(\d{2})\.([a-z0-9]+(?:-[a-z0-9]+)*)$")

# The crate shelf (SPEC §5.1): `backend/runner/shelf/Cargo.toml` names every
# crate a Rust quest may `use`, pinned, and the lockfile beside it is copied
# into every such build. The runner embeds the same two files; this script
# reads them off disk, so there is one shelf and not a copy of it here.
SHELF = REPO / "backend" / "runner" / "shelf"


def shelf_names():
    """The keys of the shelf's `[dependencies]` table, in order."""
    return [line.split("=")[0].strip() for line in shelf_dependency_lines()]


def shelf_dependency_lines():
    lines = (SHELF / "Cargo.toml").read_text().splitlines()
    out, inside = [], False
    for line in lines:
        s = line.strip()
        if s.startswith("["):
            inside = s == "[dependencies]"
            continue
        if inside and s and not s.startswith("#"):
            out.append(s)
    return out


def shelf_digest():
    """sha256 over Cargo.toml then Cargo.lock — what the runner's marker holds too."""
    import hashlib
    h = hashlib.sha256()
    h.update((SHELF / "Cargo.toml").read_bytes())
    h.update((SHELF / "Cargo.lock").read_bytes())
    return h.hexdigest()


def cargo_env():
    """A quest build's environment (runner `toolchain_env`): the caches under
    CACHE, and nothing of this shell's `RUSTFLAGS` or `~/.cargo/config`, which
    would change every artifact's hash and make the warm shelf cold."""
    e = {
        "PATH": os.environ["PATH"],
        "HOME": str(CACHE),
        "RUSTUP_HOME": os.environ.get("RUSTUP_HOME", str(pathlib.Path.home() / ".rustup")),
        "CARGO_HOME": str(CACHE / "cargo-home"),
        "CARGO_TARGET_DIR": str(CACHE / "target"),
        "CARGO_TERM_COLOR": "never",
    }
    for name in ("RUSTUP_TOOLCHAIN", "HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy",
                 "NO_PROXY", "no_proxy", "SSL_CERT_FILE", "SSL_CERT_DIR", "CARGO_HTTP_CAINFO"):
        if name in os.environ:
            e[name] = os.environ[name]
    return e


_shelf_warm = False


def ensure_shelf():
    """Build the shelf into CACHE once per cache — `cwbhacker warm`, for the
    gate. The marker holds the digest, so a shelf edited since is rebuilt;
    the network is needed only when it is."""
    global _shelf_warm
    if _shelf_warm:
        return
    marker = CACHE / "shelf.ok"
    if marker.exists() and marker.read_text().strip() == shelf_digest():
        _shelf_warm = True
        return
    shelf = CACHE / "shelf"
    (shelf / "src").mkdir(parents=True, exist_ok=True)
    for name in ("Cargo.toml", "Cargo.lock"):
        shutil.copyfile(SHELF / name, shelf / name)
    shutil.copyfile(SHELF / "src" / "lib.rs", shelf / "src" / "lib.rs")
    if marker.exists():
        marker.unlink()
    print("  warming the crate shelf (cargo fetch + build --release; the network, once) ...",
          flush=True)
    for args in (["fetch", "--locked"], ["build", "--release", "--locked"]):
        p = subprocess.run(["cargo", *args], cwd=shelf, env=cargo_env(),
                           capture_output=True, text=True, timeout=1800)
        if p.returncode != 0:
            raise SystemExit(f"cargo {' '.join(args)} on the shelf failed:\n{p.stderr[-4000:]}")
    marker.write_text(shelf_digest() + "\n")
    _shelf_warm = True


def crate_manifest(name):
    """The runner's manifest for a stdio quest with crates (`cargo.rs`): a
    binary named for the build, and the shelf's whole dependency table."""
    deps = "\n".join(shelf_dependency_lines())
    return (f'[package]\nname = "{name}"\nversion = "0.0.0"\nedition = "2021"\npublish = false\n\n'
            f'[[bin]]\nname = "{name}"\npath = "src/main.rs"\n\n'
            f'[dependencies]\n{deps}\n\n[workspace]\n')

# REMIX LAND (SPEC §12): the same program three times, one trio of nodes per
# concept, always in this order. `lang` on the quest says which toolchain
# judges it; the land says only where on the lands screen it sits.
REMIX_LANGS = ("go", "rust", "python")


def quest_lang(pack, q):
    """The toolchain a quest is judged in: its own `lang` in remix, the land elsewhere."""
    return q.get("lang", pack["land"])

MISTAKE_MAP_HEADING = "## 2. Mistake kind → concepts"


def load_vocab():
    """Parse docs/concepts.md: the slugs in §1 tables and the §7.1 kind map."""
    text = (REPO / "docs" / "concepts.md").read_text()
    part1, _, part2 = text.partition(MISTAKE_MAP_HEADING)
    vocab = set()
    for line in part1.splitlines():
        m = re.match(r"^\|\s*`([a-z0-9-]+)`\s*\|", line)
        if m:
            vocab.add(m.group(1))
    kinds = {}
    for line in part2.splitlines():
        m = re.match(r"^\|\s*`([a-z0-9-]+)`\s*\|(.*)\|\s*$", line)
        if m:
            kinds[m.group(1)] = re.findall(r"`([a-z0-9-]+)`", m.group(2))
    named = set()
    for cs in kinds.values():
        named |= set(cs)
    orphan_named = sorted(named - vocab)
    orphan_vocab = sorted(vocab - named)
    if orphan_named:
        raise SystemExit(f"docs/concepts.md: §2 names slugs not in §1: {orphan_named}")
    if orphan_vocab:
        raise SystemExit(f"docs/concepts.md: §1 slugs no mistake kind names: {orphan_vocab}")
    return vocab, kinds


# ---------------------------------------------------------------- match modes
def norm(mode, s):
    if mode == "exact":
        return s
    if mode == "trim":
        return "\n".join(l.rstrip() for l in s.split("\n")).rstrip("\n")
    if mode == "tokens":
        return " ".join(s.split())
    if mode.startswith("float:"):
        return s  # handled separately
    raise SystemExit(f"unknown match mode {mode!r}")


def matches(mode, got, want):
    if mode.startswith("float:"):
        eps = float(mode.split(":", 1)[1])
        g, w = got.split(), want.split()
        if len(g) != len(w):
            return False
        for a, b in zip(g, w):
            try:
                if abs(float(a) - float(b)) > eps:
                    return False
            except ValueError:
                if a != b:
                    return False
        return True
    return norm(mode, got) == norm(mode, want)


# ---------------------------------------------------------------- toolchain
def go_env():
    e = {
        "PATH": os.environ["PATH"],
        "HOME": str(CACHE),
        "GOCACHE": str(CACHE / "gocache"),
        "GOMODCACHE": str(CACHE / "gomodcache"),
        "GOPATH": str(CACHE / "gopath"),
        "GOFLAGS": "-mod=mod",
        "GOPROXY": "off",
    }
    return e


def build(lang, src, workdir, crates=()):
    """Compile source. Returns (ok, stderr)."""
    workdir.mkdir(parents=True, exist_ok=True)
    if lang == "rust" and crates:
        # A stdio quest with crates (SPEC §5.1): the runner's `cargo build
        # --release --offline` against the whole shelf, with the lockfile
        # copied in, in the shared target directory the shelf was warmed
        # into. The package is named for this build — cargo uplifts a binary
        # to `target/release/<name>` with no hash in it, and two builds of
        # one name would be one file — and the executable is moved out to
        # `prog` so the cache does not keep a program per quest.
        ensure_shelf()
        name = "quest-" + re.sub(r"[^A-Za-z0-9_-]", "-", workdir.name) + f"-{os.getpid()}"
        (workdir / "src").mkdir(exist_ok=True)
        (workdir / "src" / "main.rs").write_text(src)
        (workdir / "Cargo.toml").write_text(crate_manifest(name))
        shutil.copyfile(SHELF / "Cargo.lock", workdir / "Cargo.lock")
        p = subprocess.run(
            ["cargo", "build", "--release", "--offline"],
            cwd=workdir, capture_output=True, text=True, timeout=600, env=cargo_env())
        if p.returncode == 0:
            shutil.move(CACHE / "target" / "release" / name, workdir / "prog")
            for leftover in (CACHE / "target" / "release" / "deps").glob(f"{name}-*"):
                leftover.unlink()
            fingerprints = CACHE / "target" / "release" / ".fingerprint"
            for leftover in fingerprints.glob(f"{name}-*") if fingerprints.is_dir() else []:
                shutil.rmtree(leftover, ignore_errors=True)
    elif lang == "rust":
        f = workdir / "main.rs"
        f.write_text(src)
        p = subprocess.run(
            ["rustc", "--edition", "2021", "-O", "--error-format=json",
             "main.rs", "-o", "prog"],
            cwd=workdir, capture_output=True, text=True, timeout=180)
    elif lang == "go":
        f = workdir / "main.go"
        f.write_text(src)
        p = subprocess.run(
            ["go", "build", "-o", "prog", "main.go"],
            cwd=workdir, capture_output=True, text=True, timeout=180, env=go_env())
    elif lang == "cpp":
        # The same line the runner uses (SPEC §5.1): C++20, optimised, with
        # threads linked, because the advanced road is std::thread and
        # std::mutex and a quest that cannot link them is not a quest.
        f = workdir / "main.cpp"
        f.write_text(src)
        p = subprocess.run(
            ["c++", "-std=c++20", "-O2", "-pthread", "-Wall", "-o", "prog", "main.cpp"],
            cwd=workdir, capture_output=True, text=True, timeout=180)
    elif lang in ("python", "pytorch"):
        # Python has no compile step; the "build" is a syntax check, so a
        # SyntaxError lands as compile_error the way it does in the runner,
        # and `prog` is a tiny launcher so run_case stays one code path.
        #
        # PYTORCH is the same interpreter with torch in its site-packages,
        # which is why it shares this arm rather than getting one of its own:
        # `python3 -I` finds an installed torch (`-I` drops PYTHONPATH and the
        # user site, not the interpreter's own), so the only difference
        # between the two lands is what a program is allowed to import.
        f = workdir / "main.py"
        f.write_text(src)
        p = subprocess.run(
            ["python3", "-m", "py_compile", "main.py"],
            cwd=workdir, capture_output=True, text=True, timeout=60)
        if p.returncode == 0:
            launcher = workdir / "prog"
            launcher.write_text("#!/bin/sh\nexec python3 -I \"$(dirname \"$0\")/main.py\"\n")
            launcher.chmod(0o755)
    elif lang == "typescript":
        # The runner's own files, not a copy of them (SPEC §5.1): the ambient
        # declarations that are the whole of Node a quest can see, and the
        # tsconfig that makes `tsc` strict. `tsc` prints its diagnostics on
        # stdout, so they are folded into the stderr this returns.
        f = workdir / "main.ts"
        f.write_text(src)
        for name in ("node.d.ts", "tsconfig.json"):
            shutil.copyfile(TS_FILES / name, workdir / name)
        p = subprocess.run(
            [tsc(), "-p", "."],
            cwd=workdir, capture_output=True, text=True, timeout=120)
        p = subprocess.CompletedProcess(p.args, p.returncode, "", p.stdout + p.stderr)
        if p.returncode == 0:
            launcher = workdir / "prog"
            launcher.write_text(
                "#!/bin/sh\nexec node --enable-source-maps \"$(dirname \"$0\")/main.js\"\n")
            launcher.chmod(0o755)
    elif lang == "zig":
        # The runner's own line (SPEC §5.1): `-O Debug`, so every safety check
        # is on and a panic says what it is ("index out of bounds", "attempt to
        # use null value", "integer overflow") — the land is about those checks
        # — and so a compile is under a second warm. Both caches are named so
        # a `HOME` pointed elsewhere does not make every build the cold one.
        f = workdir / "main.zig"
        f.write_text(src)
        p = subprocess.run(
            ["zig", "build-exe", "main.zig", "-O", "Debug",
             "--cache-dir", str(workdir / "zig-cache"),
             "--global-cache-dir", str(CACHE / "zig-global"),
             "-femit-bin=prog"],
            cwd=workdir, capture_output=True, text=True, timeout=180)
    elif lang == "lua":
        # LuaJIT, and only LuaJIT (SPEC §5.1): `print(6/2)` is `3` here and
        # `3.0` on Lua 5.4, so a pack verified on one is wrong on the other.
        # `-b` compiles to bytecode without running a line, which is the one
        # mistake the interpreter can find before the run — a syntax error —
        # and it lands as compile_error the way `py_compile` does.
        f = workdir / "main.lua"
        f.write_text(src)
        p = subprocess.run(
            ["luajit", "-b", "main.lua", "main.luac"],
            cwd=workdir, capture_output=True, text=True, timeout=60)
        if p.returncode == 0:
            launcher = workdir / "prog"
            launcher.write_text("#!/bin/sh\nexec luajit \"$(dirname \"$0\")/main.lua\"\n")
            launcher.chmod(0o755)
    else:
        raise ValueError(f"no toolchain for land {lang!r}")
    return p.returncode == 0, p.stderr


TS_FILES = REPO / "backend" / "runner" / "src" / "typescript"


def tsc():
    """`tsc` on PATH, else the one the frontend already pins.

    The server finds `tsc` on PATH only; this falls back to the checkout's
    own so a machine that can build the frontend can check the content too.
    """
    found = shutil.which("tsc")
    if found:
        return found
    local = REPO / "frontend" / "node_modules" / ".bin" / "tsc"
    if local.exists():
        return str(local)
    raise SystemExit("typescript: no tsc on PATH (npm install -g typescript)")


def run_case(workdir, stdin, timeout_ms, max_bytes):
    # Bytes in, bytes out, decoded lossily: a program can print anything —
    # a Lua `s:reverse()` on a UTF-8 string emits bytes that are not text —
    # and the runner reads its stdout with `from_utf8_lossy`. Decoding
    # strictly here crashed the whole run on one wrong starter instead of
    # failing the one case.
    try:
        p = subprocess.run([str(workdir / "prog")], input=stdin.encode(),
                           capture_output=True,
                           timeout=timeout_ms / 1000.0, cwd=workdir)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if len(p.stdout) > max_bytes:
        return None, "output_limit"
    got = p.stdout.decode("utf-8", errors="replace")
    if p.returncode != 0:
        return got, f"runtime_error(exit={p.returncode})"
    return got, None


def judge(lang, src, q, workdir):
    """Returns (verdict, passed, total, note)."""
    t = q["tests"]
    mode = t.get("match", "trim")
    cases = t["cases"]
    ok, err = build(lang, src, workdir, crates=t.get("crates", ()))
    if not ok:
        return "compile_error", 0, len(cases), err.strip().splitlines()[:1]
    passed = 0
    notes = []
    for c in cases:
        got, prob = run_case(workdir, c.get("stdin", ""),
                             t.get("timeout_ms", 5000),
                             t.get("max_stdout_bytes", 262144))
        if prob:
            notes.append(f"{c['name']}:{prob}")
            continue
        if matches(mode, got, c["expect"]):
            passed += 1
        else:
            notes.append(f"{c['name']}: got {got!r} want {c['expect']!r}")
    verdict = "accepted" if passed == len(cases) else "wrong_answer"
    return verdict, passed, len(cases), notes



def brief_examples(brief):
    """Pull the `output:` blocks out of a brief's fenced worked examples."""
    out, inside, buf, taking = [], False, [], False
    for line in brief.split("\n"):
        if line.strip().startswith("```"):
            if inside and taking:
                out.append("\n".join(buf))
            inside, buf, taking = not inside, [], False
            continue
        if not inside:
            continue
        if line.lstrip().startswith("output:"):
            taking = True
            rest = line.split("output:", 1)[1].strip()
            buf = [rest] if rest else []
        elif taking:
            buf.append(line.strip())
    return out


# ---------------------------------------------------------------- structure
# The most lines a `basic` solution may add over its starter. BASIC is
# grammar practice, not a coding quiz: the brief explains a construct and
# shows its syntax, the starter is the whole program with a small hole, and
# the player types the idiom — one or two lines, and up to four on a
# container drill, where the lines are add, remove, edit and sort.
# Placeholder lines the solution drops cost nothing; only lines the starter
# does not have are counted — and the `ANSWER:` comment the starter carries
# at each hole is a comment, so it neither counts nor clears anything.
BASIC_MAX_ADDED = 4
# VERY BASIC is the same grammar asked as a question first: four choices,
# one right, and then the one line typed. One line, always.
VERYBASIC_MAX_ADDED = 1
MAX_ADDED = {"basic": BASIC_MAX_ADDED, "verybasic": VERYBASIC_MAX_ADDED}

# `* ` and `*/` are the inside and the end of a block comment; a bare `*` is
# not, or Rust's `*count.entry(..) += 1` would be free. `--` is Lua's line
# comment, so a `-- ANSWER:` at a hole is a comment there too; a bare `-`
# is not, or `-x` would be free.
COMMENT_STARTS = ("//", "#", "/*", "* ", "*/", "--")


def added_lines(starter, solution):
    """The solution's lines that the starter does not have: non-blank, not a
    comment, compared with the indentation stripped so a re-indented scaffold
    line is not counted as new writing."""
    have = {l.strip() for l in starter.split("\n") if l.strip()}
    out = []
    for line in solution.split("\n"):
        t = line.strip()
        if not t or t.startswith(COMMENT_STARTS) or t in have:
            continue
        out.append(t)
    return out


def structural(pack, path, vocab):
    errs = []
    land, cat = pack["land"], pack["category"]
    if pack["pack"] != f"{land}.{cat}":
        errs.append(f"pack id {pack['pack']!r} != {land}.{cat}")
    if path.parts[-2] != land or path.stem != cat:
        errs.append(f"file path {path} disagrees with land/category")
    quests = pack["quest"]
    nodes = [q["node"] for q in quests]
    if nodes != list(range(1, len(quests) + 1)):
        errs.append(f"nodes not contiguous from 1: {nodes}")
    ids = {q["id"] for q in quests}
    if len(ids) != len(quests):
        errs.append("duplicate quest ids")
    pts = []
    for q in quests:
        qid = q["id"]
        m = ID_RE.match(qid)
        if not m:
            errs.append(f"{qid}: id does not match <land>.<category>.<node:02d>.<slug>")
            continue
        if m.group(1) != land or m.group(2) != cat:
            errs.append(f"{qid}: id land/category disagrees with pack")
        # The number in an id is **the node the quest was created at**, and
        # SPEC §12 no longer requires it to match where the quest sits today.
        #
        # This check used to be here and was wrong. §4.1 has always said the
        # id is "stable forever … so a reordered map does not renumber
        # someone's cleared list into nonsense"; §12 said the number had to
        # equal `node`. The two contradicted each other, and enforcing this
        # one cost four boss quests their ids on three separate occasions —
        # each rename a delete-and-insert that discards whoever had cleared
        # them, which is precisely what §4.1 exists to prevent.
        #
        # Both hacker packs now exercise the resolved rule deliberately: the
        # LRU boss keeps `*.hacker.28.lru` while sitting at node 34. `node`
        # is the authority on position; the id is an identity.
        #
        # Everything around this still holds — the id's *shape*, its land and
        # category, and uniqueness within the pack — and those are checked
        # above and below.
        if not 1 <= q["difficulty"] <= 5:
            errs.append(f"{qid}: difficulty out of 1..5")
        if not q.get("story", "").strip():
            errs.append(f"{qid}: empty story")
        if not q.get("brief", "").strip():
            errs.append(f"{qid}: empty brief")
        cs = q.get("concepts", [])
        if not 2 <= len(cs) <= 4:
            errs.append(f"{qid}: {len(cs)} concepts, want 2..4")
        for c in cs:
            if c not in vocab:
                errs.append(f"{qid}: concept {c!r} not in docs/concepts.md")
        reqs = q.get("requires", [])
        if q["node"] == 1 and reqs:
            errs.append(f"{qid}: node 1 must have requires = []")
        if q["node"] > 1 and not reqs:
            errs.append(f"{qid}: node {q['node']} is unreachable-by-design (no requires)")
        for r in reqs:
            if r not in ids:
                errs.append(f"{qid}: requires {r!r} which is not in this pack")
            else:
                rn = next(x["node"] for x in quests if x["id"] == r)
                if rn >= q["node"]:
                    errs.append(f"{qid}: requires node {rn} >= own node {q['node']}")
        mp = q["map"]
        if not (0.0 <= mp["x"] <= 1.0 and 0.0 <= mp["y"] <= 1.0):
            errs.append(f"{qid}: map outside 0..1")
        if mp.get("kind") not in ("quest", "boss", "gate"):
            errs.append(f"{qid}: map.kind {mp.get('kind')!r} invalid")
        pts.append((mp["x"], mp["y"]))
        t = q["tests"]
        if t.get("harness", "stdio") not in ("stdio", "cargo", "gotest"):
            errs.append(f"{qid}: bad harness")
        mode = t.get("match", "trim")
        cases = t["cases"]
        if not any(c.get("visible") for c in cases):
            errs.append(f"{qid}: no visible case")
        names = [c["name"] for c in cases]
        if len(set(names)) != len(names):
            errs.append(f"{qid}: duplicate case names")
        for c in cases:
            if not norm(mode if not mode.startswith("float") else "trim", c["expect"]).strip():
                errs.append(f"{qid}: case {c['name']} expect is empty after {mode} "
                            f"— an empty main() would pass it")
        # `crates` (SPEC §5.2): rust only, every name on the shelf, and the
        # FRAMEWORKS road's reason to exist — a quest there names at least
        # one, or it is an ADVANCED quest filed on the wrong road and judged
        # by `rustc` alone, where its `use serde` does not compile.
        crates = t.get("crates", [])
        if crates and quest_lang(pack, q) != "rust":
            errs.append(f"{qid}: crates on a {quest_lang(pack, q)} quest; the shelf is rust's")
        if not isinstance(crates, list) or any(not isinstance(c, str) or not c.strip() for c in crates):
            errs.append(f"{qid}: tests.crates must be a list of crate names")
        else:
            for c in crates:
                if c not in shelf_names():
                    errs.append(f"{qid}: crate {c!r} is not on the shelf "
                                f"(backend/runner/shelf/Cargo.toml)")
        if cat == "frameworks" and not crates:
            errs.append(f"{qid}: a frameworks quest names the crates it is about in tests.crates")
        if cat == "frameworks" and land != "rust":
            errs.append(f"{qid}: the frameworks road is rust's alone")
        if cat == "hacker" and not q.get("time_limit_s"):
            errs.append(f"{qid}: hacker quest without time_limit_s")
        if cat != "hacker" and q.get("time_limit_s"):
            errs.append(f"{qid}: non-hacker quest with time_limit_s")
        if cat == "hacker" and not any(not c.get("visible") for c in cases):
            errs.append(f"{qid}: hacker quest with no hidden case")
        # the brief's worked example must be one of the visible cases, or the
        # player is being shown output the tests do not agree with
        shown = [norm("trim", c["expect"]) for c in cases if c.get("visible")]
        for example in brief_examples(q["brief"]):
            if norm("trim", example) not in shown:
                errs.append(f"{qid}: brief's worked output {example!r} "
                            f"matches no visible case")
        # BASIC is the grammar road (README, docs/story.md §4): the brief
        # explains one construct, the starter is the whole program, and the
        # player fills a hole of one or two lines. A basic quest whose answer
        # is a program is an advanced quest filed on the wrong road, and the
        # map's "0/18" would be promising a morning walk it does not deliver.
        # Counted as the solution's non-blank, non-comment lines that the
        # starter does not already have, so a scaffold the player leaves
        # alone costs nothing.
        if cat in MAX_ADDED:
            added = added_lines(q["starter"], q["solution"])
            if len(added) > MAX_ADDED[cat]:
                errs.append(f"{qid}: solution adds {len(added)} lines over its "
                            f"starter (> {MAX_ADDED[cat]}) — a {cat} quest is a "
                            f"grammar drill; the scaffolding belongs in the starter")
        # VERY BASIC: the quiz. Four choices, one of which is exactly the line
        # the solution adds; the answer given away nowhere in the starter or
        # the brief; and (checked by `main`, since it compiles) each wrong
        # choice must fail when swapped into the solution — otherwise the quiz
        # has two right answers and the player who picked the other was
        # right too.
        if cat == "verybasic":
            quiz = q.get("quiz")
            added = added_lines(q["starter"], q["solution"])
            if not quiz:
                errs.append(f"{qid}: a verybasic quest needs [quest.quiz]")
            else:
                choices = quiz.get("choices", [])
                answer = quiz.get("answer", -1)
                if len(choices) != 4:
                    errs.append(f"{qid}: quiz has {len(choices)} choices, want 4")
                if not (isinstance(answer, int) and 0 <= answer < len(choices)):
                    errs.append(f"{qid}: quiz.answer {answer!r} out of range")
                elif len(added) != 1:
                    errs.append(f"{qid}: a verybasic solution adds {len(added)} lines; the quiz is about one")
                else:
                    right = choices[answer].strip()
                    if right != added[0]:
                        errs.append(f"{qid}: quiz answer {right!r} is not the line the solution adds {added[0]!r}")
                    if sum(1 for c in choices if c.strip() == right) != 1:
                        errs.append(f"{qid}: the right answer appears more than once among the choices")
                    if right in q["starter"] or right in q["brief"]:
                        errs.append(f"{qid}: the answer line is given away in the starter or the brief")
                if len(set(c.strip() for c in choices)) != len(choices):
                    errs.append(f"{qid}: duplicate choices")
        elif "quiz" in q:
            errs.append(f"{qid}: only verybasic quests carry a quiz")
        # `lang` is REMIX LAND's field: required there, one of its three, and
        # refused everywhere else, where a `lang` that disagreed with the land
        # would send a Go program to rustc.
        if land == "remix":
            if q.get("lang") not in REMIX_LANGS:
                errs.append(f"{qid}: a remix quest needs lang = go | rust | python, "
                            f"got {q.get('lang')!r}")
        elif "lang" in q and q["lang"] != land:
            errs.append(f"{qid}: lang {q['lang']!r} in the {land} land; only remix "
                        f"quests name a language of their own")
    if land == "remix":
        errs += remix_trios(quests)
    # map layout: not a straight line, no two nodes on top of each other
    for i in range(len(pts)):
        for j in range(i + 1, len(pts)):
            d = ((pts[i][0]-pts[j][0])**2 + (pts[i][1]-pts[j][1])**2) ** .5
            if d < 0.06:
                errs.append(f"map: nodes {i+1} and {j+1} are {d:.3f} apart (<0.06)")
    xs = [p[0] for p in pts]; ys = [p[1] for p in pts]
    if max(xs) - min(xs) < 0.5:
        errs.append(f"map: x spread {max(xs)-min(xs):.2f} too flat")
    if max(ys) - min(ys) < 0.4:
        errs.append(f"map: y spread {max(ys)-min(ys):.2f} too flat")
    turns = 0
    for i in range(1, len(pts) - 1):
        ax, ay = pts[i][0]-pts[i-1][0], pts[i][1]-pts[i-1][1]
        bx, by = pts[i+1][0]-pts[i][0], pts[i+1][1]-pts[i][1]
        cross = ax*by - ay*bx
        if abs(cross) > 1e-3:
            turns += 1
    if turns < len(pts) // 2:
        errs.append(f"map: only {turns} direction changes over {len(pts)} nodes — too straight")
    return errs, turns


def remix_trios(quests):
    """REMIX LAND's own rule: nodes come in threes, go then rust then python,
    and the three of a trio are the same program — the same cases, byte for
    byte, the same difficulty, the same title after the language. "Same
    logic in three languages" is the whole promise of the land, and a trio
    whose Python asks a different question is three quests, not a remix."""
    errs = []
    if len(quests) % 3:
        errs.append(f"remix: {len(quests)} nodes is not a whole number of trios")
    by_node = sorted(quests, key=lambda q: q["node"])
    for i in range(0, len(by_node) - len(by_node) % 3, 3):
        trio = by_node[i:i + 3]
        langs = tuple(q.get("lang") for q in trio)
        if langs != REMIX_LANGS:
            errs.append(f"remix: nodes {trio[0]['node']}-{trio[-1]['node']} are "
                        f"{langs}, want {REMIX_LANGS}")
        first = trio[0]
        for q in trio[1:]:
            if q["tests"]["cases"] != first["tests"]["cases"]:
                errs.append(f"{q['id']}: its cases differ from {first['id']}'s — "
                            f"a trio is one program")
            if q["tests"].get("match", "trim") != first["tests"].get("match", "trim"):
                errs.append(f"{q['id']}: its match mode differs from {first['id']}'s")
            if q["difficulty"] != first["difficulty"]:
                errs.append(f"{q['id']}: its difficulty differs from {first['id']}'s")
            if q["title"].rsplit(" — ", 1)[0] != first["title"].rsplit(" — ", 1)[0]:
                errs.append(f"{q['id']}: its title {q['title']!r} is not "
                            f"{first['title']!r}'s with the language swapped")
    return errs


# ---------------------------------------------------------------- i18n
TEXT_LOCALES = ("ko", "yue", "zh", "ja", "cs")
TRANSLATION_CODE_FIELDS = ("brief", "story")


def fenced_blocks(text):
    """The fenced code blocks of a markdown brief, in order, verbatim.

    SPEC §12.1: code blocks, sample I/O and the strings a program must print
    are the English pack's and are not translated. Comparing the blocks is
    the cheapest check that a translator did not "helpfully" localise the
    expected output — which would make the brief disagree with the tests in
    a way the player cannot see.
    """
    out, inside, buf = [], False, []
    for line in text.split("\n"):
        if line.strip().startswith("```"):
            if inside:
                out.append("\n".join(buf))
            inside, buf = not inside, []
            continue
        if inside:
            buf.append(line)
    return out


def basic_string_lines(raw, fields):
    """Line numbers where one of `fields` is opened with a \"\"\" string.

    The same raw-text scan the importer does (`reject_basic_strings`): a TOML
    parser cannot say which quote style a string used, and a \"\"\" string
    has already eaten the backslash escapes in the brief's code blocks by the
    time it is parsed.
    """
    hits = []
    for number, line in enumerate(raw.split("\n"), 1):
        stripped = line.lstrip()
        for field in fields:
            if not stripped.startswith(field):
                continue
            rest = stripped[len(field):].lstrip()
            if rest.startswith("=") and rest[1:].lstrip().startswith('"""'):
                hits.append((number, field))
    return hits


def check_translation(english, pack_path, locale):
    """One locale × pack: the file exists and keeps to SPEC §12.1.

    Returns `(problems, untranslated_ids)`, and the split is the whole point:
    a quest a translator has not reached yet is a coverage gap, and a rule
    broken in one they have is a mistake. Only the second fails CI — see
    `main_i18n`. So a file that does not exist at all is the emptiest possible
    coverage gap, every quest untranslated and nothing wrong, rather than an
    error: the language has not been started, which is not a defect in it.
    """
    path = REPO / "content" / "i18n" / locale / f"{english['pack']}.toml"
    rel = path.relative_to(REPO)
    if not path.exists():
        return [], [q["id"] for q in english["quest"]]
    raw = path.read_text()
    errs = []
    for number, field in basic_string_lines(raw, TRANSLATION_CODE_FIELDS):
        errs.append(f"{rel}:{number}: `{field}` uses a \"\"\" basic string; use '''")
    try:
        tr = tomllib.loads(raw)
    except tomllib.TOMLDecodeError as e:
        # The importer refuses the file whole, so nothing in it reaches a
        # player however many quests it contains: every id is untranslated.
        return errs + [f"{rel}: not valid TOML: {e}"], [q["id"] for q in english["quest"]]
    if tr.get("pack") != english["pack"]:
        errs.append(f"{rel}: pack = {tr.get('pack')!r}, want {english['pack']!r}")
    if tr.get("locale") != locale:
        errs.append(f"{rel}: locale = {tr.get('locale')!r} but the file sits under i18n/{locale}/")
    for key in ("land", "category"):
        if key in tr:
            errs.append(f"{rel}: carries `{key}`; a translation names only its pack")
    by_id = {q["id"]: q for q in english["quest"]}
    seen = set()
    for q in tr.get("quest", []):
        qid = q.get("id")
        if qid in seen:
            errs.append(f"{rel}: duplicate id {qid!r}")
        seen.add(qid)
        src = by_id.get(qid)
        if src is None:
            errs.append(f"{rel}: {qid!r} is not a quest of {english['pack']}")
            continue
        for key in ("node", "starter", "solution", "tests", "difficulty", "map", "requires", "concepts"):
            if key in q:
                errs.append(f"{rel}: {qid}: carries `{key}`, which belongs to the English pack alone")
        if not str(q.get("title", "")).strip():
            errs.append(f"{rel}: {qid}: empty title")
        if not str(q.get("brief", "")).strip():
            errs.append(f"{rel}: {qid}: empty brief")
        if src.get("story", "").strip() and not str(q.get("story", "")).strip():
            errs.append(f"{rel}: {qid}: empty story (the English has one)")
        want, got = len(src.get("hints", [])), len(q.get("hints", []))
        if want != got:
            errs.append(f"{rel}: {qid}: {got} hints, the English has {want} — "
                        f"hints are revealed by index and the counts must match")
        eb, tb = fenced_blocks(src["brief"]), fenced_blocks(q.get("brief", ""))
        if eb != tb:
            errs.append(f"{rel}: {qid}: fenced code blocks differ from the English brief — "
                        f"code, sample I/O and expected output are copied verbatim, never translated")
    missing = [qid for qid in by_id if qid not in seen]
    return errs, missing


def main_i18n(argv):
    """`--i18n`: given English packs, check the translations beside them. No
    toolchain runs; a translation has no code to build.

    Two different questions, and only one of them is a build failure:

    **Is every translation file that exists correct?** Always enforced. A file
    whose hint count disagrees with the English, whose fenced code blocks were
    translated, which carries a `solution`, or which is not valid TOML at all,
    is a defect — it will mis-render or fail to import, and somebody has to fix
    it. This is what the exit status means.

    **Is every language finished?** Reported, never enforced. Translating 207
    quests into five languages is incremental by nature, and a gate that only
    goes green on the last one is a gate that is red for months and therefore
    tells nobody anything. The per-locale coverage lines and the summary at the
    bottom say exactly how far along each language is, and `--require-complete`
    turns that into a failure for whoever is doing the final sweep.
    """
    require_complete = "--require-complete" in argv
    argv = [a for a in argv if a != "--require-complete"]
    all_ok = True
    covered = {}
    for arg in argv:
        path = pathlib.Path(arg)
        if not path.is_absolute():
            path = REPO / path
        english = tomllib.loads(path.read_text())
        rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
        print(f"\n=== {rel}  (pack={english['pack']}  {len(english['quest'])} quests) — translations ===")
        total = len(english["quest"])
        for locale in TEXT_LOCALES:
            errs, missing = check_translation(english, path, locale)
            name = f"content/i18n/{locale}/{english['pack']}.toml"
            for e in errs:
                print(f"  {locale:<4} FAIL     {e}")
            if missing and len(missing) == total and not errs:
                print(f"  {locale:<4} TODO     {name}: not started")
            elif missing:
                done = total - len(missing)
                print(f"  {locale:<4} TODO     {name}: {done}/{total} translated"
                      + (", and those pass every rule" if not errs else "")
                      + "; untranslated: " + " ".join(missing[:6])
                      + (" …" if len(missing) > 6 else ""))
            if errs:
                all_ok = False
            if not errs and not missing:
                print(f"  {locale:<4} OK       {name} covers all {total} quests")
            tally = covered.setdefault(locale, [0, 0])
            tally[0] += total - len(missing)
            tally[1] += total

    print("\n=== coverage (reported, not enforced) ===")
    short = []
    for locale in TEXT_LOCALES:
        done, tot = covered.get(locale, (0, 0))
        flag = "" if done == tot else "   <-- unfinished"
        print(f"  {locale:<4} {done:>3}/{tot} quests translated{flag}")
        if done != tot:
            short.append(locale)
    if require_complete and short:
        print("\n=== --require-complete: " + " ".join(short) + " are unfinished ===")
        all_ok = False
    print(f"\n=== {'ALL TRANSLATIONS VERIFIED' if all_ok else 'TRANSLATION FILES ARE WRONG ABOVE'} ===")
    return 0 if all_ok else 1


# ---------------------------------------------------------------- main
def main(argv):
    if "--i18n" in argv:
        return main_i18n([a for a in argv if a != "--i18n"])
    complete = "--complete" in argv
    argv = [a for a in argv if a != "--complete"]
    vocab, kindmap = load_vocab()
    if SCRATCH.exists():
        shutil.rmtree(SCRATCH)
    SCRATCH.mkdir(parents=True)
    CACHE.mkdir(parents=True, exist_ok=True)
    all_ok = True
    concept_use = {}
    for arg in argv:
        path = pathlib.Path(arg)
        if not path.is_absolute():
            path = REPO / path
        pack = tomllib.loads(path.read_text())
        land = pack["land"]
        rel = path.relative_to(REPO) if path.is_relative_to(REPO) else path
        print(f"\n=== {rel}  (pack={pack['pack']} "
              f"version={pack['version']}  {len(pack['quest'])} quests) ===")
        errs, turns = structural(pack, path, vocab)
        for e in errs:
            print(f"  STRUCT FAIL  {e}")
            all_ok = False
        if not errs:
            print(f"  structure OK  (map: {turns} direction changes)")
        print(f"  {'node':>4} {'id':<34} {'sol':<10} {'cases':>7} "
              f"{'starter':<14} {'vis':>3} {'concepts'}")
        for q in pack["quest"]:
            wd_s = SCRATCH / f"{q['id']}.sol"
            wd_t = SCRATCH / f"{q['id']}.start"
            lang = quest_lang(pack, q)
            sv, sp, st, sn = judge(lang, q["solution"], q, wd_s)
            tv, tp, tt, tn = judge(lang, q["starter"], q, wd_t)
            vis = sum(1 for c in q["tests"]["cases"] if c.get("visible"))
            sol_ok = sv == "accepted" and sp == st
            start_ok = not (tv == "accepted" and tp == tt)
            # VERY BASIC: every wrong choice, swapped in for the answer line,
            # must not pass. Three more judges per quest; the quiz is honest.
            quiz_ok = True
            quiz = q.get("quiz")
            if pack["category"] == "verybasic" and quiz and len(quiz.get("choices", [])) == 4:
                right = quiz["choices"][quiz["answer"]].strip()
                for k, wrong in enumerate(quiz["choices"]):
                    if k == quiz["answer"]:
                        continue
                    lines = q["solution"].split("\n")
                    swapped = []
                    for line in lines:
                        if line.strip() == right:
                            indent = line[: len(line) - len(line.lstrip())]
                            swapped.append(indent + wrong.strip())
                        else:
                            swapped.append(line)
                    wv, wp, wt, _ = judge(lang, "\n".join(swapped), q, SCRATCH / f"{q['id']}.wrong{k}")
                    if wv == "accepted" and wp == wt:
                        quiz_ok = False
                        print(f"        WRONG CHOICE {k} ALSO PASSES: {wrong!r}")
            if not sol_ok or not start_ok or not quiz_ok:
                all_ok = False
            for c in q.get("concepts", []):
                concept_use.setdefault(c, set()).add(q["id"])
            print(f"  {q['node']:>4} {q['id']:<34} "
                  f"{('PASS' if sol_ok else 'FAIL:'+sv):<10} "
                  f"{str(sp)+'/'+str(st):>7} "
                  f"{('rejected:'+tv if start_ok else 'ACCEPTED!!'):<14} "
                  f"{vis:>3} {','.join(q.get('concepts', []))}")
            if not sol_ok:
                print(f"        solution notes: {sn}")
            if not start_ok:
                print(f"        STARTER PASSES — SPEC §9.5 violation")
    print("\n=== concept coverage (mistake kind -> quests reachable) ===")
    for kind, cs in kindmap.items():
        reach = set()
        for c in cs:
            reach |= concept_use.get(c, set())
        flag = "" if reach else "   <-- ZERO"
        if complete and not reach and kind != "other":
            flag += "  FAIL"
            all_ok = False
        print(f"  {kind:<20} {len(reach):>3} quests via {','.join(cs)}{flag}")
    unused = sorted(vocab - set(concept_use))
    if complete and unused:
        all_ok = False
    print(f"\n  vocabulary: {len(vocab)} slugs, {len(concept_use)} used, "
          f"unused in these packs: {' '.join(unused) or '(none)'}"
          + ("   FAIL" if (complete and unused) else ""))
    print(f"\n=== {'ALL PACKS VERIFIED' if all_ok else 'FAILURES ABOVE'} ===")
    return 0 if all_ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
