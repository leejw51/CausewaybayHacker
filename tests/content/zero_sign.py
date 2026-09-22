#!/usr/bin/env python3
"""A printed zero must be an exact zero, or the arch decides its sign.

This exists because of one quest and twenty minutes of red CI.
`pytorch.advanced.17.layernorm` prints the mean of a normalised row. That mean
is zero by construction, but in float32 it lands a hair either side of it —
`1.49e-08` on an arm64 Mac, the same magnitude negative on the x86 runner.
`round(-1.49e-08, 4)` is `-0.0`, `-0.0` is not `0.0` as text, and the stdio
harness compares text (SPEC §5.2). So the pack verified green on one machine
and failed on the other, which is the worst shape a content bug can take: it
is not in the content you are looking at, it is in the machine you are looking
from.

`verify_pack.py` cannot catch this. It runs a solution and compares its output
to the expectation, and on any one machine the two are self-consistent. The
question here is a different one — *could* this output have come out
differently somewhere else? — and rather than reason about it, this runs the
other machine. Each solution runs twice, with `round` wrapped so that the
second run negates exactly those values that round to zero and are not zero:

    a value that rounds to zero and is not exactly zero is a value whose sign
    is the machine's to choose, so choose the other one and look.

If the two runs print the same thing, the quest does not care which side of
nothing the arithmetic landed on. If they differ, the pack is green here and
red there, and the diff is printed as the two strings CI would have shown.

An exact `0.0` — a distance from a point to itself, a masked-out probability,
`torch.zeros`, an accuracy counted from integers — is always `+0.0` and prints
as `0.0` everywhere, so it is never flagged. All 122 quests were scanned when
this was written; exactly one was fragile, and the fix was `+ 0.0` in the
print, which under IEEE 754 turns `-0.0` into `0.0` and leaves every other
value alone. The check is written to pass *after* such a fix: it compares what
is printed, not what went into the rounding.

The solutions are `exec`'d rather than run as subprocesses, because the whole
trick is wrapping `round` in the interpreter that is about to do the rounding.
That makes this a *lint over the content*, not a second judge: `verify_pack.py`
remains the thing that says whether a pack is correct.

    python3 tests/content/zero_sign.py content/pytorch/*.toml
"""
import builtins
import contextlib
import io
import pathlib
import sys
import tomllib

REAL_ROUND = builtins.round


def run(source, stdin, flip):
    """The solution's stdout, optionally with every cancellation zero flipped.

    `flip` is the other machine. Wrapping `round` to negate exactly those
    values that round to zero and are not zero reproduces, precisely and
    locally, the one thing that differed between the Mac and the runner. If
    the output is the same either way, the quest does not care which side of
    nothing the arithmetic landed on — which is the property being checked.
    """
    caught = []

    def spy(value, digits=None):
        if isinstance(value, float):
            out = REAL_ROUND(value, digits) if digits is not None else REAL_ROUND(value)
            # `value != 0.0` is the whole test: `-0.0 != 0.0` is False, so a
            # zero that was already signed by the maths is left alone.
            if out == 0 and value != 0.0:
                caught.append(value)
                if flip:
                    value = -value
        return REAL_ROUND(value, digits) if digits is not None else REAL_ROUND(value)

    out = io.StringIO()
    saved_stdin, builtins.round = sys.stdin, spy
    try:
        sys.stdin = io.StringIO(stdin)
        with contextlib.redirect_stdout(out):
            exec(  # noqa: S102 — running the pack's own reference solution
                compile(source.lstrip("\n"), "main.py", "exec"),
                {"__name__": "__main__"},
            )
    finally:
        builtins.round, sys.stdin = REAL_ROUND, saved_stdin
    return out.getvalue(), caught


def scan(path):
    """Fragile (quest id, case, here, there) for one pack."""
    bad = []
    for quest in tomllib.loads(path.read_text())["quest"]:
        for case in quest["tests"]["cases"]:
            try:
                here, caught = run(quest["solution"], case.get("stdin", ""), flip=False)
                if not caught:
                    continue  # no cancellation zero at all: nothing to decide
                there, _ = run(quest["solution"], case.get("stdin", ""), flip=True)
            except Exception as e:  # noqa: BLE001 — verify_pack judges; this only looks
                print(f"  ? {quest['id']} [{case['name']}] did not run: {type(e).__name__}: {e}")
                continue
            if here != there:
                bad.append((quest["id"], case["name"], here, there))
    return bad


def main(argv):
    paths = [pathlib.Path(a) for a in argv]
    if not paths:
        print(__doc__)
        return 2
    bad = [row for p in paths for row in scan(p)]
    for qid, case, here, there in bad:
        print(f"  FAIL {qid} [{case}]: the output depends on the sign of a zero.")
        print(f"       here:  {here.strip()!r}")
        print(f"       there: {there.strip()!r}")
        print("       Add `+ 0.0` to the printed value — in the starter and the solution")
        print("       both, since the player types neither — and say so in the brief.")
    n = sum(len(p.read_text().split("[[quest]]")) - 1 for p in paths)
    print(
        f"\n=== {len(bad)} fragile zero(s) across {n} quests in {len(paths)} pack(s) ==="
        if bad
        else f"\n=== every printed zero in {n} quests is an exact zero ==="
    )
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
