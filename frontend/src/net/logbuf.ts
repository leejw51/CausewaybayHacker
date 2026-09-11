/**
 * `run.log` chunks, reassembled into lines.
 *
 * PROTOCOL §4.18 is explicit that a chunk may split anywhere, **including
 * mid-line**, and that `seq` counts from 0 per stream per attempt. A console
 * that printed each chunk as if it were a line would show
 * `error[E0382]: borrow of` and `moved value` as two entries, on a bad day
 * across a page boundary — and a client that never checked `seq` would never
 * know it had lost one.
 *
 * So this holds a tail per stream and only emits a line when a `\n` arrives,
 * and it notices a gap rather than pretending the output is complete.
 * Conformance §8.8.
 */
import type { LogStream } from "./protocol";

export interface LogLine {
  stream: LogStream;
  text: string;
}

export class LogBuffer {
  private readonly tail = new Map<LogStream, string>();
  private readonly next = new Map<LogStream, number>();
  /** Streams where a `seq` arrived out of order or skipped one. */
  readonly gaps = new Set<LogStream>();
  readonly lines: LogLine[] = [];

  constructor(
    readonly attemptId: string,
    /** How many lines to keep. The full text is on the server (SPEC §1). */
    private readonly limit = 500,
  ) {}

  /** Returns false when the chunk revealed a gap, so a caller can say so. */
  push(stream: LogStream, chunk: string, seq: number): boolean {
    const expected = this.next.get(stream) ?? 0;
    let ok = true;
    if (seq !== expected) {
      // A gap is reported once per stream and then the buffer carries on from
      // where the server actually is; refusing the chunk would lose more.
      this.gaps.add(stream);
      ok = false;
    }
    this.next.set(stream, seq + 1);

    const text = (this.tail.get(stream) ?? "") + chunk;
    const parts = text.split("\n");
    // The last piece has no newline after it yet, so it stays in the tail.
    this.tail.set(stream, parts.pop() ?? "");
    for (const line of parts) this.lines.push({ stream, text: line });
    this.trim();
    return ok;
  }

  /**
   * Flush whatever is still un-newlined. Called when the attempt finishes:
   * a compiler's last line often has no trailing newline, and dropping it
   * would hide the one message the player needed.
   */
  end(): void {
    for (const [stream, rest] of this.tail) {
      if (rest !== "") this.lines.push({ stream, text: rest });
      this.tail.set(stream, "");
    }
    this.trim();
  }

  private trim(): void {
    if (this.lines.length > this.limit) this.lines.splice(0, this.lines.length - this.limit);
  }

  get complete(): boolean {
    return this.gaps.size === 0;
  }
}
