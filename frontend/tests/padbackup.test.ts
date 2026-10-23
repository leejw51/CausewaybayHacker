import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { describe, expect, it } from "vitest";
import type { Snippet } from "../src/net/protocol";
import {
  backupEntries,
  backupFileName,
  backupZip,
  padsCsv,
  padsJsonl,
  padsMarkdown,
} from "../src/ui/padbackup";
import { crc32, zip } from "../src/ui/zip";

/**
 * BACKUP packs the whole shelf into one zip: JSONL, CSV and Markdown of every
 * pad, and each pad as its own file. The formats are asserted by reading them
 * back the way their readers would, and the zip by the system's own `unzip`,
 * which is the reader that matters.
 */
const pad = (over: Partial<Snippet>): Snippet => ({
  id: "pg_1",
  name: "scratch 2026-10-23",
  lang: "rust",
  source: 'fn main() {\n    println!("OK");\n}\n',
  stdin: "",
  created_at: "2026-10-23T09:00:00Z",
  updated_at: "2026-10-23T09:05:00Z",
  ...over,
});

const PADS: Snippet[] = [
  pad({}),
  pad({
    id: "pg_2",
    name: '빌림 "ideas", part 2',
    lang: "go",
    source: 'package main\n\n// ```go fences``` inside\nfunc main() { println("a,b") }\n',
    stdin: "3\n1 2 3\n",
  }),
  pad({ id: "pg_3", name: "scratch 2026-10-23", lang: "python", source: "print(input())\n" }),
];

describe("the pad backup formats", () => {
  it("JSONL is one whole Snippet per line", () => {
    const lines = padsJsonl(PADS).trimEnd().split("\n");
    expect(lines).toHaveLength(3);
    expect(lines.map((l) => JSON.parse(l))).toEqual(PADS);
    expect(padsJsonl([])).toBe("");
  });

  it("CSV quotes every field, so commas, quotes and newlines survive", () => {
    const csv = padsCsv(PADS);
    expect(csv.split("\r\n")[0]).toBe("id,name,lang,created_at,updated_at,stdin,source");
    expect(csv).toContain('"빌림 ""ideas"", part 2"');
    // A minimal RFC 4180 reader: what goes in comes out.
    const rows: string[][] = [];
    let row: string[] = [];
    let cell = "";
    let quoted = false;
    for (let i = 0; i < csv.length; i++) {
      const c = csv[i];
      if (quoted) {
        if (c === '"' && csv[i + 1] === '"') ((cell += '"'), i++);
        else if (c === '"') quoted = false;
        else cell += c;
      } else if (c === '"') quoted = true;
      else if (c === ",") (row.push(cell), (cell = ""));
      else if (c === "\r" && csv[i + 1] === "\n") {
        (row.push(cell), rows.push(row), (row = []), (cell = ""), i++);
      } else cell += c;
    }
    expect(rows).toHaveLength(4);
    expect(rows[2][1]).toBe(PADS[1].name);
    expect(rows[2][5]).toBe(PADS[1].stdin);
    expect(rows[2][6]).toBe(PADS[1].source);
  });

  it("Markdown fences each pad with more backticks than it contains", () => {
    const md = padsMarkdown(PADS, new Date("2026-10-23T10:00:00Z"));
    expect(md).toContain("# Playground pads");
    expect(md).toContain("3 pads");
    expect(md).toContain('## 빌림 "ideas", part 2');
    expect(md).toContain("````go\n");
    expect(md).toContain("```rust\n");
    expect(md).toContain("stdin:");
  });
});

describe("the backup zip", () => {
  it("has the three views and every pad as its own file", () => {
    const names = backupEntries(PADS, new Date()).map((e) => e.name);
    expect(names).toEqual([
      "pads.jsonl",
      "pads.csv",
      "pads.md",
      "pads/1-scratch-2026-10-23/main.rs",
      "pads/2-빌림-_ideas_,-part-2/main.go",
      "pads/2-빌림-_ideas_,-part-2/stdin.txt",
      // Same name as the first: the number keeps them apart.
      "pads/3-scratch-2026-10-23/main.py",
    ]);
    expect(backupFileName(new Date(2026, 9, 23, 18, 43))).toBe(
      "causewaybay-pads-20261023-1843.zip",
    );
  });

  it("is a zip that unzip checks clean and a UTF-8 reader extracts whole", () => {
    const dir = mkdtempSync(join(tmpdir(), "padbackup-"));
    const file = join(dir, "pads.zip");
    writeFileSync(file, backupZip(PADS, new Date(2026, 9, 23, 18, 43)));
    let tested: string;
    try {
      tested = execFileSync("unzip", ["-t", file], { encoding: "utf8" });
    } catch (e) {
      if ((e as { code?: string }).code === "ENOENT") return; // no unzip here
      throw e;
    }
    expect(tested).toContain("No errors detected");
    // Extracted by a reader that honours the UTF-8 name flag, as Finder and
    // Windows do. macOS's own `unzip` is built without it and mangles a
    // Korean name — a property of that binary, not of the archive.
    const out = join(dir, "out");
    execFileSync("python3", [
      "-I",
      "-c",
      "import sys, zipfile; zipfile.ZipFile(sys.argv[1]).extractall(sys.argv[2])",
      file,
      out,
    ]);
    expect(readFileSync(join(out, "pads.jsonl"), "utf8")).toBe(padsJsonl(PADS));
    expect(readFileSync(join(out, "pads/2-빌림-_ideas_,-part-2/main.go"), "utf8")).toBe(
      PADS[1].source,
    );
  });

  it("records the CRC of each entry", () => {
    const bytes = zip([{ name: "a.txt", data: "hello" }]);
    const v = new DataView(bytes.buffer);
    expect(v.getUint32(0, true)).toBe(0x04034b50);
    expect(v.getUint32(14, true)).toBe(crc32(new TextEncoder().encode("hello")));
    // End of central directory: one entry.
    expect(v.getUint32(bytes.length - 22, true)).toBe(0x06054b50);
    expect(v.getUint16(bytes.length - 22 + 10, true)).toBe(1);
  });
});

/**
 * The scene's half: BACKUP fires on the way up like POSTER (a download needs
 * the activation a finger's `pointerup` gives), CLEAR ALL asks before it
 * deletes, and the shelf's size comes from the server rather than a copy of
 * the number.
 */
describe("the playground's shelf buttons", () => {
  const SOURCE = readFileSync(resolve(process.cwd(), "src/scenes/playground.ts"), "utf8");

  it("fires BACKUP on the pointerup", () => {
    expect(SOURCE).toContain(
      'if (armed === "poster") void this.poster();\n        else if (armed === "backup") void this.backup();',
    );
    expect(SOURCE).toContain('hit.id === "poster" || hit.id === "reader" || hit.id === "backup"');
  });

  it("only clears on a second press", () => {
    const body = SOURCE.slice(SOURCE.indexOf("private async clearAll("));
    const fn = body.slice(0, body.indexOf("\n  }\n"));
    const arm = fn.indexOf("if (!this.clearArmed())");
    const del = fn.indexOf('"playground.delete"');
    expect(arm).toBeGreaterThan(-1);
    expect(del).toBeGreaterThan(arm);
    expect(fn.slice(arm, del)).toContain("return;");
  });

  it("draws the bar against the server's limit", () => {
    expect(SOURCE).toContain("this.shelfLimit = res.limit ?? null;");
    expect(SOURCE).not.toMatch(/shelfLimit\s*=\s*\d/);
  });
});
