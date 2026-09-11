# Decisions

Append-only. Newest at the bottom. One entry per decision, dated.

A proposal that crosses a directory boundary goes here first; the owning agent
applies it and appends the outcome.

---

## 2026-09-11 — Server-authoritative, no wasm core

The sibling repos put game rules in Rust→wasm with TS as a shell. We do not.
The server compiles code, holds multiple users and owns a database; a wasm
core would be a second home for the same state and the two would drift.

Lifted from the siblings: the **engine layer** only — `layout.ts`, the pixel
font, particles, the art manifest convention.

## 2026-09-11 — Wallet key material never crosses the wire

Login derives the address in the browser (`@scure/bip39` + `@scure/bip32` +
`@noble/curves`) on `m/44'/60'/0'/0/0`, matching CausewaybayWallet exactly, and
proves it with an EIP-191 signature over a server nonce. Not even on localhost,
not even "for convenience".

## 2026-09-11 — Semantic search ships with a built-in embedder

`hashed` (3-gram + unigram hashing into 512 dims, corpus IDF) is compiled in and
is the default: no download, no network, deterministic, instant cold start. A
real ONNX sentence embedder sits behind the `embed-onnx` cargo feature, off by
default, and only gets wired in after its real footprint and offline behaviour
are verified.

## 2026-09-11 — Mistakes are classified by compiler error identity

`rustc --error-format=json` gives `E0382` and a span; Go's text is normalized
into the same taxonomy. Codes, not prose regexes, are what make "your top
mistake is borrow-after-move" a query instead of a pile of strings. An
unrecognized code is stored as `other` with the code kept — never dropped.
