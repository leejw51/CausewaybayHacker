/**
 * BACKUP: every pad on the shelf, out of the server and into one zip.
 *
 * Three views of the same list, because they are read by three different
 * things — `pads.jsonl` by a program (one `Snippet` per line, exactly as the
 * server sent it), `pads.csv` by a spreadsheet, `pads.md` by a person — and
 * beside them each pad as the file it is, under `pads/`, so a backup can be
 * opened in an editor without parsing anything.
 *
 * Pure: the scene fetches, this formats, `saveFiles` hands it over.
 */
import type { Snippet } from "../net/protocol";
import { MAIN_FILE } from "./editor";
import { zip, type ZipEntry } from "./zip";

const COLUMNS = ["id", "name", "lang", "created_at", "updated_at", "stdin", "source"] as const;

export function padsJsonl(pads: readonly Snippet[]): string {
  return pads.map((p) => JSON.stringify(p)).join("\n") + (pads.length ? "\n" : "");
}

/** RFC 4180: every field quoted, quotes doubled, CRLF between records. */
export function padsCsv(pads: readonly Snippet[]): string {
  const cell = (v: string) => `"${v.replace(/"/g, '""')}"`;
  const rows = [COLUMNS.join(","), ...pads.map((p) => COLUMNS.map((c) => cell(p[c])).join(","))];
  return rows.join("\r\n") + "\r\n";
}

/** A fence longer than any run of backticks in the text, so none closes it. */
function fence(text: string): string {
  const longest = Math.max(0, ...[...text.matchAll(/`+/g)].map((m) => m[0].length));
  return "`".repeat(Math.max(3, longest + 1));
}

const MD_LANG: Record<Snippet["lang"], string> = {
  rust: "rust",
  go: "go",
  cpp: "cpp",
  python: "python",
  pytorch: "python",
  typescript: "typescript",
  zig: "zig",
  lua: "lua",
};

export function padsMarkdown(pads: readonly Snippet[], at: Date): string {
  const out = [`# Playground pads`, "", `${pads.length} pads, backed up ${at.toISOString()}.`, ""];
  for (const p of pads) {
    const f = fence(p.source);
    out.push(
      `## ${p.name}`,
      "",
      `- id: \`${p.id}\``,
      `- lang: ${p.lang}`,
      `- created: ${p.created_at}`,
      `- updated: ${p.updated_at}`,
      "",
      `${f}${MD_LANG[p.lang]}`,
      p.source.replace(/\n$/, ""),
      f,
      "",
    );
    if (p.stdin) {
      const g = fence(p.stdin);
      out.push("stdin:", "", `${g}text`, p.stdin.replace(/\n$/, ""), g, "");
    }
  }
  return out.join("\n");
}

/** A name a file system on any of the three desktops will take. */
function slug(name: string): string {
  const s = name
    .replace(/[\\/:*?"<>|\u0000-\u001f]/g, "_")
    .replace(/\s+/g, "-")
    .replace(/^[.-]+|[.-]+$/g, "");
  return s.slice(0, 60) || "pad";
}

export function backupFileName(at: Date): string {
  const two = (n: number) => String(n).padStart(2, "0");
  return `causewaybay-pads-${at.getFullYear()}${two(at.getMonth() + 1)}${two(at.getDate())}-${two(
    at.getHours(),
  )}${two(at.getMinutes())}.zip`;
}

/** The archive's entries, in the order an unzipper lists them. */
export function backupEntries(pads: readonly Snippet[], at: Date): ZipEntry[] {
  const entries: ZipEntry[] = [
    { name: "pads.jsonl", data: padsJsonl(pads) },
    { name: "pads.csv", data: padsCsv(pads) },
    { name: "pads.md", data: padsMarkdown(pads, at) },
  ];
  const width = String(pads.length).length;
  pads.forEach((p, i) => {
    // Numbered, because two pads may share a name and a directory may not.
    const dir = `pads/${String(i + 1).padStart(width, "0")}-${slug(p.name)}`;
    entries.push({ name: `${dir}/${MAIN_FILE[p.lang]}`, data: p.source });
    if (p.stdin) entries.push({ name: `${dir}/stdin.txt`, data: p.stdin });
  });
  return entries;
}

export function backupZip(pads: readonly Snippet[], at: Date): Uint8Array {
  return zip(backupEntries(pads, at), at);
}
