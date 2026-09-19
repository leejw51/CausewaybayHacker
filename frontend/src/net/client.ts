/**
 * The typed client for `PROTOCOL.md`.
 *
 * The rules it enforces so that no scene has to remember them — each numbered
 * against the §8 conformance checklist:
 *
 *   §8.2  replies are matched by `id` and may arrive out of order. A `ping`
 *         sent after a `quest.submit` comes back first, so there is a map of
 *         pending requests and never a queue.
 *   §8.3  an unknown `type` is ignored, not an error. That is what lets the
 *         server add events to a client that is already shipped.
 *   §8.4  every §3.3 code is handled; an unknown one is folded to `internal`.
 *   §8.5  no key material is ever sent — there is no field for it, and
 *         `src/wallet` will not hand one over.
 *   §8.7  `auth.resume` rotates the token; the one that comes *back* is stored.
 *   §8.9  reconnect with 0.5/1/2/4/8 s backoff and ±20% jitter, then resume.
 *   §8.10 one in-flight `quest.submit` per connection.
 *   §8.11 a `server.bye` before a close, and a close without one, both work.
 *   §8.12 an application-level `ping` every 20 s.
 *
 * The client owns no game state. It owns a socket, a map of pending requests
 * and a session token — that is the complete list, and it is why a reload
 * loses nothing.
 */
import { asError, decode, encode, makeIdSource, replyKind } from "./codec";
import type {
  ErrorPayload,
  Envelope,
  Events,
  EventType,
  Requests,
  Responses,
  Position,
  RequestType,
  User,
} from "./protocol";
import { PROTOCOL_VERSION, actionFor } from "./protocol";
import type { Transport, TransportFactory } from "./transport";

/** Thrown by `request` when the server answers `<type>.err`. */
export class WireError extends Error {
  constructor(readonly payload: ErrorPayload) {
    super(`${payload.code}: ${payload.message}`);
    this.name = "WireError";
  }

  /** What §3.3's table says a client should do about it. */
  get action() {
    return actionFor(this.payload.code);
  }
}

export type ConnState = "offline" | "connecting" | "open" | "authed";

type Pending = {
  type: string;
  resolve: (v: unknown) => void;
  reject: (e: unknown) => void;
  timer: ReturnType<typeof setTimeout>;
};

/** How long a request may sit unanswered before it is failed locally. */
const REQUEST_TIMEOUT_MS = 60_000;
/** A `quest.submit` waits on a compiler; the first cargo build is genuinely slow. */
const SUBMIT_TIMEOUT_MS = 180_000;
/** §1.1 / §8.12: the application-level keepalive. */
const PING_EVERY_MS = 20_000;
/** §6.2, in seconds: 0.5, 1, 2, 4, 8, then 8 for ever, each ±20%. */
const BACKOFF_MS = [500, 1000, 2000, 4000, 8000];

export interface ClientOptions {
  transport: TransportFactory;
  /** Where the session token is kept between reloads. Only the token. */
  storage?: Pick<Storage, "getItem" | "setItem" | "removeItem">;
  storageKey?: string;
  /** Off in tests, where a stray timer outlives the case. */
  keepalive?: boolean;
}

export class Client {
  private transport: Transport | null = null;
  private readonly pending = new Map<string, Pending>();
  private readonly nextId = makeIdSource("c");
  private readonly listeners = new Map<string, Set<(p: unknown) => void>>();
  private readonly needLoginWatchers = new Set<(why: "unauthorized" | "revoked") => void>();
  private readonly stateWatchers = new Set<(s: ConnState) => void>();
  private submitInFlight = false;
  private closing = false;
  private retry = 0;
  private retryTimer: ReturnType<typeof setTimeout> | null = null;
  /** Bumped on every connect and close, so a stale socket cannot speak. */
  private generation = 0;
  /** Said once per socket: a version mismatch is on every frame, and one toast is the message. */
  private versionWarned = false;
  private pingTimer: ReturnType<typeof setInterval> | null = null;

  state: ConnState = "offline";
  user: User | null = null;
  /**
   * §5.13. Where the server last saw this player, as of the login or resume
   * that authed this connection. The client stores nothing durable of its own
   * — the session and this are both handed over by the server, and the server
   * is what two clients share.
   */
  position: Position | null = null;
  /**
   * Set when the server said `revoked`, or answered `unauthorized` to a
   * resume. The boot and map scenes read it to decide between "reconnecting"
   * and "ask for the key again".
   */
  needsLogin = false;
  /**
   * How the current session was authenticated: `login` is the player (or the
   * kept key) signing in on this connection, `resume` is a token the store
   * already had. `App` uses it to tell a background resume — which nobody is
   * waiting on, and which may land while the login screen is up — from a login
   * the scene that asked for it is about to act on itself.
   */
  lastAuth: "login" | "resume" | null = null;
  /**
   * True once this tab has held a session. A reconnect that finds no token in
   * the store then means the session was taken away under a live tab (another
   * tab logged out, or a resume elsewhere failed and forgot it), which is a
   * `needLogin` and not a quiet return to anonymous. A tab that never had one
   * is on the login screen already and is left alone.
   */
  private hadSession = false;

  private readonly storage: ClientOptions["storage"];
  private readonly storageKey: string;

  constructor(private readonly opts: ClientOptions) {
    this.storage = opts.storage;
    this.storageKey = opts.storageKey ?? "cwbhacker.token";
  }

  // -- session -------------------------------------------------------------

  /**
   * Read from the store on every use rather than cached: the store is shared
   * by every tab and `auth.resume` rotates the token, so the freshest copy is
   * the only one the server still knows. The key is kept beside it by
   * `wallet.ts`, not by this class, which never sees it (SPEC §3.1).
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

  /**
   * Drop this session and come back with a fresh, anonymous connection.
   *
   * §3.1: `auth.login` on a connection that is already authenticated is a
   * `bad_request` — "open a new one to change user" — and the server is right.
   * A player who reaches the login screen with a live session (a second wallet
   * made in the same tab, a logout that left the socket up) would otherwise be
   * refused by the server for a reason that is entirely the client's to fix.
   */
  async restart(): Promise<void> {
    this.forgetToken();
    this.close();
    this.retry = 0;
    this.connect();
    await this.waitFor("open");
  }

  forgetToken(): void {
    this.token = null;
    this.user = null;
    this.hadSession = false;
  }

  // -- connection ----------------------------------------------------------

  connect(): void {
    if (this.transport) return;
    this.closing = false;
    // A websocket reports its close on a later task. A logout closes one
    // socket and opens the next in the same turn, so without this generation
    // stamp the *old* socket's close would arrive after the new one is up and
    // knock it back to offline — and schedule a reconnect for a connection
    // that was never lost. Callbacks from a superseded transport are ignored.
    const gen = ++this.generation;
    this.setState("connecting");
    this.transport = this.opts.transport({
      onOpen: () => {
        if (gen !== this.generation) return;
        this.versionWarned = false;
        this.setState("open");
        this.startKeepalive();
      },
      onMessage: (text) => {
        if (gen !== this.generation) return;
        this.receive(text);
      },
      onClose: (reason) => {
        if (gen !== this.generation) return;
        this.dropped(reason);
      },
    });
  }

  close(): void {
    this.closing = true;
    // The socket being dropped here is no longer ours, so its own close
    // callback is ignored (see `connect`) — which means this is the only
    // place left that can fail the requests that were riding on it.
    this.generation++;
    if (this.retryTimer) clearTimeout(this.retryTimer);
    this.retryTimer = null;
    this.stopKeepalive();
    this.failPending("closed");
    this.transport?.close();
    this.transport = null;
    this.setState("offline");
  }

  private startKeepalive(): void {
    if (this.opts.keepalive === false || this.pingTimer) return;
    // §1.1: a browser answers websocket pings itself, but a laptop that slept
    // leaves a socket that looks open and is not. The application ping is what
    // finds that out in 20 seconds instead of at the player's next click.
    this.pingTimer = setInterval(() => {
      if (this.state === "offline") return;
      this.request("ping", {}).catch(() => {
        /* the drop handler deals with it */
      });
    }, PING_EVERY_MS);
  }

  private stopKeepalive(): void {
    if (this.pingTimer) clearInterval(this.pingTimer);
    this.pingTimer = null;
  }

  /**
   * §6.6: a `quest.submit` that was in flight is *still running* server-side
   * and its result is durable. The promise fails so the UI stops waiting; the
   * quest screen tells the player to look at the history rather than
   * resubmitting.
   */
  private failPending(reason: string): void {
    this.submitInFlight = false;
    for (const [, p] of this.pending) {
      clearTimeout(p.timer);
      p.reject(
        new WireError({
          code: "internal",
          message: `connection lost: ${reason}`,
          detail: { disconnected: true },
        }),
      );
    }
    this.pending.clear();
  }

  private dropped(reason: string): void {
    this.transport = null;
    this.stopKeepalive();
    this.failPending(reason);
    this.setState("offline");
    if (this.closing) return;
    this.retryTimer = setTimeout(() => {
      this.retryTimer = null;
      void this.reconnect();
    }, this.backoff());
  }

  /** §6.2: 0.5, 1, 2, 4, 8, then 8 s, each with ±20% jitter. */
  private backoff(): number {
    const base = BACKOFF_MS[Math.min(this.retry++, BACKOFF_MS.length - 1)];
    return Math.round(base * (0.8 + Math.random() * 0.4));
  }

  /** Reconnect and, if there is a token, resume onto it before anything else. */
  private async reconnect(): Promise<void> {
    this.connect();
    const token = this.token;
    if (!token) {
      // The store had a token when this tab was authed and has none now: the
      // header still shows an address, every request would be refused with
      // "needs a session", and nothing else would ever say so. Treat it as the
      // session being gone (§6.4) so the kept key can sign in again.
      if (this.hadSession) {
        this.hadSession = false;
        this.needLogin("unauthorized");
      }
      return;
    }
    try {
      await this.waitFor("open");
      await this.resume(token);
    } catch (e) {
      // §6.4: an `unauthorized` resume means the session is gone for good and
      // the player has to produce the key again.
      if (e instanceof WireError && e.payload.code === "unauthorized") {
        this.forgetToken();
        this.needLogin("unauthorized");
        return;
      }
      // Anything else is transient — but the socket is open and anonymous,
      // so nothing would retry on its own. Schedule the next attempt here
      // rather than leaving the client quietly stuck.
      if (!this.closing && !this.retryTimer) {
        this.retryTimer = setTimeout(() => {
          this.retryTimer = null;
          this.close();
          this.closing = false;
          this.connect();
          void this.reconnect();
        }, this.backoff());
      }
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

  /**
   * The session this client had is gone and the socket is open, anonymous.
   * `unauthorized`: a resume the server refused (the token was rotated under
   * this tab, or expired). `revoked`: the server signed this session out on
   * purpose (§4.21), which the app must not quietly undo. Fired *after*
   * `needsLogin` is set, which `onState("open")` is not — the open came
   * before the resume was answered.
   */
  onNeedLogin(fn: (why: "unauthorized" | "revoked") => void): () => void {
    this.needLoginWatchers.add(fn);
    return () => this.needLoginWatchers.delete(fn);
  }

  private needLogin(why: "unauthorized" | "revoked"): void {
    this.needsLogin = true;
    for (const w of this.needLoginWatchers) w(why);
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

  /** §3.1: exactly four messages are accepted on an ANONYMOUS connection. */
  /** The calls that compile something. See the timeout in `request`. */
  private static readonly SLOW = new Set(["quest.submit", "quest.run", "playground.run"]);

  private static readonly PREAUTH = new Set([
    "ping",
    "auth.challenge",
    "auth.login",
    "auth.resume",
  ]);

  request<K extends RequestType>(type: K, payload: Requests[K]): Promise<Responses[K]> {
    if (!this.transport) {
      return Promise.reject(
        new WireError({ code: "internal", message: "not connected", detail: {} }),
      );
    }
    if (this.state !== "authed" && !Client.PREAUTH.has(type)) {
      // Rejected locally rather than queued: a scene that asks for a map before
      // login has a sequencing bug, and hiding it behind a queue makes it
      // surface later as a mysterious stall.
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
    // Every call that puts a compiler behind it gets the long budget, not just
    // the one that records a verdict: `quest.run` and `playground.run` are the
    // same runner as a submit, and a cold `cargo` build that finished at 70
    // seconds would otherwise be reported to the player as a run that never
    // came back.
    const ms = Client.SLOW.has(type) ? SUBMIT_TIMEOUT_MS : REQUEST_TIMEOUT_MS;
    return new Promise<Responses[K]>((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        if (type === "quest.submit") this.submitInFlight = false;
        reject(new WireError({ code: "internal", message: `${type} timed out`, detail: {} }));
      }, ms);
      this.pending.set(id, { type, resolve: resolve as (v: unknown) => void, reject, timer });
      this.transport!.send(encode(id, type, payload));
    });
  }

  /** True while a submission is outstanding, so a button can disable itself. */
  get submitting(): boolean {
    return this.submitInFlight;
  }

  // -- the named calls a scene actually makes ------------------------------

  challenge(address: string): Promise<Responses["auth.challenge"]> {
    return this.request("auth.challenge", { address });
  }

  /**
   * `signature` is produced by `src/wallet`, which never hands over the key
   * that made it. The address travels so the server can find the nonce; the
   * server recovers it from the signature anyway and does not trust ours.
   */
  async login(address: string, signature: string, name?: string): Promise<User> {
    const res = await this.request(
      "auth.login",
      name ? { address, signature, name } : { address, signature },
    );
    this.lastAuth = "login";
    this.adopt(res.token, res.user);
    this.position = res.position;
    return res.user;
  }

  async resume(token: string): Promise<User> {
    const res = await this.request("auth.resume", { token });
    // §4.4 carries the place too, so a reconnect mid-session does not have to
    // be told again where the player is.
    this.position = res.position;
    // §4.4 / §8.7: the server rotates on use. Storing the one we sent would
    // work until it didn't, on whichever reconnect happened to be the second.
    this.lastAuth = "resume";
    this.adopt(res.token, res.user);
    return res.user;
  }

  private adopt(token: string, user: User): void {
    // Only a *working* session resets the backoff. Resetting it on `open`
    // would mean a server that accepts connections and then fails every
    // resume gets hammered at half a second for ever.
    this.retry = 0;
    this.token = token;
    this.user = user;
    this.needsLogin = false;
    this.hadSession = true;
    this.setState("authed");
  }

  // -- events --------------------------------------------------------------

  on<K extends EventType>(type: K, fn: (payload: Events[K]) => void): () => void {
    let set = this.listeners.get(type);
    if (!set) this.listeners.set(type, (set = new Set()));
    set.add(fn as (p: unknown) => void);
    return () => set!.delete(fn as (p: unknown) => void);
  }

  private emit(type: string, payload: unknown): void {
    const set = this.listeners.get(type);
    if (!set) return; // §8.3: an unknown or unwatched event is simply ignored
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
      // §2.1: the connection stays open, so the player can be told they are too
      // old rather than watching a socket die for no visible reason. Told
      // once: every frame carries the version, and every ping reply is a
      // frame, so without this the toast came back every twenty seconds.
      if (!this.versionWarned) {
        this.versionWarned = true;
        this.emit("server.bye", { reason: `server speaks protocol v${frame.v}` });
      }
      return;
    }
    if (frame.id === null) {
      this.handleEvent(frame.type, frame.payload);
      return;
    }
    const pending = this.pending.get(frame.id);
    if (!pending) return; // a reply to something that already timed out

    const kind = replyKind(frame.type);
    // A frame that carries an id but is not a reply is not something this
    // version understands. §8.3 says ignore it — and leaving the request
    // pending is right, because the real reply may still be coming.
    if (!kind) return;

    this.pending.delete(frame.id);
    clearTimeout(pending.timer);
    if (pending.type === "quest.submit") this.submitInFlight = false;

    if (kind.base !== pending.type) {
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

  private handleEvent(type: string, payload: unknown): void {
    if (type === "server.bye") {
      const reason = (payload as { reason?: string }).reason ?? "shutdown";
      // §4.21: `revoked` means the token is dead and reconnecting with it is
      // pointless, so it is dropped here rather than after one wasted round.
      if (reason === "revoked") {
        this.forgetToken();
        this.needLogin("revoked");
      }
    }
    this.emit(type, payload);
  }
}
