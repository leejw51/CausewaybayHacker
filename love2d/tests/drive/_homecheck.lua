return {
  { until_ = function(app)
      print("HOMECHECK flag=" .. tostring(app.home)
        .. "  store=" .. tostring(require("src.store").where()))
      return true
    end, timeout = 8 },
  { quit = true },
}
