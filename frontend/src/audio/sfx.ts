/**
 * The chip synth, with names this game uses.
 *
 * `chip.ts` is Raiden's, unchanged, and speaks in numeric cue ids because its
 * core was a wasm module handing back a byte array each frame. There is no wasm
 * core here (see `docs/decisions.md`), so this is the thin adapter that turns
 * "the player cleared a street" into the right id, and the one place that would
 * change if the bank ever gains a sound of its own.
 */
import { createChip, MUSIC, SFX } from "./chip";

export class Chip {
  private readonly chip = createChip();

  /** Safe on every gesture; browsers refuse an AudioContext before one. */
  unlock(): void {
    this.chip.ensure();
  }

  private cue(...ids: number[]): void {
    this.chip.play(Uint8Array.from(ids));
  }

  select(): void {
    this.cue(SFX.select);
  }
  blip(): void {
    this.cue(SFX.blip);
  }
  coin(): void {
    this.cue(SFX.coin);
  }
  start(): void {
    this.cue(SFX.start);
  }
  fail(): void {
    this.cue(SFX.warn);
  }
  clear(): void {
    this.cue(SFX.oneup, SFX.power);
  }
  /**
   * The name landing. Two low hits and a warning tone, which is the bank's
   * nearest thing to a sting — this bank was written for a shoot-'em-up and
   * has no "dread" cue, so the dread is made out of a bomb and a siren.
   */
  stinger(): void {
    this.cue(SFX.bomb, SFX.warn2);
  }
  /** A single typed character. Quiet, and only every few letters. */
  type(): void {
    this.cue(SFX.graze);
  }
  music(which: "title" | "stage" | "boss" | "stop"): void {
    this.cue(which === "stop" ? MUSIC.stop : MUSIC[which]);
  }
  toggleMute(): boolean {
    return this.chip.toggleMute();
  }
  get muted(): boolean {
    return this.chip.muted;
  }
}
