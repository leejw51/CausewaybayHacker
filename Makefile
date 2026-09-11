# Causewaybay Hacker.
#
#   make          what you can do
#   make start    bring the servers up in the background
#   make stop     put them down again
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

# How long `start` waits for a port to answer before calling it a failure.
WAIT_SECS  ?= 90

# True when $(1) is held by a process whose name matches $(2) — that is, by
# something of ours. Used as a plain shell test rather than a sub-make, because
# a sub-make that returns non-zero prints `make: *** Error 1` at you, and
# "the frontend is not running" is an answer, not an error.
held = p=$$(lsof -nP -iTCP:$(1) -sTCP:LISTEN -t 2>/dev/null | head -1); \
       [ -n "$$p" ] && ps -o comm= -p $$p 2>/dev/null | grep -qE '$(2)'

.PHONY: help start stop restart status logs remote art gui serve web build test test-all test-all-list test-be test-fe \
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
	@if [ ! -x "$(VITE)" ]; then echo "installing frontend deps…"; cd frontend && npm install; fi
	@$(MAKE) -s art
	@if $(call held,$(BACK_PORT),cwbhacker); then :; elif [ ! -f frontend/dist/index.html ]; then \
	  echo "building the frontend (the server serves it on $(BACK_PORT))…"; \
	  cd frontend && npm run build >/dev/null 2>&1 || { echo "  frontend build failed — run 'cd frontend && npm run build'"; exit 1; }; \
	fi
	@if $(call held,$(BACK_PORT),cwbhacker); then :; else \
	  CAUSEWAYBAY_HACKER_HOME=$(HOME_DIR) nohup $(BACK_BIN) serve --bind $(BIND):$(BACK_PORT) \
	    < /dev/null > $(RUN)/backend.log 2>&1 & echo $$! > $(RUN)/backend.pid; \
	  $(MAKE) -s _wait PORT=$(BACK_PORT) WHAT=backend LOG=$(RUN)/backend.log; \
	fi
	@if $(call held,$(WEB_PORT),node|vite); then \
	  echo "  frontend already up on $(WEB_PORT)"; \
	else \
	  ( cd frontend && exec ../$(VITE) --host --port $(WEB_PORT) ) \
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

test: test-be test-fe ## the Rust and TypeScript suites (fast; see test-all)
test-be: ## the Rust suite (add ARGS="-- --ignored" for the content check)
	cd backend && cargo test --workspace $(ARGS)
test-fe: ## the TypeScript suite
	cd frontend && npm test
test-love: ## the LÖVE client, headless
	$(MAKE) -C love2d test-headless
test-e2e: ## playwright, both orientations (needs `make start`)
	cd e2e && npx playwright test
smoke: ## drive the live server against PROTOCOL.md §8 (needs `make start`)
	@test -d tests/smoke && $(MAKE) -C tests/smoke run || echo "tests/smoke is not built yet"

fmt: ## format everything
	cd backend && cargo fmt
	cd frontend && npm run fmt
	$(MAKE) -C love2d fmt

lint: ## clippy, tsc, and the LÖVE layering check
	cd backend && cargo clippy --all-targets --workspace -- -D warnings
	cd frontend && npm run lint
	$(MAKE) -C love2d lint

doctor: ## check the toolchains and the server's own view of things
	@command -v cargo >/dev/null && cargo --version   || echo "MISSING: rust   — https://rustup.rs"
	@command -v go    >/dev/null && go version        || echo "MISSING: go     — needed for the go land"
	@command -v node  >/dev/null && node --version    || echo "MISSING: node   — needed for the browser client"
	@command -v love  >/dev/null && love --version    || echo "no love on PATH — 'make -C love2d love-bin' fetches it"
	@test -x $(BACK_BIN) && CAUSEWAYBAY_HACKER_HOME=$(HOME_DIR) $(BACK_BIN) doctor \
	  || echo "backend not built yet — 'make start' or 'cd backend && cargo build'"

clean: ## drop build output (your progress is untouched)
	cd backend && cargo clean
	rm -rf frontend/dist frontend/node_modules $(RUN)
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
