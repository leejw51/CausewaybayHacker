/**
 * The box at the head of a toolbar that narrows it to the buttons you name.
 *
 * The playground's band and the quest screen's bars grew past twenty buttons,
 * and twenty touch-sized labels were most of the screen they are the tools
 * for. Empty, it shows every button; typed into, only those whose label — or
 * id, so `copy` finds COPY CODE in any language — contains what was typed.
 *
 * **Several words, any of them, and what they mean.** `run copy paste` keeps RUN, both COPY
 * buttons and both PASTE buttons: a filter that took one word could only
 * ever show one family of buttons, and the point of it is to keep the
 * handful *you* use. Words split on spaces and commas (`,` `，` `、`), each
 * matched against the label, the id, the Hangul initials (`ㅂㅅ` 복사), a
 * table of concepts (`글꼴`, `ai`, `clipboard`, `나가기`) and an abbreviation
 * of the id (`cpcd`). A leading `-` hides instead (`-font`).
 *
 * One per scene, shared by the framed screen and CODE, so a filter set on one
 * is still set on the other. It is a DOM field laid over a well the canvas
 * draws, like the playground's search box, and Escape empties it.
 */
import type { Layout } from "../engine/layout";
import { well, type Ctx, type Rect } from "../engine/ui";
import { width, type Font } from "../engine/text";
import { onLocale, t } from "../i18n";
import { Overlay } from "./overlay";

export class ToolFilter {
  private readonly el: HTMLInputElement;
  private overlay: Overlay | null = null;
  private readonly offLocale: () => void;
  query = "";

  constructor() {
    const el = document.createElement("input");
    el.type = "text";
    el.className = "cwb-field cwb-name";
    el.spellcheck = false;
    el.autocomplete = "off";
    // Room for a working set of words, not just one.
    el.maxLength = 120;
    el.placeholder = t("tools.filter");
    el.addEventListener("input", () => {
      this.query = el.value;
    });
    el.addEventListener("keydown", (ev) => {
      // Handled here: `App` hands keys typed into an overlay to the field,
      // not to the scene, so the scene's ESC-to-leave never sees this one.
      if (ev.key === "Escape") {
        ev.preventDefault();
        this.clear();
        el.blur();
      }
    });
    this.offLocale = onLocale(() => {
      el.placeholder = t("tools.filter");
    });
    this.el = el;
  }

  mount(host: HTMLElement, layout: Layout): void {
    this.overlay?.destroy();
    this.overlay = new Overlay(host, layout, this.el);
    this.overlay.hide();
  }

  clear(): void {
    this.el.value = "";
    this.query = "";
  }

  /** Whether a button stays on the bar. Everything does while it is empty. */
  keeps(item: { id: string; label: string }): boolean {
    return filterKeeps(this.query, item);
  }

  filter<T extends { id: string; label: string }>(items: T[]): T[] {
    return items.filter((i) => this.keeps(i));
  }

  /** How wide the box is drawn in a bar set in `f`: room for a short word. */
  width(f: Font): number {
    return Math.round(Math.max(width(f, t("tools.filter")), width(f, "MMMMMMMM")) + f.size * 1.5);
  }

  /** The well and the field over it. */
  draw(g: Ctx, rect: Rect, f: Font): void {
    // Nothing to type into until a scene mounts it — a quest still loading.
    if (!this.overlay) return;
    const [x, y, w, h] = rect;
    well(g, x, y, w, h, [0.06, 0.05, 0.14, 0.98]);
    this.overlay.place([x + 3, y + 3, w - 6, h - 6], f.size);
  }

  hide(): void {
    this.overlay?.hide();
  }

  destroy(): void {
    this.offLocale();
    this.overlay?.destroy();
    this.overlay = null;
  }
}

/**
 * What each family of buttons *means*, in the words a person would reach for.
 *
 * The filter is symbolic rather than literal: a word that names a concept
 * keeps every button of that concept, whatever its label says in the
 * current language. `글꼴` keeps A- / A+ and the face button, `ai` keeps the
 * agent and COPY Q+CODE, `clipboard` keeps every copy and paste. Each entry
 * is the words that call it up (English, Korean, Japanese, Chinese) and the
 * button ids — or id fragments — it stands for.
 */
const CONCEPTS: ReadonlyArray<{ words: readonly string[]; ids: readonly string[] }> = [
  {
    words: [
      "run",
      "execute",
      "exec",
      "start",
      "play",
      "compile",
      "build",
      "실행",
      "돌려",
      "컴파일",
      "빌드",
      "実行",
      "运行",
      "執行",
    ],
    ids: ["run", "autorun", "submit"],
  },
  {
    words: ["copy", "clipboard", "복사", "클립보드", "コピー", "复制", "複製"],
    ids: ["copy"],
  },
  {
    words: ["paste", "clipboard", "붙여", "붙이", "클립보드", "貼り付け", "粘贴", "貼上"],
    ids: ["paste"],
  },
  {
    words: [
      "font",
      "text",
      "type",
      "size",
      "zoom",
      "bigger",
      "smaller",
      "글꼴",
      "글자",
      "폰트",
      "크기",
      "확대",
      "축소",
      "フォント",
      "文字",
      "字体",
      "字型",
      "大小",
    ],
    ids: ["fontup", "fontdown", "face"],
  },
  {
    words: [
      "theme",
      "dark",
      "light",
      "color",
      "colour",
      "night",
      "테마",
      "다크",
      "라이트",
      "밝게",
      "어둡게",
      "색",
      "テーマ",
      "主题",
      "主題",
    ],
    ids: ["theme"],
  },
  {
    words: [
      "ai",
      "agent",
      "ask",
      "help",
      "assistant",
      "claude",
      "gpt",
      "에이전트",
      "질문",
      "물어",
      "도움",
      "인공지능",
      "エージェント",
      "助手",
      "智能",
    ],
    ids: ["agent", "copyask"],
  },
  {
    words: [
      "hint",
      "answer",
      "solve",
      "solution",
      "cheat",
      "stuck",
      "힌트",
      "정답",
      "답",
      "풀이",
      "막혔",
      "ヒント",
      "答え",
      "提示",
      "答案",
    ],
    ids: ["hint", "solve", "answer", "blanks", "solution", "complete"],
  },
  {
    words: [
      "undo",
      "redo",
      "history",
      "back",
      "revert",
      "되돌",
      "다시",
      "취소",
      "기록",
      "元に戻す",
      "撤销",
      "復原",
    ],
    ids: ["undo", "redo", "clearstack"],
  },
  {
    words: ["format", "pretty", "tidy", "indent", "정렬", "포맷", "들여쓰기", "整形", "格式"],
    ids: ["format"],
  },
  {
    words: [
      "output",
      "log",
      "console",
      "stderr",
      "error",
      "result",
      "출력",
      "로그",
      "콘솔",
      "에러",
      "오류",
      "결과",
      "出力",
      "输出",
      "輸出",
      "日志",
    ],
    ids: ["copyout", "console", "stderr", "log"],
  },
  {
    words: ["input", "stdin", "입력", "표준입력", "入力", "输入", "輸入"],
    ids: ["copyin", "pastein"],
  },
  {
    words: [
      "file",
      "save",
      "rename",
      "new",
      "scratch",
      "파일",
      "저장",
      "이름",
      "새로",
      "메모",
      "ファイル",
      "保存",
      "文件",
      "檔案",
    ],
    ids: ["save", "rename", "new"],
  },
  {
    words: [
      "share",
      "image",
      "picture",
      "poster",
      "qr",
      "export",
      "import",
      "공유",
      "이미지",
      "사진",
      "포스터",
      "디스크",
      "読み込み",
      "分享",
      "图片",
    ],
    ids: ["poster", "reader"],
  },
  {
    words: [
      "view",
      "layout",
      "screen",
      "panel",
      "full",
      "focus",
      "only",
      "side",
      "top",
      "rotate",
      "orientation",
      "화면",
      "보기",
      "배치",
      "전체",
      "패널",
      "회전",
      "방향",
      "만",
      "表示",
      "画面",
      "视图",
      "畫面",
    ],
    ids: ["stack", "briefonly", "codeonly", "focus", "code", "fullscreen", "orient", "unfocus"],
  },
  {
    words: [
      "exit",
      "leave",
      "quit",
      "home",
      "map",
      "lobby",
      "나가",
      "나가기",
      "뒤로",
      "지도",
      "로비",
      "홈",
      "戻る",
      "地图",
      "返回",
    ],
    ids: ["back", "lobby", "unfocus"],
  },
  {
    words: ["language", "lang", "언어", "言語", "语言", "語言"],
    ids: ["rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua"],
  },
  {
    words: [
      "reset",
      "clear",
      "clean",
      "wipe",
      "초기화",
      "지우",
      "리셋",
      "リセット",
      "重置",
      "清除",
    ],
    ids: ["reset", "clearstack"],
  },
  {
    words: [
      "brief",
      "task",
      "quiz",
      "problem",
      "question",
      "job",
      "과제",
      "문제",
      "퀴즈",
      "課題",
      "任务",
      "任務",
      "题目",
    ],
    ids: ["copybrief", "briefonly", "stack"],
  },
];

/** Hangul syllables to their leading consonant, so `ㅂㅅ` finds 복사. */
const CHOSEONG = "ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ";
function choseong(text: string): string {
  let out = "";
  for (const ch of text) {
    const c = ch.charCodeAt(0);
    out += c >= 0xac00 && c <= 0xd7a3 ? CHOSEONG[Math.floor((c - 0xac00) / 588)] : ch;
  }
  return out;
}
const ONLY_JAMO = /^[ㄱ-ㅎ]+$/;
const HANGUL = /[가-힣]/;

/** `cpcd` finds `copycode`: every letter, in order, with gaps allowed. */
function subsequence(word: string, text: string): boolean {
  let i = 0;
  for (const ch of text) if (ch === word[i] && ++i === word.length) return true;
  return false;
}

/** The words of a filter query: split on spaces and commas, lower-cased. */
export function filterWords(query: string): string[] {
  return query
    .toLowerCase()
    .split(/[\s,，、]+/)
    .filter((w) => w !== "");
}

/** The ids a word calls up through the concept table. */
function conceptIds(word: string): string[] {
  // A word long enough to mean something: two letters, or one Hangul
  // syllable (`답`, `색`), which already carries a whole idea.
  if (word.length < 2 && !HANGUL.test(word)) return [];
  const out: string[] = [];
  for (const c of CONCEPTS) {
    if (c.words.some((w) => w.startsWith(word) || (word.length >= 3 && word.startsWith(w)))) {
      out.push(...c.ids);
    }
  }
  return out;
}

/** Whether one word keeps one button. */
function wordKeeps(word: string, label: string, id: string): boolean {
  if (label.includes(word) || id.includes(word)) return true;
  // Hangul initials: `ㅂㅅ` is 복사, `ㅈㅈ` is 저장.
  if (ONLY_JAMO.test(word)) return choseong(label).replace(/\s+/g, "").includes(word);
  // The concept table: `글꼴` is A- / A+, `ai` is the agent.
  if (conceptIds(word).some((c) => id === c || id.startsWith(c))) return true;
  // An abbreviation of the id: `cpcd` is copycode, `fup` is fontup.
  return word.length >= 3 && /^[a-z]+$/.test(word) && subsequence(word, id);
}

/**
 * Whether a button stays drawn under `query`.
 *
 * Words are OR'd: a button stays when **any** word keeps it, because the box
 * is for naming the handful of buttons you use. A word with a leading `-`
 * takes away instead (`-font` hides the font buttons), and a query of only
 * `-` words starts from every button. Nothing typed keeps everything.
 */
export function filterKeeps(query: string, item: { id: string; label: string }): boolean {
  const words = filterWords(query);
  if (words.length === 0) return true;
  const label = item.label.toLowerCase();
  const id = item.id.toLowerCase();
  const minus = words.filter((w) => w.startsWith("-") && w.length > 1).map((w) => w.slice(1));
  const plus = words.filter((w) => !w.startsWith("-"));
  if (minus.some((w) => wordKeeps(w, label, id))) return false;
  if (plus.length === 0) return true;
  return plus.some((w) => wordKeeps(w, label, id));
}
