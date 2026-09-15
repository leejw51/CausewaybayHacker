import { chromium } from "@playwright/test";
const b = await chromium.launch();
const p = await b.newPage({ viewport: { width: 470, height: 1180 }, deviceScaleFactor: 2 });
await p.goto("file://" + process.argv[2]);
await p.waitForTimeout(3500);
await p.screenshot({ path: process.argv[3], fullPage: true });
await b.close();
