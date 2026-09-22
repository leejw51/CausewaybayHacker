# Causewaybay Hacker.
#
#   make          what you can do
#   make start    bring the servers up in the background
#   make stop     put them down again
#   make package  every release binary into dist/ (server tarball, LÖVE app)
#
# `start` runs the servers detached, with their pids in .run/ and their output
# in .run/*.log, so a terminal that started them can be closed and another one
# can still stop them. Two rules make that reliable:
#
#   * Nothing is launched through a wrapper. `cargo run` and `npm run` each
#     fork a child and hand you the *wrapper's* pid, so killing what you were
#     given leaves the real server holding the port. We build first, then exec
#     the binary and vite directly, and the pid we record is the pid that
#     listens.
#   * `stop` still sweeps the ports afterwards, in case something was started
#     by hand — but only kills a process it recognises as ours. Somebody
#     else's server on 5291 is their business.
#
# Both servers are started under `nohup` with stdin on /dev/null, so they hold
# none of the launching terminal's descriptors. Without that, `make start`
# appears to hang — the shell has returned, but whatever is reading its output
# waits on a pipe the servers are still holding open — and closing the window
# later takes the servers down with it.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Override any of these: `make start BACK_PORT=6000`
BACK_PORT  ?= 5390
WEB_PORT   ?= 5291

# What the server listens on. 0.0.0.0 so a phone on the tailnet (or the LAN)
# can reach it; `make start LOCAL=1` pins it back to loopback.
#
# Read this before leaving it open: the server compiles and runs the code
# submitted to it, on this machine, as you (SPEC §5.3). On a tailnet that is
# your own devices. On a network you do not control it is a remote shell with
# extra steps. `start` prints what is reachable every time, so the state is
# never a surprise.
BIND       ?= $(if $(LOCAL),127.0.0.1,0.0.0.0)

# Tailscale has no CLI on PATH in the macOS app build; the binary inside the
# bundle is the same program. Failing that, a 100.x address on an interface is
# the tailnet by CGNAT convention.
TS_BIN     := $(firstword $(shell command -v tailscale) /Applications/Tailscale.app/Contents/MacOS/Tailscale)
TS_IP       = $$($(TS_BIN) ip -4 2>/dev/null | head -1 || ifconfig 2>/dev/null | grep -oE 'inet 100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 | cut -d' ' -f2)
LAN_IP      = $$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null)
HOME_DIR   ?= $(HOME)/.causewaybayhacker
RUN        := .run
BACK_BIN   := backend/target/debug/cwbhacker
VITE       := frontend/node_modules/.bin/vite

# **The game's own python leads PATH, when the machine has one set aside.**
#
# PyTorch Land's toolchain is the fifth entry on the list — RUST, GO, C++,
# PYTHON, ANACONDA — and the odd one out: not a program on PATH but a package
# inside an interpreter. The interpreters a Mac or a PEP 668 distribution
# hands you refuse to install into themselves, so the answer everywhere
# (`make doctor`, SPEC §5.1, the runner's own hint) is an environment of the
# game's own: a conda env named `cwbhacker`, or a venv at $(HOME_DIR)/venv.
#
# Finding it cannot be the player's job. `make start` from an ordinary shell
# finds /usr/bin/python3 — on a Mac, a 3.9 with no torch — and the fifth land
# goes back to dying of ModuleNotFoundError on every node, which is how this
# rule came to be written. So if one of these exists, everything this Makefile
# starts sees it first: the server, `doctor`, the content gate. Nothing
# exists, nothing changes; the ambient python3 is used exactly as before.
#
# In order: an override you set, then conda, then a venv. The conda roots are
# listed rather than resolved through `conda` itself, because `conda` is a
# shell function on a configured machine and not a program a Makefile can run.
CONDA_ENV  := $(firstword $(wildcard \
                $(patsubst %/bin/conda,%,$(CONDA_EXE))/envs/cwbhacker/bin \
                /opt/anaconda3/envs/cwbhacker/bin \
                /opt/miniconda3/envs/cwbhacker/bin \
                $(HOME)/anaconda3/envs/cwbhacker/bin \
                $(HOME)/miniconda3/envs/cwbhacker/bin \
                $(HOME)/miniforge3/envs/cwbhacker/bin))
GAME_PY_BIN ?= $(firstword $(CONDA_ENV) $(wildcard $(HOME_DIR)/venv/bin))
ifneq ($(wildcard $(GAME_PY_BIN)/python3),)
PATH       := $(GAME_PY_BIN):$(PATH)
export PATH
endif

# How long `start` waits for a port to answer before calling it a failure.
WAIT_SECS  ?= 90

# The version of record. Four manifests carry one: the backend workspace, the
# CLI crate, the LÖVE key library and the frontend. `make version` prints it
# only when all four agree, and the release workflow compares the tag to it.
BE_VERSION  := $(shell sed -n 's/^version = "\(.*\)"/\1/p' backend/Cargo.toml | head -1)
CLI_VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' cli/Cargo.toml | head -1)
FFI_VERSION := $(shell sed -n 's/^version = "\(.*\)"/\1/p' love2d/ffi/Cargo.toml | head -1)
FE_VERSION  := $(shell sed -n 's/^  "version": "\(.*\)",/\1/p' frontend/package.json | head -1)
VERSION     := $(BE_VERSION)

# Where `make package` puts what it built, and what the archives are named.
DIST       := dist
TARGET     := $(shell rustc -vV 2>/dev/null | sed -n 's/^host: //p')
SIGN       := scripts/codesign-binary.sh
SERVER_PKG := causewaybay-hacker-server-$(VERSION)-$(TARGET)

# True when $(1) is held by a process whose name matches $(2) — that is, by
# something of ours. Used as a plain shell test rather than a sub-make, because
# a sub-make that returns non-zero prints `make: *** Error 1` at you, and
# "the frontend is not running" is an answer, not an error.
held = p=$$(lsof -nP -iTCP:$(1) -sTCP:LISTEN -t 2>/dev/null | head -1); \
       [ -n "$$p" ] && ps -o comm= -p $$p 2>/dev/null | grep -qE '$(2)'

# The two "is what we built still current?" questions. Both are *staleness*,
# not existence: guarding a rebuild on `dist/index.html` being present means a
# pull that changes the frontend is never rebuilt, and the server goes on
# serving the previous bundle with no sign that it is doing so. That is a
# silent wrong answer, which is worse than a slow one.
#
# npm >= 7 writes node_modules/.package-lock.json when it installs, so the
# lockfile being newer than that marker is exactly "someone added a dependency
# since the last install". Missing marker means no install has ever happened.
deps_stale = [ ! -f frontend/node_modules/.package-lock.json ] || \
             [ frontend/package-lock.json -nt frontend/node_modules/.package-lock.json ]

# `art` rsyncs with -a (which implies -t), so frontend/public/art keeps the
# mtimes of art/ and including public/ here does not re-trigger on every start.
DIST_SRC := frontend/src frontend/public frontend/index.html \
            frontend/package.json frontend/vite.config.ts frontend/tsconfig.json
dist_stale = [ ! -f frontend/dist/index.html ] || \
             [ -n "$$(find $(DIST_SRC) -newer frontend/dist/index.html 2>/dev/null | head -1)" ]

.PHONY: help dev start stop restart status logs remote art rebuild _deps _bundle gui serve web build test test-all test-all-list test-be test-fe \
        fmt-check check version package release package-server package-server-verify package-gui package-love \
        test-love test-e2e smoke fmt lint doctor clean clean-home

##@ Running

help: ## what you can do
	@awk 'BEGIN {FS = ":.*##"} \
	  /^##@/ { printf "\n\033[1m%s\033[0m\n", substr($$0, 5); next } \
	  /^[a-z][a-z-]*:.*##/ { printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2 }' \
	  $(MAKEFILE_LIST)
	@echo ""
	@echo "  the game        http://127.0.0.1:$(BACK_PORT)   (and from a phone, see: make remote)"
	@echo "  hot reload      http://127.0.0.1:$(WEB_PORT)   (this machine only)"
	@echo "  your progress   $(HOME_DIR)"
	@echo ""

dev: start ## alias for start (the README's and PLAN.md's name for it)

start: ## start both servers in the background
	@mkdir -p $(RUN)
	@# Per service, not all-or-nothing: a rebuild replaces the backend binary
	@# and kills it while the dev server keeps running, and refusing to start
	@# the half that is down because the other half is up is how you end up
	@# staring at CONNECTION LOST.
	@if $(call held,$(BACK_PORT),cwbhacker); then \
	  echo "backend already up on $(BACK_PORT) — 'make restart' to bounce it"; \
	else \
	  echo "building the backend (the first one is slow)…"; \
	  ( cd backend && cargo build -p cwbhacker 2>&1 | tail -3 ) || exit 1; \
	fi
	@$(MAKE) -s _deps
	@$(MAKE) -s art
	@if $(call dist_stale); then $(MAKE) -s _bundle; fi
	@if $(call held,$(BACK_PORT),cwbhacker); then :; else \
	  CAUSEWAYBAY_HACKER_HOME=$(HOME_DIR) nohup $(BACK_BIN) serve --bind $(BIND):$(BACK_PORT) \
	    < /dev/null > $(RUN)/backend.log 2>&1 & echo $$! > $(RUN)/backend.pid; \
	  $(MAKE) -s _wait PORT=$(BACK_PORT) WHAT=backend LOG=$(RUN)/backend.log; \
	fi
	@if $(call held,$(WEB_PORT),node|vite); then \
	  echo "  frontend already up on $(WEB_PORT)"; \
	else \
	  ( cd frontend && exec ../$(VITE) --port $(WEB_PORT) ) \
	    < /dev/null > $(RUN)/web.log 2>&1 & echo $$! > $(RUN)/web.pid; \
	  $(MAKE) -s _wait PORT=$(WEB_PORT) WHAT=frontend LOG=$(RUN)/web.log; \
	fi
	@echo ""
	@echo "  play here     http://127.0.0.1:$(BACK_PORT)"
	@echo "  hot reload    http://127.0.0.1:$(WEB_PORT)   (this machine only — see below)"
	@$(MAKE) -s remote
	@echo "  logs          make logs"
	@echo "  stop          make stop"

stop: ## stop both servers
	@$(MAKE) -s _stop-one WHAT=frontend PIDFILE=$(RUN)/web.pid PORT=$(WEB_PORT) MATCH=node
	@$(MAKE) -s _stop-one WHAT=backend  PIDFILE=$(RUN)/backend.pid PORT=$(BACK_PORT) MATCH=cwbhacker
	@echo "stopped"

restart: ## stop, then start
	@$(MAKE) -s stop
	@$(MAKE) -s start

status: ## what is up, and on which port
	@printf "  %-10s " backend; \
	  if $(call held,$(BACK_PORT),cwbhacker); then \
	    echo "up    pid $$(lsof -nP -iTCP:$(BACK_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1)  ws://127.0.0.1:$(BACK_PORT)/ws"; \
	  else echo "down"; fi
	@printf "  %-10s " frontend; \
	  if $(call held,$(WEB_PORT),node|vite); then \
	    echo "up    pid $$(lsof -nP -iTCP:$(WEB_PORT) -sTCP:LISTEN -t 2>/dev/null | head -1)  http://127.0.0.1:$(WEB_PORT)"; \
	  else echo "down"; fi
	@printf "  %-10s %s\n" home "$(HOME_DIR)"

remote: ## the addresses a phone or another machine can use
	@ts=$(TS_IP); lan=$(LAN_IP); \
	if [ "$(BIND)" = "127.0.0.1" ]; then \
	  echo "  remote        none — bound to loopback (drop LOCAL=1 to open it up)"; \
	else \
	  [ -n "$$ts" ]  && echo "  on tailscale  http://$$ts:$(BACK_PORT)"   || echo "  on tailscale  not connected"; \
	  [ -n "$$lan" ] && echo "  on this LAN   http://$$lan:$(BACK_PORT)"  || true; \
	  echo "  ⚠ this port compiles and runs submitted code as you. Fine on your"; \
	  echo "    own tailnet; not fine on a network you do not control."; \
	fi
	@echo "  note          use $(BACK_PORT) from a phone, not $(WEB_PORT): the page and the"
	@echo "                websocket must share an origin, and $(WEB_PORT) is dev-only."

logs: ## follow both logs (ctrl-C to stop following; the servers stay up)
	@tail -f $(RUN)/backend.log $(RUN)/web.log

gui: ## play in the LÖVE desktop client (fetches LÖVE and builds the key library if needed)
	@# The client needs three things and each fails differently if it is missing,
	@# so check them here rather than let the player meet three separate errors.
	@if ! $(call held,$(BACK_PORT),cwbhacker); then \
	  echo "the server is not up — starting it first"; $(MAKE) -s start; fi
	@test -f love2d/ffi/target/release/libcwbh_ffi.dylib \
	  || { echo "building the key library…"; $(MAKE) -s -C love2d ffi; }
	@command -v love >/dev/null || test -d love2d/build/love.app \
	  || { echo "fetching LÖVE…"; $(MAKE) -s -C love2d love-bin; }
	@echo "  connecting to ws://127.0.0.1:$(BACK_PORT)/ws  (CWBH_SERVER overrides)"
	CWBH_SERVER=ws://127.0.0.1:$(BACK_PORT)/ws $(MAKE) -s -C love2d run

serve: ## the backend in the foreground, for a stack trace
	cd backend && CAUSEWAYBAY_HACKER_HOME=$(HOME_DIR) cargo run -p cwbhacker -- serve --bind $(BIND):$(BACK_PORT)

web: ## the frontend in the foreground
	cd frontend && npm run dev

rebuild: ## rebuild the frontend bundle the game server serves
	@$(MAKE) -s _deps
	@$(MAKE) -s art
	@$(MAKE) -s _bundle
	@if $(call held,$(BACK_PORT),cwbhacker); then \
	  echo "  reload the page on $(BACK_PORT) — the server reads dist/ per request"; \
	else \
	  echo "  'make start' to bring the server up"; \
	fi

# Install only when the lockfile has moved since the last install. Checking
# that the vite binary exists answers a different question, and answers it yes
# for every dependency added after the first install.
_deps:
	@if $(call deps_stale); then \
	  echo "installing frontend deps…"; \
	  ( cd frontend && npm install ) || exit 1; \
	fi

# The one place the bundle is built. `start` calls it behind `dist_stale`,
# `rebuild` calls it unconditionally. Output is kept on failure — the reason a
# build failed (a missing module, a type error) is the whole message, and
# sending it to /dev/null leaves "frontend build failed" and nothing to act on.
_bundle:
	@echo "building the frontend (the server serves it on $(BACK_PORT))…"
	@( cd frontend && npm run build 2>&1 | tail -5 ) || \
	  { echo "  frontend build failed — see above"; exit 1; }

art: ## copy art/ into the frontend's public/ (it serves its own copy)
	@rsync -a --delete --exclude tools/ --exclude raw/ --exclude prompts.toml art/ frontend/public/art/
	@printf "  art  %s files in frontend/public/art\n" "$$(ls frontend/public/art/*.png frontend/public/art/*.jpg 2>/dev/null | wc -l | tr -d ' ')"

##@ Building and testing

build: ## release build, with the frontend bundled into the server
	@$(MAKE) -s art
	cd frontend && npm ci && npm run build
	cd backend && cargo build --release

test-all: ## every suite, one command, with an honest summary of what was skipped
	node tests/run-all.mjs
test-all-list: ## what test-all would run, and why anything would not
	node tests/run-all.mjs --list

# All three clients share one protocol and now one derivation — the display
# name is implemented in Rust, TypeScript and Lua, and the three agree only
# because the same vectors are asserted in each. Running two of the three and
# calling it `test` is how they would drift.
#
# The LÖVE suite is headless and needs `luajit`, not a LÖVE binary or a window.
test: test-be test-fe test-love ## the Rust, TypeScript and LÖVE suites (see test-all)
test-be: ## the Rust suite (add ARGS="-- --ignored" for the content check)
	cd backend && cargo test --workspace $(ARGS)
test-fe: ## the TypeScript suite
	cd frontend && npm test
test-love: ## the LÖVE client, headless
	$(MAKE) -C love2d test-headless
test-e2e: ## playwright, both orientations (needs `make start`)
	cd e2e && npx playwright test
smoke: ## drive the live server against PROTOCOL.md §8 (needs `make start`)
	@# `tests/smoke` has no Makefile; the checker is one node script with one
	@# dependency, and it used to be asked for a `run` target that never
	@# existed — so `make smoke` printed "not built yet" on a checkout that
	@# had it and nobody ran the contract.
	@test -d tests/smoke/node_modules/ws || ( cd tests/smoke && npm ci --silent )
	node tests/smoke/contract.mjs

fmt: ## format everything
	cd backend && cargo fmt
	cd frontend && npm run fmt
	$(MAKE) -C love2d fmt

lint: ## clippy (backend, cli, key library), tsc, and the LÖVE layering check
	cd backend && cargo clippy --all-targets --workspace -- -D warnings
	cd love2d/ffi && cargo clippy --all-targets -- -D warnings
	cd frontend && npm run lint
	$(MAKE) -C love2d lint

fmt-check: ## fail if anything is not formatted (what CI runs)
	cd backend && cargo fmt --check
	cd cli && cargo fmt --check
	cd love2d/ffi && cargo fmt --check

check: fmt-check lint test test-love ## everything CI runs on a pull request, in one word
	$(MAKE) -C cli check

version: ## print the version, once every manifest agrees on it
	@test "$(BE_VERSION)" = "$(CLI_VERSION)" -a "$(BE_VERSION)" = "$(FFI_VERSION)" -a "$(BE_VERSION)" = "$(FE_VERSION)" || { \
	  echo "ERROR: the manifests disagree — backend $(BE_VERSION), cli $(CLI_VERSION), love2d/ffi $(FFI_VERSION), frontend $(FE_VERSION)" >&2; \
	  exit 1; }
	@echo "$(VERSION)"

##@ Packaging

# `make package` is every release binary, into $(DIST):
#
#   $(SERVER_PKG).tar.gz        the server: cwbhacker (BE) with the built
#                               frontend (FE) and the content packs beside it,
#                               plus the cwbh terminal client and a run script
#   CausewaybayHacker-macos.zip the LÖVE client as a double-clickable .app
#                               (macOS only — see love2d/Makefile)
#   causewaybay-hacker.love     the same game for anyone with their own LÖVE 11
#
# The halves are separate targets because they want different machines: the
# server tarball is per platform and builds anywhere Rust and Node do, the
# app needs macOS. The release workflow runs each where it belongs.
package: package-server package-gui ## every release binary: the server tarball and the LÖVE client
	@echo
	@echo "  $(DIST)/"
	@ls -1 $(DIST) | sed 's/^/    /'

release: package ## alias for package

package-server: ## the server (BE + FE + content) and the CLI, as one tarball in $(DIST)
	@$(MAKE) -s version >/dev/null
	@$(MAKE) -s art
	cd frontend && npm ci --silent && npm run build --silent
	cd backend && cargo build --release -p cwbhacker
	cd cli && cargo build --release
	@rm -rf "$(DIST)/$(SERVER_PKG)" "$(DIST)/$(SERVER_PKG).tar.gz"
	@mkdir -p "$(DIST)/$(SERVER_PKG)/web"
	@cp backend/target/release/cwbhacker "$(DIST)/$(SERVER_PKG)/cwbhacker"
	@cp cli/target/release/cwbh "$(DIST)/$(SERVER_PKG)/cwbh"
	@cp -R frontend/dist/. "$(DIST)/$(SERVER_PKG)/web/"
	@cp -R content "$(DIST)/$(SERVER_PKG)/content"
	@cp README.md LICENSE SPEC.md PROTOCOL.md "$(DIST)/$(SERVER_PKG)/"
	@$(SIGN) "$(DIST)/$(SERVER_PKG)/cwbhacker"
	@$(SIGN) "$(DIST)/$(SERVER_PKG)/cwbh"
	@# The launcher: the server needs to be told where its frontend and its
	@# content are, because outside a checkout it cannot walk up to them.
	@printf '%s\n' \
		'#!/bin/sh' \
		'# Causewaybay Hacker — the server, with the web client and the content packs beside it.' \
		'#' \
		'#   ./run.sh                  serve on 127.0.0.1:5390 (this machine only)' \
		'#   ./run.sh --bind 0.0.0.0:5390   ...reachable from your other devices' \
		'#' \
		'# Read README.md before binding to anything but loopback: the server compiles' \
		'# and runs the code submitted to it, on this machine, as you. It is a trainer,' \
		'# not a sandbox. Progress lives in ~/.causewaybayhacker (or --home DIR).' \
		'set -eu' \
		'here=$$(CDPATH= cd -- "$$(dirname -- "$$0")" && pwd)' \
		'exec "$$here/cwbhacker" serve --static "$$here/web" --content "$$here/content" "$$@"' \
		> "$(DIST)/$(SERVER_PKG)/run.sh"
	@chmod +x "$(DIST)/$(SERVER_PKG)/run.sh"
	@$(MAKE) -s package-server-verify
	@cd "$(DIST)" && COPYFILE_DISABLE=1 tar -czf "$(SERVER_PKG).tar.gz" "$(SERVER_PKG)"
	@echo "  $(DIST)/$(SERVER_PKG).tar.gz  ($$(du -h "$(DIST)/$(SERVER_PKG).tar.gz" | cut -f1))"

# Start what was staged, from outside the checkout, and see that it serves
# the page and imports every pack. A staged server that cannot find its
# frontend answers the root with a "there is no frontend/dist yet" page and
# a 200, so the check is for the page's own markup, not the status.
package-server-verify:
	@pkg="$(abspath $(DIST)/$(SERVER_PKG))"; port=$$((5600 + RANDOM % 200)); home=$$(mktemp -d); \
	"$$pkg/cwbhacker" --version | grep -q "$(VERSION)" || { echo "  cwbhacker does not report $(VERSION)" >&2; exit 1; }; \
	"$$pkg/cwbh" --version | grep -q "$(VERSION)" || { echo "  cwbh does not report $(VERSION)" >&2; exit 1; }; \
	( cd /tmp && "$$pkg/run.sh" --bind 127.0.0.1:$$port --home "$$home" --strict-content > "$$home/server.log" 2>&1 & echo $$! > "$$home/pid" ); \
	ok=""; for _ in $$(seq 1 60); do \
	  if curl -fsS "http://127.0.0.1:$$port/" 2>/dev/null | grep -q '<script'; then ok=1; break; fi; sleep 0.5; \
	done; \
	kill "$$(cat "$$home/pid")" 2>/dev/null || true; \
	if [ -z "$$ok" ]; then echo "  the packaged server did not serve the page:" >&2; tail -20 "$$home/server.log" >&2; rm -rf "$$home"; exit 1; fi; \
	grep -q "content imported" "$$home/server.log" || { echo "  the packaged server did not import its content:" >&2; tail -20 "$$home/server.log" >&2; rm -rf "$$home"; exit 1; }; \
	rm -rf "$$home"; \
	echo "  the packaged server serves the page and imports every pack"

package-gui: ## the LÖVE client: a macOS .app (signed) and a .love, into $(DIST)
	@$(MAKE) -s version >/dev/null
	@$(MAKE) -C love2d app $(if $(SKIP_SMOKE),SKIP_SMOKE=1,)
	@mkdir -p "$(DIST)"
	@cp love2d/build/CausewaybayHacker-macos.zip "$(DIST)/CausewaybayHacker-$(VERSION)-$(TARGET).zip"
	@cp love2d/build/causewaybay-hacker.love "$(DIST)/causewaybay-hacker-$(VERSION).love"
	@echo "  $(DIST)/CausewaybayHacker-$(VERSION)-$(TARGET).zip"
	@echo "  $(DIST)/causewaybay-hacker-$(VERSION).love"

package-love: ## just the .love archive (any platform with zip)
	@$(MAKE) -C love2d love-file
	@mkdir -p "$(DIST)"
	@cp love2d/build/causewaybay-hacker.love "$(DIST)/causewaybay-hacker-$(VERSION).love"
	@echo "  $(DIST)/causewaybay-hacker-$(VERSION).love"

doctor: ## check the toolchains and the server's own view of things
	@command -v cargo >/dev/null && cargo --version   || echo "MISSING: rust   — https://rustup.rs"
	@command -v go    >/dev/null && go version        || echo "MISSING: go     — needed for the go land"
	@command -v c++   >/dev/null && c++ --version | head -1 || echo "MISSING: c++    — needed for the cpp land (clang or gcc)"
	@command -v python3 >/dev/null && python3 --version || echo "MISSING: python3 — needed for the python land (3.10+)"
	@if python3 -I -c "import torch" 2>/dev/null; then \
	  python3 -I -c "import torch; print('torch      ', torch.__version__)"; \
	  python3 -I -c "import numpy" 2>/dev/null \
	    || printf 'no numpy beside torch — torch prints a NumPy warning on stderr on every\n            import, which lands in every attempt: pip install numpy\n'; \
	else \
	  printf 'MISSING: torch   — needed for the pytorch land. Give it an env of its own:\n'; \
	  printf '           conda create -n cwbhacker python=3.13 -y\n'; \
	  printf '           conda run -n cwbhacker pip install torch numpy black\n'; \
	  printf '           and this Makefile will find it by name and put it first on PATH\n'; \
	  printf '           for everything it starts. No conda? A venv at\n'; \
	  printf '           ~/.causewaybayhacker/venv is picked up the same way, and\n'; \
	  printf '           GAME_PY_BIN=/path/to/bin overrides both. An env of its own because\n'; \
	  printf "           macOS's own python3 and any PEP 668 distribution refuse to install\n"; \
	  printf '           into themselves, and the --user they suggest instead is the one\n'; \
	  printf '           place the isolated "python3 -I" the runner uses will not look.\n'; \
	fi
	@command -v clang-format >/dev/null && clang-format --version || echo "no clang-format on PATH — optional; the cpp land has no fmt without it"
	@command -v node  >/dev/null && node --version    || echo "MISSING: node   — needed for the browser client"
	@command -v love  >/dev/null && love --version    || echo "no love on PATH — 'make -C love2d love-bin' fetches it"
	@test -x $(BACK_BIN) && CAUSEWAYBAY_HACKER_HOME=$(HOME_DIR) $(BACK_BIN) doctor \
	  || echo "backend not built yet — 'make start' or 'cd backend && cargo build'"

clean: ## drop build output (your progress is untouched)
	cd backend && cargo clean
	rm -rf frontend/dist frontend/node_modules $(RUN) $(DIST)
	$(MAKE) -C love2d clean

clean-home: ## DELETE every user's code, attempts and progress in $(HOME_DIR)
	@echo "This deletes $(HOME_DIR): every user, every attempt, every cleared node."
	@read -p "Type the word yes to confirm: " a; [ "$$a" = "yes" ] || { echo "left alone"; exit 1; }
	rm -rf $(HOME_DIR)

# ---------------------------------------------------------------- internals --
# Not in `help`: no `##` comment.

_wait:
	@for i in $$(seq 1 $(WAIT_SECS)); do \
	  if lsof -nP -iTCP:$(PORT) -sTCP:LISTEN >/dev/null 2>&1; then \
	    echo "  $(WHAT) up on $(PORT)"; exit 0; fi; \
	  sleep 1; \
	done; \
	echo "  $(WHAT) did not come up on $(PORT) in $(WAIT_SECS)s. Last of $(LOG):"; \
	tail -20 $(LOG); exit 1

_stop-one:
	@pid=$$(cat $(PIDFILE) 2>/dev/null); \
	if [ -n "$$pid" ] && kill -0 $$pid 2>/dev/null; then \
	  kill $$pid 2>/dev/null; \
	  for i in $$(seq 1 10); do kill -0 $$pid 2>/dev/null || break; sleep 0.5; done; \
	  kill -0 $$pid 2>/dev/null && { echo "  $(WHAT) ignored SIGTERM; SIGKILL"; kill -9 $$pid 2>/dev/null; }; \
	  echo "  $(WHAT) stopped (pid $$pid)"; \
	fi; \
	rm -f $(PIDFILE); \
	holder=$$(lsof -nP -iTCP:$(PORT) -sTCP:LISTEN -t 2>/dev/null | head -1); \
	if [ -n "$$holder" ]; then \
	  name=$$(ps -o comm= -p $$holder 2>/dev/null); \
	  case "$$name" in \
	    *$(MATCH)*) kill $$holder 2>/dev/null; echo "  $(WHAT) orphan on $(PORT) stopped (pid $$holder)";; \
	    *) echo "  note: $(PORT) is held by $$name (pid $$holder), which is not ours — left alone";; \
	  esac; \
	fi
