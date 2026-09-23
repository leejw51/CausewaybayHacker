#!/usr/bin/env python3
"""
Build art/manifest.json in CausewaybayGolang's shape (docs/art.md §3).

Every `box` is measured from the actual alpha, never guessed: it is the
sprite's ink bounds inside its transparent canvas, so the renderer can place a
sprite by its feet and its centre of mass rather than by the corner of its
cell. A sprite without one sits wrong on the map path and nobody can say why.
"""
import json, os, sys
from PIL import Image
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from process import box_of

# Draw order is the read order: the screens first, then the cast, then the
# furniture. It is the list a new engineer reads to learn what exists.
ORDER = [
    "title_bg", "title_bg_p",
    "map_rust", "map_rust_p", "map_go", "map_go_p",
    "map_cpp", "map_cpp_p", "map_python", "map_python_p",
    "map_pytorch", "map_pytorch_p",
    "map_typescript", "map_typescript_p",
    "bg_street", "bg_times", "bg_till", "bg_mtr",
    "bg_room732", "bg_room732_p", "bg_datacentre",
    "sprite_mei", "sprite_alex", "sprite_ferris", "sprite_gogo",
    "sprite_cpp", "sprite_python", "sprite_pytorch",
    "sprite_typescript",
    "agent_skynet",
    # The Rust coder — the AI agent on the code screens — and the three
    # provider bots that fly beside it. Borrowed from CausewaybayRaiden
    # (docs/agent.md §4).
    "agent_coder", "agent_bot_anthropic", "agent_bot_openai", "agent_bot_grok",
    # The agent's flourishes, from CausewaybayGolang: a star when it lands a
    # program, a coin, confetti.
    "fx_star", "ui_coin", "fx_confetti",
    # CODE PLAYGROUND's own emblem band on the land select (docs/agent.md).
    "emblem_playground",
    "boss_autocomplete", "boss_deadlock", "boss_nullptr",
    "boss_race", "boss_whiteboard", "boss_clock",
    "boss_segfault", "boss_dangling", "boss_linker",
    "boss_none", "boss_gil", "boss_recursion",
    "node_quest", "node_boss", "node_locked",
    "stamp_cleared", "fx_ribbon", "fx_medal", "fx_trophy", "ui_panel",
    # The opening (docs/story.md §2), in the order the sequence plays.
    "open_flat", "open_flat_p",
    "open_cursor", "open_cursor_p",
    "open_ghost", "open_ghost_p",
    "open_face", "open_face_p",
    "open_tills", "open_tills_p",
    "open_stairs", "open_stairs_p",
    "open_lands", "open_lands_p",
    # For the technique round: an animation strip, a near-parallax overlay,
    # and a palette-cycling source.
    "walk_mei", "fg_wires", "neon_signs",
    # CHOOSE YOUR LAND: one wide emblem band per land x category, the mascot
    # doing that category's job, and the two states a row can be in.
    "emblem_rust_basic", "emblem_rust_advanced", "emblem_rust_hacker",
    "emblem_go_basic", "emblem_go_advanced", "emblem_go_hacker",
    "emblem_cpp_basic", "emblem_cpp_advanced", "emblem_cpp_hacker",
    "emblem_python_basic", "emblem_python_advanced", "emblem_python_hacker",
    "emblem_pytorch_basic", "emblem_pytorch_advanced", "emblem_pytorch_hacker",
    "emblem_typescript_basic", "emblem_typescript_advanced", "emblem_typescript_hacker",
    "mascot_rust_basic", "mascot_rust_advanced", "mascot_rust_hacker",
    "mascot_go_basic", "mascot_go_advanced", "mascot_go_hacker",
    "mascot_cpp_basic", "mascot_cpp_advanced", "mascot_cpp_hacker",
    "mascot_python_basic", "mascot_python_advanced", "mascot_python_hacker",
    "mascot_pytorch_basic", "mascot_pytorch_advanced", "mascot_pytorch_hacker",
    "mascot_typescript_basic", "mascot_typescript_advanced", "mascot_typescript_hacker",
    "badge_cleared", "badge_locked",
    # The playground: the one room in the game with no problem in it.
    "bg_playground", "bg_playground_p",
    # The poster (frontend/src/ui/poster.ts): a square night street for the
    # sleeve, and the wax seal the credits are stamped with.
    "bg_poster", "poster_seal",
    # The award set (docs/decisions.md, "BE: XP, levels and the badge set").
    # Nine shapes: the silhouette is the family, tiers differ by colour and by
    # the number the engine prints over them.
    "badge_stamp", "badge_star",
    "badge_flame", "badge_flame_7", "badge_flame_30",
    "badge_chain", "badge_chain_10", "badge_chain_25",
    "badge_watch", "badge_shackle", "badge_flags", "badge_tally",
    "badge_chevron_bronze", "badge_chevron_silver", "badge_chevron",
    "badge_slot",
    # The trainer screens: AI mode's three plans, and the cleared_since meter
    # that turns SPEC §7.2's 0..5 counter into a shape.
    "emblem_ai_repeat", "emblem_ai_weakness", "emblem_ai_spaced",
    "shackle_break", "fx_shards",
    # The editor's own effects: rubble for a deleted character, dust for ENTER.
    "fx_bricks", "fx_dust",
]

# Assets that are not one picture. `walk_mei` is four frames in a row; the
# renderer needs the frame size and a box per frame, not one box for the sheet.
STRIPS = {"walk_mei": 4, "shackle_break": 6, "fx_bricks": 6, "fx_dust": 4}

root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..")
art = []
for name in ORDER:
    for ext in ("jpg", "png"):
        path = os.path.join(root, f"{name}.{ext}")
        if not os.path.exists(path):
            continue
        im = Image.open(path)
        e = {"name": name, "file": f"{name}.{ext}", "w": im.width, "h": im.height}
        if ext == "png":
            if name in STRIPS:
                n = STRIPS[name]
                e["frames"] = n
                e["fw"] = im.width // n
                e["fh"] = im.height
                e["boxes"] = [
                    box_of(im.convert("RGBA").crop((i * e["fw"], 0, (i + 1) * e["fw"], im.height)))
                    for i in range(n)
                ]
            else:
                b = box_of(im.convert("RGBA"))
                if b:
                    e["box"] = b
        art.append(e)
        break
    else:
        sys.stderr.write(f"missing: {name}\n")

out = os.path.join(root, "manifest.json")
with open(out, "w") as f:
    json.dump({"art": art}, f, indent=2)
    f.write("\n")
print(f"{len(art)} assets -> {out}")
