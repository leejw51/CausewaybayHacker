-- AI MODE — `ai.plan` / `ai.next` / `ai.finish` (§4.16). Milestone 2 on the
-- server side; this screen probes for it rather than faking a drill.
return require("src.scenes.stub").make({
  title = "AI MODE",
  probe = "ai.plan",
  payload = { mode = "weakness", land = "rust", size = 5 },
  blurb = "A drill built from your own mistake table: the server picks the "
    .. "next quest and says, in one line, why it picked it.",
  plan = {
    "three modes: repeat, weakness, spaced",
    "the plan is fixed at creation, so a reconnect resumes it",
    "`why` on every step — the line that makes it a coach, not a shuffle",
    "a finish summary: attempted, cleared, kinds improved",
  },
})
