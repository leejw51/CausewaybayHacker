#!/usr/bin/env python3
"""Compile and run every mistake fixture, capture what the toolchain really
said, and write expected.json.

SPEC §9.7 wants "fixture sources → expected kind, one per row of the §7.1
table". The value of this fixture is that nobody guessed: every `code` in
expected.json was read off `rustc --error-format=json` or `go build` on this
machine, and a case whose real output does not contain the expected code is
written down as `verified: false` rather than quietly asserted anyway.

    python3 tests/vectors/mistakes/generate.py
    python3 tests/vectors/mistakes/generate.py --check   # CI: fail if stale

Each source is copied into a fresh temp directory and compiled there as
`main.rs` / `main.go`, so the spans in the captured JSON say `main.rs` and not
this machine's absolute paths — BE's classifier can be tested offline against
genuine compiler output without a path from another computer baked into it.
The copied name is recorded per case as `compiled_as`.
"""

from __future__ import annotations

import argparse
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent

RUST_COMPILE = ["rustc", "--edition", "2021", "-O", "--error-format=json"]
GO_BUILD = ["go", "build", "-o", "prog"]

# phase: what the runner is doing when the mistake surfaces.
#   compile — the build fails
#   lint    — the build SUCCEEDS and the diagnostic is a warning
#   runtime — the build succeeds and the program dies
#   tool    — needs a checker that is not `rustc`/`go build` (vet, -race)
CASES = [
    # ---- rust -----------------------------------------------------------
    ("rust/borrow-after-move.rs", "borrow-after-move", "E0382", "compile", "error"),
    ("rust/borrow-conflict.rs", "borrow-conflict", "E0499", "compile", "error"),
    ("rust/borrow-conflict-shared.rs", "borrow-conflict", "E0502", "compile", "error"),
    ("rust/lifetime-missing.rs", "lifetime", "E0106", "compile", "error"),
    ("rust/lifetime-too-short.rs", "lifetime", "E0597", "compile", "error"),
    ("rust/type-mismatch.rs", "type-mismatch", "E0308", "compile", "error"),
    ("rust/unknown-name.rs", "unknown-name", "E0425", "compile", "error"),
    ("rust/unknown-path.rs", "unknown-name", "E0433", "compile", "error"),
    ("rust/missing-trait.rs", "missing-trait", "E0277", "compile", "error"),
    ("rust/unused.rs", "unused", "unused_variables", "lint", "warning"),
    ("rust/mutability-borrow.rs", "mutability", "E0596", "compile", "error"),
    ("rust/mutability-assign.rs", "mutability", "E0594", "compile", "error"),
    ("rust/unhandled-error.rs", "unhandled-error", "E0277", "compile", "error"),
    ("rust/syntax.rs", "syntax", None, "compile", "error"),
    ("rust/index-range.rs", "index-range", None, "runtime", "panic"),
    ("rust/other-unmatched.rs", "other", "E0384", "compile", "error"),
    # ---- go -------------------------------------------------------------
    ("go/type-mismatch.go", "type-mismatch", "go:cannot-use-as", "compile", "error"),
    ("go/unknown-name.go", "unknown-name", "go:undefined", "compile", "error"),
    ("go/unused-var.go", "unused", "go:declared-not-used", "compile", "error"),
    ("go/unused-import.go", "unused", "go:imported-not-used", "compile", "error"),
    ("go/syntax.go", "syntax", "go:syntax", "compile", "error"),
    ("go/nil-deref.go", "nil-deref", "go:nil-deref", "runtime", "panic"),
    ("go/index-range.go", "index-range", "go:index-out-of-range", "runtime", "panic"),
    ("go/deadlock.go", "deadlock", "go:deadlock", "runtime", "fatal"),
    ("go/unhandled-error.go", "unhandled-error", None, "tool", "vet"),
    ("go/data-race.go", "data-race", "go:data-race", "tool", "race"),
    ("go/other-unmatched.go", "other", "go:missing-return", "compile", "error"),
]

# Cases kept in the suite for the evidence they carry, but whose expected
# identity this machine's toolchain does NOT produce. `verified: false` on
# these is the finding, not a bug in the fixture — the reason is recorded and
# the captured output is the proof.
GAPS = {
    "go/unhandled-error.go": "SPEC §7.1 maps this row to \"`err` assigned and "
    "not checked (vet)\". Plain `go vet` — the standard analyzer set — does "
    "not report a discarded error; that check is `errcheck`, a separate tool "
    "that is not installed and is not part of the Go distribution. The "
    "captured `go vet` output (exit 0, empty) is the evidence. Either BE "
    "vendors errcheck, or the row loses its Go half. See docs/decisions.md.",
}

# Starters that ship in `content/**` and are rejected by the compiler itself.
#
# These are worth more than the synthetic cases beside them: they are the
# exact bytes a player's editor opens with, so the classifier's first real
# input on day one is one of these. The source is NOT copied here — it lives
# in content/, PM owns it, and a copy would drift. What is captured is the
# compiler output, which is all a classifier needs offline.
#
# (quest id, pack file, kind, code)
CONTENT_CASES = [
    ("rust.basic.04.the-move", "rust/basic", "borrow-after-move", "E0382"),
    ("rust.advanced.02.move", "rust/advanced", "lifetime", "E0373"),
    ("rust.advanced.05.rwlock", "rust/advanced", "mutability", "E0596"),
    ("rust.advanced.06.lifetimes", "rust/advanced", "lifetime", "E0106"),
    ("rust.advanced.07.generics", "rust/advanced", "type-mismatch", "E0308"),
    # PM fixed `go.advanced.09.errors-in-flight` so its starter compiles, and
    # this row went `verified: false` the moment it did — which is the fixture
    # working: it is read out of `content/**` at generate time rather than
    # copied, so a content edit shows up as a stale claim instead of a test
    # quietly checking a file nobody ships any more.
    #
    # `chan-directions` is the replacement: the only Go starter in the shipped
    # content that still fails to compile today (its brief says so outright).
    #
    # It classifies as **`other`**, not `type-mismatch`, and that is correct.
    # Its message is `invalid operation: cannot send to receive-only channel`,
    # and §7.1's Go column for `type-mismatch` is specifically
    # `cannot use … as … value` — a different message shape. §7.1 says an
    # unmatched code is stored as `other` **with the code kept**, and the
    # classifier does exactly that.
    #
    # The first version of this row claimed `type-mismatch` because it read
    # like one to a human. BE's classifier disagreed, the fixture went red,
    # and the classifier was right — which is the fixture earning its keep in
    # the direction that matters least often and costs most when it is missed.
    # Whether the taxonomy *should* have a row for a directional-channel
    # misuse is a question for PM; see docs/decisions.md. Until it does, this
    # asserts what really happens.
    ("go.advanced.12.chan-directions", "go/advanced", "other", "go:invalid-operation"),
]

# Rows of the §7.1 table that no fixture can honestly cover. Written into
# expected.json so "not covered" is a recorded fact rather than an omission.
NOT_COVERED = {
    "wrong-answer": "A verdict, not a compiler identity: the program compiles, "
    "runs and prints the wrong thing. Covered by SPEC §9.6 runner tests "
    "against a quest's test cases, not by a source fixture.",
    "timeout": "Also a verdict. The fixture for it is an infinite loop, which "
    "belongs to the runner-limits suite (§9.6) because what is asserted is "
    "the SIGKILL, not a diagnostic.",
}


# Runtime output carries three things that change on every run and are
# properties of this machine, not of the mistake: the scratch directory's
# path, the thread id in a Rust panic, and the program counter in a Go one.
# Left in, they make `--check` impossible AND bake a path from this computer
# into a fixture BE is meant to run anywhere. They are normalised out, and
# the substitutions are recorded in expected.json so nobody mistakes the
# placeholders for something the toolchain printed.
RUNTIME_NORMALISATIONS = [
    (r"/[^\s\"]*cwbhacker-(?:mistake|content|gobuild)-[A-Za-z0-9_]+", "<work>"),
    (r"panicked at ([^:]+):(\d+):(\d+)", r"panicked at \1:\2:\3"),  # keep, listed for clarity
    (r"thread '([^']*)' \(\d+\)", r"thread '\1' (<tid>)"),
    (r"pc=0x[0-9a-f]+", "pc=0x<pc>"),
    (r"goroutine (\d+) \[", r"goroutine \1 ["),  # stable; listed for clarity
]


def normalise_runtime(text: str) -> str:
    import re

    for pattern, repl in RUNTIME_NORMALISATIONS:
        text = re.sub(pattern, repl, text)
    return text


def tool_version(*argv: str) -> str:
    try:
        out = subprocess.run(argv, capture_output=True, text=True, check=True)
        return (out.stdout or out.stderr).strip().splitlines()[0]
    except Exception as exc:  # noqa: BLE001
        return f"unavailable: {exc}"


def go_env(build_root: pathlib.Path) -> dict:
    """SPEC §5.1's environment: caches under the home, and no network."""
    env = dict(os.environ)
    env.update(
        {
            "GOCACHE": str(build_root / "gocache"),
            "GOMODCACHE": str(build_root / "gomodcache"),
            "GOPATH": str(build_root / "gopath"),
            "GOFLAGS": "-mod=mod",
            "GOPROXY": "off",
        }
    )
    return env


def run_rust(src: pathlib.Path, work: pathlib.Path) -> dict:
    shutil.copy(src, work / "main.rs")
    compile_out = subprocess.run(
        [*RUST_COMPILE, "main.rs", "-o", "prog"],
        cwd=work,
        capture_output=True,
        text=True,
    )
    result = {
        "compiled_as": "main.rs",
        "compile_command": " ".join([*RUST_COMPILE, "main.rs", "-o", "prog"]),
        "compile_exit": compile_out.returncode,
        "compiles": compile_out.returncode == 0,
        "diagnostics": parse_rustc_json(compile_out.stderr),
        "raw_compile_stderr": compile_out.stderr,
    }
    if result["compiles"]:
        run_out = subprocess.run(
            ["./prog"], cwd=work, capture_output=True, text=True, timeout=20
        )
        result["run_command"] = "./prog"
        result["run_exit"] = run_out.returncode
        result["run_stdout"] = normalise_runtime(run_out.stdout)
        result["run_stderr"] = normalise_runtime(run_out.stderr)
    return result


def parse_rustc_json(stderr: str) -> list:
    out = []
    for line in stderr.splitlines():
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            d = json.loads(line)
        except json.JSONDecodeError:
            continue
        if d.get("$message_type") not in (None, "diagnostic"):
            continue
        level = d.get("level")
        if level not in ("error", "warning"):
            continue
        code = (d.get("code") or {}).get("code")
        span = (d.get("spans") or [{}])[0]
        out.append(
            {
                "level": level,
                "code": code,
                "message": d.get("message"),
                "file": span.get("file_name"),
                "line": span.get("line_start"),
                "col": span.get("column_start"),
            }
        )
    return out


def run_go(src: pathlib.Path, work: pathlib.Path, build_root: pathlib.Path) -> dict:
    shutil.copy(src, work / "main.go")
    env = go_env(build_root)
    build = subprocess.run(
        GO_BUILD + ["main.go"], cwd=work, capture_output=True, text=True, env=env
    )
    result = {
        "compiled_as": "main.go",
        "compile_command": " ".join(GO_BUILD + ["main.go"]),
        "compile_exit": build.returncode,
        "compiles": build.returncode == 0,
        "raw_compile_stderr": normalise_runtime(build.stderr),
        "diagnostics": parse_go_text(build.stderr),
    }
    if result["compiles"]:
        try:
            run_out = subprocess.run(
                ["./prog"], cwd=work, capture_output=True, text=True, timeout=20
            )
            result["run_command"] = "./prog"
            result["run_exit"] = run_out.returncode
            result["run_stdout"] = normalise_runtime(run_out.stdout)
            result["run_stderr"] = normalise_runtime(run_out.stderr)
        except subprocess.TimeoutExpired:
            result["run_command"] = "./prog"
            result["run_exit"] = None
            result["run_stderr"] = "<timed out after 20s>"
        # go vet, for the row the compiler is happy about.
        vet = subprocess.run(
            ["go", "vet", "./main.go"], cwd=work, capture_output=True, text=True, env=env
        )
        result["vet_command"] = "go vet ./main.go"
        result["vet_exit"] = vet.returncode
        result["vet_stderr"] = normalise_runtime(vet.stderr)
        # -race, run three times: the detector is sampling, not proving.
        races = []
        for _ in range(3):
            r = subprocess.run(
                ["go", "run", "-race", "main.go"],
                cwd=work,
                capture_output=True,
                text=True,
                env=env,
                timeout=180,
            )
            races.append("DATA RACE" in r.stderr)
            if races[-1]:
                result["race_stderr"] = normalise_runtime(r.stderr)
        result["race_command"] = "go run -race main.go"
        result["race_detected_runs"] = races
    return result


def parse_go_text(stderr: str) -> list:
    """Go has no error codes, so the identity is the normalized message —
    exactly what SPEC §7.1 says ("the message text is matched against a small
    table and normalized"). This captures the raw lines; normalizing them is
    BE's job and this is the input to it."""
    out = []
    for line in stderr.splitlines():
        line = line.rstrip()
        if not line or line.startswith("#"):
            continue
        # main.go:7:6: message
        parts = line.split(":", 3)
        if len(parts) == 4 and parts[1].isdigit() and parts[2].isdigit():
            out.append(
                {
                    "file": parts[0].strip(),
                    "line": int(parts[1]),
                    "col": int(parts[2]),
                    "message": parts[3].strip(),
                }
            )
        else:
            out.append({"file": None, "line": None, "col": None, "message": line.strip()})
    return out


def observed_identity(lang: str, res: dict) -> list:
    if lang == "rust":
        ids = [d["code"] for d in res["diagnostics"] if d["code"]]
        if res.get("run_stderr"):
            ids.append("<runtime>")
        return ids
    return [d["message"] for d in res["diagnostics"]]


def verify(case: dict, res: dict) -> tuple[bool, str]:
    """Did the toolchain actually produce what the row claims?"""
    lang = case["lang"]
    code = case["code"]
    phase = case["phase"]

    if phase == "compile":
        if res["compiles"]:
            return False, "expected a compile failure; it compiled"
        if lang == "rust":
            if code is None:
                ok = any(d["level"] == "error" for d in res["diagnostics"])
                return ok, "" if ok else "no error diagnostic in the JSON stream"
            ok = any(d["code"] == code for d in res["diagnostics"])
            return ok, "" if ok else f"{code} not among {observed_identity(lang, res)}"
        blob = res["raw_compile_stderr"]
        needle = {
            "go:cannot-use-as": "cannot use",
            "go:invalid-operation": "invalid operation",
            "go:undefined": "undefined:",
            "go:declared-not-used": "declared and not used",
            "go:imported-not-used": "imported and not used",
            "go:syntax": "syntax error",
            "go:missing-return": "missing return",
        }[code]
        ok = needle in blob
        return ok, "" if ok else f"{needle!r} not in the build output"

    if phase == "lint":
        if not res["compiles"]:
            return False, "expected a clean build with warnings; it failed"
        ok = any(d["level"] == "warning" and d["code"] == code for d in res["diagnostics"])
        return ok, "" if ok else f"warning {code} not emitted"

    if phase == "runtime":
        if not res["compiles"]:
            return False, "expected it to compile; it did not"
        blob = (res.get("run_stderr") or "") + (res.get("run_stdout") or "")
        needle = {
            None: "index out of bounds",
            "go:nil-deref": "nil pointer dereference",
            "go:index-out-of-range": "index out of range",
            "go:deadlock": "all goroutines are asleep",
        }[code]
        ok = needle in blob
        return ok, "" if ok else f"{needle!r} not in the program's output"

    if phase == "tool":
        if code == "go:data-race":
            runs = res.get("race_detected_runs") or []
            ok = any(runs)
            return ok, "" if ok else "-race did not report a race in 3 runs"
        # unhandled-error, go: does plain `go vet` say anything?
        said = bool((res.get("vet_stderr") or "").strip()) or res.get("vet_exit", 0) != 0
        return said, "" if said else "go vet is silent about the discarded error"

    return False, f"unknown phase {phase}"


def content_starters(build_root: pathlib.Path) -> list:
    """Compile the real shipped starters and capture what the toolchain said."""
    import tomllib

    repo = HERE.parents[2]
    out = []
    for quest_id, pack, kind, code in CONTENT_CASES:
        toml_path = repo / "content" / f"{pack}.toml"
        if not toml_path.exists():
            out.append(
                {
                    "quest_id": quest_id,
                    "kind": kind,
                    "code": code,
                    "verified": False,
                    "verification_failure": f"content pack not found: {toml_path}",
                }
            )
            continue
        doc = tomllib.loads(toml_path.read_bytes().decode())
        quest = next((q for q in doc["quest"] if q["id"] == quest_id), None)
        if quest is None:
            out.append(
                {
                    "quest_id": quest_id,
                    "kind": kind,
                    "code": code,
                    "verified": False,
                    "verification_failure": f"{quest_id} is no longer in {pack}.toml",
                }
            )
            continue
        lang = "rust" if quest_id.startswith("rust.") else "go"
        work = pathlib.Path(tempfile.mkdtemp(prefix="cwbhacker-content-"))
        try:
            src = work / ("starter.rs" if lang == "rust" else "starter.go")
            src.write_text(quest["starter"])
            res = (
                run_rust(src, work)
                if lang == "rust"
                else run_go(src, work, build_root)
            )
        finally:
            shutil.rmtree(work, ignore_errors=True)

        case = {
            "quest_id": quest_id,
            "pack": f"content/{pack}.toml",
            "lang": lang,
            "kind": kind,
            "code": code,
            "phase": "compile",
            "level": "error",
            "compile_time": True,
            "compiles": res["compiles"],
            "source_is_in": f"content/{pack}.toml → quest {quest_id} → starter",
        }
        ok, why = verify({"lang": lang, "code": code, "phase": "compile"}, res)
        case["verified"] = ok
        case["assert_me"] = True
        if not ok:
            case["verification_failure"] = why
        case["observed"] = {
            "compile_command": res["compile_command"],
            "compile_exit": res["compile_exit"],
            "identities": observed_identity(lang, res),
            "diagnostics": res["diagnostics"][:4],
        }
        ext = "rustc.json" if lang == "rust" else "gobuild.txt"
        cap = HERE / "content" / f"{quest_id}.{ext}"
        cap.parent.mkdir(exist_ok=True)
        cap.write_text(res["raw_compile_stderr"])
        case["captured"] = str(cap.relative_to(HERE))
        out.append(case)
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    args = ap.parse_args()

    build_root = pathlib.Path(tempfile.mkdtemp(prefix="cwbhacker-gobuild-"))
    cases_out = []
    try:
        for rel, kind, code, phase, level in CASES:
            src = HERE / rel
            if not src.exists():
                raise SystemExit(f"missing fixture source: {src}")
            lang = "rust" if rel.startswith("rust/") else "go"
            work = pathlib.Path(tempfile.mkdtemp(prefix="cwbhacker-mistake-"))
            try:
                res = (
                    run_rust(src, work)
                    if lang == "rust"
                    else run_go(src, work, build_root)
                )
            finally:
                shutil.rmtree(work, ignore_errors=True)

            case = {
                "file": rel,
                "lang": lang,
                "kind": kind,
                "code": code,
                "phase": phase,
                "level": level,
                "compile_time": phase in ("compile", "lint"),
                "compiles": res["compiles"],
            }
            ok, why = verify(case, res)
            case["verified"] = ok
            if rel in GAPS:
                case["known_gap"] = GAPS[rel]
                case["assert_me"] = False
                if ok:
                    case["known_gap"] = (
                        "RECORDED AS A GAP BUT IT PASSED — the toolchain "
                        "changed under us. Re-read the gap note and delete it. "
                        + GAPS[rel]
                    )
            else:
                case["assert_me"] = True
                if not ok:
                    case["verification_failure"] = why
            case["observed"] = {
                "compile_command": res["compile_command"],
                "compile_exit": res["compile_exit"],
                "identities": observed_identity(lang, res),
                "diagnostics": res["diagnostics"][:6],
            }
            for extra in (
                "run_command",
                "run_exit",
                "run_stderr",
                "vet_command",
                "vet_exit",
                "vet_stderr",
                "race_command",
                "race_detected_runs",
            ):
                if extra in res:
                    v = res[extra]
                    if isinstance(v, str) and len(v) > 2000:
                        v = v[:2000] + "\n…truncated"
                    case["observed"][extra] = v

            # The genuine compiler output, on disk, so BE's classifier can be
            # unit-tested with no toolchain present.
            if lang == "rust":
                cap = HERE / (rel.rsplit(".", 1)[0] + ".rustc.json")
                cap.write_text(res["raw_compile_stderr"])
                case["captured"] = str(cap.relative_to(HERE))
                if res.get("run_stderr"):
                    rcap = HERE / (rel.rsplit(".", 1)[0] + ".runtime.txt")
                    rcap.write_text(res["run_stderr"])
                    case["captured_runtime"] = str(rcap.relative_to(HERE))
            else:
                cap = HERE / (rel.rsplit(".", 1)[0] + ".gobuild.txt")
                cap.write_text(res["raw_compile_stderr"])
                case["captured"] = str(cap.relative_to(HERE))
                blob = (res.get("run_stderr") or "") or res.get("race_stderr") or ""
                if blob:
                    rcap = HERE / (rel.rsplit(".", 1)[0] + ".runtime.txt")
                    rcap.write_text(blob)
                    case["captured_runtime"] = str(rcap.relative_to(HERE))
            cases_out.append(case)
        content_out = content_starters(build_root)
    finally:
        shutil.rmtree(build_root, ignore_errors=True)

    covered = sorted({c["kind"] for c in cases_out if c["verified"]})
    unverified = [
        c["file"] for c in cases_out if not c["verified"] and c.get("assert_me", True)
    ] + [c["quest_id"] for c in content_out if not c["verified"]]

    # Two kinds keyed off one code cannot both be decided by the code alone.
    # The classifier needs a second signal; naming the collisions here is
    # cheaper than BE finding out from a misfiled mistake row.
    by_code: dict[str, set] = {}
    for c in cases_out + content_out:
        if c.get("code"):
            by_code.setdefault(f"{c['lang']}:{c['code']}", set()).add(c["kind"])
    collisions = {
        code: {
            "kinds": sorted(kinds),
            "note": "the code alone does not decide the kind; the classifier "
            "needs the message or the span too",
        }
        for code, kinds in by_code.items()
        if len(kinds) > 1
    }

    # Codes these fixtures actually produced that SPEC §7.1's table does not
    # list. §7.1 says "Never drop a code you did not recognize" — so the
    # honest place for them is a named list, not a silent `other`.
    TAXONOMY_CODES = {
        "E0382", "E0505", "E0499", "E0502", "E0106", "E0597", "E0621", "E0308",
        "E0425", "E0433", "E0277", "E0596", "E0594",
        "unused_variables", "unused_imports",
    }
    off_table = sorted(
        {
            c["code"]
            for c in cases_out + content_out
            if c.get("lang") == "rust"
            and c.get("code")
            and c["code"] not in TAXONOMY_CODES
            and c.get("kind") != "other"
        }
    )

    doc = {
        "$comment": "Generated by tests/vectors/mistakes/generate.py — do not edit by hand.",
        "spec": "SPEC §7.1 (the taxonomy), §9.7 (the test)",
        "toolchain": {
            "rustc": tool_version("rustc", "--version"),
            "go": tool_version("go", "version"),
            "host": tool_version("uname", "-srm"),
        },
        "how_to_read_this": {
            "kind": "the §7.1 taxonomy slug the classifier must produce",
            "code": "the identity it must key off: a rustc code, or a slug for "
            "the normalized Go message. null where the toolchain gives none.",
            "phase": "compile = build fails | lint = build succeeds with a "
            "warning | runtime = build succeeds, program dies | tool = needs "
            "go vet or -race, not the plain build",
            "compile_time": "true for compile and lint, false for runtime and tool",
            "verified": "this generator re-ran the toolchain and saw the "
            "expected identity. false means the row is a claim, not a fact.",
            "captured": "the real compiler output, so the classifier can be "
            "tested with no toolchain installed. Byte for byte except for the "
            "normalisations below.",
        },
        "normalisation": {
            "why": "runtime output carries a scratch path, a thread id and a "
            "program counter that differ on every run and on every machine. "
            "Left in, they make `--check` impossible and bake this computer's "
            "temp directory into a fixture meant to run anywhere.",
            "substitutions": {
                "<work>": "the per-case scratch directory",
                "<tid>": "the thread id in a Rust panic header",
                "0x<pc>": "the program counter in a Go SIGSEGV line",
            },
            "not_normalised": "file names and line:col — `main.rs:5:21` is the "
            "span the classifier reads, and it is already relative because each "
            "source is compiled from its own temp cwd",
        },
        "cases": cases_out,
        "content_starter_cases": content_out,
        "kinds_covered": covered,
        "kinds_not_covered": NOT_COVERED,
        "known_gaps": {k: v for k, v in GAPS.items()},
        "code_collisions": collisions,
        "rust_codes_outside_the_71_table": {
            "codes": off_table,
            "note": "These came out of real fixtures but are in no row of SPEC "
            "§7.1's table. §7.1 says an unmatched code is stored as `other` "
            "with the code kept — but each of these has an obvious home, and "
            "filing a shipped quest's own starter under `other` on day one "
            "would be a poor first impression of the training loop. Proposed "
            "to PM in docs/decisions.md.",
        },
        "unverified_cases": unverified,
    }

    text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
    path = HERE / "expected.json"
    old = path.read_text() if path.exists() else None
    if args.check:
        if old != text:
            print("expected.json is stale — rerun the generator", file=sys.stderr)
            return 1
        print("expected.json is up to date")
        return 0
    path.write_text(text)
    print(
        f"wrote {path}: {len(cases_out)} synthetic + {len(content_out)} real-content "
        f"cases, {len(unverified)} unverified"
    )
    for f in unverified:
        print(f"  UNVERIFIED: {f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
