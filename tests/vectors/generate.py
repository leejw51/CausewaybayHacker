#!/usr/bin/env python3
"""Regenerate tests/vectors/addresses.json and tests/vectors/signatures.json.

Every value in those two files comes out of `CausewaybayWallet`'s own binary.
Nothing here reimplements BIP-32, keccak or secp256k1 — that is the entire
point: if this file computed the answers itself, the conformance test would
only prove that QA agrees with QA.

    python3 tests/vectors/generate.py            # writes both files
    python3 tests/vectors/generate.py --check    # exits 1 if they would change

The wallet binary is found at $CWBWALLET, else at the sibling checkout's
debug build. `utils derive` / `utils sign` / `utils keccak` store nothing
(the wallet's own help calls them "the calculator, not the wallet"), but a
throwaway --home is passed anyway so a bug in that claim cannot reach the
user's real store.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile

HERE = pathlib.Path(__file__).resolve().parent
DEFAULT_WALLET = (
    HERE.parents[2] / "CausewaybayWallet" / "rustcli" / "target" / "debug" / "cwbwallet"
)

# ---------------------------------------------------------------- the inputs

# Well-known, published, and holding nothing. Never a phrase that could be a
# real user's: every one of these is printed in a README somewhere.
MNEMONICS = [
    {
        "name": "bip39-canonical",
        "note": "The all-zero-entropy phrase from the BIP-39 English test vectors.",
        "phrase": "abandon abandon abandon abandon abandon abandon abandon "
        "abandon abandon abandon abandon about",
        "indices": [0, 1, 2, 3, 4],
    },
    {
        "name": "foundry-anvil-default",
        "note": "What Anvil and Hardhat print on startup. Anyone who has run a "
        "local node has seen these addresses.",
        "phrase": "test test test test test test test test test test test junk",
        "indices": [0, 1, 2],
    },
    {
        "name": "bip39-legal-winner",
        "note": "The second BIP-39 English test vector.",
        "phrase": "legal winner thank year wave sausage worth useful legal "
        "winner thank yellow",
        "indices": [0, 1],
    },
]

# SPEC §3.2's challenge, with the nonce and expiry frozen so the digest is a
# constant. The nonce is derived from a fixed string rather than typed, so it
# is reproducible and obviously synthetic.
NONCE = hashlib.sha256(b"causewaybay-hacker signature fixture v1").hexdigest()
EXPIRES = "2026-09-11T04:14:33Z"

SIGNERS = [
    {
        "name": "anvil-account-0",
        "note": "Anvil's first account. Published in Foundry's startup banner.",
        "private_key": "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
    },
    {
        "name": "bip39-canonical-index-0",
        "note": "Account 0 of the all-zero-entropy BIP-39 mnemonic.",
        "private_key": "0x1ab42cc412b618bdea3a599e3c9bae199ebf030895b039e9db1e30dafb12b727",
    },
]

# ---------------------------------------------------------------- the driver


class Wallet:
    def __init__(self, binary: pathlib.Path, home: pathlib.Path) -> None:
        self.binary = binary
        self.home = home
        self.calls: list[str] = []

    def run(self, *args: str) -> dict:
        argv = [str(self.binary), "--json", "--home", str(self.home), *args]
        # Recorded with the throwaway home elided, so the README shows a
        # command a reader can paste.
        self.calls.append(
            " ".join(["cwbwallet", "--json", *args])
        )
        out = subprocess.run(argv, capture_output=True, text=True, check=False)
        if out.returncode != 0:
            raise SystemExit(
                f"wallet call failed: {' '.join(argv)}\n{out.stdout}{out.stderr}"
            )
        env = json.loads(out.stdout)
        if not env.get("ok"):
            raise SystemExit(f"wallet returned not-ok: {' '.join(argv)}\n{out.stdout}")
        return env["data"]

    def version(self) -> str:
        out = subprocess.run(
            [str(self.binary), "--version"], capture_output=True, text=True, check=True
        )
        return out.stdout.strip()


def challenge_message(address_eip55: str) -> str:
    """PROTOCOL.md §4.2, verbatim.

    Four lines, `\n`-separated, no trailing newline. SPEC §3.2 printed this
    inside a fenced block, which did not settle whether a final newline was
    part of it; PROTOCOL.md §4.2 — now the authority for the wire — says it
    is not. EIP-191 hashes the byte length, so that one newline is the
    difference between a login that works and one that silently does not.

    The `(EIP-55)` that SPEC §3.2 printed beside the address is an annotation
    about spelling, not part of the message.
    """
    return (
        "Causewaybay Hacker login\n"
        f"address: {address_eip55}\n"
        f"nonce: {NONCE}\n"
        f"expires: {EXPIRES}"
    )


def eip191_digest(wallet: Wallet, message: str) -> str:
    """keccak256("\\x19Ethereum Signed Message:\\n" + len + message), the long way.

    Computed through `utils keccak --hex` over bytes this script assembles,
    rather than read off the signer — so the digest in the fixture is
    confirmed by a second path through the same binary.
    """
    body = message.encode("utf-8")
    prefixed = b"\x19Ethereum Signed Message:\n" + str(len(body)).encode() + body
    return wallet.run("utils", "keccak", "--hex", prefixed.hex())["keccak256"]


# ---------------------------------------------------------------- generation


def build_addresses(wallet: Wallet) -> dict:
    entries = []
    for m in MNEMONICS:
        accounts = []
        for i in m["indices"]:
            d = wallet.run(
                "utils", "derive", "--mnemonic", m["phrase"], "--index", str(i)
            )
            assert d["derivation_path"] == f"m/44'/60'/0'/0/{i}", d
            accounts.append(
                {
                    "index": i,
                    "path": d["derivation_path"],
                    "address": d["address"],
                    "address_lower": d["address"].lower(),
                    "private_key": d["private_key"],
                    "public_key_compressed": d["public_key_compressed"],
                }
            )
        entries.append(
            {
                "name": m["name"],
                "note": m["note"],
                "phrase": m["phrase"],
                "accounts": accounts,
            }
        )
    return entries


def build_signatures(wallet: Wallet) -> list:
    vectors = []
    for s in SIGNERS:
        derived = wallet.run("utils", "derive", "--private-key", s["private_key"])
        address = derived["address"]
        message = challenge_message(address)
        body = message.encode("utf-8")
        digest = eip191_digest(wallet, message)
        signed = wallet.run(
            "utils", "sign", "--private-key", s["private_key"], "--message", message
        )
        sig = signed["signature"]
        assert sig.startswith("0x") and len(sig) == 132, sig
        # The wallet's own recovery, as a third opinion on the same bytes.
        recovered = wallet.run(
            "verify", "--message", message, "--signature", sig, "--address", address
        )
        vectors.append(
            {
                "name": s["name"],
                "note": s["note"],
                "private_key": s["private_key"],
                "address": address,
                "address_lower": address.lower(),
                "message": message,
                "message_hex": "0x" + body.hex(),
                "message_len": len(body),
                "message_ends_with_newline": message.endswith("\n"),
                "nonce": NONCE,
                "expires_at": EXPIRES,
                "eip191_digest": digest,
                "signature": sig,
                "r": "0x" + sig[2:66],
                "s": "0x" + sig[66:130],
                "v": int(sig[130:132], 16),
                "recovery_id": int(sig[130:132], 16) - 27,
                "wallet_verify": recovered,
            }
        )
    return vectors


def negative_cases(vectors: list) -> list:
    """Signatures that must NOT authenticate. A verifier that only ever sees
    good input passes by accident."""
    good = vectors[0]
    flipped = good["signature"][:-2] + ("1b" if good["v"] == 28 else "1c")
    zeroed = "0x" + "00" * 65
    return [
        {
            "name": "wrong-v",
            "why": "the same r||s with the other parity recovers a different address",
            "message": good["message"],
            "signature": flipped,
            "claimed_address": good["address"],
            "expect": "auth_bad_signature",
        },
        {
            "name": "all-zero",
            "why": "a 65-byte zero signature must be rejected, not crash the recoverer",
            "message": good["message"],
            "signature": zeroed,
            "claimed_address": good["address"],
            "expect": "auth_bad_signature",
        },
        {
            "name": "truncated",
            "why": "64 bytes, no recovery id — a length check must catch it first",
            "message": good["message"],
            "signature": good["signature"][:130],
            "claimed_address": good["address"],
            "expect": "auth_bad_signature",
        },
        {
            "name": "other-signer",
            "why": "a valid signature over the right message by the wrong key",
            "message": good["message"],
            "signature": vectors[1]["signature"],
            "claimed_address": good["address"],
            "expect": "auth_bad_signature",
        },
    ]


def cross_check(addresses: list) -> dict:
    """The wallet's own testvectors/derivation.json came from `eth-account`,
    an independent implementation. Where the two overlap they must agree, and
    that agreement is the claim worth recording."""
    ref_path = (
        HERE.parents[2] / "CausewaybayWallet" / "testvectors" / "derivation.json"
    )
    if not ref_path.exists():
        return {"checked": False, "reason": f"not found: {ref_path}"}
    ref = json.loads(ref_path.read_text())
    by_name = {m["name"]: m for m in ref["mnemonics"]}
    compared = 0
    for entry in addresses:
        other = by_name.get(entry["name"])
        if not other:
            continue
        ref_accounts = {a["index"]: a for a in other["accounts"]}
        for acct in entry["accounts"]:
            r = ref_accounts.get(acct["index"])
            if not r:
                continue
            if r["address"] != acct["address"]:
                raise SystemExit(
                    f"DRIFT: {entry['name']}[{acct['index']}] "
                    f"wallet CLI says {acct['address']}, "
                    f"eth-account vector says {r['address']}"
                )
            compared += 1
    return {
        "checked": True,
        # Relative to the checkout, not this machine: an absolute path in a
        # committed fixture is a path that is wrong on every other computer.
        "source": "../CausewaybayWallet/testvectors/derivation.json",
        "source_generator": ref.get("source"),
        "rows_compared": compared,
    }


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true", help="fail if output would change")
    args = ap.parse_args()

    binary = pathlib.Path(os.environ.get("CWBWALLET", DEFAULT_WALLET))
    if not binary.exists():
        print(
            f"cwbwallet not found at {binary}\n"
            "build it:  make -C ../CausewaybayWallet build\n"
            "or point $CWBWALLET at it.",
            file=sys.stderr,
        )
        return 2

    home = pathlib.Path(tempfile.mkdtemp(prefix="cwbhacker-vectors-"))
    try:
        wallet = Wallet(binary, home)
        version = wallet.version()
        addresses = build_addresses(wallet)
        signatures = build_signatures(wallet)
        crosscheck = cross_check(addresses)

        addresses_doc = {
            "$comment": "Generated by tests/vectors/generate.py — do not edit by hand.",
            "spec": "SPEC §3.1, §3.4, §9.1",
            "generated_by": {
                "tool": "CausewaybayWallet cwbwallet",
                "version": version,
                "command": "cwbwallet --json utils derive --mnemonic <phrase> --index <i>",
                "home": "a throwaway --home; `utils derive` stores nothing",
            },
            "cross_checked_against": crosscheck,
            "path_template": "m/44'/60'/0'/0/{index}",
            "mnemonics": addresses,
        }
        signatures_doc = {
            "$comment": "Generated by tests/vectors/generate.py — do not edit by hand.",
            "spec": "SPEC §3.2, §9.2",
            "generated_by": {
                "tool": "CausewaybayWallet cwbwallet",
                "version": version,
                "sign": "cwbwallet --json utils sign --private-key <k> --message <msg>",
                "digest": "cwbwallet --json utils keccak --hex <0x19 || prefix || len || message>",
                "recover": "cwbwallet --json verify --message <msg> --signature <sig> --address <a>",
            },
            "authority": "PROTOCOL.md §4.2 (the message) and §4.3 (the digest "
            "and the v encoding). SPEC §6 is a summary of it.",
            "message_template": {
                "lines": [
                    "Causewaybay Hacker login",
                    "address: {address_eip55}",
                    "nonce: {nonce}",
                    "expires: {expires_at}",
                ],
                "joined_by": "\\n",
                "trailing_newline": False,
                "note": "SPEC §3.2 printed '(EIP-55)' beside the address line as "
                "an annotation; it is NOT part of the message. PROTOCOL.md §4.2 "
                "pins both the four lines and the absence of a trailing newline. "
                "Clients must sign this string byte-for-byte as the server gives "
                "it, never rebuild it from the parts.",
            },
            "v_encoding": {
                "in_fixture": "27 or 28 (Ethereum convention, the last byte of r||s||v)",
                "k256_recovery_id": "v - 27, i.e. 0 or 1",
                "note": "k256's RecoveryId is 0/1. A verifier that feeds it 27/28 "
                "fails on every login. Both forms are in each vector.",
            },
            "vectors": signatures,
            "must_reject": negative_cases(signatures),
        }
    finally:
        shutil.rmtree(home, ignore_errors=True)

    changed = False
    for name, doc in (
        ("addresses.json", addresses_doc),
        ("signatures.json", signatures_doc),
    ):
        text = json.dumps(doc, indent=2, ensure_ascii=False) + "\n"
        path = HERE / name
        old = path.read_text() if path.exists() else None
        if old != text:
            changed = True
            if args.check:
                print(f"would change: {path}", file=sys.stderr)
            else:
                path.write_text(text)
                print(f"wrote {path}")
    if args.check:
        if changed:
            print("vectors are stale — run tests/vectors/generate.py", file=sys.stderr)
            return 1
        print("vectors are up to date")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
