// Ported from CausewaybayRaiden/typescript/src/audio/chip.ts. The 16-bit register —
// the chip synth and the colour multiply — is that project's, unchanged except
// where noted.
/**
 * The 8-bit synth, ported from `love2d/src/audio.lua`.
 *
 * Square, triangle and noise, rendered into buffers at 22 050 Hz once and then
 * played back — the same approach LÖVE took, and the reason there is not a
 * single audio file to download. The note data and the envelopes are copied
 * across unchanged, so the tunes are the ones the desktop game plays.
 *
 * Nothing is built until the first gesture: browsers will not start an audio
 * context before one, and rendering four songs up front would stall the boot
 * screen for no reason.
 */
const SR = 22050;

// Cue ids, matching `crates/raiden-core/src/audio.rs`.
export const SFX = {
  shot: 1,
  shot2: 2,
  hit: 3,
  coin: 4,
  start: 5,
  power: 6,
  oneup: 7,
  bomb: 8,
  explode: 9,
  explodeBig: 10,
  death: 11,
  warn: 12,
  warn2: 13,
  blip: 14,
  graze: 15,
  select: 16,
} as const;

export const MUSIC = { title: 20, stage: 21, boss: 22, over: 23, stop: 24 } as const;

type Wave = "square" | "tri" | "noise";
type Channel = { wave: Wave; duty?: number; vol?: number; notes: string[] };

const clamp = (v: number) => (v > 1 ? 1 : v < -1 ? -1 : v);

function square(phase: number, duty: number): number {
  return phase - Math.floor(phase) < duty ? 1 : -1;
}

function tri(phase: number): number {
  const p = phase - Math.floor(phase);
  return p < 0.5 ? p * 4 - 1 : 3 - p * 4;
}

const noise = () => Math.random() * 2 - 1;

/** Attack/release envelope over a run of `n` samples. */
function envAR(i: number, n: number, atk: number, rel: number): number {
  const a = Math.max(1, Math.floor(SR * atk));
  const r = Math.max(1, Math.floor(SR * rel));
  if (i < a) return i / a;
  if (i > n - r) return Math.max(0, (n - i) / r);
  return 1;
}

/** Note name to frequency, C1 through B6. */
const NOTES = (() => {
  const names = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"];
  const out: Record<string, number> = {};
  for (let oct = 1; oct <= 6; oct += 1) {
    names.forEach((name, i) => {
      const midi = 12 * (oct + 1) + i;
      out[`${name}${oct}`] = 440 * 2 ** ((midi - 69) / 12);
    });
  }
  return out;
})();

const notes = (s: string): string[] => s.trim().split(/\s+/);
const freq = (tok: string): number => (tok === "." || tok === "-" ? 0 : (NOTES[tok] ?? 0));

type Render = (ctx: BaseAudioContext) => AudioBuffer;

function buffer(ctx: BaseAudioContext, n: number, fill: (out: Float32Array) => void): AudioBuffer {
  const buf = ctx.createBuffer(1, Math.max(1, n), SR);
  const out = buf.getChannelData(0);
  fill(out);
  return buf;
}

function pulseTone(f: number, dur: number, vol: number, duty: number, decay: number): Render {
  return (ctx) => {
    const n = Math.max(1, Math.floor(SR * dur));
    return buffer(ctx, n, (out) => {
      for (let i = 0; i < n; i += 1) {
        const t = i / SR;
        const e = Math.max(0, envAR(i, n, 0.004, 0.02) * (1 - (decay * t) / dur));
        out[i] = clamp(square(t * f, duty) * vol * e);
      }
    });
  };
}

function noiseBurst(dur: number, vol: number, decay: number): Render {
  return (ctx) => {
    const n = Math.max(1, Math.floor(SR * dur));
    return buffer(ctx, n, (out) => {
      let last = 0;
      for (let i = 0; i < n; i += 1) {
        // Held for a few samples at a time: the cheap NES-ish rasp.
        if (i % 3 === 0) last = noise();
        const e = (1 - i / SR / dur) ** decay;
        out[i] = clamp(last * vol * e);
      }
    });
  };
}

function sweep(f0: number, f1: number, dur: number, vol: number, duty: number): Render {
  return (ctx) => {
    const n = Math.max(1, Math.floor(SR * dur));
    return buffer(ctx, n, (out) => {
      let phase = 0;
      for (let i = 0; i < n; i += 1) {
        const u = i / n;
        phase += (f0 + (f1 - f0) * u) / SR;
        const e = envAR(i, n, 0.003, 0.03) * (1 - u * 0.4);
        out[i] = clamp(square(phase, duty) * vol * e);
      }
    });
  };
}

function arp(freqs: number[], step: number, vol: number): Render {
  return (ctx) => {
    const stepN = Math.floor(SR * step);
    const n = Math.max(1, stepN * freqs.length);
    return buffer(ctx, n, (out) => {
      for (let i = 0; i < n; i += 1) {
        const f = freqs[Math.min(freqs.length - 1, Math.floor(i / stepN))];
        const e = envAR(i % stepN, stepN, 0.002, 0.01);
        out[i] = clamp(square((i / SR) * f, 0.25) * vol * e);
      }
    });
  };
}

/** Mix a multi-channel pattern down to one buffer. */
function song(bpm: number, pattern: Channel[], vol: number): Render {
  return (ctx) => {
    const spb = 60 / bpm / 4; // one sixteenth
    const len = pattern[0].notes.length;
    const stepN = Math.floor(SR * spb);
    const n = Math.max(1, Math.floor(SR * spb * len));
    return buffer(ctx, n, (out) => {
      for (const ch of pattern) {
        let phase = 0;
        for (let i = 0; i < n; i += 1) {
          const ni = Math.floor(i / stepN);
          const f = freq(ch.notes[ni % ch.notes.length]);
          const e = envAR(i % stepN, stepN, 0.003, 0.012) * (ch.vol ?? 1);
          let s = 0;
          if (f > 0) {
            phase += f / SR;
            if (ch.wave === "tri") s = tri(phase);
            else if (ch.wave === "noise") s = i % 4 === 0 ? noise() * 0.7 : 0;
            else s = square(phase, ch.duty ?? 0.25);
          } else {
            // A rest resets the oscillator, so the next note starts clean.
            phase = 0;
          }
          out[i] += s * e * vol;
        }
      }
      for (let i = 0; i < n; i += 1) out[i] = clamp(out[i]);
    });
  };
}

const SFX_SPEC: Record<number, Render> = {
  [SFX.shot]: pulseTone(1244, 0.045, 0.18, 0.125, 0.4),
  [SFX.shot2]: pulseTone(1568, 0.04, 0.12, 0.25, 0.6),
  [SFX.hit]: pulseTone(220, 0.04, 0.22, 0.5, 1.2),
  [SFX.coin]: arp([988, 1318, 1568], 0.05, 0.22),
  [SFX.start]: arp([523, 659, 784, 1046, 784, 1046, 1318], 0.07, 0.2),
  [SFX.power]: arp([392, 523, 659, 784, 1046], 0.055, 0.22),
  [SFX.oneup]: arp([523, 659, 784, 1046, 1318, 1568, 2093], 0.07, 0.2),
  [SFX.bomb]: sweep(120, 40, 0.55, 0.28, 0.5),
  [SFX.explode]: noiseBurst(0.28, 0.32, 1.4),
  [SFX.explodeBig]: noiseBurst(0.55, 0.38, 1.1),
  [SFX.death]: sweep(440, 80, 0.7, 0.26, 0.25),
  [SFX.warn]: sweep(440, 880, 0.35, 0.2, 0.25),
  [SFX.warn2]: sweep(880, 440, 0.35, 0.2, 0.25),
  [SFX.blip]: pulseTone(880, 0.05, 0.16, 0.25, 0.2),
  [SFX.graze]: pulseTone(1760, 0.03, 0.08, 0.125, 0.8),
  [SFX.select]: pulseTone(660, 0.06, 0.16, 0.25, 0.3),
};

// Title: bright Konami-ish C major.
const TITLE = song(
  150,
  [
    {
      wave: "square",
      duty: 0.25,
      vol: 0.55,
      notes: notes(`
        C5 . E5 . G5 . C6 G5 E5 C5 A4 . C5 . E5 . A5 E5
        F5 . A5 . C6 . A5 F5 . G5 . B5 . D6 C6 G5 .
        C5 . E5 . G5 . C6 G5 E5 C5 A4 . C5 . E5 . A5 E5
        F5 A5 C6 . G5 B5 D6 . C6 . . . G5 . . . C5 .`),
    },
    {
      wave: "square",
      duty: 0.5,
      vol: 0.28,
      notes: notes(`
        E4 . . . G4 . . . E4 . . . C4 . . . F4 . . . A4 . . . D4 . . . G4 . . .
        E4 . . . G4 . . . E4 . . . C4 . . . F4 . . . G4 . . . E4 . . . . . . .`),
    },
    {
      wave: "tri",
      vol: 0.45,
      notes: notes(`
        C3 C3 C3 C3 G2 G2 G2 G2 A2 A2 A2 A2 E2 E2 E2 E2
        F2 F2 F2 F2 C3 C3 C3 C3 G2 G2 G2 G2 C3 C3 G2 G2
        C3 C3 C3 C3 G2 G2 G2 G2 A2 A2 A2 A2 E2 E2 E2 E2
        F2 F2 F2 F2 G2 G2 G2 G2 C3 . . . G2 . . . C3 .`),
    },
    {
      wave: "noise",
      vol: 0.18,
      notes: notes(`
        C3 . C3 . C3 . C3 C3 C3 . C3 . C3 . C3 C3
        C3 . C3 . C3 . C3 C3 C3 . C3 . C3 C3 C3 .
        C3 . C3 . C3 . C3 C3 C3 . C3 . C3 . C3 C3
        C3 . C3 . C3 . C3 C3 C3 . . . C3 . . .`),
    },
  ],
  0.22,
);

// Stage: an A-minor driving raid theme.
const STAGE = song(
  138,
  [
    {
      wave: "square",
      duty: 0.125,
      vol: 0.5,
      notes: notes(`
        A4 . C5 E5 . D5 C5 B4 A4 . E4 . A4 . C5 B4
        G4 . B4 D5 . C5 B4 A4 G4 . D4 . G4 . B4 A4
        F4 . A4 C5 . B4 A4 G4 F4 . C4 . F4 . A4 G4
        E4 . G4 B4 . A4 G4 F4 E4 . B3 . E4 . G4 E4`),
    },
    {
      wave: "square",
      duty: 0.5,
      vol: 0.22,
      notes: notes(`
        E4 . . A4 . . E4 . D4 . . G4 . . D4 .
        C4 . . F4 . . C4 . B3 . . E4 . . B3 .`),
    },
    {
      wave: "tri",
      vol: 0.5,
      notes: notes(`
        A2 A2 E3 E3 A2 A2 E3 E3 G2 G2 D3 D3 G2 G2 D3 D3
        F2 F2 C3 C3 F2 F2 C3 C3 E2 E2 B2 B2 E2 E2 G2 G2`),
    },
    {
      wave: "noise",
      vol: 0.16,
      notes: notes(`
        C3 . C3 C3 C3 . C3 . C3 . C3 C3 C3 . C3 C3
        C3 . C3 C3 C3 . C3 . C3 . C3 C3 C3 C3 C3 .`),
    },
  ],
  0.2,
);

// Boss: faster, harsher.
const BOSS = song(
  168,
  [
    {
      wave: "square",
      duty: 0.25,
      vol: 0.55,
      notes: notes(`
        E4 F4 F#4 G4 . . G4 . D#4 E4 F4 F#4 . . F#4 .
        G4 G#4 A4 A#4 . A4 G4 . E4 . G4 . B4 . E5 .
        E4 F4 F#4 G4 . . G4 . D#4 E4 F4 F#4 . . F#4 .
        C5 . B4 . A#4 . A4 . G4 . E4 . D4 . E4 .`),
    },
    {
      wave: "tri",
      vol: 0.48,
      notes: notes(`
        E2 E2 E3 E3 E2 E2 B2 B2 D#2 D#2 D#3 D#3 D#2 D#2 A#2 A#2
        G2 G2 G3 G3 G2 G2 D3 D3 E2 E2 B2 B2 E2 E2 E3 E3`),
    },
    {
      wave: "noise",
      vol: 0.22,
      notes: notes(`
        C3 C3 C3 . C3 C3 C3 . C3 C3 C3 . C3 C3 C3 C3
        C3 C3 C3 . C3 C3 C3 . C3 . C3 . C3 C3 C3 .`),
    },
  ],
  0.22,
);

const OVER = song(
  90,
  [
    {
      wave: "square",
      duty: 0.5,
      vol: 0.45,
      notes: notes(`
        E5 . D5 . C5 . B4 . A4 . G4 . E4 . . . C4 . . .
        D4 . E4 . G4 . E4 . D4 . . . C4 . . . . . . .`),
    },
    {
      wave: "tri",
      vol: 0.4,
      notes: notes(`
        A2 . . . E2 . . . F2 . . . C2 . . . G2 . . . D2 . . . A2 . . . . . . .`),
    },
  ],
  0.18,
);

const MUSIC_SPEC: Record<number, { render: Render; loop: boolean }> = {
  [MUSIC.title]: { render: TITLE, loop: true },
  [MUSIC.stage]: { render: STAGE, loop: true },
  [MUSIC.boss]: { render: BOSS, loop: true },
  [MUSIC.over]: { render: OVER, loop: false },
};

export type Chip = {
  /** Start (or resume) the audio context. Safe to call on every gesture. */
  ensure: () => void;
  /** Play a frame's worth of cues, sfx and music ids mixed together. */
  play: (cues: Uint8Array) => void;
  toggleMute: () => boolean;
  readonly muted: boolean;
};

export function createChip(): Chip {
  type Ctor = typeof AudioContext;
  const Ctx: Ctor | undefined =
    typeof AudioContext !== "undefined"
      ? AudioContext
      : (globalThis as { webkitAudioContext?: Ctor }).webkitAudioContext;

  let ctx: AudioContext | null = null;
  let master: GainNode | null = null;
  let sfxBuffers: Map<number, AudioBuffer> | null = null;
  let musicBuffers: Map<number, AudioBuffer> | null = null;
  let current = 0;
  let playing: AudioBufferSourceNode | null = null;
  let muted = false;

  function ensure(): void {
    if (!Ctx) return;
    if (!ctx) {
      ctx = new Ctx();
      master = ctx.createGain();
      master.gain.value = muted ? 0 : 1;
      master.connect(ctx.destination);
    }
    if (ctx.state === "suspended") void ctx.resume();
  }

  /** Render the sound bank. Done once, on demand, off the boot path. */
  function bank(): void {
    if (!ctx || sfxBuffers) return;
    sfxBuffers = new Map();
    for (const [id, render] of Object.entries(SFX_SPEC)) {
      sfxBuffers.set(Number(id), render(ctx));
    }
    musicBuffers = new Map();
    for (const [id, spec] of Object.entries(MUSIC_SPEC)) {
      musicBuffers.set(Number(id), spec.render(ctx));
    }
  }

  function fire(buf: AudioBuffer, vol: number): void {
    if (!ctx || !master) return;
    const src = ctx.createBufferSource();
    src.buffer = buf;
    const gain = ctx.createGain();
    gain.gain.value = vol;
    src.connect(gain).connect(master);
    src.start();
  }

  function setMusic(id: number): void {
    if (!ctx || !master || id === current) return;
    playing?.stop();
    playing?.disconnect();
    playing = null;
    current = id;
    if (id === MUSIC.stop) return;
    const buf = musicBuffers?.get(id);
    if (!buf) return;
    const src = ctx.createBufferSource();
    src.buffer = buf;
    src.loop = MUSIC_SPEC[id]?.loop ?? true;
    const gain = ctx.createGain();
    gain.gain.value = 0.55;
    src.connect(gain).connect(master);
    src.start();
    playing = src;
  }

  function play(cues: Uint8Array): void {
    if (!ctx || cues.length === 0) return;
    bank();
    for (const id of cues) {
      if (id >= MUSIC.title) setMusic(id);
      else {
        const buf = sfxBuffers?.get(id);
        if (buf) fire(buf, 0.9);
      }
    }
  }

  return {
    ensure,
    play,
    toggleMute: () => {
      muted = !muted;
      if (master) master.gain.value = muted ? 0 : 1;
      return muted;
    },
    get muted() {
      return muted;
    },
  };
}
