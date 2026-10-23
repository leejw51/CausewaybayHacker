-- THE PLAYGROUND (PROTOCOL §4.9c). Mei's own desk.
--
-- A scratchpad: no quest, no tests, no verdict. You write whatever you like,
-- run it, and it prints what it prints.
--
-- ## Nothing here is scored, and the screen has to say so by how it looks
--
-- DESIGN made `bg_playground` and deliberately nothing else — the room the
-- game opens in, "identity is absence". So this screen follows the same rule
-- in its language:
--
--   * **compiler output does not speak in the failure register.** No red, no
--     `Theme.verdict` colours, no banner. A compile error here is information,
--     not a judgement, and the outcome line says "did not compile" the way a
--     terminal would. The one deliberate exception: the output card's header
--     flashes for 600 ms when a run comes back -- green when it ran, the
--     danger colour (`Theme.bad`) when the build did not go through -- and
--     is cream again before anybody has read it. A moment, not a verdict.
--   * **the word "wrong" does not appear**, and neither does FAIL, ERROR as a
--     headline, or anything else that implies there was a right answer. There
--     is no answer here; there is only what the program did.
--
-- That is not decoration. §4.9c says a playground run is deliberately *not*
-- recorded and does not feed the curriculum, precisely because this is where
-- somebody writes something broken on purpose to see what the compiler says.
-- A screen that scolded them for it would be arguing with its own contract.
--
-- ## Snippets live on the server
--
-- §4.9c: saved per user, server-side, so the same scratchpad opens in the
-- browser and here. Autosave is on a timer and `playground.save` is idempotent
-- by contract, so an unchanged buffer costs nothing.
--
-- And **nothing is overwritten without asking**. A save of this pad on
-- another device arrives as `playground.updated` (§4.22): a clean pad takes
-- it, and a pad with unsaved typing stops and asks -- TAKE THEIRS or KEEP
-- MINE -- and saves nothing until it is answered (`resolve_conflict`).

local Layout = require("src.layout")
local Theme = require("src.theme")
local Assets = require("src.assets")
local UI = require("src.ui")
local I18n = require("src.i18n")
local SFX = require("src.sfx")
local Editor = require("src.editor")
local CodePane = require("src.codepane")
local CodeFx = require("src.codefx")
local CoderM = require("src.agent.coder")
local Anim = require("src.anim")
local Juice = require("src.juice")
local runlog = require("src.net.runlog")

local Playground = {}
Playground.__index = Playground

local Land = require("src.land")
local Poster = require("src.poster")
local Reader = require("src.diskreader")
local Wallet = require("src.wallet")
local Store = require("src.store")
local Computer = require("src.computer")
local RetroScreen = require("src.retroscreen")
local Monitor = require("src.retromonitor")

-- TAB walks the languages in the lands' order, and the starter is the same
-- program in each: the smallest thing that compiles and prints, so the desk
-- proves the toolchain is there before anybody types.
-- The languages, not the lands: REMIX LAND is a place where three of these
-- are spoken, and a scratchpad has to be in one of them (PROTOCOL §5.9).
local LANGS = Land.LANGS

local STARTER = {
  -- A Rust scratchpad has the crate shelf (PROTOCOL §4.9c), and the starter
  -- uses every crate on it once, so the pad opens on a working reference.
  rust = table.concat({
    "// Every crate on the shelf, used once. Keep what you need, delete the rest.",
    "use std::sync::Arc;",
    "",
    "use anyhow::{Context, Result};",
    "use bytes::Bytes;",
    "use chrono::NaiveDate;",
    "use clap::Parser;",
    "use indexmap::IndexMap;",
    "use itertools::Itertools;",
    "use parking_lot::Mutex;",
    "use rand::{rngs::StdRng, RngExt, SeedableRng};",
    "use rayon::prelude::*;",
    "use regex::Regex;",
    "use serde::{Deserialize, Serialize};",
    "use thiserror::Error;",
    "use tokio::sync::mpsc;",
    "use uuid::Uuid;",
    "",
    "#[derive(Debug, Serialize, Deserialize)]",
    "struct Receipt {",
    "    merchant: String,",
    "    cents: i64,",
    "}",
    "",
    "#[derive(Debug, Error)]",
    "enum TillError {",
    "    #[error(\"insufficient funds: need {need}, have {have}\")]",
    "    Insufficient { need: i64, have: i64 },",
    "}",
    "",
    "#[derive(Parser, Debug)]",
    "struct Cli {",
    "    #[arg(long, default_value_t = 3)]",
    "    workers: usize,",
    "}",
    "",
    "#[tokio::main]",
    "async fn main() -> Result<()> {",
    "    // tracing + tracing-subscriber; `log` records are picked up too",
    "    tracing_subscriber::fmt().with_ansi(false).without_time().with_target(false).init();",
    "    tracing::info!(\"hello, causewaybay\");",
    "    log::info!(\"the till is open\");",
    "",
    "    // clap: a command line, here handed in rather than read from argv",
    "    let cli = Cli::try_parse_from([\"pad\", \"--workers\", \"2\"])?;",
    "",
    "    // serde + serde_json + bincode + bytes + hex",
    "    let receipt = Receipt { merchant: \"Lucky Mac\".into(), cents: 3800 };",
    "    let json = serde_json::to_string(&receipt)?;",
    "    let packed = Bytes::from(bincode::serde::encode_to_vec(&receipt, bincode::config::standard())?);",
    "    println!(\"{json}\");",
    "    println!(\"{} bytes: {}\", packed.len(), hex::encode(&packed));",
    "",
    "    // toml",
    "    let config: toml::Table = toml::from_str(\"[till]\\nfloat = 500\\n\")?;",
    "    println!(\"float = {}\", config[\"till\"][\"float\"]);",
    "",
    "    // thiserror + anyhow",
    "    let refused: Result<()> = Err(TillError::Insufficient { need: 300, have: 100 }).context(\"transfer 1\");",
    "    println!(\"{:#}\", refused.unwrap_err());",
    "",
    "    // regex + itertools + indexmap",
    "    let re = Regex::new(r\"HK\\$(\\d+)\")?;",
    "    let amounts: Vec<i64> = re.captures_iter(\"HK$30 and HK$12\").map(|c| c[1].parse().unwrap()).collect();",
    "    println!(\"{} = {}\", amounts.iter().join(\" + \"), amounts.iter().sum::<i64>());",
    "    let mut seen = IndexMap::new();",
    "    for merchant in [\"SOGO\", \"Lucky Mac\", \"SOGO\"] {",
    "        *seen.entry(merchant).or_insert(0) += 1;",
    "    }",
    "    println!(\"{seen:?}\");",
    "",
    "    // chrono + rand (seeded) + uuid (v5, so it is the same every run)",
    "    let date = NaiveDate::parse_from_str(\"2026-10-06\", \"%Y-%m-%d\")?;",
    "    let draw: u32 = StdRng::seed_from_u64(7).random_range(1..=100);",
    "    let id = Uuid::new_v5(&Uuid::NAMESPACE_DNS, b\"causewaybay\");",
    "    println!(\"{}  draw {draw}  {id}\", date.format(\"%a %d %b %Y\"));",
    "",
    "    // rayon + parking_lot + crossbeam",
    "    let total: i64 = (1..=100i64).into_par_iter().sum();",
    "    let ledger = Arc::new(Mutex::new(0i64));",
    "    crossbeam::scope(|s| {",
    "        for _ in 0..cli.workers {",
    "            let ledger = Arc::clone(&ledger);",
    "            s.spawn(move |_| *ledger.lock() += total);",
    "        }",
    "    })",
    "    .unwrap();",
    "    println!(\"ledger {}\", ledger.lock());",
    "",
    "    // tokio mpsc + futures",
    "    let (tx, mut rx) = mpsc::channel(8);",
    "    for i in 1..=3 {",
    "        let tx = tx.clone();",
    "        tokio::spawn(async move { tx.send(i * 10).await.unwrap() });",
    "    }",
    "    drop(tx);",
    "    let mut got = Vec::new();",
    "    while let Some(v) = rx.recv().await {",
    "        got.push(v);",
    "    }",
    "    got.sort();",
    "    let doubled = futures::future::join_all(got.iter().map(|v| async move { v * 2 })).await;",
    "    println!(\"{got:?} -> {doubled:?}\");",
    "",
    "    // rusqlite, in memory",
    "    let db = rusqlite::Connection::open_in_memory()?;",
    "    db.execute_batch(\"CREATE TABLE t(cents INTEGER); INSERT INTO t VALUES (3800), (12500);\")?;",
    "    let sum: i64 = db.query_row(\"SELECT sum(cents) FROM t\", [], |r| r.get(0))?;",
    "    println!(\"sqlite sum {sum}\");",
    "",
    "    // reqwest: a client, and no request — the pad may have no network",
    "    let _client = reqwest::Client::new();",
    "    Ok(())",
    "}",
    "",
  }, "\n"),
  go = 'package main\n\nimport "fmt"\n\nfunc main() {\n\tfmt.Println("hello")\n}\n',
  cpp = '#include <iostream>\n\nint main() {\n    std::cout << "hello\\n";\n}\n',
  python = 'print("hello")\n',
  pytorch = 'import torch\n\nprint("hello", torch.tensor([1, 2, 3]).tolist())\n',
  -- Stdin the one way `node.d.ts` declares it: there is no @types/node.
  typescript = 'const input: string = require("fs").readFileSync(0, "utf8");\n\nconsole.log("hello");\n',
  -- Zig 0.16: stdout is a buffered writer that has to be flushed, or the
  -- program ends with "hello" still in `buf`. `std.debug.print` would be
  -- the short way, and it is stderr, which the judge does not read.
  zig = 'const std = @import("std");\n\npub fn main(init: std.process.Init) !void {\n    var buf: [256]u8 = undefined;\n    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);\n    const w = &out.interface;\n    try w.print("hello\\n", .{});\n    try w.flush();\n}\n',
  lua = 'print("hello")\n',
}
Playground.LANGS = LANGS
Playground.STARTER = STARTER

--- §5.9's `outcome`, in plain words. Not one of them is a verdict: every line
--- describes what the program did, which is all that happened.
local OUTCOME = {
  ok = "ran",
  compile_error = "did not compile",
  runtime_error = "stopped early",
  timeout = "took too long",
  output_limit = "printed too much",
}

-- AUTO-RUN and STDERR, the browser's two switches beside RUN.
--
--   * **AUTO-RUN** runs the pad on every ENTER typed in the editor, so the
--     answer on screen follows the code a line at a time. On unless somebody
--     turned it off, as in the browser.
--   * **STDERR** shows the program's stderr and the compiler's notes. Off
--     unless somebody turned it on: the output is then what the program
--     printed, and the compiler only when the build failed -- warnings,
--     panics' backtraces and the compiler's progress chatter stay out of the
--     way of the answer.
--
-- On the module rather than the scene, so they outlive a visit to the map,
-- and in the store (`pgprefs.set`), so they outlive the program: `App:load`
-- reads them back through `Playground.restore_prefs`.
Playground.PREFS = { auto_run = true, stderr = false }

--- The saved switches and the saved computer, put back before the first
--- frame. Only fields that were saved: a store that never heard of STDERR
--- leaves it at its default rather than at nil.
function Playground.restore_prefs(prefs, computer)
  if type(prefs) == "table" then
    if type(prefs.auto_run) == "boolean" then Playground.PREFS.auto_run = prefs.auto_run end
    if type(prefs.stderr) == "boolean" then Playground.PREFS.stderr = prefs.stderr end
  end
  if computer then Computer.set(computer) end
end

-- How long an untouched buffer waits before it is saved. Long enough that
-- typing does not generate traffic, short enough that nobody loses a thought.
Playground.AUTOSAVE_S = 4

function Playground.new(app)
  return setmetatable({
    app = app,
    lang = "rust",
    snippets = nil,
    snippet_id = nil,
    pad_serial = 0,
    name = nil,
    focus = "editor",       -- "editor" | "stdin" | "snippets"
    stdin = "",
    running = false,
    result = nil,
    log = nil,
    stage = nil,
    elapsed_ms = 0,
    note = nil,
    problem = nil,
    formatting = false,
    format_unsupported = nil,
    cursor = 1,
    dirty_at = nil,
    saved_at = nil,
    t = 0,
    -- CODE: the editor and nothing else. The quest screen has the same mode
    -- for the same reason — this screen is five panes in one window, and on
    -- a phone that leaves the thing you are typing into a few lines tall.
    big = false,
    -- What is in the name field while somebody is renaming. Nil when nobody
    -- is: `focus == "name"` and this are set and cleared together.
    name_edit = nil,
    -- True until the first keystroke of a rename, which then replaces the
    -- whole name rather than appending to it — the desktop client's "arrives
    -- selected", with no selection to draw.
    name_fresh = false,
    -- Narrowing the list by name. The pads are in most-recently-touched
    -- order, which is the right order to keep and the wrong one to hunt
    -- through once there are a dozen.
    query = "",
    finding = false,
    -- POSTER and DISK READER (`src/poster.lua`, `src/diskreader.lua`).
    -- The key for the stamp. The session keeps the key it signed in with,
    -- and the store keeps it for the next launch (`Session:signer`); only
    -- an account with nothing kept on this machine is asked, once, in
    -- place, and `stamp_with` keeps what it typed.
    secret = nil,
    secret_index = 0,
    stamp_edit = nil,   -- what is in the key field; nil when it is closed
    disk_edit = nil,    -- what is in the path field; nil when it is closed
    postering = false,
    -- The Rust coder: the AI agent that flies over the code
    -- (`src/agent/coder.lua`). Made in `enter`, because it wants the editor.
    coder = nil,
    -- A save of this pad from another device that arrived while this one had
    -- unsaved typing, waiting for the player to choose (`resolve_conflict`).
    -- While it waits nothing is saved from here: an autosave would be the
    -- choice made for them by a timer.
    conflict = nil,
    conflict_rects = nil,
    -- An ENTER landed while a run was out (AUTO-RUN): run once more when it
    -- is back, so the answer on screen is for the code on screen and not
    -- for a line ago.
    run_again = false,
    -- The output pane, scrolled: lines back from the tail, as the browser
    -- counts them, so the same moment stays put while more streams in.
    out_scroll = 0,
    out_overflow = 0,
    -- The box at the head of the toolbars that narrows them to the buttons
    -- named in it (`Playground.filter_keeps`). One for the bench and CODE,
    -- so a filter set on one is still set on the other.
    tools_query = "",
    -- The old computer's tube over the editor (`src/retroscreen.lua`).
    retro = nil,
    -- What the pointer is over: `"tool:<id>"`, `"list:<id>"`, `"pad:<i>"`,
    -- `"lang"`, `"computer"`, `"name"` or `"done"`. The kit's buttons lift
    -- under it.
    hover = nil,
    -- The toolbar's rects by id, whichever view drew them last.
    tool_rects = nil,
    -- The colour the output header flashes when a run comes back.
    ran_tint = nil,
    -- When the editor last scrolled, for the scrollbar's fade.
    last_scroll = nil,
    scrolled_at = nil,
  }, Playground)
end

function Playground:enter()
  self.editor = Editor.new({
    clipboard = {
      get = function() return love.system.getClipboardText() or "" end,
      set = function(text) love.system.setClipboardText(text or "") end,
    },
    now = function() return love.timer.getTime() end,
  })
  -- Same pane object as the quest screen's: the hit test, drag-select and the
  -- bracket overlay are one implementation, not two that look alike.
  self.pane = CodePane.new(self.editor)
  -- The typing effects, over the editor: `src/codefx.lua`.
  self.fx = self.fx or CodeFx.new()
  self.fx:clear()
  self.fx:attach(self.editor, self.pane)
  self.editor.auto_close = true
  self.editor.lang = self.lang
  self.editor:set_text(STARTER[self.lang])
  self.editor.dirty = false

  self.subscriptions = {
    self.app.session:on("run.stage", function(payload) self:on_stage(payload) end),
    self.app.session:on("run.log", function(payload) self:on_log(payload) end),
    -- §4.22, §4.23: the same pad open here and on another device. A save or
    -- a room change there arrives here.
    self.app.session:on("playground.updated", function(payload)
      self:remote_saved(payload and payload.snippet)
    end),
    self.app.session:on("playground.chat.updated", function(payload)
      if self.coder and payload then
        self.coder:room_updated(payload.id, payload.message, payload.cleared == true)
      end
    end),
  }
  self.coder = CoderM.new(self.app, self:agent_host())
  self.coder:mount(self.editor)
  -- Arriving with a machine already picked only warms the tube up; the
  -- banner is for the moment it is chosen.
  self.retro = self.retro or RetroScreen.new()
  self.retro:power(Computer.get(), false)
  -- The kit's motion state for this screen starts over on every visit.
  Juice.forget("pg:")
  self:list()
end

--- What the coder is allowed to do on this screen. The playground is the
--- generous one: it runs code, formats it, has a room per pad and can put a
--- picture in it. The quest screen hands over a much shorter list.
function Playground:agent_host()
  local scene = self
  return {
    lang = function() return scene.lang end,
    caret = function()
      if not scene.pane then return nil end
      return scene.pane:cell(scene.editor.line, scene.editor.col)
    end,
    room_id = function() return scene.snippet_id end,
    -- Changes with every pad the screen moves to, saved or not: what tells
    -- NEW from the unsaved pad before it, which `room_id` (nil for both)
    -- cannot. See `Sync.room_move`.
    room_key = function() return scene.pad_serial end,
    room_name = function() return scene.name or "" end,
    ensure_room = function()
      -- A pad nobody has saved has no id, and a room belongs to an id. So the
      -- first thing said in an unsaved pad saves it.
      if scene.snippet_id then return false end
      scene:save()
      return true
    end,
    touched = function()
      scene.dirty_at = Anim.now()
    end,
    fx = function() return scene.fx end,
    request = function(type_name, payload, cb)
      scene.app.session:request(type_name, payload, cb)
    end,
    run = function(stdin, done)
      if scene.running then return done(nil) end
      if stdin then scene.stdin = stdin end
      scene.agent_run_done = done
      scene:run()
    end,
    format = function(done)
      scene.agent_format_done = done
      scene:format()
    end,
  }
end

function Playground:leave()
  if self.coder then self.coder:leave() end
  -- The shader and its canvas are given back with the screen: the tube is
  -- the playground's, and nothing else draws it.
  if self.retro then self.retro:release() end
  -- The stamp's key does not outlive the screen.
  Wallet.forget(self, "secret")
  self.stamp_edit, self.disk_edit = nil, nil
  -- Save on the way out rather than losing the last few seconds of typing.
  if self.editor and self.editor.dirty then self:save() end
  self.app.session:off_all(self.subscriptions)
  self.subscriptions = nil
end

-- ----------------------------------------------------------------- snippets

function Playground:list()
  self.app.session:request("playground.list", {}, function(ok, payload)
    if not ok then return end
    self.snippets = payload.snippets or {}
    self.cursor = math.max(1, math.min(#self.snippets, self.cursor))
  end)
end

--- §4.9c: idempotent by contract, so this can sit on a timer.
--- Keep the pad.
---
--- **One at a time, and a failure waits.** The autosave fires from `update`
--- whenever the text has been dirty for four seconds, and `dirty_at` was only
--- cleared by a *successful* reply — so a save the server refused left the
--- condition true and sent another on the very next frame, and the next, until
--- the server said "too fast" to all of them. That was invisible while saves
--- always worked; the coder's room hangs off this id, and it asks for a save
--- the moment somebody says something in a pad that has never had one.
function Playground:save(explicit)
  if not self.editor then return end
  -- Not while another device's save is waiting on a choice: this would be
  -- KEEP MINE, chosen by the autosave or by leaving the screen.
  if self.conflict then return end
  if self.save_inflight then
    -- One in flight already: remember that the text has moved on since, so
    -- the reply starts another. Without this, `leave`'s save — the one that
    -- exists so the last few seconds of typing are not lost — would be the
    -- one dropped when it landed during an autosave's round trip.
    self.save_again = true
    return
  end
  self.save_inflight = true
  local payload = {
    lang = self.lang,
    source = self.editor:text(),
    -- The pad's input belongs to the pad: a scratchpad has no test cases, so
    -- this is the only thing its program will ever read, and reopening the
    -- pad without it hands back a program that cannot be run.
    stdin = self.stdin or "",
  }
  if self.snippet_id then payload.id = self.snippet_id end
  if self.name then payload.name = self.name end

  local sent = self.app.session:request("playground.save", payload, function(ok, reply, why)
    self.save_inflight = false
    local again = self.save_again
    self.save_again = false
    if not ok then
      -- The next attempt is one autosave interval away, not one frame.
      self.dirty_at = Anim.now()
      -- Never silently: `why.player` is nil for codes this client has no
      -- sentence for, and a save that failed with an empty note is a save
      -- that looks like it worked. The coder's room hangs off this id.
      self.note = (why and why.player) or ("save refused: " .. tostring(reply and reply.code))
      return
    end
    local snippet = reply.snippet
    self.snippet_id = snippet.id
    self.name = snippet.name
    self.stdin = snippet.stdin or self.stdin or ""
    self.saved_at = Anim.now()
    self.editor.dirty = false
    self.dirty_at = nil
    -- A save somebody asked for says so, briefly; the autosave is quiet and
    -- the dirty dot going out is its whole announcement.
    if explicit then self:say(I18n.t("saved"), "good") end
    self:list()
    if again then self:save() end
  end)
  -- A request that could not even be framed answers nobody, and a flag left
  -- true would mean this pad is never saved again.
  if not sent then self.save_inflight = false end
end

function Playground:load(index)
  local brief = self.snippets and self.snippets[index]
  if not brief then return end
  self.app.session:request("playground.load", { id = brief.id }, function(ok, payload, why)
    if not ok then self.note = why.player; return end
    local snippet = payload.snippet
    self.pad_serial = self.pad_serial + 1
    self.snippet_id = snippet.id
    self.name = snippet.name
    self.lang = snippet.lang
    self.editor:set_text(snippet.source or "")
    -- The input comes back with the code: one entry, two things.
    self.stdin = snippet.stdin or ""
    self.editor.dirty = false
    self.dirty_at = nil
    self.result = nil
    self.log = nil
    self.out_scroll = 0
    self:say("opened " .. tostring(snippet.name))
    SFX.play("select")
  end)
end

function Playground:delete(index)
  local brief = self.snippets and self.snippets[index]
  if not brief then return end
  self.app.session:request("playground.delete", { id = brief.id }, function(ok, _, why)
    if not ok then self.note = why.player; return end
    if self.snippet_id == brief.id then
      -- The room went with the pad; what is held is a new unsaved pad now.
      self.pad_serial = self.pad_serial + 1
      self.snippet_id = nil
      self.name = nil
    end
    self:say("deleted")
    self:list()
  end)
end

--- What a `playground.updated` from another connection of the same user
--- means for the pad on this screen (PROTOCOL §4.22). Pure, so the suite can
--- ask without a screen.
---
---   * "ignore": a different pad, or none held.
---   * "apply": this pad, and nothing unsaved here — take the saved text.
---   * "ask": this pad, but unsaved typing here. Leave the buffer alone and
---     ask which to keep -- the other device's save, or this text saved over
---     it. Replacing text under fingers that are typing is the one thing this
---     must never do, and neither is letting the next autosave from here throw
---     the other device's work away without a word.
function Playground.remote_save_action(held_id, snippet_id, dirty)
  if held_id == nil or held_id ~= snippet_id then return "ignore" end
  return dirty and "ask" or "apply"
end

--- Make `snippet` the pad on screen, clean: what `open` would do, without
--- moving to another pad.
function Playground:take_snippet(snippet)
  local source = snippet.source or ""
  self.lang = snippet.lang or self.lang
  self.editor.lang = self.lang
  self.name = snippet.name
  self.stdin = snippet.stdin or ""
  if source ~= self.editor:text() then self.editor:set_text(source) end
  self.editor.dirty = false
  self.dirty_at = nil
  self.saved_at = Anim.now()
end

--- The answer to "saved on another device -- which one?".
---
---   * "theirs": the other device's pad replaces what is here, unsaved typing
---     and all. It was asked for, so it is not a loss.
---   * "mine": what is here is saved over the server's copy, and from there
---     reaches the other device like any save.
function Playground:resolve_conflict(choice)
  local snippet = self.conflict
  if not snippet then return end
  self.conflict = nil
  self.conflict_rects = nil
  if choice == "theirs" then
    self:take_snippet(snippet)
    self:say(I18n.t("took the other device's version"))
  else
    self.editor.dirty = true
    self:save()
  end
  SFX.play("select")
end

--- This pad was saved on another device (§4.22): taken as `open` would take
--- it when nothing here is unsaved, and asked about when there is.
function Playground:remote_saved(snippet)
  if not snippet or not self.editor then return end
  local action = Playground.remote_save_action(self.snippet_id, snippet.id, self.editor.dirty)
  if action == "ignore" then
    self:list()
    return
  end
  local source = snippet.source or ""
  local changed = source ~= self.editor:text()
    or (snippet.stdin or "") ~= (self.stdin or "")
    or snippet.name ~= self.name
    or snippet.lang ~= self.lang
  if not changed then
    -- The other device saved exactly what is on screen here: nothing to
    -- choose between, and this pad is as saved as that one.
    self:take_snippet(snippet)
    self.conflict = nil
    return
  end
  if action == "apply" then
    self:take_snippet(snippet)
    self:say(I18n.t("updated on another device"))
  else
    -- A second save from over there while the question is open replaces
    -- the first: "theirs" is always their latest.
    self.conflict = snippet
    self:say(I18n.t("saved on another device: choose which version to keep"), "warn")
    UI.modalReset("pg:conflict")
  end
  self:list()
  -- The effect: a burst over the code and a chime, so a change that arrived
  -- from nowhere visible is seen to arrive.
  local r = self.code_rect
  if self.fx and r then
    self.fx:burst(r.x + r.w / 2, r.y + math.min(r.h / 2, 80), 36, Theme.coin)
  end
  SFX.play("coin")
end

function Playground:new_snippet()
  self.pad_serial = self.pad_serial + 1
  self.snippet_id = nil
  self.name = nil
  self.editor:set_text(STARTER[self.lang])
  self.editor.dirty = false
  self.result = nil
  self.log = nil
  self:say(I18n.t("a fresh page"))
  SFX.play("select")
end

function Playground:toggle_lang()
  for i, lang in ipairs(LANGS) do
    if lang == self.lang then
      self.lang = LANGS[i % #LANGS + 1]
      break
    end
  end
  -- Only swap the starter into a buffer nobody has touched; somebody's Rust
  -- must not vanish because they looked at what Go does.
  if not self.editor.dirty then
    self.editor:set_text(STARTER[self.lang])
    self.editor.dirty = false
  end
  self:say(Land.name(self.lang))
  SFX.play("move")
end

-- --------------------------------------------------------------------- run

function Playground:on_stage(payload)
  if self.attempt_id and payload.attempt_id ~= self.attempt_id then return end
  self.attempt_id = payload.attempt_id
  self.stage = payload.stage
  self.elapsed_ms = payload.elapsed_ms or 0
end

function Playground:on_log(payload)
  if not self.log or (self.log.attempt_id and payload.attempt_id ~= self.log.attempt_id) then
    self.log = runlog.new(payload.attempt_id)
  end
  self.log:add(payload)
end

function Playground:run()
  if self.running then return end
  self.running = true
  self.result = nil
  self.log = nil
  self.attempt_id = nil
  self.stage = "queued"
  self.elapsed_ms = 0
  self.note = nil
  self.problem = nil
  self.out_scroll = 0
  SFX.play("submit")

  self.app.session:request("playground.run", {
    lang = self.lang,
    source = self.editor:text(),
    stdin = self.stdin,
  }, function(ok, payload, why)
    self.running = false
    self.stage = nil
    if not ok then
      -- Still not the failure register: a refusal is about the request, not
      -- about the program.
      self.note = why.player
      self:tell_agent_run(nil)
      self:drain_run_again()
      return
    end
    self.result = payload.run
    -- The log streamed in pinned to its tail; the answer is read from the
    -- top, and scrolling back up after every RUN was the chore.
    self.out_to_top = true
    -- The output header flashes for a moment: green when it ran, the danger
    -- colour when the build did not go through, gold for the rest.
    local outcome = payload.run and payload.run.outcome
    self.ran_tint = outcome == "ok" and Theme.green
      or outcome == "compile_error" and Theme.bad or Theme.gold
    Juice.trigger("pg:ran")
    -- An old computer has its own words for a run that did not finish, and
    -- puts them up on the tube for a few seconds. The scene's own words stay
    -- the terminal's (`OUTCOME`); these are the machine's, and live with it.
    if self.retro then
      self.retro:say(Computer.says(Computer.get(), payload.run and payload.run.outcome))
    end
    -- No accepted/rejected chime either way. Nothing was judged.
    SFX.play("move")
    self:tell_agent_run(payload.run)
    self:drain_run_again()
  end)
end

--- The run AUTO-RUN queued while one was out, now that it is back.
function Playground:drain_run_again()
  if not self.run_again then return end
  self.run_again = false
  if self.conflict then return end
  self:run()
end

--- ENTER in the editor, with AUTO-RUN on. A run already out is not
--- interrupted; one more follows it, for the code as it is by then.
function Playground:auto_enter()
  if not Playground.PREFS.auto_run or self.conflict then return end
  if self.running then self.run_again = true else self:run() end
end

--- AUTO-RUN or STDERR, flipped.
function Playground:toggle_pref(which)
  local prefs = Playground.PREFS
  prefs[which] = not prefs[which]
  if which == "stderr" then self.out_scroll = 0 end
  Store.set_pg_prefs(prefs)
  SFX.play("select")
end

--- What each switch says: the state it is **in**, like every toggle here.
function Playground.auto_label()
  return Playground.PREFS.auto_run and I18n.t("AUTO-RUN ON") or I18n.t("AUTO-RUN OFF")
end

function Playground.stderr_label()
  return Playground.PREFS.stderr and I18n.t("STDERR ON") or I18n.t("STDERR OFF")
end

--- Whether the output pane shows stderr (and the compiler's notes) for
--- `result`: with STDERR on, always; off, only for a build that failed,
--- where the compiler's words are the whole answer. The browser's
--- `loud = showStderr || r?.outcome === "compile_error"`.
function Playground.loud(result)
  return Playground.PREFS.stderr == true
    or (result ~= nil and result.outcome == "compile_error")
end

--- One step of the code's type size, down or up: the F-key's cycle, as two
--- buttons for a screen with no F-keys. `Layout.setFont` keeps the step.
function Playground:size_font(dir)
  local step = (Layout.font or 1) + dir
  if not Layout.FONT_STEPS[step] then return end
  Layout.setFont(step)
  self:say("type size " .. Layout.fontLabel())
  SFX.play("select")
end

-- ------------------------------------------------------- the old computers

--- The machine's name on its button. "NORMAL" is a word, so it is translated;
--- the others are names, so they are not.
function Playground.computer_label()
  local c = Computer.get()
  return Computer.NAME[c] or I18n.t("NORMAL")
end

--- Every label the COMPUTER button can wear, so it is sized for the widest.
function Playground.computer_labels()
  local out = { I18n.t("NORMAL") }
  for _, c in ipairs(Computer.COMPUTERS) do
    if Computer.NAME[c] then out[#out + 1] = Computer.NAME[c] end
  end
  return out
end

--- Which old computer the pad is on (`src/computer.lua`): its paper, its
--- face, its tube and its room, all at once, with the power-on to show it.
---
--- The face goes with the machine because a green-phosphor Apple in Iosevka
--- is a costume, not a computer -- and it stays a face the person can change
--- after, on the button beside this one. "Normal" leaves the face alone, and
--- so does a machine whose face this client does not carry.
function Playground:cycle_computer()
  local next_computer = Computer.next()
  local face = Computer.FACE[next_computer]
  if face and Assets.CODE_FACE_NAME[face] then
    Assets.setCodeFace(face)
    Store.set_face(face)
  end
  Computer.set(next_computer)
  Store.set_computer(next_computer)
  self.retro = self.retro or RetroScreen.new()
  self.retro:power(next_computer, true)
  self:say(I18n.t("computer %s"):format(Playground.computer_label()))
  SFX.play(next_computer == "normal" and "select" or "coin")
end

--- The code pane's colours: the machine's, on an old computer, or the
--- theme's. Read once per draw, and never written back into `Theme` -- the
--- quest screen shares those tables and is never a machine.
function Playground.palette()
  local p = Computer.PALETTE[Computer.get()]
  if p then return p.code, p.pane end
  return Theme.code, Theme.pane
end

--- The coder asked for the RUN it is watching; hand it the report exactly
--- once. The button's own run answers nobody, which is why this is a
--- separate call rather than something the callback always does.
function Playground:tell_agent_run(report)
  local done = self.agent_run_done
  self.agent_run_done = nil
  if done then done(report) end
end

function Playground:tell_agent_format(report)
  local done = self.agent_format_done
  self.agent_format_done = nil
  if done then done(report) end
end

function Playground:format()
  if not self.editor or self.formatting or self.format_unsupported then return end
  self.formatting = true
  self.note = nil
  self.problem = nil
  self.app.session:request("code.format", {
    lang = self.lang,
    source = self.editor:text(),
  }, function(ok, payload, why)
    self.formatting = false
    if not ok then
      if payload.code == "not_found" then
        self.format_unsupported = true
        self:say(I18n.t("FORMAT is not on this server yet"), "warn")
      else
        self.note = why.player
      end
      self:tell_agent_format({ changed = false, problem = self.note })
      return
    end
    if payload.problem and payload.problem ~= "" then
      self.problem = payload.problem
      self:tell_agent_format({ changed = false, problem = payload.problem })
      return
    end
    if payload.changed == false then
      self:say(I18n.t("already tidy"))
      self:tell_agent_format({ changed = false })
      return
    end
    self.editor:replace_all(payload.source or self.editor:text())
    self:say("formatted", "good")
    self:tell_agent_format({ changed = true })
  end)
end

function Playground:update(dt)
  self.t = self.t + dt
  if self.fx then self.fx:update(dt) end
  if self.retro then self.retro:update(dt) end
  if self.coder then
    -- The whole screen is the coder's sky, minus whatever the panel took.
    self.coder:fly({ 0, 0, Layout.vw, Layout.vh }, self.agent_rect)
    self.coder:update(dt)
  end
  if self.editor then self.editor.lang = self.lang end
  if self.running then self.elapsed_ms = self.elapsed_ms + dt * 1000 end

  -- Autosave. The contract says `playground.save` is cheap and idempotent, so
  -- the only thing this has to avoid is sending on every keystroke.
  if self.editor and self.editor.dirty then
    self.dirty_at = self.dirty_at or Anim.now()
    if Anim.now() - self.dirty_at >= Playground.AUTOSAVE_S then
      self:save()
    end
  end
end

-- ------------------------------------------------------------------ drawing
--
-- The chrome is the kit's (`docs/love2d-ui.md`): a header bar, one toolbar
-- band of measured buttons under it, then cards — the pads' list, the
-- editor with its code well and STDIN well, and the output with its own
-- header — inside `UI.bounded()`. CODE is the same toolbar over an editor
-- that takes the full width. The code itself is the hero and the chrome
-- recedes; what moves is the kit's motion (a lifted button, a pressed one,
-- a toast) and nothing in the code pane except the caret.

--- The header band: the kit's height (`App:toast_top` reads this).
function Playground:header_h()
  return UI.headerHeight()
end

--- Say something briefly: a toast, and the status line keeps the words for
--- the pane. Guarded, because the headless suites hand the scene an app
--- with no dock.
function Playground:say(text, kind)
  if self.app and self.app.toast then
    self.app:toast(text, nil, kind)
  else
    self.note = text
  end
end

--- Whether the status line has anything to say beyond the file: a note, or
--- a field that is open on it. The bench draws it only then; CODE, which
--- has no card header to name the file, always does.
function Playground:status_live()
  return self.note ~= nil or self.focus == "stamp" or self.focus == "disk" or self.focus == "name"
end

--- The footer's hints, in priority order: the footer keeps the longest
--- prefix that fits, so the key somebody needs most is first.
function Playground:hints()
  local items = UI.parseHint(I18n.t("F5 run   F2 format   TAB lang   CTRL-S save   CTRL-N new   ESC back"))
  local rank = { F5 = 1, F2 = 2, ["CTRL-S"] = 3, ESC = 4, TAB = 5, ["CTRL-N"] = 6 }
  table.sort(items, function(a, b)
    return (rank[a.key] or 9) < (rank[b.key] or 9)
  end)
  return items
end

--- The room: the machine's own, until it has arrived, then the usual one,
--- under the felt. An old computer's room is lit by its screen and is the
--- point of it, so less of the night is pulled over it.
function Playground:draw_room()
  local vw, vh = Layout.vw, Layout.vh
  local portrait = Layout.isPortrait()
  local mine, mine_wide = Computer.room(Computer.get(), portrait)
  local name = Assets.pick(mine or "", mine_wide or "",
    portrait and "bg_playground_p" or "bg_playground",
    "bg_playground", "bg_datacentre", "bg_flat")
  Assets.cover(name, 0, 0, vw, vh)
  local scrim = portrait and 0.8 or 0.72
  if mine and Assets.image(mine) or (mine_wide and Assets.image(mine_wide)) then
    scrim = 0.4
  end
  UI.setColor(Theme.felt, scrim)
  love.graphics.rectangle("fill", 0, 0, vw, vh)
  love.graphics.setColor(1, 1, 1, 1)
end

--- Which machine the pad is on, or nil on NORMAL.
local function machine_on()
  local c = Computer.get()
  return Computer.NAME[c] and c or nil
end

--- What the file chip says: the file, and the pad's name when it has one.
function Playground:file_label()
  local file = ({ rust = "main.rs", go = "main.go", cpp = "main.cpp", python = "main.py",
    pytorch = "main.py", typescript = "main.ts", zig = "main.zig", lua = "main.lua" })[self.lang]
    or "main"
  if self.focus == "name" then return (self.name_edit or "") .. "_" end
  local name = self.name and tostring(self.name) or I18n.t("unsaved")
  return file .. " · " .. name
end

--- The header bar. `view` is `"bench"` or `"code"`: CODE puts DONE on the
--- left. On the right, measured first so the title gives way: the language
--- chip with its TAB keycap, and the machine chip, gold when a machine is
--- on. The title is cut to what is left, never printed through.
function Playground:draw_header(view)
  local vw = Layout.vw
  local h = self:header_h()
  local g = Layout.gutter()
  UI.card(0, 0, vw, h, { variant = "bar", pad = 0 })
  UI.setColor(Theme.edge, 0.6)
  love.graphics.rectangle("fill", 0, h - 2, vw, 2)
  love.graphics.setColor(1, 1, 1, 1)

  local chip_h = Theme.control.chip
  local cy = math.floor((h - chip_h) / 2)
  local x = g
  self.done_rect = nil
  if view == "code" then
    local label = I18n.t("DONE")
    local bw, bh = UI.buttonSize(label, { key = "ESC" })
    bh = math.max(Theme.control.buttonM, bh)
    local r = { x = x, y = math.floor((h - bh) / 2), w = bw, h = bh }
    UI.button(r.x, r.y, r.w, r.h, label, self.hover == "done" and "hot" or "normal", nil,
      { variant = "secondary", id = "pg:done", key = "ESC" })
    self.done_rect = r
    x = x + bw + Theme.space.lg
  end

  -- The right block, laid right to left.
  local right = vw - g
  local lang = Land.name(self.lang)
  local lw = UI.chipWidth(lang)
  local lx = right - lw
  UI.chip(lx, cy, lang, { selected = true, hot = self.hover == "lang" })
  self.lang_rect = { x = lx, y = cy, w = lw, h = chip_h }
  local kw = UI.keycapWidth("TAB")
  local kx = lx - Theme.space.sm - kw
  UI.keycap(kx, cy + math.floor((chip_h - Theme.control.keycap) / 2), "TAB")
  right = kx - Theme.space.lg
  local machine = machine_on()
  local mlabel = Playground.computer_label()
  local mw = UI.chipWidth(mlabel)
  if right - mw > x + 120 then
    UI.chip(right - mw, cy, mlabel, { selected = machine ~= nil, hot = self.hover == "computer" })
    self.machine_rect = { x = right - mw, y = cy, w = mw, h = chip_h }
    right = right - mw - Theme.space.lg
  else
    self.machine_rect = nil
  end

  -- The title, then the file chip in what is left.
  local title = I18n.t("PLAYGROUND")
  local room = right - x
  local tw = math.min(UI.labelWidth(title, "title"), room)
  UI.label(title, x, math.floor((h - UI.lead("title")) / 2), "title",
    { width = room, ellipsis = true })
  local fx = x + tw + Theme.space.lg
  local flabel = self:file_label()
  local fw = UI.chipWidth(flabel)
  self.name_rect = nil
  if fx + fw <= right then
    UI.chip(fx, cy, flabel, { hot = self.focus == "name" or self.hover == "name" })
    if self.editor and self.editor.dirty and self.focus ~= "name" then
      UI.setColor(Theme.gold)
      love.graphics.circle("fill", fx + fw + 6, cy + chip_h / 2, 3, 8)
      love.graphics.setColor(1, 1, 1, 1)
    end
    self.name_rect = { x = fx, y = cy, w = fw, h = chip_h }
  end
end

--- The status line under the toolbar: the file, the name, whether it is
--- safe on the server, and the last note — or the key field / the path
--- field while one is open. One line, cut with "…".
function Playground:draw_status(x, y, w)
  local info = self:file_label()
  if self.editor and self.editor.dirty then info = info .. "  ·" end
  local color = Theme.mute
  if self.focus == "stamp" then
    info = ("%s   %s_"):format(I18n.t("POSTER"), (self.stamp_edit or ""):gsub("%S", "*"))
    color = Theme.gold
  elseif self.focus == "disk" then
    info = ("%s   %s_"):format(I18n.t("DISK READER"), self.disk_edit or "")
    color = Theme.gold
  elseif self.focus == "name" then
    color = Theme.gold
  elseif self.note then
    info = info .. "   " .. tostring(self.note)
  end
  UI.label(info, x, y, "label", { color = color, width = w, ellipsis = true })
  return UI.lead("label")
end

--- The STDIN well: the label at the left, the text after it; real lines
--- when there is height for them. `stdin_rect` is the hit target.
function Playground:draw_stdin(x, y, w, h)
  local hot = self.focus == "stdin"
  UI.card(x, y, w, h, { variant = "well", pad = 0, edge = hot and Theme.gold or nil })
  local label = I18n.t("STDIN")
  local pad = Theme.space.md
  local lead = UI.lead("label")
  local font = Assets.mono(Layout.codeSize(16))
  local stacked = h >= lead + font:getHeight() + pad * 2
  local tx, ty
  if stacked then
    UI.label(label, x + pad, y + Theme.space.sm, "label", { color = Theme.mute, caps = true })
    tx, ty = x + pad, y + Theme.space.sm + lead + 2
  else
    UI.label(label, x + pad, y + math.floor((h - lead) / 2), "label", { color = Theme.mute, caps = true })
    tx, ty = x + pad + UI.labelWidth(label, "label") + pad, y + math.floor((h - font:getHeight()) / 2)
  end
  love.graphics.setFont(font)
  UI.setColor(Theme.text)
  love.graphics.setScissor(x + 2, y + 1, math.max(0, w - 4), math.max(0, h - 2))
  if stacked then
    local lh = font:getHeight()
    local yy = ty
    local text = (self.stdin or "") .. (hot and "_" or "")
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if yy + lh > y + h - 4 then break end
      love.graphics.print(line, tx, yy)
      yy = yy + lh
    end
  else
    local shown = (self.stdin or ""):gsub("\n", "⏎")
    if hot then shown = shown .. "_" end
    love.graphics.print(shown, tx, ty)
  end
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)
  self.stdin_rect = { x = x, y = y, w = w, h = h }
end

--- The bench's arrangement — one function, read by the draw and by the
--- click. Returns the code, output and list rects, and the band the
--- toolbar takes.
function Playground:panes()
  local portrait = Layout.isPortrait()
  local header = self:header_h()
  -- The code is the hero: on a wide canvas the bench takes a wider bound
  -- than the kit's default, so the editor gets the room a 1920 screen has
  -- rather than 340 px of street each side.
  local wide = Layout.vw >= Theme.wideCanvas
  local cx, cy, cw, ch = UI.bounded(wide and Playground.WIDE_BOUND or nil, header + Theme.space.lg,
    Layout.vh - UI.footerHeight() - Theme.space.lg)
  local tools_h = self:tools_h("bench", cw)
  local status_h = self:status_live() and (Theme.space.sm + UI.lead("label")) or 0
  local band = { x = cx, y = cy, w = cw, h = tools_h + status_h }
  local top = cy + band.h + Theme.space.md
  local h = math.max(0, cy + ch - top)
  local gap = Theme.gap
  if portrait then
    -- Stacked, the browser's way: the pads on top, then the bench, then
    -- the output. The list is as tall as what it holds, up to three pads,
    -- never more than three tenths; the code gets most of the rest.
    local row = Theme.control.chip + Theme.space.xs
    local shown = math.max(1, math.min(3, #(self.snippets or {})))
    -- Upright the list is compact: its buttons share the title row.
    local need = Theme.space.md + Playground.tool_h() + Theme.space.sm
      + (self:searchable() and (Theme.control.chip + Theme.space.sm) or 0)
      + shown * row + Theme.space.sm
    local list_h = math.min(math.floor(h * 0.3), need)
    local rest = h - list_h - gap * 2
    -- The output is a drawer: a quarter until something has run, then
    -- two fifths, so the compiler's answer can be read without CODE.
    local has_out = (self.result ~= nil) or (self.log ~= nil) or self.running
    local code_h = math.floor(rest * (has_out and 0.6 or 0.75))
    return
      { x = cx, y = top + list_h + gap, w = cw, h = code_h },
      { x = cx, y = top + list_h + gap + code_h + gap, w = cw, h = rest - code_h },
      { x = cx, y = top, w = cw, h = list_h },
      band
  end
  local list_w = wide and 300 or math.max(200, math.min(240, math.floor(cw * 0.2)))
  local out_w = wide and 420 or math.floor((cw - list_w - gap * 2) * 0.32)
  local code_w = cw - list_w - out_w - gap * 2
  return
    { x = cx + list_w + gap, y = top, w = code_w, h = h },
    { x = cx + list_w + gap + code_w + gap, y = top, w = out_w, h = h },
    { x = cx, y = top, w = list_w, h = h },
    band
end

--- The bench's bound on a wide canvas (`Theme.wideCanvas` and up): the
--- gutters and little else.
Playground.WIDE_BOUND = 1760

--- The code's pixel size for a glass `h` tall: the type step's size, and on
--- a wide canvas never drawn under `WIDE_CODE_PX` -- 16 px code beside 24 px
--- button labels read as a footnote. Asked of the face's own scale
--- (`Assets.CODE_FACE_SCALE`), so an outline face lands on 18 real pixels
--- and a pixel face snaps to its grid as it always did.
Playground.WIDE_CODE_PX = 18

function Playground.code_px(h)
  local size = Layout.codeSizeFor(18, h, 6)
  if Layout.vw >= Theme.wideCanvas then
    local scale = Assets.CODE_FACE_SCALE[Assets.codeFace()] or 1
    size = math.max(size, math.ceil(Playground.WIDE_CODE_PX / scale))
  end
  return size
end

function Playground:draw()
  if self.big then self:draw_big() else self:draw_bench() end
  if self.conflict then self:draw_conflict() end
end

--- "Saved on another device -- which one?", a modal until answered.
---
--- Modal on purpose: the keys and the pointer go to the two answers and to
--- nothing else (`keypressed`, `textinput`, `mousepressed`), because an
--- editor that can still be typed into while the question is open makes the
--- answer out of date as it is given.
function Playground:draw_conflict()
  local body = I18n.t("This pad was just saved on another device, and you have unsaved changes here. Take the other device's version, or keep yours and save it over theirs?")
  local portrait = Layout.isPortrait()
  local w = portrait and (Layout.vw - Theme.space.lg * 2) or 620
  local pad = portrait and Theme.space.lg or Theme.space.xl
  local inner = w - pad * 2
  local theirs_l, mine_l = I18n.t("TAKE THEIRS  T"), I18n.t("KEEP MINE  K")
  local tw, bh = UI.buttonSize(theirs_l)
  local mw = UI.buttonSize(mine_l)
  bh = math.max(Theme.control.buttonM, bh)
  local body_h = UI.readHeight(body, inner)
  local x, y, cw, _, _, sheet = UI.modal({ id = "pg:conflict", title = I18n.t("SAVED ON ANOTHER DEVICE"),
    w = w, h = body_h + Theme.space.lg + bh * 2 + Theme.space.sm })
  y = y + UI.read(body, x, y, cw) + Theme.space.lg
  local gap = Theme.space.md
  local bw = math.floor((cw - gap) / 2)
  local stacked = tw > bw or mw > bw
  local theirs, mine
  if stacked then
    theirs = { x = x, y = y, w = cw, h = bh }
    mine = { x = x, y = y + bh + Theme.space.sm, w = cw, h = bh }
  else
    theirs = { x = x, y = y, w = bw, h = bh }
    mine = { x = x + bw + gap, y = y, w = bw, h = bh }
  end
  -- The sheet was measured for one row; a second row stays inside it
  -- because the modal clamps its height to the window, not to the rows.
  if sheet and mine.y + mine.h > sheet.y + sheet.h - pad then
    mine.y = sheet.y + sheet.h - pad - bh
    theirs.y = mine.y - Theme.space.sm - bh
  end
  UI.button(theirs.x, theirs.y, theirs.w, theirs.h, theirs_l, "normal", nil,
    { variant = "primary", id = "pg:theirs" })
  UI.button(mine.x, mine.y, mine.w, mine.h, mine_l, "normal", nil,
    { variant = "secondary", id = "pg:mine" })
  self.conflict_rects = { theirs = theirs, mine = mine }
end

--- The felt behind the header and the toolbar when a machine is on, so the
--- MSX's room never sits under a label.
function Playground:draw_band_scrim(bottom)
  if not machine_on() then return end
  UI.setColor(Theme.felt, 0.85)
  love.graphics.rectangle("fill", 0, 0, Layout.vw, bottom)
  love.graphics.setColor(1, 1, 1, 1)
end

function Playground:draw_bench()
  self:draw_room()
  local code, out, list, band = self:panes()
  self:draw_band_scrim(band.y + band.h + Theme.space.sm)
  self:draw_header("bench")

  local tools_h, rects = self:draw_tools(band.x, band.y, band.w, "bench")
  self.bench_rects = rects
  self.big_rects = nil
  -- The rects the drives and the old hit test know by name.
  self.code_button_rect = rects.code
  self.rename_rect = rects.rename
  self.poster_rect = rects.poster
  self.reader_rect = rects.reader
  self.agent_button_rect = rects.agent
  if self:status_live() then
    self:draw_status(band.x, band.y + tools_h + Theme.space.sm, band.w)
  end

  if list.h > 0 then self:draw_snippets(list) end
  self:draw_code(code, false)
  self:draw_output(out)

  if self.fx then self.fx:draw() end
  -- **The room is not a sliver.** The panel takes the code and output panes
  -- together and the list stays where it is.
  local body = {
    x = code.x,
    y = math.min(code.y, out.y),
    w = out.x + out.w - code.x,
    h = math.max(code.y + code.h, out.y + out.h) - math.min(code.y, out.y),
  }
  self:draw_agent(body, not Layout.isPortrait())
  self.app:footer(self:hints())
end

--- Every label the CODE screen's language button can wear: each language's
--- name (`Land.LANGS`, the list TAB walks), so the button is as wide as the
--- longest of them and every language is drawn at the same size.
function Playground.lang_labels()
  local out = {}
  for i, lang in ipairs(LANGS) do out[i] = Land.name(lang) end
  return out
end

--- How wide a legacy-sized button is at authored size `at`: its widest
--- label plus the padding. The toolbar measures in the label role now
--- (`Playground.tool_w`); this is kept for `tests/test_playground.lua`.
function Playground.button_w(labels, at)
  local w = 0
  for _, label in ipairs(labels) do w = math.max(w, UI.textWidth(label, at) + 16) end
  return w
end

--- CODE: the editor and the toolbar, and nothing else. Full width.
function Playground:draw_big()
  local vw, vh = Layout.vw, Layout.vh
  self:draw_room()
  local g = Layout.gutter()
  local x, w = g, vw - g * 2
  local y = self:header_h() + Theme.space.md
  local tools_h = self:tools_h("code", w)
  local status_h = UI.lead("label")
  self:draw_band_scrim(y + tools_h + Theme.space.sm + status_h + Theme.space.sm)
  self:draw_header("code")

  local _, rects = self:draw_tools(x, y, w, "code")
  self.big_rects = rects
  self.bench_rects = nil
  self:draw_status(x, y + tools_h + Theme.space.sm, w)
  local top = y + tools_h + Theme.space.sm + status_h + Theme.space.md

  -- **Beside the code when the window is wide, under it when it is tall.**
  -- Input and output keep each other company across the short axis: wide,
  -- the output is a column beside the code and stdin sits at the top of it;
  -- tall, the output is a band under the code and stdin takes the left of
  -- it. Nothing run yet: stdin is a strip under the code.
  local has_out = (self.result ~= nil) or (self.log ~= nil) or self.running
  local wide = not Layout.isPortrait()
  local gap = Theme.gap
  local body_h = vh - top - UI.footerHeight() - Theme.space.lg
  local fed_h = Theme.control.buttonM
  if has_out and wide then
    local out_w = math.floor(w * 0.36)
    local ox = x + w - out_w
    local in_h = math.max(fed_h, math.floor(body_h * 0.26))
    self:draw_code({ x = x, y = top, w = w - out_w - gap, h = body_h }, true)
    self:draw_stdin(ox, top, out_w, in_h)
    self:draw_output({ x = ox, y = top + in_h + Theme.space.sm, w = out_w, h = body_h - in_h - Theme.space.sm })
  elseif has_out then
    local band_h = math.max(fed_h, math.floor(body_h * 0.3))
    local by = top + body_h - band_h
    local in_w = math.floor(w * 0.4)
    self:draw_code({ x = x, y = top, w = w, h = body_h - band_h - gap }, true)
    self:draw_stdin(x, by, in_w, band_h)
    self:draw_output({ x = x + in_w + Theme.space.sm, y = by, w = w - in_w - Theme.space.sm, h = band_h })
  else
    self:draw_code({ x = x, y = top, w = w, h = body_h - fed_h - Theme.space.sm }, true)
    self:draw_stdin(x, top + body_h - fed_h, w, fed_h)
    self.out_rect = nil
  end

  if self.fx then self.fx:draw() end
  self:draw_agent({ x = x, y = top, w = w, h = body_h }, wide)
  self.app:footer(self:hints())
end

--- The coder's panel, and then the coder itself.
---
--- **The sprite is drawn last, after every pane and after the panel.** LÖVE
--- has no z-index; a thing is on top of the interface by being painted after
--- it, and the whole point of this character is that it flies over the code.
---
--- The panel takes the short axis the way the browser's does: a column on the
--- right of a wide window, a band across the foot of a tall one, so the
--- editor gives up one dimension and not two.
function Playground:draw_agent(body, wide)
  self.agent_rect = nil
  if not self.coder then return end
  if self.coder.panel.open then
    local rect
    if wide then
      local w = math.max(320, math.floor(body.w * 0.52))
      rect = { x = body.x + body.w - w, y = body.y, w = w, h = body.h }
    else
      local h = math.max(240, math.floor(body.h * 0.52))
      rect = { x = body.x, y = body.y + body.h - h, w = body.w, h = h }
    end
    self.agent_rect = rect
    self.coder:draw_panel(rect)
  end
  self.coder:draw()
end

--- The pads' list: a card with the search well, a row per pad with its
--- land's stripe, and NEW / RENAME / DELETE at the foot.
function Playground:draw_snippets(rect)
  local focused = self.focus == "snippets"
  UI.card(rect.x, rect.y, rect.w, rect.h, { pad = 0, strip = focused and Theme.gold or nil })
  local pad = Theme.space.md
  local x, w = rect.x + pad, rect.w - pad * 2
  local y = rect.y + pad + (focused and Theme.stripH or 0)
  local lead = UI.lead("label")
  -- The buttons: NEW, RENAME, and DELETE only while a saved pad is open.
  -- Upright they share the title row, so the list is as short as what it
  -- holds; on the bench they are the foot of the card.
  local items = {
    { id = "new", label = I18n.t("NEW") },
    { id = "rename", label = I18n.t("RENAME") },
  }
  if self.snippet_id then items[#items + 1] = { id = "delete", label = I18n.t("DELETE") } end
  local bh = Playground.tool_h()
  local gap = Theme.space.sm
  local widths, total = {}, 0
  for i, item in ipairs(items) do
    widths[i] = math.ceil((UI.buttonSize(item.label)))
    total = total + widths[i]
  end
  total = total + gap * (#items - 1)
  local title = I18n.t("SNIPPETS")
  local title_w = UI.labelWidth(title, "label")
  local beside = Layout.isPortrait() and total + title_w + Theme.space.lg <= w
  self.list_rects = {}
  local function button(item, r)
    UI.button(r.x, r.y, r.w, r.h, item.label,
      self.hover == "list:" .. item.id and "hot" or "normal", nil,
      { id = "pg:list:" .. item.id, variant = item.id == "delete" and "danger" or "secondary" })
    self.list_rects[item.id] = r
  end
  local foot_y
  if beside then
    UI.label(title, x, y + math.floor((bh - lead) / 2), "label", { color = Theme.mute, caps = true })
    local bx = x + w - total
    for i, item in ipairs(items) do
      button(item, { x = bx, y = y, w = widths[i], h = bh })
      bx = bx + widths[i] + gap
    end
    y = y + bh + Theme.space.sm
    foot_y = rect.y + rect.h - pad
  else
    UI.label(title, x, y, "label", { color = Theme.mute, caps = true, width = w, ellipsis = true })
    y = y + lead + Theme.space.sm
    local across = total <= w
    local rows_of = across and 1 or #items
    local foot_h = rows_of * bh + (rows_of - 1) * gap
    foot_y = rect.y + rect.h - pad - foot_h
    if foot_y > y then
      local bx, by = x, foot_y
      for i, item in ipairs(items) do
        local bw = across and widths[i] or w
        button(item, { x = bx, y = by, w = bw, h = bh })
        if across then bx = bx + bw + gap else by = by + bh + gap end
      end
    else
      foot_y = rect.y + rect.h - pad
    end
  end

  -- The search well, once there are enough pads to be worth hunting through.
  self.find_rect = nil
  if self:searchable() then
    local fh = Theme.control.chip
    local hot = self.focus == "find"
    UI.card(x, y, w, fh, { variant = "well", pad = 0, edge = hot and Theme.gold or nil })
    local shown = (self.query or "") ~= "" and self.query or I18n.t("SEARCH")
    if hot then shown = (self.query or "") .. "_" end
    UI.label(shown, x + Theme.space.sm, y + math.floor((fh - lead) / 2), "label",
      { color = (self.query or "") ~= "" and Theme.text or Theme.mute, width = w - Theme.space.sm * 2, ellipsis = true })
    self.find_rect = { x = x, y = y, w = w, h = fh }
    y = y + fh + Theme.space.sm
  end

  -- The rows scroll to keep the cursor in view.
  local row = Theme.control.chip + Theme.space.xs
  local hits = self:visible_snippets()
  local room = math.max(0, math.floor((foot_y - Theme.space.sm - y) / row))
  local at = 1
  for k, hit in ipairs(hits) do
    if hit.index == self.cursor then at = k end
  end
  local first = math.max(1, math.min(at - room + 1, #hits - room + 1))
  self.snippet_rects = {}
  local shown_n = 0
  for k = first, math.min(#hits, first + room - 1) do
    local i, brief = hits[k].index, hits[k].brief
    local here = brief.id == self.snippet_id
    local under = focused and i == self.cursor
    local hot = self.hover == "pad:" .. i
    local a = Juice.follow("pg:pad" .. i, (hot or under) and 1 or 0, { speed = 18 })
    local fill = here and Theme.cardHi or Theme.bar
    if a > 0 then fill = Theme.mix(fill, Theme.cardHi, a) end
    UI.setColor(fill)
    UI.rrect("fill", x, y, w, row - Theme.space.xs, Theme.radiusInner)
    if under or here then
      UI.stroke(x, y, w, row - Theme.space.xs, Theme.radiusInner, under and Theme.gold or Theme.edge)
    end
    -- The land's colour along the left edge, the browser's way.
    UI.setColor(Theme.land[brief.lang] or Theme.mute, 0.9)
    UI.rrect("fill", x, y, 6 + Theme.radiusInner, row - Theme.space.xs, Theme.radiusInner)
    UI.setColor(fill)
    love.graphics.rectangle("fill", x + 6, y, Theme.radiusInner, row - Theme.space.xs)
    local initial = tostring(brief.lang):sub(1, 1):upper()
    local iw = UI.labelWidth(initial, "label")
    local label = tostring(brief.name or brief.id)
    local ty = y + math.floor((row - Theme.space.xs - lead) / 2)
    UI.label(label, x + 6 + Theme.space.sm, ty, "label",
      { color = here and Theme.gold or Theme.text, width = w - 6 - Theme.space.sm * 3 - iw, ellipsis = true })
    UI.label(initial, x + w - Theme.space.sm - iw, ty, "label", { color = Theme.mute })
    self.snippet_rects[i] = { x = x, y = y, w = w, h = row - Theme.space.xs }
    y = y + row
    shown_n = shown_n + 1
  end
  love.graphics.setColor(1, 1, 1, 1)
  if #hits > room and room > 0 then
    UI.scrollbar(rect.x + rect.w - pad - 6, y - shown_n * row, shown_n * row,
      room / #hits, (first - 1) / math.max(1, #hits - room), { alpha = 0.7 })
  end
  local empty
  if not self.snippets then
    empty = "…"
  elseif #self.snippets == 0 then
    empty = I18n.t("nothing saved yet")
  elseif #hits == 0 then
    empty = I18n.t("no pad by that name")
  end
  if empty and y + lead <= foot_y then
    local font = UI.font("label")
    local lines = UI.wrapWith(empty, w, font)
    for i, line in ipairs(lines) do
      if y + i * lead > foot_y then break end
      UI.label(line, x, y + (i - 1) * lead, "label", { color = Theme.mute })
    end
  end
end

--- The editor.
---
--- On the bench it is a card: a header row with the file, the name and the
--- count, the code well, and the STDIN well under it. In CODE (`bare`) the
--- well takes the rect and CODE draws stdin itself. On an old computer the
--- card gives way to the machine's monitor, which takes the code rows, and
--- the STDIN well stays the game's under it.
function Playground:draw_code(rect, bare)
  local machine = machine_on()
  local code_c, pane_c = Playground.palette()
  local pad = Theme.space.md
  local lead = UI.lead("label")
  local head_h = bare and 0 or (lead + Theme.space.lg)
  local fed_h = bare and 0 or Theme.control.buttonM
  -- The code is served first: a pane too short for a monitor is a plain
  -- well, and a pane too short for the STDIN well drops it.
  local strip = bare and 0 or (fed_h + Theme.space.sm)
  if not bare and rect.h - head_h - strip < 3 * lead then strip = 0; fed_h = 0 end
  if machine and rect.h - head_h - strip < 90 then
    machine = nil
    code_c, pane_c = Theme.code, Theme.pane
  end

  local area
  if machine then
    -- The monitor takes the card's place over the code rows; the strip
    -- under them stays the game's.
    area = Monitor.draw({ x = rect.x, y = rect.y, w = rect.w, h = rect.h - strip }, machine, self.t, self.running)
    if fed_h > 0 then
      self:draw_stdin(rect.x, rect.y + rect.h - fed_h, rect.w, fed_h)
    end
  elseif bare then
    UI.card(rect.x, rect.y, rect.w, rect.h, { variant = "well", pad = 0,
      edge = self.focus == "editor" and Theme.withAlpha(Theme.gold, 0.6) or nil })
    area = { x = rect.x + 2, y = rect.y + 2, w = rect.w - 4, h = rect.h - 4 }
  else
    UI.card(rect.x, rect.y, rect.w, rect.h, { pad = 0 })
    -- The header row: the file and the name, and the size at the right.
    local hy = rect.y + Theme.space.sm
    local count = I18n.t("%d lines   %d bytes%s", self.editor:line_count(), #self.editor:text(), "")
    local cw = UI.labelWidth(count, "label")
    UI.label(count, rect.x + rect.w - pad - cw, hy, "label", { color = Theme.mute })
    local file = self:file_label()
    UI.label(file, rect.x + pad, hy, "label",
      { color = self.focus == "name" and Theme.gold or Theme.text,
        width = rect.w - pad * 3 - cw, ellipsis = true })
    if self.editor.dirty and self.focus ~= "name" then
      local fw = math.min(UI.labelWidth(file, "label"), rect.w - pad * 3 - cw)
      UI.setColor(Theme.gold)
      love.graphics.circle("fill", rect.x + pad + fw + Theme.space.sm, hy + lead / 2, 3, 8)
      love.graphics.setColor(1, 1, 1, 1)
    end
    local wy = rect.y + head_h
    local wh = rect.h - head_h - strip - pad
    UI.card(rect.x + pad, wy, rect.w - pad * 2, wh, { variant = "well", pad = 0,
      edge = self.focus == "editor" and Theme.withAlpha(Theme.gold, 0.6) or nil })
    area = { x = rect.x + pad + 2, y = wy + 2, w = rect.w - pad * 2 - 4, h = wh - 4 }
    if fed_h > 0 then
      self:draw_stdin(rect.x + pad, rect.y + rect.h - pad - fed_h + Theme.space.xs, rect.w - pad * 2, fed_h - Theme.space.xs)
    end
  end

  local font = Assets.mono(Playground.code_px(area.h - 6))
  local line_h = font:getHeight()
  -- The trailing space is not decoration: `%4d` right-aligns, so without
  -- it the last digit of the line number touches the first character of an
  -- unindented line.
  local gutter = font:getWidth("0000 ")
  local rows = math.max(1, math.floor((area.h - 6) / line_h))
  self.editor:ensure_visible(rows)
  self.editor:ensure_visible_across(function(s) return font:getWidth(s) end,
    area.w - gutter - 14 - 10)
  local shift = self.editor.scroll_x or 0
  self.visible_rows = rows
  self.code_rect = rect
  self.glass_rect = area
  self.line_h = line_h
  self.gutter = gutter
  self.mono_font = font
  -- The scrollbar shows while the page moves and fades 800 ms after.
  local now = love.timer.getTime()
  if self.editor.scroll ~= self.last_scroll then
    self.last_scroll = self.editor.scroll
    self.scrolled_at = now
  end

  area.w, area.h = math.max(0, area.w), math.max(0, area.h)
  love.graphics.setScissor(area.x, area.y, area.w, area.h)
  if pane_c.paper then
    UI.setColor(pane_c.paper)
    love.graphics.rectangle("fill", area.x, area.y, area.w, area.h)
  end
  love.graphics.setFont(font)
  -- The leftover goes above the text when the pane is scrolled, so a
  -- scrolled pane fills to its bottom edge; an unscrolled page keeps its
  -- slack at the foot.
  local slack = math.max(0, (area.h - 6) - rows * line_h)
  local x0 = area.x + 5
  local y0 = area.y + 3 + (self.editor.scroll > 0 and slack or 0)
  self.pane:frame(rect, font, gutter, x0, y0, line_h, rows)
  local state = "code"
  for i = 1, self.editor.scroll do
    _, state = Editor.highlight(self.editor.lines[i] or "", state, self.editor.lang)
  end
  local sel_l1, sel_c1, sel_l2, sel_c2 = self.editor:selection()
  local glow = pane_c.glow
  -- The caret: a soft block that breathes rather than snaps, on the game's
  -- screens; the inverse-video block every one of the three machines drew,
  -- blinking at the browser's 1.06 s, on a machine.
  local blink = (now % 1.06) < 0.6
  local caret_a = Juice.follow("pg:caret", blink and 1 or 0, { speed = 14 })
  local caret_on = self.focus == "editor" and (machine and blink or caret_a > 0.02)

  for row = 1, rows do
    local index = self.editor.scroll + row
    local line = self.editor.lines[index]
    if not line then break end
    local y = y0 + (row - 1) * line_h
    if index == self.editor.line then
      UI.setColor(pane_c.active)
      love.graphics.rectangle("fill", area.x, y, area.w, line_h)
    end
    if sel_l1 and index >= sel_l1 and index <= sel_l2 then
      local from = (index == sel_l1) and sel_c1 or 1
      local to = (index == sel_l2) and sel_c2 or (#line + 1)
      local sx = x0 + gutter - shift + font:getWidth(line:sub(1, from - 1))
      UI.setColor(pane_c.select)
      love.graphics.rectangle("fill", sx, y,
        math.max(2, font:getWidth(line:sub(from, to - 1))), line_h)
    end
    local spans
    spans, state = Editor.highlight(line, state, self.editor.lang)
    local cx = x0 + gutter - shift
    for _, span in ipairs(spans) do
      local colour = code_c[span.kind] or code_c.text or Theme.text
      if glow and not span.text:match("^%s*$") then
        love.graphics.setColor(colour[1], colour[2], colour[3], glow[4])
        love.graphics.print(span.text, cx - 1, y)
        love.graphics.print(span.text, cx + 1, y)
      end
      UI.setColor(colour)
      love.graphics.print(span.text, cx, y)
      cx = cx + font:getWidth(span.text)
    end
    -- The line numbers are a ruler: painted after the text, so a line
    -- scrolled sideways slides under them.
    UI.setColor(pane_c.gutter)
    love.graphics.rectangle("fill", area.x, y, gutter + 5, line_h)
    if pane_c.gutter_rule then
      UI.setColor(pane_c.gutter_rule)
      love.graphics.rectangle("fill", area.x + gutter + 3, y, 2, line_h)
    end
    local ink, ink_a = self.pane:gutter_color(index)
    if pane_c.gutter_ink and ink ~= Theme.brick then ink, ink_a = pane_c.gutter_ink, 1 end
    if index == self.editor.line and ink ~= Theme.brick and not pane_c.gutter_ink then
      ink, ink_a = Theme.text, 0.9
    end
    UI.setColor(ink, ink_a)
    love.graphics.print(("%4d"):format(index), x0, y)
    if index == self.editor.line and caret_on then
      local kx = x0 + gutter - shift + font:getWidth(line:sub(1, self.editor.col - 1))
      local under = line:sub(self.editor.col):match("^[%z\1-\127\194-\244][\128-\191]*") or ""
      local kw = font:getWidth(under ~= "" and under or " ")
      if machine then
        UI.setColor(pane_c.caret)
        love.graphics.rectangle("fill", kx, y, kw, line_h)
        if under ~= "" and pane_c.paper then
          UI.setColor(pane_c.paper)
          love.graphics.print(under, kx, y)
        end
      else
        UI.setColor(pane_c.caret, 0.35 * caret_a)
        love.graphics.rectangle("fill", kx, y, kw, line_h)
        UI.setColor(pane_c.caret, caret_a)
        love.graphics.rectangle("fill", kx, y, 2, line_h)
      end
    end
  end
  -- The bracket outlines read `Theme.pane.match`; on a machine that is the
  -- machine's colour for the length of this one call.
  local theme_pane = Theme.pane
  Theme.pane = pane_c
  local drew = pcall(self.pane.draw_brackets, self.pane)
  Theme.pane = theme_pane
  if not drew then self.pane:draw_brackets() end
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)
  if not machine then
    local total = #self.editor.lines
    if total > rows then
      local age = now - (self.scrolled_at or -10)
      local alpha = age < 0.8 and 1 or math.max(0.25, 1 - (age - 0.8) / 0.4)
      UI.scrollbar(area.x + area.w - 10, area.y + 4, area.h - 8, rows / total,
        self.editor.scroll / math.max(1, total - rows), { alpha = alpha })
    end
  end
  -- The tube over the glass, after the code and after the scissor.
  if self.retro then self.retro:draw(area) end
  if bare then self.run_rect, self.format_rect = nil, nil end
end

--- What the program did: a card with OUTPUT and the outcome in its header,
--- a well of what it printed, a scrollbar. Deliberately flat: one outcome
--- line, then stdout, then stderr. No banner, no verdict colour — §4.9c,
--- nothing here is scored. The header does flash for a moment when a run
--- comes back, green when it ran and in the danger colour when the build
--- did not go through, and then it is cream again.
function Playground:draw_output(rect)
  self.out_rect = rect
  UI.card(rect.x, rect.y, rect.w, rect.h, { pad = 0 })
  local pad = Theme.space.md
  local lead = UI.lead("label")
  local head_h = lead + Theme.space.lg
  local hy = rect.y + Theme.space.sm

  -- The flash: the header row tinted for 600 ms after the reply.
  local since = Juice.since("pg:ran")
  if since and since < 0.6 and self.ran_tint then
    UI.setColor(self.ran_tint, 0.4 * (1 - since / 0.6))
    UI.rrect("fill", rect.x + 2, rect.y + 2, rect.w - 4, head_h, Theme.radius)
    love.graphics.setColor(1, 1, 1, 1)
  end

  local head, colour
  if self.running then
    head = ("%s…  %dms"):format(tostring(self.stage or "queued"), math.floor(self.elapsed_ms))
    colour = Theme.gold
  elseif self.result then
    head = I18n.t(OUTCOME[self.result.outcome] or tostring(self.result.outcome))
    -- `ok` gets a quiet green; everything else gets **cream**, not red.
    colour = self.result.outcome == "ok" and Theme.green or Theme.text
  else
    head = I18n.t("nothing has run yet")
    colour = Theme.mute
  end
  local title = I18n.t("OUTPUT")
  local tw = UI.labelWidth(title, "label")
  local room = rect.w - pad * 3 - tw
  if self.result then
    -- The timing and the exit code follow the outcome when they fit, and
    -- give way one at a time when they do not: the outcome is the answer.
    local r = self.result
    local ms = ("%dms"):format((r.compile_ms or 0) + (r.run_ms or 0))
    local exit = "exit " .. (r.exit_code == nil and "-" or tostring(r.exit_code))
    for _, candidate in ipairs({ head .. " · " .. ms .. " · " .. exit, head .. " · " .. exit, head }) do
      if UI.labelWidth(candidate, "label") <= room then head = candidate; break end
    end
  end
  UI.label(title, rect.x + pad, hy, "label", { color = Theme.mute, caps = true })
  UI.label(head, rect.x + pad + tw + pad, hy, "label",
    { color = colour, width = room, ellipsis = true, align = "right" })

  local font = Assets.mono(Layout.codeSize(16))
  local line_h = font:getHeight()
  local wx, wy = rect.x + pad, rect.y + head_h
  local ww, wh = rect.w - pad * 2, rect.h - head_h - pad
  if wh < line_h + 8 then
    self.out_body = nil
    self.out_overflow = 0
    return
  end
  UI.card(wx, wy, ww, wh, { variant = "well", pad = 0 })
  local x, y = wx + Theme.space.sm, wy + Theme.space.sm
  local text_w = ww - Theme.space.sm * 2 - 10
  local bottom = wy + wh - Theme.space.sm

  -- The format's problem, or the last note, above what the program said.
  local out = {}
  local function push(text, c)
    for _, line in ipairs(Playground.wrap_mono(text, text_w,
      function(t) return font:getWidth(t) end)) do
      out[#out + 1] = { line, c }
    end
  end
  if self.problem then
    for line in (tostring(self.problem) .. "\n"):gmatch("(.-)\n") do push(line, Theme.gold) end
    out[#out + 1] = { "", Theme.mute }
  end
  local function block(label, text, c)
    if not text or text == "" then return end
    if #out > 0 then out[#out + 1] = { "", Theme.mute } end
    out[#out + 1] = { label, Theme.mute }
    for line in (text .. "\n"):gmatch("(.-)\n") do
      if line ~= "" then push(line, c) end
    end
  end
  local r = self.result
  local loud = Playground.loud(r)
  if r then
    block("STDOUT", r.stdout, Theme.text)
    if loud then block("STDERR", r.stderr, Theme.withAlpha(Theme.text, 0.8)) end
    if loud and r.diagnostics and #r.diagnostics > 0 then
      local lines = {}
      for _, d in ipairs(r.diagnostics) do
        local where = d.line and (" (" .. d.line .. (d.col and (":" .. d.col) or "") .. ")") or ""
        lines[#lines + 1] = ("%s%s%s  %s"):format(d.kind or "",
          d.code and (" [" .. d.code .. "]") or "", where, d.message or "")
      end
      block(I18n.t("WHAT THE COMPILER SAID"), table.concat(lines, "\n"), Theme.blue)
    end
  elseif self.log then
    for _, name in ipairs(self.log.order) do
      if loud or name == "stdout" then
        local lines, tail = self.log:lines(name)
        for _, line in ipairs(lines) do push(line, Theme.withAlpha(Theme.text, 0.85)) end
        if tail ~= "" then push(tail, Theme.withAlpha(Theme.text, 0.85)) end
      end
    end
  end

  local room = math.max(1, math.floor((bottom - y) / line_h))
  self.out_body = { x = wx, y = wy, w = ww, h = wh }
  love.graphics.setFont(font)
  if #out == 0 then
    self.out_overflow = 0
    if r then
      UI.setColor(Theme.mute)
      love.graphics.print(I18n.t("the program wrote nothing"), x, y)
    end
    love.graphics.setColor(1, 1, 1, 1)
    return
  end
  -- `out_scroll` counts lines back from the tail (0 = live), so the same
  -- moment stays on screen as more output streams in.
  self.out_overflow = math.max(0, #out - room)
  if self.out_to_top and r then
    self.out_to_top = false
    self.out_scroll = self.out_overflow
  end
  local scroll = math.max(0, math.min(self.out_scroll or 0, self.out_overflow))
  self.out_scroll = scroll
  local last = #out - scroll
  love.graphics.setScissor(wx + 1, wy + 1, math.max(0, ww - 2), math.max(0, wh - 2))
  local ly = y
  for i = math.max(1, last - room + 1), last do
    UI.setColor(out[i][2])
    love.graphics.print(out[i][1], x, ly)
    ly = ly + line_h
  end
  love.graphics.setScissor()
  love.graphics.setColor(1, 1, 1, 1)
  if self.out_overflow > 0 then
    UI.scrollbar(wx + ww - 10, wy + 4, wh - 8, room / #out,
      (last - room) / self.out_overflow, { alpha = 0.9 })
  end
end

--- `text` broken into lines no wider than `width`, at spaces where it can
--- and anywhere where it must: a compiler's path has no spaces in it.
function Playground.wrap_mono(text, width, measure)
  local lines = {}
  local line = ""
  for word in tostring(text):gmatch("%s*%S+") do
    if line ~= "" and measure(line .. word) > width then
      lines[#lines + 1] = line
      line = word:gsub("^%s+", "")
    else
      line = line .. word
    end
    while measure(line) > width and #line > 1 do
      local cut = #line
      while cut > 1 and measure(line:sub(1, cut)) > width do cut = cut - 1 end
      -- Not inside a UTF-8 character.
      while cut > 1 and line:byte(cut + 1) and line:byte(cut + 1) >= 128
        and line:byte(cut + 1) < 192 do cut = cut - 1 end
      lines[#lines + 1] = line:sub(1, cut)
      line = line:sub(cut + 1)
    end
  end
  if line ~= "" or #lines == 0 then lines[#lines + 1] = line end
  return lines
end

-- -------------------------------------------------------------------- input

function Playground:textinput(text)
  -- Nothing reaches the program while the question is open; the T or K that
  -- answered it is not a character of anybody's code.
  if self.conflict then return end
  if self.eat_text then
    self.eat_text = false
    return
  end
  -- The room's field first while it is open: whatever is being typed into
  -- the panel is not being typed into the program.
  if self.coder and self.coder:textinput(text) then return end
  if self.focus == "name" then
    if self.name_fresh then self.name_edit, self.name_fresh = "", false end
    if #(self.name_edit or "") < 48 then self.name_edit = (self.name_edit or "") .. text end
  elseif self.focus == "find" then
    if #(self.query or "") < 48 then self.query = (self.query or "") .. text end
  elseif self.focus == "tools" then
    -- Room for a working set of words, not just one.
    if #(self.tools_query or "") < 120 then self.tools_query = (self.tools_query or "") .. text end
  elseif self.focus == "stamp" then
    if #(self.stamp_edit or "") < 400 then self.stamp_edit = (self.stamp_edit or "") .. text end
  elseif self.focus == "disk" then
    if #(self.disk_edit or "") < 1024 then self.disk_edit = (self.disk_edit or "") .. text end
  elseif self.focus == "editor" then
    self.editor:textinput(text)
    SFX.play("type")
  elseif self.focus == "stdin" then
    self.stdin = self.stdin .. text
    -- Part of the pad, so touching it is an edit: without this the autosave
    -- never carries what was typed into it.
    self.editor.dirty = true
    self.dirty_at = Anim.now()
  end
end

--- Open the name field, with what it is called already in it.
---
--- `name_fresh` is the browser client's "arrives selected": the first thing
--- typed replaces the name, and backspace or an arrow key keeps it to edit.
--- There is no selection to draw here, so the flag is the whole of it.
function Playground:start_rename()
  self.focus = "name"
  self.name_edit = self.name and tostring(self.name) or ""
  self.name_fresh = true
end

--- The pads the list is showing: all of them, or those the query matches.
---
--- Each carries the index it has in `self.snippets`, because `load` takes a
--- position in that list and a filtered view would otherwise open the wrong
--- pad the moment anything was typed.
function Playground:visible_snippets()
  local out = {}
  local q = (self.query or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  for i, brief in ipairs(self.snippets or {}) do
    local name = tostring(brief.name or brief.id):lower()
    if q == "" or name:find(q, 1, true) then
      out[#out + 1] = { index = i, brief = brief }
    end
  end
  return out
end

--- Whether the box is worth its row. Four pads are read in one glance.
function Playground:searchable()
  return #(self.snippets or {}) >= 5 or (self.query or "") ~= ""
end

--- The code face, cycled and remembered.
---
--- One preference for both code panes, because how somebody likes to read
--- code is a fact about them and not about which screen they are on.
--- UNDO / REDO on the CODE strip: one step along the editor's own stack.
--- The editor marks itself dirty on a step, which is what the autosave
--- watches, so the pad on the server follows the step like any edit.
function Playground:step_history(which)
  local stepped = which == "undo" and self.editor:undo() or self.editor:redo()
  if stepped then
    self.focus = "editor"
    self.dirty_at = Anim.now()
    SFX.play("select")
  end
end

function Playground:cycle_face()
  local faces = Assets.CODE_FACES
  local at = 1
  for i, name in ipairs(faces) do
    if name == Assets.codeFace() then at = i end
  end
  local next_face = faces[(at % #faces) + 1]
  Assets.setCodeFace(next_face)
  require("src.store").set_face(next_face)
  self:say(Assets.CODE_FACE_NAME[next_face])
  SFX.play("select")
end

--- What the THEME button says: the theme the pane is in now.
function Playground.theme_label()
  return Theme.codeTheme() == "light" and I18n.t("LIGHT") or I18n.t("DARK")
end

--- The code pane's light or dark, cycled and remembered. One preference for
--- both code panes, like the face.
function Playground:cycle_theme()
  local themes = Theme.CODE_THEMES
  local at = 1
  for i, name in ipairs(themes) do
    if name == Theme.codeTheme() then at = i end
  end
  local next_theme = themes[(at % #themes) + 1]
  Theme.setCodeTheme(next_theme)
  require("src.store").set_code_theme(next_theme)
  self:say(Playground.theme_label())
  SFX.play("select")
end

--- What the run said, as text somebody can paste somewhere else.
---
--- Canvas output is pixels: nothing in that pane can be selected with a
--- mouse, so this is the only way a compiler error leaves the screen — which
--- is the thing somebody wants to hand to an assistant and ask about.
function Playground:output_text()
  local out = {}
  local r = self.result
  if r then
    out[#out + 1] = ("%s   %dms compile   %dms run   exit %s"):format(
      I18n.t(OUTCOME[r.outcome] or tostring(r.outcome)),
      r.compile_ms or 0, r.run_ms or 0,
      r.exit_code == nil and "-" or tostring(r.exit_code))
    if r.stdout and r.stdout ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "STDOUT"
      out[#out + 1] = r.stdout
    end
    if r.stderr and r.stderr ~= "" then
      out[#out + 1] = ""
      out[#out + 1] = "STDERR"
      out[#out + 1] = r.stderr
    end
    for _, d in ipairs(r.diagnostics or {}) do
      out[#out + 1] = ("%s%s %s"):format(d.kind or "",
        d.code and (" [" .. d.code .. "]") or "", d.message or "")
    end
  elseif self.log then
    for _, name in ipairs(self.log.order) do
      local lines, tail = self.log:lines(name)
      for _, line in ipairs(lines) do out[#out + 1] = line end
      if tail ~= "" then out[#out + 1] = tail end
    end
  end
  return (table.concat(out, "\n"):gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Copy and paste: the two halves of working with something else.
function Playground:clip(which)
  if which == "code" then
    love.system.setClipboardText(self.editor and self.editor:text() or "")
    self:say(I18n.t("copied"), "good")
  elseif which == "out" then
    local text = self:output_text()
    if text == "" then self:say(I18n.t("nothing has run yet"), "warn"); return end
    love.system.setClipboardText(text)
    self:say(I18n.t("copied"), "good")
  elseif which == "copyin" then
    local text = self.stdin or ""
    if text == "" then self:say(I18n.t("nothing to copy"), "warn"); return end
    love.system.setClipboardText(text)
    self:say(I18n.t("copied"), "good")
  elseif which == "in" then
    -- Checked like the editor's paste is: an empty clipboard silently wiping
    -- the program's input is a button that looks like it worked.
    local text = love.system.getClipboardText() or ""
    if text == "" then self:say(I18n.t("the clipboard is empty"), "warn"); return end
    self.stdin = text
    self.editor.dirty = true
    self.dirty_at = Anim.now()
    self:say(I18n.t("pasted"), "good")
  elseif which == "paste" and self.editor then
    local text = love.system.getClipboardText() or ""
    if text == "" then self:say(I18n.t("the clipboard is empty"), "warn"); return end
    self.editor:set_text(text)
    self.editor.dirty = true
    self:say(I18n.t("pasted"), "good")
  end
  SFX.play("select")
end

-- ------------------------------------------------------ POSTER / DISK READER

--- Who signed, through the library: `recover(message, signature) -> address|nil`.
function Playground:recoverer()
  local lib = self.app.wallet_lib
  return function(message, signature)
    local r = Wallet.recover(lib, message, signature)
    return r and r.address or nil
  end
end

--- A `deflate:` label's body back to its source, through the library.
function Playground:inflater()
  local lib = self.app.wallet_lib
  return function(b64)
    return (Wallet.inflate(lib, b64))
  end
end

--- POSTER: the pad as one square PNG, signed, saved to disk.
---
--- The signature is EIP-191 over the source and only the source — the same
--- scheme as the login challenge and as the browser client's poster, so one
--- reader checks both. Made here because the key is here — or is not: this
--- client keeps the phrase for the run after a login with one, and a session
--- resumed from its token has none: then the field opens and `stamp_with`
--- comes back to this. A stranger's key is dropped again at
--- once; the right one stays for the screen.
function Playground:poster()
  if self.postering then return end
  local lib = self.app.wallet_lib
  if not lib then
    self.note = "libcwbh_ffi is not built — " .. Wallet.BUILD_HINT
    return
  end
  -- The session keeps the key it signed in with (`Session:signer`), the
  -- way the browser holds it for the tab; a session resumed from its token
  -- has none, and only then does the field open.
  if not self.secret then
    local signer = self.app.session:signer()
    if signer then
      self.secret, self.secret_index = signer.secret, signer.index
    else
      return self:start_stamp()
    end
  end
  self.postering = true
  local ok, err = pcall(function() self:make_poster(lib) end)
  self.postering = false
  if not ok then
    self.app:log("warn", "poster: " .. tostring(err))
    self:say(I18n.t("could not make the poster"), "warn")
    SFX.play("locked")
  end
end

function Playground:make_poster(lib)
  local source = self.editor and self.editor:text() or ""
  local address = self.app.session:address()
  if not address then error("nobody is signed in") end
  local signed, sign_err = Wallet.sign(lib, self.secret, self.secret_index, source)
  if not signed then error(sign_err or "the library did not sign") end
  local signature = signed.signature
  -- The output as the pane shows it: every stream's whole lines, then the
  -- partial tail a run may have ended on.
  local log_lines = {}
  if self.log then
    for _, name in ipairs(self.log.order or {}) do
      local lines, tail = self.log:lines(name)
      for _, line in ipairs(lines) do log_lines[#log_lines + 1] = { stream = name, text = line } end
      if tail and tail ~= "" then log_lines[#log_lines + 1] = { stream = name, text = tail } end
    end
  end
  local pad_name = self.name and tostring(self.name) or "scratch"
  local function qr(text)
    local r = Wallet.qr(lib, text)
    if not r then error("no QR holds that label") end
    return r.rows
  end
  local rendered = Poster.make({
    lang = self.lang,
    name = pad_name,
    file = ({ rust = "main.rs", go = "main.go", cpp = "main.cpp", python = "main.py", pytorch = "main.py",
      typescript = "main.ts", zig = "main.zig", lua = "main.lua" })[self.lang],
    source = source,
    run = Poster.run_of(self.result, log_lines),
    user = { name = self.app.session:display_name() or "hacker", address = address },
    signature = signature,
    at = os.time(),
    qr = qr,
    too_dense = function(text)
      local r = Wallet.qr(lib, text)
      return (not r) or r.size > Poster.QR_MAX_MODULES
    end,
    keccak_hex = function(text)
      local r = Wallet.keccak(lib, text)
      return r and r.digest:sub(3) or ("0"):rep(64)
    end,
  })
  -- Where it goes: `<home>/posters/`, made 0700 by the library (LÖVE has no
  -- mkdir outside its own save directory).
  local dir = Store.home(self.app.home) .. "/posters"
  Wallet.secure(lib, dir, true)
  local path = dir .. "/" .. Poster.file_name(pad_name, os.time())
  local written, werr = Poster.write_png(rendered.canvas, path)
  rendered.canvas:release()
  if not written then error(werr or "could not write the PNG") end
  local ok, perr = Wallet.png_text(lib, path, {
    Title = pad_name,
    Author = self.app.session:display_name() or "hacker",
    Software = "Causewaybay Hacker",
    Source = source,
    Lang = self.lang,
    Signer = address,
    Signature = signature,
    Comment = "Signature is EIP-191 personal_sign over Source, by Signer (Cronos EVM / Ethereum address).",
  })
  if not ok then error(perr or "could not write the proof") end
  -- Proved against the file on disk before it is kept: the signature to the
  -- address, the chunks to the program, the label off the pixels.
  local read = Wallet.disk_read(lib, path, true)
  local problem = Reader.prove(read, read and read.label, source, address, signature,
    self:recoverer(), rendered.payload)
  if problem then
    os.remove(path)
    self.note = ("%s: %s"):format(I18n.t("not saved — the disk did not read back"), problem)
    SFX.play("locked")
    return
  end
  -- The PNG only: it is the one with the proof in the file, and the whole
  -- program in it whatever the length. A JPEG kept only what the label held.
  self:say(("%s · %s"):format(I18n.t("poster saved"), path), "good")
  SFX.play("select")
end

--- Ask for the key, on the status line.
function Playground:start_stamp()
  self.focus = "stamp"
  self.stamp_edit = ""
  self.note = I18n.t("paste your phrase or private key to stamp — kept on this machine, never sent")
end

--- Take what was typed as the key: derived at the index the login used,
--- kept only if it is the account that is signed in.
function Playground:stamp_with(text)
  local typed = (text or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if typed == "" then return end
  local lib = self.app.wallet_lib
  local index = self.app.session.index or 0
  local who = Wallet.derive(lib, typed, index)
  if not who then
    self.note = I18n.t("that is not a phrase or a private key")
    SFX.play("locked")
    return
  end
  local me = self.app.session:address() or ""
  if who.address:lower() ~= me:lower() then
    self.note = I18n.t("that key is not the account signed in here")
    SFX.play("locked")
    return
  end
  self.secret, self.secret_index = typed, index
  -- The right key, kept: the session holds it for the run and the store for
  -- the next launch, so this field does not open again for this account.
  self.app.session:keep(typed, index, who.address)
  SFX.play("select")
  self:poster()
end

--- DISK READER: a path field, or a file dropped on the window.
function Playground:start_disk()
  self.focus = "disk"
  self.disk_edit = ""
  self.note = I18n.t("drop a poster on the window, or type its path and press ENTER")
end

function Playground:filedropped(file)
  local path = file.getFilename and file:getFilename() or tostring(file)
  self:read_disk_path(path)
end

--- A picture at `path` back into a pad, with the verdict on the status line.
--- The program opens as a **new, unsaved pad** in its own language, named
--- after the poster, so reading a disk never overwrites what was being
--- written.
function Playground:read_disk_path(path)
  path = Store.expand_tilde((path or ""):gsub("^%s+", ""):gsub("%s+$", ""))
  if path == "" then return end
  local lib = self.app.wallet_lib
  if not lib then
    self.note = "libcwbh_ffi is not built — " .. Wallet.BUILD_HINT
    return
  end
  local read, err = Wallet.disk_read(lib, path)
  if not read then
    self.note = I18n.t("could not read that file")
    self.app:log("warn", "disk reader: " .. tostring(err))
    SFX.play("locked")
    return
  end
  local disk = Reader.from_read(read, self:recoverer(), self:inflater())
  if not disk then
    self.note = I18n.t("no disk on that picture")
    SFX.play("locked")
    return
  end
  local short = disk.address:sub(1, 6) .. "…" .. disk.address:sub(-4)
  if disk.verdict == "hashed" then
    self.note = I18n.t("the label holds only the hash — the code is on the disc, not the label")
    SFX.play("locked")
    return
  end
  self:new_snippet()
  self.lang = disk.lang
  self.editor.lang = disk.lang
  self.editor:set_text(disk.source)
  self.editor.dirty = true
  self.dirty_at = Anim.now()
  self.name = disk.title or Reader.name_from_file(path)
  if disk.verdict == "verified" then
    self:say(I18n.t("disk read · written and signed by %s · verified"):format(short), "good")
    SFX.play("select")
  elseif disk.verdict == "forged" then
    self:say(I18n.t("disk read · the signature does NOT match %s"):format(short), "warn")
    SFX.play("locked")
  else
    self:say(I18n.t("disk read · unsigned · claims %s"):format(short))
    SFX.play("select")
  end
end

--- Take what is in the field, if it is anything, and save under it.
function Playground:commit_rename()
  local want = (self.name_edit or ""):gsub("^%s+", ""):gsub("%s+$", "")
  self.focus = "editor"
  self.name_edit = nil
  if want == "" or want == self.name then return end
  self.name = want
  self.editor.dirty = true
  self:save()
  SFX.play("select")
end

function Playground:keypressed(key, mods)
  mods = mods or {}
  local cmd = mods.ctrl or mods.gui

  -- The question is modal: T (or Enter) takes theirs, K keeps mine, and no
  -- other key may save, run, type or leave around it.
  if self.conflict then
    if key == "t" or key == "return" or key == "kpenter" then
      self:resolve_conflict("theirs")
    elseif key == "k" then
      self:resolve_conflict("mine")
    end
    -- LÖVE sends the letter again as `textinput` after this; by then the
    -- question is closed, and the T or K would be typed into the code.
    if key == "t" or key == "k" then self.eat_text = true end
    return true
  end

  -- Ctrl/Cmd-Shift-A opens and closes the coder from anywhere on the screen,
  -- the browser's accelerator.
  if key == "a" and cmd and mods.shift then
    if self.coder then self.coder:toggle() end
    return true
  end
  -- Then the panel, while it is open and holding a field.
  if self.coder and self.coder:keypressed(key, mods) then return true end

  -- The name field owns every key while it is open: a rename that ran F5
  -- because the name has an "f5" in it would be a field nobody trusts.
  if self.focus == "find" then
    if key == "backspace" then
      self.query = (self.query or ""):sub(1, -2)
    elseif key == "escape" then
      self.query, self.focus = "", "editor"
    elseif key == "return" or key == "kpenter" then
      -- Enter opens the only match, which is what a search box that found
      -- one thing should do.
      local hits = self:visible_snippets()
      if #hits > 0 then self:load(hits[1].index) end
      self.focus = "editor"
    end
    return true
  end

  -- The toolbar filter owns every key while it is open, like the search
  -- box: ESC empties it, ENTER hands the keys back to the code.
  if self.focus == "tools" then
    if key == "backspace" then
      -- One character, not one byte: `필터` is typed in Korean too.
      self.tools_query = (self.tools_query or ""):gsub("[%z\1-\127\194-\244][\128-\191]*$", "")
    elseif key == "escape" then
      self.tools_query, self.focus = "", "editor"
    elseif key == "return" or key == "kpenter" then
      self.focus = "editor"
    end
    return true
  end

  if self.focus == "stamp" or self.focus == "disk" then
    local field = self.focus == "stamp" and "stamp_edit" or "disk_edit"
    if key == "backspace" then
      self[field] = (self[field] or ""):sub(1, -2)
    elseif cmd and key == "v" then
      self[field] = (self[field] or "") .. (love.system.getClipboardText() or "")
    elseif key == "escape" then
      self[field], self.focus = nil, "editor"
    elseif key == "return" or key == "kpenter" then
      local text = self[field] or ""
      self[field], self.focus = nil, "editor"
      if field == "stamp_edit" then self:stamp_with(text) else self:read_disk_path(text) end
    end
    return true
  end

  if self.focus == "name" then
    -- Backspace edits what is there rather than clearing it: the whole name
    -- being "selected" means the first *character* replaces it, not the first
    -- key of any kind.
    self.name_fresh = false
    if key == "backspace" then
      self.name_edit = (self.name_edit or ""):sub(1, -2)
    elseif key == "return" or key == "kpenter" then
      self:commit_rename()
    elseif key == "escape" then
      self.focus, self.name_edit = "editor", nil
    end
    return true
  end

  -- The keys go through the same press as the buttons, so RUN pushes in and
  -- sparks on F5 exactly as it does under a finger.
  if key == "f5" or (cmd and not mods.shift and (key == "return" or key == "kpenter")) then
    self:press_tool("run"); return true
  end
  if key == "f2" then self:press_tool("format"); return true end
  if cmd and key == "s" then self:press_tool("save"); return true end
  if cmd and key == "n" then self:press_tool("new"); return true end
  if key == "tab" and not cmd and self.focus ~= "editor" then
    self:toggle_lang(); return true
  end
  if cmd and key == "tab" then
    self.focus = ({ editor = "stdin", stdin = "snippets", snippets = "editor" })[self.focus]
    return true
  end

  if self.focus == "stdin" then
    if key == "backspace" then self.stdin = self.stdin:sub(1, -2); return true end
    if key == "return" or key == "kpenter" then self.stdin = self.stdin .. "\n"; return true end
    if key == "escape" then self.focus = "editor"; return true end
    return true
  end

  if self.focus == "snippets" then
    local n = #(self.snippets or {})
    if key == "up" then self.cursor = math.max(1, self.cursor - 1); return true end
    if key == "down" then self.cursor = math.min(n, self.cursor + 1); return true end
    if key == "return" or key == "kpenter" then self:load(self.cursor); return true end
    if key == "delete" or key == "backspace" then self:delete(self.cursor); return true end
    if key == "escape" then self.focus = "editor"; return true end
    return true
  end

  -- In CODE, ESC is the way back to the framed screen, not out of it: the
  -- mode is a place you are, and the key that leaves a place leaves the
  -- innermost one first.
  if key == "escape" and self.big then
    self.big = false
    SFX.play("select")
    return true
  end

  if self.editor:keypressed(key, mods) then
    -- AUTO-RUN: a bare ENTER typed into the code runs it, after the newline
    -- is in. A chord is somebody else's ENTER (CTRL-ENTER is RUN already).
    if (key == "return" or key == "kpenter") and self.focus == "editor"
      and not (cmd or mods.shift or mods.alt) then
      self:auto_enter()
    end
    return true
  end
  return false
end

function Playground:wheelmoved(_, dy)
  if self.coder then
    local mx, my = love.mouse.getPosition()
    local vx, vy = Layout.toVirtual(mx, my)
    if self.coder:wheelmoved(dy, vx, vy) then return end
  end
  -- Over the output, the output scrolls: up is back through what it said.
  local mx, my = Layout.toVirtual(love.mouse.getPosition())
  local o = self.out_rect
  if o and (self.out_overflow or 0) > 0 and mx >= o.x and mx <= o.x + o.w
    and my >= o.y and my <= o.y + o.h then
    self.out_scroll = math.max(0, math.min(self.out_overflow,
      (self.out_scroll or 0) + math.floor(dy * 3 + 0.5)))
    return
  end
  if self.focus == "editor" then
    self.editor:scroll_by(-dy * 3, self.visible_rows or 20)
  end
end

function Playground:mousepressed(x, y, button)
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  -- The question first, and only the question, while it is open.
  if self.conflict then
    local r = self.conflict_rects or {}
    if inside(r.theirs) then UI.press("pg:theirs", r.theirs, { sfx = false }); self:resolve_conflict("theirs")
    elseif inside(r.mine) then UI.press("pg:mine", r.mine, { sfx = false }); self:resolve_conflict("mine") end
    return
  end
  -- The coder next: its panel is drawn over the screen and owns what is
  -- under it, and a press on the sprite holds it still. A press anywhere else
  -- lets a held sprite go and then **carries on** to whatever it was aimed
  -- at, which is why this is not a plain "handled" gate.
  if self.coder and self.coder:mousepressed(x, y, button) then return end
  -- The header's chips, in either view.
  if inside(self.lang_rect) then self:toggle_lang(); return end
  if inside(self.machine_rect) then self:cycle_computer(); return end
  if inside(self.name_rect) then self:start_rename(); return end
  if inside(self.filter_rect) then self.focus = "tools"; return end
  local shift = love.keyboard.isDown("lshift", "rshift")
  if self.big then
    if inside(self.done_rect) then
      UI.press("pg:done", self.done_rect)
      self.big = false
      return
    end
    for id, rect in pairs(self.big_rects or {}) do
      if inside(rect) and self:press_tool(id) then return end
    end
    -- CODE draws the stdin field itself. Without this the box took no caret
    -- and nothing could be typed into it.
    if inside(self.stdin_rect) then self.focus = "stdin"; return end
    if self.pane:mousepressed(x, y, button, shift) then self.focus = "editor" end
    return
  end
  if inside(self.find_rect) then self.focus = "find"; return end
  for id, rect in pairs(self.bench_rects or {}) do
    if inside(rect) and self:press_tool(id) then return end
  end
  local lr = self.list_rects or {}
  if inside(lr.new) then UI.press("pg:list:new", lr.new, { sfx = false }); self:new_snippet(); return end
  if inside(lr.rename) then UI.press("pg:list:rename", lr.rename); self:start_rename(); return end
  if inside(lr.delete) then
    UI.press("pg:list:delete", lr.delete)
    for i, brief in ipairs(self.snippets or {}) do
      if brief.id == self.snippet_id then self:delete(i) end
    end
    return
  end
  if inside(self.stdin_rect) then self.focus = "stdin"; return end
  for i, rect in pairs(self.snippet_rects or {}) do
    if inside(rect) then
      self.focus = "snippets"
      if self.cursor == i then self:load(i) else self.cursor = i; SFX.play("move") end
      return
    end
  end
  -- Both shifts: the old hit test asked for the left one only.
  if self.pane:mousepressed(x, y, button, shift) then
    self.focus = "editor"
    return
  end
  if inside(select(1, self:panes())) then self.focus = "editor" end
end

--- What the pointer is over, so the kit's buttons lift under it.
function Playground:mousemoved(x, y)
  -- A moving mouse slows the coder's wander, so it can be caught.
  if self.coder then self.coder:mousemoved(x, y) end
  if self.pane then self.pane:mousemoved(x, y) end
  local function inside(r)
    return r and x >= r.x and x <= r.x + r.w and y >= r.y and y <= r.y + r.h
  end
  local over = nil
  for id, r in pairs(self.tool_rects or {}) do
    if inside(r) then over = "tool:" .. id end
  end
  for id, r in pairs(self.list_rects or {}) do
    if inside(r) then over = "list:" .. id end
  end
  for i, r in pairs(self.snippet_rects or {}) do
    if inside(r) then over = "pad:" .. i end
  end
  if inside(self.lang_rect) then over = "lang" end
  if inside(self.machine_rect) then over = "computer" end
  if inside(self.name_rect) then over = "name" end
  if inside(self.done_rect) then over = "done" end
  self.hover = over
  if self.fx then self.fx:pointer(x, y) end
end

function Playground:mousereleased()
  if self.pane then self.pane:mousereleased() end
end

-- ------------------------------------------------------------ the toolbar
--
-- Every button the browser's playground has, visible, in its order, on the
-- bench and in CODE alike: the filter box heads the first row and the
-- buttons flow after it, wrapping by measurement into as many rows as they
-- need. Grouped — run · edit · clipboard · tools · look · view — with a
-- wider gap between groups than inside one. **Every button is as wide as
-- the widest label it can wear**, measured in the label role `UI.button`
-- draws it in, so nothing is ever cut to "…" and a toggle does not reflow
-- the row when it flips.

--- The size and look buttons: the code's type a step down and up, the code
--- face, the interface face, the paper, and the machine.
---
--- `A-` and `A+` are literals, like `RUN`: they are a glyph and a sign.
function Playground:look_items()
  local machine = Computer.NAME[Computer.get()] ~= nil
  local faces = {}
  for _, name in ipairs(Assets.CODE_FACES) do faces[#faces + 1] = Assets.CODE_FACE_NAME[name] end
  local ui_faces = {}
  for _, name in ipairs(Assets.UI_FACES) do
    ui_faces[#ui_faces + 1] = I18n.t("FONT %s", Assets.UI_FACE_NAME[name])
  end
  return {
    { id = "fontdown", label = "A-", every = { "A-" },
      state = Layout.FONT_STEPS[(Layout.font or 1) - 1] and "normal" or "disabled" },
    { id = "fontup", label = "A+", every = { "A+" },
      state = Layout.FONT_STEPS[(Layout.font or 1) + 1] and "normal" or "disabled" },
    -- The face code is drawn in, cycled. Says the face it is **in**, like
    -- every other toggle here.
    { id = "face", label = Assets.CODE_FACE_NAME[Assets.codeFace()] or "?", every = faces,
      state = "normal" },
    -- The interface face (F8), for the person who asked for "font change"
    -- and should not have to find the settings sheet for it.
    { id = "uifont", label = I18n.t("FONT %s", Assets.UI_FACE_NAME[Assets.uiFace()] or "?"),
      every = ui_faces, state = "normal" },
    -- Light or dark, for the code pane alone. Dim on an old computer: the
    -- machine brings its own paper.
    { id = "theme", label = Playground.theme_label(),
      every = { I18n.t("DARK"), I18n.t("LIGHT") }, state = machine and "disabled" or "normal" },
    -- The machine, saying which it is.
    { id = "computer", label = Playground.computer_label(),
      every = Playground.computer_labels(), state = "normal" },
  }
end

--- AUTO-RUN and STDERR, each saying the state it is in.
function Playground:switch_items()
  return {
    { id = "autorun", label = Playground.auto_label(),
      every = { I18n.t("AUTO-RUN ON"), I18n.t("AUTO-RUN OFF") }, state = "normal" },
    { id = "stderr", label = Playground.stderr_label(),
      every = { I18n.t("STDERR ON"), I18n.t("STDERR OFF") }, state = "normal" },
  }
end

--- The toolbar's groups for `view` (`"bench"` or `"code"`), filtered by the
--- box. The browser's order: run, then what acts on the file, the
--- clipboard, the poster pair, the look of the code, and the way in or out
--- of CODE.
function Playground:tool_groups(view)
  local editor = self.editor
  local run = {
    { id = "run", label = self.running and "RUNNING…" or "RUN", every = { "RUNNING…", "RUN" },
      key = "F5", variant = "run", state = self.running and "disabled" or "normal" },
  }
  for _, item in ipairs(self:switch_items()) do run[#run + 1] = item end
  run[#run + 1] = { id = "format", label = self.formatting and "…" or I18n.t("FORMAT"),
    every = { I18n.t("FORMAT") }, key = "F2",
    state = self.format_unsupported and "disabled" or "normal" }
  local edit = {
    -- The Rust coder. Next to RUN because it is the other thing that acts
    -- on the program rather than on the file.
    { id = "agent", label = I18n.t("AGENT"), every = { I18n.t("AGENT") },
      state = (self.coder and self.coder.panel.open) and "hot" or "normal" },
    -- The editor's own undo stack (`src/editor.lua`), as buttons -- the
    -- steps ctrl-Z takes, for a touch screen that has no ctrl.
    { id = "undo", label = I18n.t("UNDO"), every = { I18n.t("UNDO") },
      state = (editor and #editor.undo_stack > 0) and "normal" or "disabled" },
    { id = "redo", label = I18n.t("REDO"), every = { I18n.t("REDO") },
      state = (editor and #editor.redo_stack > 0) and "normal" or "disabled" },
    { id = "save", label = I18n.t("SAVE"), every = { I18n.t("SAVE") }, state = "normal" },
    -- A fresh page. Dim while the other device's save waits on an answer.
    { id = "new", label = I18n.t("NEW"), every = { I18n.t("NEW") },
      state = self.conflict and "disabled" or "normal" },
    { id = "rename", label = I18n.t("RENAME"), every = { I18n.t("RENAME") }, state = "normal" },
  }
  local clip = {
    -- In and out of the screen. Nothing on a canvas can be selected with a
    -- mouse, so without these the code and the compiler's answer cannot
    -- leave it at all.
    { id = "copycode", label = I18n.t("COPY CODE"), every = { I18n.t("COPY CODE") },
      state = "normal" },
    { id = "pastecode", label = I18n.t("PASTE"), every = { I18n.t("PASTE") }, state = "normal" },
    { id = "copyout", label = I18n.t("COPY OUTPUT"), every = { I18n.t("COPY OUTPUT") },
      state = (self.result or self.log) and "normal" or "disabled" },
    { id = "copyin", label = I18n.t("COPY INPUT"), every = { I18n.t("COPY INPUT") },
      state = (self.stdin or "") ~= "" and "normal" or "disabled" },
    { id = "pastein", label = I18n.t("PASTE INPUT"), every = { I18n.t("PASTE INPUT") },
      state = "normal" },
  }
  local tools = {
    -- Out of the screen as a picture, signed; and a picture back in, checked.
    { id = "poster", label = I18n.t("POSTER"), every = { I18n.t("POSTER") },
      state = self.postering and "disabled" or "normal" },
    { id = "reader", label = I18n.t("DISK READER"), every = { I18n.t("DISK READER") },
      state = "normal" },
  }
  local look = self:look_items()
  local way = {}
  if view == "code" then
    -- Measured from every language's name, not from one: sized for
    -- "PYTHON", TYPESCRIPT only fitted by drawing a step smaller.
    look[#look + 1] = { id = "lang", label = Land.name(self.lang), every = Playground.lang_labels(),
      state = "normal" }
  else
    way[#way + 1] = { id = "code", label = I18n.t("CODE"), every = { I18n.t("CODE") }, state = "normal" }
  end
  local groups = {}
  for _, group in ipairs({ run, edit, clip, tools, look, way }) do
    local kept = self:filtered(group)
    if #kept > 0 then groups[#groups + 1] = kept end
  end
  return groups
end

--- Only the buttons the filter box keeps.
function Playground:filtered(items)
  local q = self.tools_query or ""
  if q == "" then return items end
  local out = {}
  for _, item in ipairs(items) do
    if Playground.filter_keeps(q, item) then out[#out + 1] = item end
  end
  return out
end

--- How wide a button is: its widest label in the label role, the kit's
--- padding each side, and its keycap when it wears one — exactly the room
--- `UI.button` gives a label, so it is never cut.
function Playground.tool_w(item)
  local w = 0
  for _, label in ipairs(item.every or { item.label }) do
    w = math.max(w, (UI.buttonSize(label, { key = item.key })))
  end
  w = math.max(w, (UI.buttonSize(item.label, { key = item.key })))
  return math.max(Theme.control.buttonM, math.ceil(w))
end

--- How tall a toolbar button is: what its face needs on this canvas, never
--- under the kit's medium button.
function Playground.tool_h()
  local _, h = UI.buttonSize("A")
  return math.max(Theme.control.buttonM, h)
end

--- How wide the filter box is: room for a short word. `at` is ignored; the
--- box is set in the label role like the buttons beside it.
function Playground.filter_w(at)
  local font = UI.buttonFont()
  return math.max(font:getWidth(I18n.t("FILTER")), font:getWidth("MMMMMMMM")) + Theme.space.lg
end

--- Lay `groups` into rows from `x`, `w` wide, the first row starting `lead`
--- in (the filter box). Pure: returns the rows, each a list of
--- `{ item, x, w }`. A group's buttons sit `space.sm` apart; groups sit
--- `space.lg` apart; a button that does not fit starts the next row.
function Playground.flow(groups, x, w, lead)
  local rows, line = {}, {}
  local bx = x + (lead or 0)
  local limit = x + w
  for _, group in ipairs(groups) do
    for gi, item in ipairs(group) do
      local iw = Playground.tool_w(item)
      if #line > 0 and bx + iw > limit then
        rows[#rows + 1] = line
        line, bx = {}, x
      end
      line[#line + 1] = { item = item, x = bx, w = iw }
      bx = bx + iw + (gi < #group and Theme.space.sm or Theme.space.lg)
    end
  end
  if #line > 0 then rows[#rows + 1] = line end
  if #rows == 0 then rows[1] = {} end
  return rows
end

--- The height the toolbar takes at `w` wide, measured before anything
--- under it is laid out.
function Playground:tools_h(view, w)
  local rows = Playground.flow(self:tool_groups(view), 0, w, Playground.filter_w() + Theme.space.sm)
  local bh = Playground.tool_h()
  return #rows * bh + (#rows - 1) * Theme.space.sm
end

--- The toolbar, drawn: the filter box, then the rows. Returns the height
--- it took and the rects it drew, keyed by id.
function Playground:draw_tools(x, y, w, view)
  local fw = Playground.filter_w()
  local rows = Playground.flow(self:tool_groups(view), x, w, fw + Theme.space.sm)
  local bh = Playground.tool_h()
  local rects = {}
  self:draw_filter(x, y, fw, bh)
  for ri, row in ipairs(rows) do
    local ry = y + (ri - 1) * (bh + Theme.space.sm)
    for _, cell in ipairs(row) do
      local item = cell.item
      local state = item.state or "normal"
      if state ~= "disabled" and self.hover == "tool:" .. item.id then state = "hot" end
      UI.button(cell.x, ry, cell.w, bh, item.label, state, nil,
        { variant = item.variant or "secondary", id = "pg:" .. item.id, key = item.key })
      rects[item.id] = { x = cell.x, y = ry, w = cell.w, h = bh }
    end
  end
  self.tool_rects = rects
  return #rows * bh + (#rows - 1) * Theme.space.sm, rects
end

--- The filter box, with what is typed in it or what it is for.
function Playground:draw_filter(x, y, w, h)
  local hot = self.focus == "tools"
  UI.card(x, y, w, h, { variant = "well", pad = 0, edge = hot and Theme.gold or nil })
  local q = self.tools_query or ""
  local shown = q ~= "" and q or I18n.t("FILTER")
  if hot then shown = q .. "_" end
  local font, bold = UI.buttonFont()
  shown = UI.ellipsizeWith(shown, w - Theme.space.sm * 2, font)
  UI.buttonLabel(shown, x + Theme.space.sm, y + math.floor((h - font:getHeight()) / 2), font,
    q ~= "" and Theme.text or Theme.mute, bold, {})
  self.filter_rect = { x = x, y = y, w = w, h = h }
end

--- A button on the toolbar, pressed. Shared by the bench and CODE so the
--- two can never disagree about what a button does. The push-in, the puff
--- and the click come from `UI.press`; an action with a sound of its own
--- keeps it.
function Playground:press_tool(id)
  local rect = self.tool_rects and self.tool_rects[id]
  if id == "run" then
    UI.press("pg:run", rect, { sfx = false })
    self:run()
  elseif id == "format" then UI.press("pg:format", rect, { sfx = false }); self:format()
  elseif id == "autorun" then UI.press("pg:autorun", rect, { sfx = false }); self:toggle_pref("auto_run")
  elseif id == "stderr" then UI.press("pg:stderr", rect, { sfx = false }); self:toggle_pref("stderr")
  elseif id == "save" then UI.press("pg:save", rect); self:save(true)
  elseif id == "new" then
    if not self.conflict then UI.press("pg:new", rect, { sfx = false }); self:new_snippet() end
  elseif id == "rename" then UI.press("pg:rename", rect); self:start_rename()
  elseif id == "undo" or id == "redo" then UI.press("pg:" .. id, rect, { sfx = false }); self:step_history(id)
  elseif id == "copycode" then UI.press("pg:copycode", rect, { sfx = false }); self:clip("code")
  elseif id == "pastecode" then UI.press("pg:pastecode", rect, { sfx = false }); self:clip("paste")
  elseif id == "copyout" then UI.press("pg:copyout", rect, { sfx = false }); self:clip("out")
  elseif id == "copyin" then UI.press("pg:copyin", rect, { sfx = false }); self:clip("copyin")
  elseif id == "pastein" then UI.press("pg:pastein", rect, { sfx = false }); self:clip("in")
  elseif id == "fontdown" then UI.press("pg:fontdown", rect, { sfx = false }); self:size_font(-1)
  elseif id == "fontup" then UI.press("pg:fontup", rect, { sfx = false }); self:size_font(1)
  elseif id == "face" then UI.press("pg:face", rect, { sfx = false }); self:cycle_face()
  elseif id == "uifont" then
    UI.press("pg:uifont", rect)
    if self.app and self.app.cycle_ui_face then self.app:cycle_ui_face() end
  elseif id == "theme" then
    -- The machine brings its own paper; the button says so by being dim.
    if not Computer.NAME[Computer.get()] then UI.press("pg:theme", rect, { sfx = false }); self:cycle_theme() end
  elseif id == "computer" then UI.press("pg:computer", rect, { sfx = false }); self:cycle_computer()
  elseif id == "poster" then UI.press("pg:poster", rect, { sfx = false }); self:poster()
  elseif id == "reader" then UI.press("pg:reader", rect); self:start_disk()
  elseif id == "lang" then UI.press("pg:lang", rect, { sfx = false }); self:toggle_lang()
  elseif id == "agent" then
    UI.press("pg:agent", rect)
    if self.coder then self.coder:toggle() end
  elseif id == "code" then
    UI.press("pg:code", rect)
    self.big = true
  else return false end
  return true
end

-- ------------------------------------------------- the toolbar filter's words

--- What each family of buttons *means*, in the words a person would reach
--- for. The browser's `ui/toolfilter.ts`, word for word: a word that names a
--- concept keeps every button of that concept, whatever its label says in
--- the current language -- `글꼴` keeps A- / A+ and the face button, `ai`
--- keeps the agent, `clipboard` keeps every copy and paste.
Playground.FILTER_CONCEPTS = {
  { words = { "run", "execute", "exec", "start", "play", "compile", "build", "실행", "돌려",
      "컴파일", "빌드", "実行", "运行", "執行" },
    ids = { "run", "autorun", "submit" } },
  { words = { "copy", "clipboard", "복사", "클립보드", "コピー", "复制", "複製" }, ids = { "copy" } },
  { words = { "paste", "clipboard", "붙여", "붙이", "클립보드", "貼り付け", "粘贴", "貼上" },
    ids = { "paste" } },
  { words = { "font", "text", "type", "size", "zoom", "bigger", "smaller", "글꼴", "글자", "폰트",
      "크기", "확대", "축소", "フォント", "文字", "字体", "字型", "大小" },
    ids = { "fontup", "fontdown", "face" } },
  { words = { "theme", "dark", "light", "color", "colour", "night", "테마", "다크", "라이트",
      "밝게", "어둡게", "색", "テーマ", "主题", "主題" },
    ids = { "theme" } },
  { words = { "ai", "agent", "ask", "help", "assistant", "claude", "gpt", "에이전트", "질문",
      "물어", "도움", "인공지능", "エージェント", "助手", "智能" },
    ids = { "agent", "copyask" } },
  { words = { "undo", "redo", "history", "back", "revert", "되돌", "다시", "취소", "기록",
      "元に戻す", "撤销", "復原" },
    ids = { "undo", "redo", "clearstack" } },
  { words = { "format", "pretty", "tidy", "indent", "정렬", "포맷", "들여쓰기", "整形", "格式" },
    ids = { "format" } },
  { words = { "output", "log", "console", "stderr", "error", "result", "출력", "로그", "콘솔",
      "에러", "오류", "결과", "出力", "输出", "輸出", "日志" },
    ids = { "copyout", "console", "stderr", "log" } },
  { words = { "input", "stdin", "입력", "표준입력", "入力", "输入", "輸入" },
    ids = { "copyin", "pastein" } },
  { words = { "file", "save", "rename", "new", "scratch", "파일", "저장", "이름", "새로", "메모",
      "ファイル", "保存", "文件", "檔案" },
    ids = { "save", "rename", "new" } },
  { words = { "share", "image", "picture", "poster", "qr", "export", "import", "공유", "이미지",
      "사진", "포스터", "디스크", "読み込み", "分享", "图片" },
    ids = { "poster", "reader" } },
  { words = { "view", "layout", "screen", "panel", "full", "focus", "only", "side", "top",
      "rotate", "orientation", "화면", "보기", "배치", "전체", "패널", "회전", "방향", "만",
      "表示", "画面", "视图", "畫面" },
    ids = { "stack", "briefonly", "codeonly", "focus", "code", "fullscreen", "orient", "unfocus" } },
  { words = { "exit", "leave", "quit", "home", "map", "lobby", "나가", "나가기", "뒤로", "지도",
      "로비", "홈", "戻る", "地图", "返回" },
    ids = { "back", "lobby", "unfocus" } },
  { words = { "language", "lang", "언어", "言語", "语言", "語言" },
    ids = { "rust", "go", "cpp", "python", "pytorch", "typescript", "zig", "lua", "lang" } },
  { words = { "reset", "clear", "clean", "wipe", "초기화", "지우", "리셋", "リセット", "重置",
      "清除" },
    ids = { "reset", "clearstack" } },
  -- The old computers: a playground-only family the browser files under
  -- "theme" by label alone. Named here so `retro` and `컴퓨터` find it.
  { words = { "computer", "retro", "machine", "apple", "msx", "amiga", "컴퓨터", "레트로",
      "コンピューター", "电脑", "電腦" },
    ids = { "computer" } },
}

--- The characters of a UTF-8 string, one per entry.
local function chars(text)
  local out = {}
  for ch in text:gmatch("[%z\1-\127\194-\244][\128-\191]*") do out[#out + 1] = ch end
  return out
end

--- The code point of one UTF-8 character.
local function codepoint(ch)
  local b1, b2, b3 = ch:byte(1, 3)
  if not b2 then return b1 end
  if b1 < 0xE0 then return (b1 - 0xC0) * 64 + (b2 - 0x80) end
  if b1 < 0xF0 and b3 then return ((b1 - 0xE0) * 64 + (b2 - 0x80)) * 64 + (b3 - 0x80) end
  return -1
end

local CHOSEONG = chars("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")

--- Hangul syllables to their leading consonant, so `ㅂㅅ` finds 복사.
local function choseong(text)
  local out = {}
  for _, ch in ipairs(chars(text)) do
    local c = codepoint(ch)
    if c >= 0xAC00 and c <= 0xD7A3 then
      out[#out + 1] = CHOSEONG[math.floor((c - 0xAC00) / 588) + 1]
    else
      out[#out + 1] = ch
    end
  end
  return table.concat(out)
end

local function only_jamo(word)
  for _, ch in ipairs(chars(word)) do
    local c = codepoint(ch)
    if c < 0x3131 or c > 0x314E then return false end
  end
  return word ~= ""
end

local function has_hangul(word)
  for _, ch in ipairs(chars(word)) do
    local c = codepoint(ch)
    if c >= 0xAC00 and c <= 0xD7A3 then return true end
  end
  return false
end

--- `cpcd` finds `copycode`: every letter, in order, with gaps allowed.
local function subsequence(word, text)
  local i = 1
  for k = 1, #text do
    if text:sub(k, k) == word:sub(i, i) then
      i = i + 1
      if i > #word then return true end
    end
  end
  return false
end

--- The words of a filter query: split on spaces and commas, lower-cased.
function Playground.filter_words(query)
  local out = {}
  local text = tostring(query or ""):lower():gsub("，", " "):gsub("、", " ")
  for word in text:gmatch("[^%s,]+") do out[#out + 1] = word end
  return out
end

--- The ids a word calls up through the concept table.
local function concept_ids(word)
  -- A word long enough to mean something: two letters, or one Hangul
  -- syllable (`답`, `색`), which already carries a whole idea.
  local n = #chars(word)
  if n < 2 and not has_hangul(word) then return {} end
  local out = {}
  for _, c in ipairs(Playground.FILTER_CONCEPTS) do
    for _, w in ipairs(c.words) do
      if w:sub(1, #word) == word or (n >= 3 and word:sub(1, #w) == w) then
        for _, id in ipairs(c.ids) do out[#out + 1] = id end
        break
      end
    end
  end
  return out
end

--- Whether one word keeps one button.
local function word_keeps(word, label, id)
  if label:find(word, 1, true) or id:find(word, 1, true) then return true end
  -- Hangul initials: `ㅂㅅ` is 복사, `ㅈㅈ` is 저장.
  if only_jamo(word) then
    return (choseong(label):gsub("%s+", "")):find(word, 1, true) ~= nil
  end
  -- The concept table: `글꼴` is A- / A+, `ai` is the agent.
  for _, c in ipairs(concept_ids(word)) do
    if id == c or id:sub(1, #c) == c then return true end
  end
  -- An abbreviation of the id: `cpcd` is copycode, `fup` is fontup.
  return #word >= 3 and word:match("^[a-z]+$") ~= nil and subsequence(word, id)
end

--- Whether a button stays drawn under `query`.
---
--- Words are OR'd: a button stays when **any** word keeps it, because the box
--- is for naming the handful of buttons you use. A word with a leading `-`
--- takes away instead (`-font` hides the font buttons), and a query of only
--- `-` words starts from every button. Nothing typed keeps everything.
function Playground.filter_keeps(query, item)
  local words = Playground.filter_words(query)
  if #words == 0 then return true end
  local label = tostring(item.label or ""):lower()
  local id = tostring(item.id or ""):lower()
  local plus = {}
  for _, w in ipairs(words) do
    if w:sub(1, 1) == "-" and #w > 1 then
      if word_keeps(w:sub(2), label, id) then return false end
    elseif w:sub(1, 1) ~= "-" then
      plus[#plus + 1] = w
    end
  end
  if #plus == 0 then return true end
  for _, w in ipairs(plus) do
    if word_keeps(w, label, id) then return true end
  end
  return false
end

return Playground
