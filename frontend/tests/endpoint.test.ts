/**
 * Which server the page talks to (`net/endpoint.ts`).
 *
 * The desktop app serves its page from the webview's own origin and puts its
 * server on a random loopback port, which it hands the page as
 * `window.__CWBH_SERVER__`. That has to win over `location`, or the socket is
 * `ws://localhost/ws` on a page whose host is the webview, not the server.
 */
import { afterEach, describe, expect, it } from "vitest";
import { serverBase, serverUrl, wsUrl } from "../src/net/endpoint";

afterEach(() => {
  delete window.__CWBH_SERVER__;
});

describe("without the desktop app", () => {
  it("derives the socket from the page's own address", () => {
    expect(serverBase()).toBe("");
    expect(wsUrl()).toBe(`ws://${location.host}/ws`);
  });

  it("leaves server paths relative", () => {
    expect(serverUrl("/photos/7/abc.jpg")).toBe("/photos/7/abc.jpg");
  });
});

describe("in the desktop app", () => {
  it("talks to the port the app named", () => {
    window.__CWBH_SERVER__ = "http://127.0.0.1:61234";
    expect(serverBase()).toBe("http://127.0.0.1:61234");
    expect(wsUrl()).toBe("ws://127.0.0.1:61234/ws");
  });

  it("puts the chat's photos on the server, and leaves data URLs alone", () => {
    window.__CWBH_SERVER__ = "http://127.0.0.1:61234/";
    expect(serverUrl("/photos/7/abc.jpg")).toBe("http://127.0.0.1:61234/photos/7/abc.jpg");
    expect(serverUrl("data:image/png;base64,AAAA")).toBe("data:image/png;base64,AAAA");
    expect(serverUrl("//evil.example/x")).toBe("//evil.example/x");
  });

  it("ignores something that is not an http URL", () => {
    window.__CWBH_SERVER__ = "javascript:alert(1)";
    expect(serverBase()).toBe("");
    expect(wsUrl()).toBe(`ws://${location.host}/ws`);
  });
});
