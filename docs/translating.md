# Translating the quests

The mechanical contract — where the file goes, what it may contain, what CI
checks — is [`SPEC.md` §12.1](../SPEC.md). This file is the other half: how to
write one so it reads as though the quest had been written in that language,
rather than converted into it.

The interface is a separate job and is already done. `frontend/src/i18n/*.ts`
and `love2d/src/lang/*.lua` hold every label and message the client writes
itself. **Read your language's UI catalogue before you start**: its header
comment fixes the words for land, quest, brief, hint, cleared, submit, run and
compile, and a translation that calls a land something else than the button
above it does is worse than one that is late.

## What is translated, and what is not

Four fields: `title`, `story`, `brief`, `hints`. Nothing else may appear in the
file.

**Never translated**, because the program's behaviour depends on them being
exactly what the English says:

* fenced code blocks — starter fragments, sample input, expected output. CI
  compares them byte for byte.
* inline code in backticks: identifiers, types, keywords, function names,
  file names, flags, compiler error codes (`E0382`).
* the exact strings a program must print. `hello, causewaybay` is data.
* boss names: **NULLPTR**, **THE GIL**, **SEGFAULT**, **THE AUTOCOMPLETE**.
  They are names, like RUST and GO, and they stay as they are in every
  language — the same rule the UI catalogues already follow.

**Always translated**: the prose around all of that, including the titles. The
English titles are uppercase because that is how the map draws them; in a CJK
locale write a natural title and let the engine do the shouting.

Hong Kong place names take the locale's established form where one exists
(銅鑼灣, 铜锣湾, 코즈웨이베이, コーズウェイベイ) and stay English where none
does. The story is set in a real neighbourhood and a reader from there should
recognise it.

## The brief is a specification

A `story` line can be loose. A `brief` cannot: it is the statement of the
problem, and a player who fails a hidden case because the translation dropped
"and nothing else" has been cheated by this file.

Carry every constraint: the exact output format, every numeric bound, the
edge cases, whether the count is inclusive, what happens on empty input. When
the English says *print exactly*, say exactly. When it names a complexity the
solution must meet, name it. Read your translation back and ask whether you
could solve the quest from it alone, without the English.

Hints are revealed one at a time and are **paid for**, so hint *N* must be the
translation of hint *N*: they walk from a nudge to nearly the answer, and a
reordering sells the player the wrong thing. The count must match, and CI
enforces that.

## Register, per language

| locale | register |
| --- | --- |
| `ko` | As the UI catalogue does. Technical nouns in English where that is what Korean developers say. |
| `yue` | **Colloquial written Cantonese in traditional characters** — 嘅／咗／唔／係／喺／而家／冇. Not Standard Written Chinese in traditional glyphs; that is `zh` with different shapes, and shipping both would be shipping one language twice. The jargon is the exception: 編譯, 提交, 格式化 are what people actually say. |
| `zh` | Simplified characters, standard written register. Reads as a tool, deliberately: `yue` is the one with a voice from the neighbourhood. |
| `ja` | As the UI catalogue does, consistently — do not drift between です・ます and 常体 inside one pack. |
| `cs` | As the UI catalogue does. Czech declines: the quest titles are names and should still read as Czech, not as transliterated English. |

Inside a string, use the language's own quotation marks — 「」or “ ” — never a
bare ASCII `"`, which ends the TOML string and breaks the file. This has
happened.

## Working order

One pack at a time. Read the whole English pack first, so the vocabulary a
later quest depends on is already chosen. Then write the file and run:

```
python3 tests/content/verify_pack.py --i18n content/<land>/<category>.toml
```

until your locale's line reads `OK`. The verifier checks coverage, hint counts,
the `'''` rule and the code blocks. It cannot check that the prose is good, or
even that it is in the right language, so that part is on the writer.

## Where each language has got to

278 quests per language: 69 each in Rust and Go, 70 each in C++ and Python.
The counts below are what `verify_pack.py --i18n` prints; trust it over this
table, which is a snapshot.

| locale | translated | left |
| --- | --- | --- |
| `ko` | 173 | `rust.hacker` done; `cpp.*` and `python.hacker` outstanding |
| `zh` | 173 | as `ko` |
| `ja` | 173 | as `ko` |
| `cs` | 139 | also `rust.hacker` |
| `yue` | 105 | also `rust.hacker` and `go.hacker` |

No language has any of the three `cpp` packs yet — C++ Land is newer than the
translation effort. `verify_pack.py --i18n` prints this table's live version at
the bottom of every run; trust that over this file.
