#!/usr/bin/env python3
"""Verify a Causewaybay Hacker content pack against SPEC.md §5 and §12.

Usage: verify_pack.py content/rust/basic.toml [more.toml ...]

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

ID_RE = re.compile(r"^(rust|go)\.(basic|advanced|hacker)\.(\d{2})\.([a-z0-9]+(?:-[a-z0-9]+)*)$")

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


def build(lang, src, workdir):
    """Compile source. Returns (ok, stderr)."""
    workdir.mkdir(parents=True, exist_ok=True)
    if lang == "rust":
        f = workdir / "main.rs"
        f.write_text(src)
        p = subprocess.run(
            ["rustc", "--edition", "2021", "-O", "--error-format=json",
             "main.rs", "-o", "prog"],
            cwd=workdir, capture_output=True, text=True, timeout=180)
    else:
        f = workdir / "main.go"
        f.write_text(src)
        p = subprocess.run(
            ["go", "build", "-o", "prog", "main.go"],
            cwd=workdir, capture_output=True, text=True, timeout=180, env=go_env())
    return p.returncode == 0, p.stderr


def run_case(workdir, stdin, timeout_ms, max_bytes):
    try:
        p = subprocess.run([str(workdir / "prog")], input=stdin,
                           capture_output=True, text=True,
                           timeout=timeout_ms / 1000.0, cwd=workdir)
    except subprocess.TimeoutExpired:
        return None, "timeout"
    if len(p.stdout.encode()) > max_bytes:
        return None, "output_limit"
    if p.returncode != 0:
        return p.stdout, f"runtime_error(exit={p.returncode})"
    return p.stdout, None


def judge(lang, src, q, workdir):
    """Returns (verdict, passed, total, note)."""
    t = q["tests"]
    mode = t.get("match", "trim")
    cases = t["cases"]
    ok, err = build(lang, src, workdir)
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


# ---------------------------------------------------------------- main
def main(argv):
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
            sv, sp, st, sn = judge(land, q["solution"], q, wd_s)
            tv, tp, tt, tn = judge(land, q["starter"], q, wd_t)
            vis = sum(1 for c in q["tests"]["cases"] if c.get("visible"))
            sol_ok = sv == "accepted" and sp == st
            start_ok = not (tv == "accepted" and tp == tt)
            if not sol_ok or not start_ok:
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
