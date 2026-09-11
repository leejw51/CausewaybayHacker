#!/bin/sh
# One asset, end to end: generate with Grok, knock the magenta out, measure the
# box, and record the prompt in art/prompts.toml so the set can be re-rolled.
#
#   art/tools/gen.sh <name> <sprite|bg> <aspect> <w> <h> [feet|center] "prompt"
#
# An asset nobody can regenerate is a liability, so the prompt is appended
# BEFORE the image is processed — a crashed run still leaves the recipe.
set -eu
cd "$(dirname "$0")/../.."
name=$1 kind=$2 aspect=$3 w=$4 h=$5 anchor=$6
shift 6
prompt=$*
ext=png; [ "$kind" = bg ] && ext=jpg

art/tools/grok_image.sh "art/raw/$name.png" "$aspect" "$prompt" >/dev/null
python3 - "$name" "$kind" "$aspect" "$w" "$h" "$prompt" <<'PY' >> art/prompts.toml
import sys, datetime
name, kind, aspect, w, h, prompt = sys.argv[1:7]
print(f'\n[[asset]]\nname = "{name}"\nkind = "{kind}"\naspect = "{aspect}"')
print(f'size = [{w}, {h}]\ngenerated = "{datetime.date.today()}"\nrerolls = 0')
print('prompt = """\\\n' + prompt.replace('\\', '\\\\').replace('"""', '\\"\\"\\"') + '"""')
PY
python3 art/tools/process.py "$kind" "art/raw/$name.png" "art/$name.$ext" "$w" "$h" "$anchor"
