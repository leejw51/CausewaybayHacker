#!/usr/bin/env python3
"""Re-roll an asset that is already in `art/prompts.toml`, by name.

`gen.sh` is for an asset that does not exist yet: it generates, then *appends*
a new `[[asset]]` block with the recipe in it. Running it against a name the
file already carries would leave two blocks with one name, and the next reader
— `manifest.py`, a person, the next re-roll — has no way to tell which one the
file on disk came from.

This is the other half: the recipe is already written down, so read it rather
than retype it. The prompt, the kind and the size come out of the file, the
image comes back from Grok, `process.py` finishes it exactly as `gen.sh` would,
and the block is stamped in place — `generated` to today, `rerolls` up by one.

    XAI_API_KEY=... art/tools/reroll.py sprite_pytorch
    XAI_API_KEY=... art/tools/reroll.py emblem_pytorch_basic mascot_pytorch_hacker
    XAI_API_KEY=... art/tools/reroll.py --land pytorch

Nothing is written until the image is in hand: a failed call leaves the asset
on disk and the block in the file exactly as they were, which matters when the
asset being replaced is the one thing standing between a land and a blank
screen. Use `--dry-run` to see what would be rolled, and what it would cost.
"""
import argparse
import datetime
import json
import pathlib
import re
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
PROMPTS = ROOT / "art" / "prompts.toml"
RAW = ROOT / "art" / "raw"


def load():
    """Every `[[asset]]` block, as (name, text, parsed fields)."""
    text = PROMPTS.read_text()
    blocks = []
    for m in re.finditer(r"\[\[asset\]\]\n(?:.*?\n)*?(?=\n\[\[asset\]\]|\Z)", text):
        body = m.group(0)
        name = re.search(r'^name = "([^"]+)"', body, re.M)
        if not name:
            continue
        kind = re.search(r'^kind = "([^"]+)"', body, re.M)
        aspect = re.search(r'^aspect = "([^"]+)"', body, re.M)
        size = re.search(r"^size = \[(\d+), *(\d+)\]", body, re.M)
        prompt = re.search(r'^prompt = """\\?\n?(.*?)"""', body, re.M | re.S)
        blocks.append(
            {
                "name": name.group(1),
                "span": m.span(),
                "body": body,
                "kind": kind.group(1) if kind else "sprite",
                "aspect": aspect.group(1) if aspect else "1:1",
                "size": (int(size.group(1)), int(size.group(2))) if size else (128, 128),
                "prompt": prompt.group(1).strip() if prompt else "",
            }
        )
    return text, blocks


def stamp(name):
    """`generated` to today and `rerolls` up one, in that one block."""
    text, blocks = load()
    block = next(b for b in blocks if b["name"] == name)
    body = block["body"]
    rolls = int(re.search(r"^rerolls = (\d+)", body, re.M).group(1))
    body = re.sub(
        r'^generated = "[^"]*"', f'generated = "{datetime.date.today()}"', body, flags=re.M
    )
    body = re.sub(r"^rerolls = \d+", f"rerolls = {rolls + 1}", body, flags=re.M)
    lo, hi = block["span"]
    PROMPTS.write_text(text[:lo] + body + text[hi:])


def roll(asset, anchor, dry):
    name, kind = asset["name"], asset["kind"]
    w, h = asset["size"]
    ext = "jpg" if kind == "bg" else "png"
    dst = ROOT / "art" / f"{name}.{ext}"
    if dry:
        print(f"  {name:<26} {kind:<7} {asset['aspect']:<5} {w}x{h} -> {dst.name}")
        return True
    if not asset["prompt"]:
        print(f"  {name}: no prompt recorded; nothing to roll from", file=sys.stderr)
        return False

    RAW.mkdir(parents=True, exist_ok=True)
    raw = RAW / f"{name}.png"
    print(f"  {name}: generating…", flush=True)
    gen = subprocess.run(
        [str(ROOT / "art/tools/grok_image.sh"), str(raw), asset["aspect"], asset["prompt"]],
        capture_output=True,
        text=True,
    )
    if gen.returncode != 0 or not raw.exists():
        print(f"  {name}: FAILED\n{gen.stderr.strip()}", file=sys.stderr)
        return False

    out = subprocess.run(
        [
            sys.executable,
            str(ROOT / "art/tools/process.py"),
            kind,
            str(raw),
            str(dst),
            str(w),
            str(h),
            anchor,
        ],
        capture_output=True,
        text=True,
    )
    if out.returncode != 0:
        print(f"  {name}: process.py failed\n{out.stderr.strip()}", file=sys.stderr)
        return False
    stamp(name)
    print(f"  {name}: {json.loads(out.stdout)['file']}")
    return True


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("names", nargs="*", help="asset names, as `prompts.toml` spells them")
    ap.add_argument("--land", help="every asset whose name ends in this land")
    ap.add_argument("--anchor", default="feet", choices=["feet", "center"])
    ap.add_argument("--dry-run", action="store_true", help="say what would be rolled")
    args = ap.parse_args()

    _, blocks = load()
    by_name = {b["name"]: b for b in blocks}
    wanted = list(args.names)
    if args.land:
        # `sprite_pytorch`, `mascot_pytorch_*`, `emblem_pytorch_*` — and not
        # `map_pytorch`, which is a shared plate rather than this land's own.
        wanted += [
            b["name"]
            for b in blocks
            if args.land in b["name"].split("_") and not b["name"].startswith("map_")
        ]
    if not wanted:
        ap.error("name at least one asset, or a --land")

    missing = [n for n in wanted if n not in by_name]
    if missing:
        ap.error(f"not in {PROMPTS.name}: {', '.join(missing)}")

    print(f"{len(wanted)} asset(s) from {PROMPTS.name}:")
    ok = all(roll(by_name[n], args.anchor, args.dry_run) for n in wanted)
    if not args.dry_run:
        print("\nnow: python3 art/tools/manifest.py && make art")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
