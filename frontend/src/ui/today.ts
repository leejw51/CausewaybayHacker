/**
 * Today at the bench: what the HUD's streak and the TODAY'S GOALS panel
 * read. Counted on this device from real runs — how many today, whether a
 * failed build was fixed, which languages ran — and the days in a row that
 * had at least one run. Nothing here is awarded or sent anywhere; it is a
 * scoreboard of what you actually did.
 *
 * Pure apart from the storage it is handed, so a test can give it a map.
 */
export interface Store {
  get(key: string): string | null;
  set(key: string, value: string): void;
}

export interface Today {
  date: string;
  runs: number;
  fixes: number;
  langs: string[];
}

const TODAY_KEY = "pg.today";
const DAYS_KEY = "pg.days";
/** How many days of history the streak keeps: enough for any streak worth showing. */
const KEEP_DAYS = 400;

export const GOAL_RUNS = 5;
export const GOAL_FIXES = 1;
export const GOAL_LANGS = 3;

/** `YYYY-MM-DD` in local time: a day is the person's day, not UTC's. */
export function dayOf(d: Date): string {
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

function parse<T>(raw: string | null, fallback: T): T {
  if (!raw) return fallback;
  try {
    return JSON.parse(raw) as T;
  } catch {
    return fallback;
  }
}

export function readToday(store: Store, now: Date): Today {
  const date = dayOf(now);
  const t = parse<Today | null>(store.get(TODAY_KEY), null);
  if (!t || t.date !== date || !Array.isArray(t.langs))
    return { date, runs: 0, fixes: 0, langs: [] };
  return t;
}

/** One run finished: count it, and the day toward the streak. */
export function recordRun(store: Store, now: Date, lang: string, fixed: boolean): Today {
  const t = readToday(store, now);
  const next: Today = {
    date: t.date,
    runs: t.runs + 1,
    fixes: t.fixes + (fixed ? 1 : 0),
    langs: t.langs.includes(lang) ? t.langs : [...t.langs, lang],
  };
  store.set(TODAY_KEY, JSON.stringify(next));
  const days = parse<string[]>(store.get(DAYS_KEY), []);
  if (!days.includes(t.date))
    store.set(DAYS_KEY, JSON.stringify([...days, t.date].slice(-KEEP_DAYS)));
  return next;
}

/**
 * Days in a row with a run, ending today — or yesterday, so a streak is not
 * shown as broken in the morning before the first run of the day.
 */
export function streak(store: Store, now: Date): number {
  const days = new Set(parse<string[]>(store.get(DAYS_KEY), []));
  const d = new Date(now.getFullYear(), now.getMonth(), now.getDate());
  if (!days.has(dayOf(d))) d.setDate(d.getDate() - 1);
  let n = 0;
  while (days.has(dayOf(d))) {
    n++;
    d.setDate(d.getDate() - 1);
  }
  return n;
}

/** The browser's storage, or nothing at all when it is refused. */
export const localStore: Store = {
  get(key) {
    try {
      return localStorage.getItem(key);
    } catch {
      return null;
    }
  },
  set(key, value) {
    try {
      localStorage.setItem(key, value);
    } catch {
      /* a private window: the scoreboard just does not keep */
    }
  },
};
