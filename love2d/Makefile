# CAUSEWAYBAY HACKER — the LÖVE client.
#
#   make ffi            build the Rust key library (do this first)
#   make run            play, against $(CWBH_SERVER)
#   make test           the suite, under LÖVE
#   make test-headless  the same suite under a bare luajit, no window
#   make drive          replay a scripted session and take screenshots
#   make love-file      the game as one .love archive (needs LÖVE 11 to run)
#   make app            a double-clickable macOS .app with LÖVE inside
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
        fmt lint check-layering clean love-bin \
        love-file verify-archive app app-icon app-sign app-smoke notarize gatekeeper

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
LAYERED := src/json.lua src/editor.lua src/fxplan.lua src/wallet.lua src/store.lua \
           src/anim.lua src/clock.lua src/i18n.lua src/lang/*.lua src/net/*.lua \
           src/agent/prefs.lua src/agent/typist.lua src/agent/tools.lua \
           src/agent/http.lua src/agent/sse.lua src/agent/providers.lua \
           src/agent/session.lua src/agent/sprite.lua src/agent/sync.lua src/agent/tips.lua

check-layering: ## Assert net, json, editor, wallet, store, anim, clock, i18n and the agent's pure half never touch love
	@bad=""; \
	for f in $(LAYERED); do \
		hit=$$(sed -e 's/--.*$$//' -e 's/"[^"]*"/""/g' -e "s/'[^']*'/''/g" "$$f" \
			| grep -nE '(^|[^[:alnum:]_])love[[:space:]]*\.' || true); \
		if [ -n "$$hit" ]; then bad="$$bad\n$$f: $$hit"; fi; \
	done; \
	if [ -n "$$bad" ]; then \
		printf "these files must not reference love:%b\n" "$$bad"; exit 1; \
	fi; \
	echo "  layering ok: net, json, editor, wallet, store, anim, clock, i18n and the agent's pure half are LÖVE-free"

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

# ------------------------------------------------------------------ package

# The version of record, from the FFI crate — `make version` at the root
# checks that every manifest agrees before a release is cut.
VERSION   := $(shell sed -n 's/^version = "\(.*\)"/\1/p' ffi/Cargo.toml | head -1)
BUILD     := build
GAME_LOVE := $(BUILD)/causewaybay-hacker.love

# The shared library the binding loads at run time, named per platform the
# way `src/wallet.lua` names it.
UNAME := $(shell uname -s)
ifeq ($(UNAME),Darwin)
  FFI_LIB := libcwbh_ffi.dylib
else ifeq ($(OS),Windows_NT)
  FFI_LIB := cwbh_ffi.dll
else
  FFI_LIB := libcwbh_ffi.so
endif

# The game as one archive.
#
# `art/` goes **inside**. `src/assets.lua` tries `art/…` inside the game
# before it walks to `<source>/../art`, precisely so that a packaged build can
# carry a copy and need no checkout beside it. The intermediates (`raw/`), the
# generator (`tools/`, `prompts.toml`) and the manifest's siblings stay out —
# a player has no use for eight megabytes of Grok output.
#
# A glob for the Lua, not a list. A hand-written list goes stale the first
# time a module is added, and it dies on somebody else's machine, because the
# checkout it was built from has the file sitting right there.
love-file: ## The game as one .love archive (needs LÖVE 11 on the machine that runs it)
	@mkdir -p "$(BUILD)"
	@rm -rf "$(BUILD)/stage" "$(GAME_LOVE)" && mkdir -p "$(BUILD)/stage/art"
	@cp -R main.lua conf.lua src assets "$(BUILD)/stage/"
	@rsync -a --exclude raw/ --exclude tools/ --exclude prompts.toml "$(REPO)/art/" "$(BUILD)/stage/art/"
	@cd "$(BUILD)/stage" && zip -qr9 "../$(notdir $(GAME_LOVE))" . -x '.DS_Store' -x '*/.DS_Store'
	@rm -rf "$(BUILD)/stage"
	@$(MAKE) --no-print-directory verify-archive ARCHIVE="$(GAME_LOVE)"
	@echo "  $(GAME_LOVE)  ($$(du -h "$(GAME_LOVE)" | cut -f1))"

# Every module and every manifest entry has to be in the archive. A missing
# module dies on the first `require`; a missing painting is a magenta
# rectangle on the title card. Both are the kind of fault `make run` can
# never show, because the working tree always has the file.
verify-archive:
	@test -f "$(ARCHIVE)" || { echo "  no archive at $(ARCHIVE)" >&2; exit 1; }
	@listing=$$(unzip -Z1 "$(ARCHIVE)"); missing=""; \
	for f in main.lua conf.lua $$(cd . && find src -name '*.lua'); do \
		echo "$$listing" | grep -qx "$$f" || missing="$$missing $$f"; \
	done; \
	for f in $$(python3 -c 'import json,sys; [print(a["file"]) for a in json.load(open(sys.argv[1]))["art"]]' "$(REPO)/art/manifest.json" 2>/dev/null); do \
		echo "$$listing" | grep -qx "art/$$f" || missing="$$missing art/$$f"; \
	done; \
	if [ -n "$$missing" ]; then \
		echo "  the archive is missing:$$missing" >&2; exit 1; \
	fi; \
	echo "  archive carries every module and every painting ($$(echo "$$listing" | grep -c '\.lua$$') lua, $$(echo "$$listing" | grep -c '^art/') art)"

# ---------------------------------------------------------------- macOS app
#
# A real double-clickable .app, with LÖVE inside it: the runtime is downloaded
# and embedded, the archive above goes in Resources, the key library goes in
# Frameworks (where a signed bundle keeps its nested binaries, and where
# `src/wallet.lua` looks for it), the icon is built from the game's own coin,
# and the whole thing is signed and zipped.
#
# Two entitlements are not optional and both are LuaJIT's fault: the hardened
# runtime needs `allow-jit` and `allow-unsigned-executable-memory`, or the
# app dies the moment LuaJIT compiles anything. `disable-library-validation`
# is the third, because the key library is not signed by whoever signed LÖVE
# and dlopen would otherwise refuse it.
#
# Signing uses a Developer ID if the machine has one and falls back to
# ad-hoc, which is enough to run locally and not enough to hand to somebody
# else without them right-clicking Open. `make notarize` finishes the job.

APP_NAME  := CausewaybayHacker
BUNDLE_ID := com.causewaybay.hacker
APP       := $(BUILD)/$(APP_NAME).app
APP_ZIP   := $(BUILD)/$(APP_NAME)-macos.zip
ICON_SRC  := assets/ui_coin.png

app: ffi love-file ## A double-clickable macOS .app with LÖVE embedded (SKIP_SMOKE=1 on a headless runner)
	@test "$$(uname -s)" = "Darwin" || { echo "  'make app' is macOS only." >&2; exit 1; }
	@rm -rf "$(APP)" "$(APP_ZIP)" "$(BUILD)/love-macos"
	@$(MAKE) --no-print-directory love-bin >/dev/null
	@mkdir -p "$(BUILD)/love-macos"
	@unzip -q -o "$(BUILD)/love-$(LOVE_VERSION)-macos.zip" -d "$(BUILD)/love-macos"
	@mv "$(BUILD)/love-macos/love.app" "$(APP)"
	@cp "$(GAME_LOVE)" "$(APP)/Contents/Resources/game.love"
	@mkdir -p "$(APP)/Contents/Frameworks"
	@cp -f "ffi/target/release/$(FFI_LIB)" "$(APP)/Contents/Frameworks/$(FFI_LIB)"

	@# Without these the bundle is still called "LÖVE" everywhere macOS shows
	@# a name, and two LÖVE games installed at once collide on the bundle id.
	@plutil -replace CFBundleName -string "Causewaybay Hacker" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleDisplayName -string "Causewaybay Hacker" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleIdentifier -string "$(BUNDLE_ID)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleShortVersionString -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@plutil -replace CFBundleVersion -string "$(VERSION)" "$(APP)/Contents/Info.plist"
	@# LÖVE ships as an editor for .love documents, so a .love dropped on the
	@# icon runs. This bundle *is* one game and must not open somebody else's.
	@plutil -remove CFBundleDocumentTypes "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -remove UTExportedTypeDeclarations "$(APP)/Contents/Info.plist" 2>/dev/null || true
	@plutil -replace CFBundleExecutable -string "love" "$(APP)/Contents/Info.plist"
	@plutil -replace NSHighResolutionCapable -bool true "$(APP)/Contents/Info.plist"

	@$(MAKE) --no-print-directory app-icon
	@$(MAKE) --no-print-directory app-sign

	@# Skipped where there is no window server to draw into: a CI runner has
	@# no display, and a smoke test that cannot open a window would fail for
	@# a reason that has nothing to do with the bundle. `verify-archive`
	@# above still runs there and catches the missing-module class of fault.
	@if [ -n "$(SKIP_SMOKE)" ]; then \
		echo "  smoke test skipped (SKIP_SMOKE set)"; \
	else \
		$(MAKE) --no-print-directory app-smoke; \
	fi

	@cd "$(BUILD)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" "$(notdir $(APP_ZIP))"
	@rm -rf "$(BUILD)/love-macos"
	@echo
	@echo "  $(APP)"
	@du -sh "$(APP)" "$(APP_ZIP)" | sed 's/^/    /'
	@echo "  open it with: open \"$(APP)\""

# The icon, from the game's own coin. `sips` will not upscale cleanly, so the
# 1024 px source is the top of the ladder and every size is cut from it.
app-icon:
	@test -f "$(ICON_SRC)" || { echo "  no $(ICON_SRC); keeping LÖVE's icon"; exit 0; }
	@rm -rf "$(BUILD)/icon.iconset" && mkdir -p "$(BUILD)/icon.iconset"
	@for size in 16 32 64 128 256 512 1024; do \
		sips -s format png -z $$size $$size "$(ICON_SRC)" \
			--out "$(BUILD)/icon.iconset/icon_$${size}x$${size}.png" > /dev/null 2>&1; \
	done
	@for size in 16 32 128 256 512; do \
		double=$$((size * 2)); \
		cp "$(BUILD)/icon.iconset/icon_$${double}x$${double}.png" \
			"$(BUILD)/icon.iconset/icon_$${size}x$${size}@2x.png" 2>/dev/null || true; \
	done
	@rm -f "$(BUILD)/icon.iconset/icon_1024x1024.png"
	@iconutil -c icns "$(BUILD)/icon.iconset" -o "$(BUILD)/icon.icns"
	@cp "$(BUILD)/icon.icns" "$(APP)/Contents/Resources/OS X AppIcon.icns" 2>/dev/null || true
	@cp "$(BUILD)/icon.icns" "$(APP)/Contents/Resources/Love.icns" 2>/dev/null || true
	@rm -rf "$(BUILD)/icon.iconset" "$(BUILD)/icon.icns"
	@echo "  icon from $(ICON_SRC)"

# Signed inside-out: nested binaries first, then the executable, then the
# bundle. Signing the outer bundle first invalidates itself the moment
# anything inside it is signed afterwards. Every stage gets the entitlements,
# which matches a LÖVE game known to pass notarisation; Apple says they only
# matter on the main executable, so this is redundant rather than wrong.
app-sign:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app'" >&2; exit 1; }
	@rm -f "$(BUILD)/entitlements.plist"
	@printf '%s\n' \
		'<?xml version="1.0" encoding="UTF-8"?>' \
		'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' \
		'<plist version="1.0"><dict>' \
		'  <key>com.apple.security.cs.allow-jit</key><true/>' \
		'  <key>com.apple.security.cs.allow-unsigned-executable-memory</key><true/>' \
		'  <key>com.apple.security.cs.disable-library-validation</key><true/>' \
		'</dict></plist>' \
		> "$(BUILD)/entitlements.plist"
	@# `APPLE_SIGNING_IDENTITY` wins when it is set: that is what the release
	@# workflow exports after importing the certificate into a keychain it
	@# made for the job. The keychain search is for a laptop.
	@identity="$${APPLE_SIGNING_IDENTITY:-}"; \
	if [ -z "$$identity" ] || [ "$$identity" = "-" ]; then \
		identity=$$(security find-identity -v -p codesigning 2>/dev/null \
			| grep "Developer ID Application" | head -1 | awk -F'"' '{print $$2}'); \
	fi; \
	if [ -z "$$identity" ]; then \
		identity="-"; \
		echo "  no Developer ID found - signing ad-hoc (runs here, not elsewhere)"; \
	else \
		echo "  signing as $$identity"; \
	fi; \
	stamp=--timestamp; \
	[ "$$identity" = "-" ] && stamp=""; \
	find "$(APP)/Contents/Frameworks" -type f 2>/dev/null | while read -r file; do \
		if file "$$file" | grep -q "Mach-O"; then \
			codesign --force --options runtime --sign "$$identity" \
				--entitlements "$(BUILD)/entitlements.plist" $$stamp "$$file" || exit 1; \
		fi; \
	done; \
	find "$(APP)/Contents/Frameworks" -maxdepth 1 -name "*.framework" 2>/dev/null | while read -r bundle; do \
		codesign --force --options runtime --sign "$$identity" \
			--entitlements "$(BUILD)/entitlements.plist" $$stamp "$$bundle" || exit 1; \
	done; \
	codesign --force --options runtime --sign "$$identity" \
		--entitlements "$(BUILD)/entitlements.plist" $$stamp \
		"$(APP)/Contents/MacOS/love" || exit 1; \
	codesign --force --options runtime --sign "$$identity" \
		--entitlements "$(BUILD)/entitlements.plist" $$stamp "$(APP)" || exit 1
	@rm -f "$(BUILD)/entitlements.plist"
	@codesign --verify --deep --strict "$(APP)" && echo "  signature verifies"

# Start the thing that was built and see whether it runs. The archive check
# proves every file is present; this proves they add up to a program *and*
# that the bundle found its own key library, which `make run` can never show
# because a checkout always has ffi/target beside it. Driven by a script
# rather than a screenshot so the answer is a line in the log, not a picture.
app-smoke:
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app'" >&2; exit 1; }
	@rm -rf "$(BUILD)/smoke-home" && mkdir -p "$(BUILD)/smoke-home"
	@printf '%s\n' \
		'return {' \
		'  { until_ = function(app)' \
		'      if app.wallet_lib then print("SMOKE ok: the bundle found its key library") return true end' \
		'      return false' \
		'    end, timeout = 15 },' \
		'  { quit = true },' \
		'}' > "$(BUILD)/smoke.lua"
	@CWBH_DRIVE="$(abspath $(BUILD))/smoke.lua" CWBH_SERVER="ws://127.0.0.1:1/ws" \
		"$(APP)/Contents/MacOS/love" --home "$(abspath $(BUILD))/smoke-home" \
		> "$(BUILD)/smoke.log" 2>&1; \
	status=$$?; \
	if [ $$status -ne 0 ] || ! grep -q "SMOKE ok" "$(BUILD)/smoke.log"; then \
		echo "  the bundle did not come up (exit $$status):" >&2; \
		grep -v CapsLock "$(BUILD)/smoke.log" | tail -20 >&2; \
		exit 1; \
	fi
	@rm -rf "$(BUILD)/smoke-home" "$(BUILD)/smoke.lua" "$(BUILD)/smoke.log"
	@echo "  the bundle starts, and it found its key library"

# ---------------------------------------------------------------- notarize
#
# Signing is not enough on its own. Since macOS 10.15 anything distributed
# outside the App Store must also be notarised, or a *downloaded* copy gets
# "Apple could not verify…". Not part of `make app`: it needs credentials
# this repository must not carry, and it uploads the bundle to Apple and
# waits. The variable names are `scripts/codesign-binary.sh`'s, so one
# exported set covers the server binary and the app:
#
#     export APPLE_ID=you@example.com
#     export APPLE_PASSWORD=abcd-efgh-ijkl-mnop   # app-specific
#     export APPLE_TEAM_ID=ABCDE12345
#     make notarize
notarize: ## Notarize and staple the built .app (needs Apple credentials)
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app' first" >&2; exit 1; }
	@for name in APPLE_ID APPLE_PASSWORD APPLE_TEAM_ID; do \
		eval "value=\$$$$name"; \
		[ -n "$$value" ] || { \
			echo "  $$name is not set." >&2; \
			echo "  Notarising needs an Apple ID, an app-specific password" >&2; \
			echo "  from appleid.apple.com, and the team id. None is kept here." >&2; \
			exit 1; }; \
	done
	@# Ad-hoc cannot be notarised, and finding that out from Apple takes
	@# minutes. The signature says which it is, so ask it first.
	@codesign -dv --verbose=2 "$(APP)" 2>&1 | grep -q "Authority=Developer ID Application" || { \
		echo "  $(APP) is not signed with a Developer ID." >&2; \
		echo "  Apple will refuse an ad-hoc signature; there is nothing to submit." >&2; \
		exit 1; }
	@echo "  submitting to Apple - this takes minutes, not seconds"
	@ditto -c -k --sequesterRsrc --keepParent "$(APP)" "$(BUILD)/notarize.zip"
	@xcrun notarytool submit "$(BUILD)/notarize.zip" \
		--apple-id "$$APPLE_ID" \
		--password "$$APPLE_PASSWORD" \
		--team-id "$$APPLE_TEAM_ID" \
		--wait --timeout 20m
	@rm -f "$(BUILD)/notarize.zip"
	@# Stapled, so the ticket travels with the bundle and Gatekeeper can
	@# check it with no network at all.
	@xcrun stapler staple "$(APP)"
	@xcrun stapler validate "$(APP)"
	@# The distribution zip was made before any of this and carries an
	@# unstapled copy. Rebuilt, or the download is exactly what it was.
	@rm -f "$(APP_ZIP)"
	@cd "$(BUILD)" && ditto -c -k --sequesterRsrc --keepParent "$(APP_NAME).app" "$(notdir $(APP_ZIP))"
	@$(MAKE) --no-print-directory gatekeeper

# What a person who downloads it will actually get. `--context
# context:primary-signature` is the one that matters: plain `spctl -a`
# accepts an un-notarised Developer ID bundle, and Finder does not.
gatekeeper: ## Assess the bundle the way Finder does
	@test -d "$(APP)" || { echo "  no $(APP); run 'make app' first" >&2; exit 1; }
	@codesign --verify --deep --strict "$(APP)" && echo "  signature: valid"
	@if xcrun stapler validate "$(APP)" > /dev/null 2>&1; then \
		echo "  notarised: yes, and stapled"; \
	else \
		echo "  notarised: NO - a downloaded copy will be blocked"; \
	fi
	@spctl -a -vvv -t open --context context:primary-signature "$(APP)" 2>&1 \
		| sed 's/^/  /' || true
