/**
 * The kept key, where it is used: login keeps it, boot recalls it, logout
 * forgets it, and a session the server retired is signed in again without
 * anybody typing. Pinned against the source, the way the poster tests are,
 * because each is an ordering rule inside a method that needs a browser to
 * run.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

const read = (p: string) => readFileSync(resolve(process.cwd(), p), "utf8");
const LOGIN = read("src/scenes/login.ts");
const BOOT = read("src/scenes/boot.ts");
const APP = read("src/app.ts");
const MAIN = read("src/main.ts");
const WALLET = read("src/wallet/wallet.ts");

/** A method's body, from its signature to the first `\n  }`. */
function method(src: string, sig: string): string {
  const at = src.indexOf(sig);
  expect(at, `${sig} exists`).toBeGreaterThan(0);
  const body = src.slice(at);
  return body.slice(0, body.indexOf("\n  }\n") + 4);
}

describe("login keeps the key", () => {
  it("only after the server accepted it, and before the screen leaves", () => {
    const attempt = method(LOGIN, "private async attempt(");
    const login = attempt.indexOf("await this.app.client.login(");
    const kept = attempt.indexOf("keep();");
    const gone = attempt.indexOf("await this.app.go(");
    expect(login).toBeGreaterThan(0);
    expect(kept).toBeGreaterThan(login);
    expect(kept).toBeLessThan(gone);
    // Nothing kept on the derive: a phrase the server turns down stays unwritten.
    expect(attempt.slice(0, login)).not.toContain("keep(");
  });
});

describe("boot recalls it", () => {
  it("after a resume, for the resumed address", () => {
    const enter = method(BOOT, "async enter(");
    const resumed = enter.indexOf("await this.app.client.resume(token)");
    const recalled = enter.indexOf("recall(user.address)");
    expect(resumed).toBeGreaterThan(0);
    expect(recalled).toBeGreaterThan(resumed);
  });

  it("signs in with the kept key when there is no token or a dead one, before the title", () => {
    const enter = method(BOOT, "async enter(");
    const again = enter.indexOf("await this.app.signInAgain()");
    const title = enter.indexOf("new TitleScene(");
    const forgot = enter.indexOf("this.app.client.forgetToken()");
    expect(again).toBeGreaterThan(forgot);
    expect(again).toBeLessThan(title);
  });
});

describe("the app", () => {
  it("forgets the kept key on logout, before the token", () => {
    const logout = method(APP, "async logout(");
    const key = logout.indexOf("forgetKey();");
    const token = logout.indexOf("this.client.forgetToken();");
    expect(key).toBeGreaterThan(0);
    expect(key).toBeLessThan(token);
    expect(APP).not.toContain("wipeKey()");
  });

  it("signs in again when the session was retired under it, and the key is kept", () => {
    const again = method(APP, "async signInAgain(");
    expect(again).toContain("recall(address)");
    expect(again).toContain("this.client.challenge(address)");
    expect(again).toContain("signMessage(challenge.message)");
    expect(again).toContain("this.restorePlace(this.client.position)");
    // Wired to the client's own signal, which fires after the flag is set —
    // `onState("open")` fires before the resume is answered and would miss it.
    expect(APP).toContain("client.onNeedLogin((why) => void this.sessionLost(why))");
    const lost = method(APP, "private async sessionLost(");
    // `revoked` is the server signing the session out on purpose: the key goes.
    expect(lost).toMatch(/if \(why === "revoked"\) \{\s*forgetKey\(\);/);
    expect(lost).toContain("await this.signInAgain()");
    // A sign-in that did not reach a verdict keeps the key: only the server's
    // own refusal is grounds to throw it away.
    expect(lost).toContain(
      'await this.logout(t("err.unauthorized"), { keepKey: outcome === "transient" })',
    );
    // And the retry loop is bounded.
    expect(lost).toContain("for (const wait of [1000, 2000, 4000])");
    // `logout` itself only forgets the key when not told to keep it.
    expect(method(APP, "async logout(")).toContain("if (!opts.keepKey) forgetKey();");
    // And it never hands the phrase or the key anywhere: only a signature crosses.
    expect(again).not.toContain("localStorage");
    expect(again).not.toMatch(/login\([^)]*key/);
  });

  it("keeps the token in localStorage, shared by every tab, and nothing else per tab", () => {
    expect(MAIN).toContain("storage: localStore()");
    expect(MAIN).not.toContain("sessionStorage");
    expect(MAIN).not.toContain("tabsession");
    expect(method(MAIN, "function localStore(")).toContain("globalThis.localStorage");
  });
});

describe("the wallet is the only reader and writer of the key", () => {
  it("nothing outside wallet.ts touches the key slot", () => {
    for (const f of [
      "src/app.ts",
      "src/main.ts",
      "src/scenes/login.ts",
      "src/scenes/boot.ts",
      "src/scenes/playground.ts",
    ]) {
      const src = read(f);
      expect(src, f).not.toContain("cwbhacker.key.");
      expect(src, f).not.toContain("KEY_SLOT");
    }
    expect(WALLET).toContain("KEY_SLOT");
    // Nothing returns the secret: `keep` writes it, `recall` reads it, and
    // both take the store rather than handing the bytes back.
    expect(WALLET).not.toMatch(/return (toHex\()?secret;/);
    expect(WALLET).toContain("store.setItem(KEY_SLOT(held.lower), toHex(secret))");
  });
});
