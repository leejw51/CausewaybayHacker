/**
 * What the client talks through.
 *
 * A real `WebSocket` and the dev mock (`mock.ts`) both satisfy this, which is
 * what lets the whole client — correlation, reconnect, the event fan-out — be
 * exercised without a server, and lets the mock be a build-time choice rather
 * than a branch inside `client.ts`.
 */
export interface Transport {
  send(text: string): void;
  close(): void;
}

export interface TransportHandlers {
  onOpen(): void;
  onMessage(text: string): void;
  onClose(reason: string): void;
}

export type TransportFactory = (h: TransportHandlers) => Transport;

export function websocketTransport(url: string): TransportFactory {
  return (h) => {
    const ws = new WebSocket(url);
    ws.addEventListener("open", () => h.onOpen());
    ws.addEventListener("message", (ev) => {
      // Text frames only (SPEC §6). A binary frame is a protocol violation and
      // is dropped rather than guessed at.
      if (typeof ev.data === "string") h.onMessage(ev.data);
    });
    ws.addEventListener("close", (ev) => h.onClose(ev.reason || `closed ${ev.code}`));
    ws.addEventListener("error", () => {
      /* `close` always follows, and carries the only detail a browser gives. */
    });
    return {
      send: (text) => {
        if (ws.readyState === WebSocket.OPEN) ws.send(text);
      },
      close: () => ws.close(),
    };
  };
}
