/**
 * Typing like a person.
 *
 * The model answers in a burst and the editor could take the whole file in
 * one dispatch, and that is exactly what this must not do: the agent is a
 * character who *writes*, and the whole reason it is a sprite rather than a
 * PASTE button is that you can watch the program appear and read it as it
 * goes. So the text is fed in one character at a time on a schedule that
 * looks typed — a floor so it never blurs, jitter so it never ticks, a
 * breath at every newline, a longer one after a `}` or a `;`, and a rush
 * through the middle of a long identifier the way fingers do once the word
 * is decided.
 *
 * `schedule` is pure and tested. `Typist` is the driver: it owns the clock,
 * takes a sink to type into, and can be stopped between two characters.
 */

/** Milliseconds per character, before jitter. */
export const BASE_MS = 46;
/** The floor: never faster than this, or the screen shows a paste. */
export const FLOOR_MS = 18;
/** The breath at a newline — read the line you just wrote. */
export const NEWLINE_MS = 190;
/** After a closing brace or a semicolon: the thought ends. */
export const STOP_MS = 110;
/** Whole-file typing is capped so a 300-line answer is not a five-minute wait. */
export const MAX_TOTAL_MS = 45_000;

/** Deterministic jitter from the character's index, so tests can pin it. */
function jitter(i: number): number {
  // A cheap LCG-ish hash in [0, 1).
  let x = (i + 1) * 2654435761;
  x = (x ^ (x >>> 13)) * 1274126177;
  return ((x ^ (x >>> 16)) >>> 0) / 4294967296;
}

/**
 * The delay *before* each character of `text`, in milliseconds.
 *
 * The sum is bounded by `MAX_TOTAL_MS`: when the text is long the whole
 * schedule is scaled down, floored per character, so a long file is typed
 * faster rather than not being watched at all.
 */
export function schedule(text: string): number[] {
  const out: number[] = [];
  let run = 0;
  for (let i = 0; i < text.length; i++) {
    const ch = text[i];
    const prev = i > 0 ? text[i - 1] : "";
    let ms = BASE_MS * (0.7 + jitter(i) * 0.6);
    // Inside a word the fingers speed up; the third letter on is fast.
    if (/[A-Za-z0-9_]/.test(ch) && /[A-Za-z0-9_]/.test(prev)) {
      run++;
      if (run >= 2) ms *= 0.65;
    } else run = 0;
    if (prev === "\n") ms += NEWLINE_MS;
    else if (prev === "}" || prev === ";") ms += STOP_MS;
    // Leading indentation is one motion, not four keystrokes.
    if (ch === " " && (prev === " " || prev === "\n")) ms = FLOOR_MS;
    out.push(Math.max(FLOOR_MS, Math.round(ms)));
  }
  const total = out.reduce((a, b) => a + b, 0);
  if (total > MAX_TOTAL_MS) {
    const k = MAX_TOTAL_MS / total;
    for (let i = 0; i < out.length; i++) out[i] = Math.max(FLOOR_MS, Math.round(out[i] * k));
  }
  return out;
}

export interface Sink {
  /** Put `ch` in at the caret. */
  type(ch: string): void;
}

/**
 * Feed `text` into `sink` on the schedule. Resolves `true` when everything
 * went in, `false` when stopped. One at a time: a second `run` stops the
 * first.
 */
export class Typist {
  private timer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;
  /** How many characters of the current text have gone in. */
  typed = 0;
  total = 0;
  get busy(): boolean {
    return this.timer !== null;
  }

  run(text: string, sink: Sink, onEach?: () => void): Promise<boolean> {
    this.stop();
    this.stopped = false;
    this.typed = 0;
    this.total = text.length;
    const delays = schedule(text);
    return new Promise((resolve) => {
      const step = (i: number) => {
        if (this.stopped) return resolve(false);
        if (i >= text.length) {
          this.timer = null;
          return resolve(true);
        }
        this.timer = setTimeout(() => {
          if (this.stopped) return resolve(false);
          sink.type(text[i]);
          this.typed = i + 1;
          onEach?.();
          step(i + 1);
        }, delays[i]);
      };
      step(0);
    });
  }

  stop(): void {
    this.stopped = true;
    if (this.timer !== null) clearTimeout(this.timer);
    this.timer = null;
  }
}
