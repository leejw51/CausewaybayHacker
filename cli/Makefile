# Causewaybay Hacker — the terminal client.
#
# One crate, one binary: `cwbh`. `make` lists the targets.
#
# The suite here is in two halves. `cargo test --test vectors` is the shared
# conformance fixtures in `tests/vectors/` — the same ones the browser, the
# LÖVE client and the smoke harness are checked against, so four
# implementations cannot drift apart without this going red.
# `cargo test --test conformance` is PROTOCOL §8's checklist, against a mock
# websocket server: the half of §8 that is a property of the *client* and that
# a real server will not exhibit on request.

CARGO   ?= cargo
BIN     := cwbh
SERVER  ?= 127.0.0.1:5390

.DEFAULT_GOAL := help

.PHONY: help
help: ## Show this help
	@echo "Causewaybay Hacker — the terminal client ($(BIN))"
	@echo
	@grep -hE '^[a-zA-Z0-9_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-14s\033[0m %s\n", $$1, $$2}'
	@echo
	@echo "  make run ARGS=\"map rust basic\"     make tui     make check"
	@echo

.PHONY: build
build: ## Build the debug binary
	$(CARGO) build

.PHONY: release
release: ## Build the optimised binary
	$(CARGO) build --release

.PHONY: test
test: ## Unit tests, the shared vectors, and the §8 conformance suite
	$(CARGO) test --all-targets

.PHONY: test-vectors
test-vectors: ## Only the shared fixtures in tests/vectors (SPEC §9)
	$(CARGO) test --test vectors

.PHONY: test-conformance
test-conformance: ## Only PROTOCOL §8, against the mock server
	$(CARGO) test --test conformance

.PHONY: fmt
fmt: ## Format the source
	$(CARGO) fmt --all

.PHONY: fmt-check
fmt-check: ## Fail if the source is not formatted
	$(CARGO) fmt --all --check

.PHONY: lint
lint: ## clippy, warnings denied, changing nothing
	$(CARGO) clippy --all-targets -- -D warnings

.PHONY: check
check: fmt-check lint test ## Everything CI would run

.PHONY: run
run: ## Run a command, e.g. make run ARGS="map rust basic"
	@$(CARGO) run --quiet -- $(ARGS)

.PHONY: tui
tui: ## Launch the full-screen client
	@$(CARGO) run --quiet -- tui

.PHONY: doctor
doctor: ## What this client thinks about the store, the server and your editor
	@$(CARGO) run --quiet -- --server $(SERVER) doctor

.PHONY: install
install: ## Install cwbh into ~/.cargo/bin
	$(CARGO) install --path . --force

.PHONY: demo
demo: build ## A throwaway login and a look around, in ./.demo-home
	@rm -rf .demo-home
	@printf 'abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon abandon about\n' \
		| CWBH_HOME=$$PWD/.demo-home ./target/debug/$(BIN) --server $(SERVER) login --stdin --name demo
	@CWBH_HOME=$$PWD/.demo-home ./target/debug/$(BIN) --server $(SERVER) maps
	@echo
	@echo "Store contents (a token and a server; no key material):"
	@cat .demo-home/state.jsonl

.PHONY: clean
clean: ## Remove build artefacts and the demo home
	$(CARGO) clean
	rm -rf .demo-home
