/**
 * The typed client for SPEC §6.
 *
 * Three rules from §6.4 are enforced here rather than left to the scenes,
 * because a scene that forgets one produces a bug that looks like a server
 * fault:
 *
 *   - a connection is anonymous until `auth.login`/`auth.resume`, and only
 *     `ping` and `auth.challenge` are legal before that;
 *   - one in-flight `quest.submit` per connection;
 *   - a reconnect resumes with the stored token, and nothing else is restored,
 *     because nothing in the game lives in the browser.
 *
 * The client owns no game state. It owns a socket, a map of pending requests
 * and a session token — that is the complete list, and it is the reason a
 * reload loses nothing.
 */
import { asError, decode, encode, makeIdSource, replyKind } from "./codec";
import type {
  ErrorPayload,
  Envelope,
  Events,
  EventType,
  Requests,
  Responses,
  RequestType,
  User,
} from "./protocol";
import { PROTOCOL_VERSION } from "./protocol";
import type { Transport, TransportFactory } from "./transport";

/** Thrown by `request` when the server answers `<type>.err`. */
export class WireError extends Error {
  constructor(readonly payload: ErrorPayload) {
    super(`${payload.code}: ${payload.message}`);
    this.name = "WireError";
  }
}

export type ConnState = "offline" | "connecting" | "open" | "authed";

type Pending = {
  type: string;
  resolve: (v: unknown) => void;
  reject: (e: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
};

type EventHandler<K extends EventType> = (payload: Events[K]) => void;

/** How long a request may sit unanswered before it is failed locally. */
const REQUEST_TIMEOUT_MS = 60_000;
/** A `quest.submit` waits on a compiler; the first cargo build is genuinely slow. */
const SUBMIT_TIMEOUT_MS = 180_000;

export interface ClientOptions {
  transport: TransportFactory;
  /** Where the session token is kept between reloads. Only the token. */
  storage?: Pick<Storage, "getItem" | "setItem" | "removeItem">;
  storageKey?: string;
}

export class Client {
  private transport: Transport | null = null;
  private readonly pending = new Map<string, Pending>();
  private readonly nextId = makeIdSource("c");
  private readonly listeners = new Map<string, Set<(p: unknown) => void>>();
  private readonly stateWatchers = new Set<(s: ConnState) => void>();
  private submitInFlight = false;
  private closing = false;
  private retry = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;

  state: ConnState = "offline";
  user: User | null = null;

  private readonly storage: ClientOptions["storage"];
  private readonly storageKey: string;

  constructor(private readonly opts: ClientOptions) {
    this.storage = opts.storage;
    this.storageKey = opts.storageKey ?? "cwbhacker.token";
  }

  // -- session -------------------------------------------------------------

  /**
   * The *only* thing persisted. The mnemonic and the private key are never
   * written anywhere (SPEC §3.1); the token is what makes that survivable,
   * because `auth.resume` trades it for a live connection without the key
   * being touched again.
   */
  get token(): string | null {
    try {
      return this.storage?.getItem(this.storageKey) ?? null;
    } catch {
      return null; // private browsing, or storage disabled
    }
  }

  private set token(value: string | null) {
    try {
      if (value === null) this.storage?.removeItem(this.storageKey);
      else this.storage?.setItem(this.storageKey, value);
    } catch {
      /* a session that cannot be remembered still works for this tab */
    }
  }

  forgetToken(): void {
    this.token = null;
    this.user = null;
  }

  // -- connection ----------------------------------------------------------

  connect(): void {
    if (this.transport) return;
    this.closing = false;
    this.setState("connecting");
    this.transport = this.opts.transport({
      onOpen: () => {
        this.retry = 0;
        this.setState("open");
      },
      onMessage: (text) => this.receive(text),
      onClose: (reason) => this.dropped(reason),
    });
  }

  close(): void {
    this.closing = true;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.transport?.close();
    this.transport = null;
    this.setState("offline");
  }

  private dropped(reason: string): void {
    this.transport = null;
    this.submitInFlight = false;
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(new WireError({ code: "internal", message: `connection lost: ${reason}`, detail: {} }));
    }
    this.pending.clear();
    this.setState("offline");
    if (this.closing) return;
    // Exponential backoff with a one-second floor and an eight-second ceiling:
    // a local server being restarted by `cargo watch` is back inside that, and
    // a server that is genuinely gone is not helped by a tighter loop.
    const wait = Math.min(8000, 1000 * 2 ** this.retry++);
    this.retryTimer = setTimeout(() => this.reconnect(), wait);
  }

  /** Reconnect and, if there is a token, resume onto it before anything else. */
  private async reconnect(): Promise<void> {
    this.connect();
    const token = this.token;
    if (!token) return;
    try {
      await this.waitFor("open");
      await this.resume(token);
    } catch {
      /* a dead token simply leaves the client anonymous; the login screen asks */
    }
  }

  private setState(s: ConnState): void {
    if (this.state === s) return;
    this.state = s;
    for (const w of this.stateWatchers) w(s);
  }

  onState(fn: (s: ConnState) => void): () => void {
    this.stateWatchers.add(fn);
    return () => this.stateWatchers.delete(fn);
  }

  /** Resolve once the connection reaches a state at least as far along as `s`. */
  waitFor(s: ConnState): Promise<void> {
    const rank: Record<ConnState, number> = { offline: 0, connecting: 1, open: 2, authed: 3 };
    if (rank[this.state] >= rank[s]) return Promise.resolve();
    return new Promise((resolve, reject) => {
      const off = this.onState((next) => {
        if (rank[next] >= rank[s]) {
          off();
          resolve();
        } else if (next === "offline") {
          off();
          reject(new Error("connection closed while waiting"));
        }
      });
    });
  }

  // -- requests ------------------------------------------------------------

  /** Types that are legal on an anonymous connection (SPEC §6.4). */
  private static readonly PREAUTH = new Set(["ping", "auth.challenge", "auth.login", "auth.resume"]);

  request<K extends RequestType>(type: K, payload: Requests[K]): Promise<Responses[K]> {
    if (!this.transport) {
      return Promise.reject(
        new WireError({ code: "internal", message: "not connected", detail: {} }),
      );
    }
    if (this.state !== "authed" && !Client.PREAUTH.has(type)) {
      // Rejected locally rather than queued: a scene that asks for a map
      // before login has a sequencing bug, and hiding it behind a queue makes
      // it surface later as a mysterious stall.
      return Promise.reject(
        new WireError({ code: "unauthorized", message: `${type} needs a session`, detail: {} }),
      );
    }
    if (type === "quest.submit") {
      if (this.submitInFlight) {
        return Promise.reject(
          new WireError({ code: "busy", message: "an attempt is already running", detail: {} }),
        );
      }
      this.submitInFlight = true;
    }

    const id = this.nextId();
    const ms = type === "quest.submit" ? SUBMIT_TIMEOUT_MS : REQUEST_TIMEOUT_MS;
    return new Promise<Responses[K]>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        if (type === "quest.submit") this.submitInFlight = false;
        reject(new WireError({ code: "internal", message: `${type} timed out`, detail: {} }));
      }, ms);
      this.pending.set(id, {
        type,
        resolve: resolve as (v: unknown) => void,
        reject,
        timer,
      });
      this.transport!.send(encode(id, type, payload));
    });
  }

  // -- the named calls a scene actually makes ------------------------------

  async challenge(addressEip55: string): Promise<Responses["auth.challenge"]> {
    return this.request("auth.challenge", { address: addressEip55 });
  }

  /**
   * `signature` is produced by `src/wallet`, which never hands over the key
   * that made it. The address travels so the server can look up the nonce; the
   * server re-derives it from the signature anyway and does not trust ours.
   */
  async login(addressEip55: string, signature: string): Promise<User> {
    const res = await this.request("auth.login", { address: addressEip55, signature });
    this.token = res.token;
    this.user = res.user;
    this.setState("authed");
    return res.user;
  }

  async resume(token: string): Promise<User> {
    const res = await this.request("auth.resume", { token });
    this.token = res.token;
    this.user = res.user;
    this.setState("authed");
    return res.user;
  }

  // -- events --------------------------------------------------------------

  on<K extends EventType>(type: K, fn: EventHandler<K>): () => void {
    let set = this.listeners.get(type);
    if (!set) this.listeners.set(type, (set = new Set()));
    set.add(fn as (p: unknown) => void);
    return () => set!.delete(fn as (p: unknown) => void);
  }

  private emit(type: string, payload: unknown): void {
    const set = this.listeners.get(type);
    if (!set) return;
    for (const fn of [...set]) {
      try {
        fn(payload);
      } catch (e) {
        console.error(`listener for ${type} threw`, e);
      }
    }
  }

  // -- inbound -------------------------------------------------------------

  private receive(text: string): void {
    const d = decode(text);
    if (d.kind === "bad") {
      console.warn("dropping a frame:", d.reason);
      return;
    }
    const frame: Envelope = d.frame;
    if (frame.v !== PROTOCOL_VERSION) {
      // §6.1: the connection stays open. The player is told once, by the
      // banner, rather than the client silently misreading every frame.
      this.emit("server.bye", { reason: `server speaks protocol v${frame.v}` });
      return;
    }
    if (frame.id === null) {
      this.emit(frame.type, frame.payload);
      return;
    }
    const pending = this.pending.get(frame.id);
    if (!pending) return; // a reply to something that already timed out
    this.pending.delete(frame.id);
    clearTimeout(pending.timer);
    if (pending.type === "quest.submit") this.submitInFlight = false;

    const kind = replyKind(frame.type);
    if (!kind || kind.base !== pending.type) {
      pending.reject(
        new WireError({
          code: "internal",
          message: `reply ${frame.type} does not answer ${pending.type}`,
          detail: {},
        }),
      );
      return;
    }
    if (kind.ok) pending.resolve(frame.payload);
    else pending.reject(new WireError(asError(frame.payload)));
  }
}
