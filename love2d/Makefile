# CAUSEWAYBAY HACKER — the LÖVE client.
#
#   make ffi            build the Rust key library (do this first)
#   make run            play, against $(CWBH_SERVER)
#   make test           the suite, under LÖVE
#   make test-headless  the same suite under a bare luajit, no window
#   make drive          replay a scripted session and take screenshots
#
# The server is a separate program: `cargo run -p cwbhacker -- serve` from
# `backend/`. This client talks to ws://127.0.0.1:5390/ws and owns no rules.

GAME_DIR  := $(CURDIR)
REPO      := $(abspath $(CURDIR)/..)
CWBH_SERVER ?= ws://127.0.0.1:5390/ws

# Finding LÖVE, in order: an explicit LOVE=, `love` on PATH, a copy this
# Makefile downloaded into build/. Homebrew's `love` cask was disabled on
# 2026-09-01 for failing the macOS Gatekeeper check, so `brew install love`
# is not the answer here; `make love-bin` fetches the official release.
LOVE_VERSION ?= 11.5
LOVE_APP     := $(GAME_DIR)/build/love.app/Contents/MacOS/love
LOVE_URL     := https://github.com/love2d/love/releases/download/$(LOVE_VERSION)/love-$(LOVE_VERSION)-macos.zip
LOVE         ?= $(shell command -v love 2>/dev/null || ([ -x "$(LOVE_APP)" ] && echo "$(LOVE_APP)"))

LUAJIT  := luajit
CARGO   := cargo
STYLUA  := stylua
SRC     := main.lua conf.lua src tests

.DEFAULT_GOAL := help

.PHONY: help ffi ffi-test run play test test-headless test-all drive shots \
        fmt lint check-layering clean love-bin

help: ## Show this help
	@awk 'BEGIN {FS = ":.*##"; printf "\n  CAUSEWAYBAY HACKER  //  love2d\n\n"} \
		/^[a-zA-Z0-9_-]+:.*##/ { printf "  make %-14s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)
	@printf "\n  server: $(CWBH_SERVER)   (CWBH_SERVER= to change)\n"
	@printf "  F1 orientation   F3 scanlines   F4 sound   F11 fullscreen\n\n"

# ------------------------------------------------------------------- the FFI

ffi: ## Build the Rust key library (bip39 + bip32 + secp256k1 + keccak)
	@command -v $(CARGO) >/dev/null 2>&1 || { \
		echo "cargo not found — install Rust from https://rustup.rs"; exit 1; }
	$(CARGO) build --release --manifest-path ffi/Cargo.toml
	@ls -la ffi/target/release/libcwbh_ffi.* 2>/dev/null | sed 's/^/  /' || true

ffi-test: ## Run the Rust crate's own tests
	$(CARGO) test --release --manifest-path ffi/Cargo.toml

# --------------------------------------------------------------------- play

run: ## Play (needs LÖVE; see `make love-bin`)
	@test -n "$(LOVE)" || { \
		echo "no love binary. Put one on PATH, set LOVE=/path/to/love,"; \
		echo "or run 'make love-bin' to fetch LÖVE $(LOVE_VERSION)."; exit 1; }
	CWBH_SERVER="$(CWBH_SERVER)" "$(LOVE)" "$(GAME_DIR)"

play: run ## Alias for run

portrait: ## Play, starting in portrait
	@test -n "$(LOVE)" || { echo "no love binary; see 'make love-bin'"; exit 1; }
	CWBH_SERVER="$(CWBH_SERVER)" CWBH_ORIENT=portrait "$(LOVE)" "$(GAME_DIR)"

# -------------------------------------------------------------------- tests

test: ## The suite under LÖVE (adds the layout and scene cases)
	@test -n "$(LOVE)" || { echo "no love binary; see 'make love-bin'"; exit 1; }
	CWBH_TEST=1 CWBH_VECTORS="$(REPO)/tests/vectors" "$(LOVE)" "$(GAME_DIR)" --test

test-headless: check-layering ## The suite under a bare luajit, no window
	@command -v $(LUAJIT) >/dev/null 2>&1 || { \
		echo "luajit not found — brew install luajit"; exit 1; }
	CWBH_VECTORS="$(REPO)/tests/vectors" $(LUAJIT) tests/run.lua

test-all: ffi-test test-headless test ## Everything: Rust, headless Lua, LÖVE

# The structural rule the headless suite rests on: the codec, the JSON, the
# editor model, the store, the two clocks and the FFI binding must not touch
# LÖVE. `T.no_love` asserts the same thing from inside the suite; this is the
# version that works even when the suite cannot start.
#
# Comments are stripped, and so are string literals. The second one stopped
# being optional when `src/store.lua` grew a record tagged
# `from = "love.filesystem"` — the directory the first migration moved out
# of, a name that is in every existing player's log and cannot be renamed to
# please a grep. A quoted word is data, not a call.
LAYERED := src/json.lua src/editor.lua src/wallet.lua src/store.lua \
           src/anim.lua src/clock.lua src/net/*.lua

check-layering: ## Assert net, json, editor, wallet, store, anim and clock never touch love
	@bad=""; \
	for f in $(LAYERED); do \
		hit=$$(sed -e 's/--.*$$//' -e 's/"[^"]*"/""/g' -e "s/'[^']*'/''/g" "$$f" \
			| grep -nE '(^|[^[:alnum:]_])love[[:space:]]*\.' || true); \
		if [ -n "$$hit" ]; then bad="$$bad\n$$f: $$hit"; fi; \
	done; \
	if [ -n "$$bad" ]; then \
		printf "these files must not reference love:%b\n" "$$bad"; exit 1; \
	fi; \
	echo "  layering ok: net, json, editor, wallet, store, anim and clock are LÖVE-free"

# -------------------------------------------------------------------- drive

# `ARGS` is passed straight to the client, which is how a script that needs a
# signed-out player gets one without deleting somebody's store:
#
#   make drive SCRIPT=tests/drive/slice.lua ARGS="--home $$(mktemp -d)"
drive: ## Replay a script: make drive SCRIPT=tests/drive/slice.lua [ARGS=...]
	@test -n "$(SCRIPT)" || { echo "usage: make drive SCRIPT=tests/drive/slice.lua"; exit 1; }
	@test -n "$(LOVE)" || { echo "no love binary; see 'make love-bin'"; exit 1; }
	CWBH_SERVER="$(CWBH_SERVER)" CWBH_DRIVE="$(SCRIPT)" "$(LOVE)" "$(GAME_DIR)" $(ARGS)
	@echo "  screenshots: $$HOME/Library/Application Support/LOVE/causewaybay-hacker"

shots: ## Screenshot every screen in both orientations
	@$(MAKE) --no-print-directory drive SCRIPT=tests/drive/tour.lua

# --------------------------------------------------------------------- misc

fmt: ## Format the Lua with stylua, and the Rust with cargo fmt
	@command -v $(STYLUA) >/dev/null 2>&1 && $(STYLUA) $(SRC) \
		|| echo "  stylua not found — brew install stylua (skipped)"
	@$(CARGO) fmt --manifest-path ffi/Cargo.toml 2>/dev/null \
		|| echo "  cargo fmt unavailable (skipped)"

lint: check-layering ## Load every module, so a syntax error is caught early
	@command -v $(LUAJIT) >/dev/null 2>&1 || { echo "luajit not found"; exit 1; }
	@for f in $$(find src tests -name '*.lua') main.lua conf.lua; do \
		$(LUAJIT) -bl "$$f" >/dev/null || { echo "  syntax error in $$f"; exit 1; }; \
	done
	@echo "  every Lua file parses"

love-bin: ## Fetch LÖVE $(LOVE_VERSION) into build/ (macOS)
	@mkdir -p build
	@test -f "build/love-$(LOVE_VERSION)-macos.zip" || { \
		echo "  fetching LÖVE $(LOVE_VERSION)"; \
		curl -fsSL -o "build/love-$(LOVE_VERSION)-macos.zip" "$(LOVE_URL)"; }
	@rm -rf build/love.app
	@unzip -q -o "build/love-$(LOVE_VERSION)-macos.zip" -d build
	@"$(LOVE_APP)" --version
	@echo "  LOVE=$(LOVE_APP)"

clean: ## Remove build output
	@rm -rf build ffi/target
	@echo "  cleaned"
