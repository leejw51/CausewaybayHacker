-- SEARCH — `search.query` (§4.12). Milestone 2 on the server side; see
-- `src/scenes/stub.lua` for why this screen probes rather than pretends.
return require("src.scenes.stub").make({
  title = "SEARCH",
  probe = "search.query",
  payload = { q = "borrow checker", mode = "unified", limit = 5 },
  blurb = "BM25, semantic and the fused ranking over every quest, with the "
    .. "component scores shown so a hit says why it matched.",
  plan = {
    "a query line, and the three modes on a toggle",
    "hits best-first with the FTS5 snippet, <b> marked up as colour",
    "bm25 / cosine / fused scores, side by side (§5.5)",
    "filters: land, category, state",
  },
})
