# Causewaybay Hacker. `make` lists the targets.
.DEFAULT_GOAL := help
.PHONY: help dev serve web build test test-be test-fe test-e2e fmt lint doctor clean

help: ## list the targets
	@grep -hE '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed 's/:.*##/\t/' | expand -t22

dev: ## server + frontend with hot reload
	@$(MAKE) -j2 serve web

serve: ## the backend on :5390
	cd backend && cargo run -p cwbhacker -- serve

web: ## the frontend dev server
	cd frontend && npm run dev

build: ## release build, frontend bundled into the server
	cd frontend && npm ci && npm run build
	cd backend && cargo build --release

test: test-be test-fe ## every test except e2e
test-be: ## rust tests
	cd backend && cargo test
test-fe: ## typescript tests
	cd frontend && npm test
test-e2e: ## playwright, both orientations
	cd e2e && npx playwright test

fmt: ## format everything
	cd backend && cargo fmt
	cd frontend && npm run fmt

lint: ## clippy + tsc
	cd backend && cargo clippy --all-targets -- -D warnings
	cd frontend && npm run lint

doctor: ## check the toolchains
	@command -v cargo >/dev/null && cargo --version || echo "MISSING: rust"
	@command -v go    >/dev/null && go version       || echo "MISSING: go"
	@command -v node  >/dev/null && node --version   || echo "MISSING: node"

clean: ## drop build output (not ~/.causewaybayhacker)
	cd backend && cargo clean
	rm -rf frontend/dist frontend/node_modules
