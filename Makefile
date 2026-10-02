GODOT  ?= godot
BRIDGE := bridge/bin/kubiverse-bridge
ADDR   ?= 127.0.0.1:8088

.PHONY: serve-lan test test-go test-game lint-go test-race bench metrics-server cluster cluster-delete cluster-ha cluster-ha-delete scenario scenario-delete play-kind serve-web-kind all bridge bridge-all bridge-bundle webdist game-import web macos linux windows native run-bridge play play-demo serve-web demo-apply demo-delete clean readme-shots test-guard hooks coverage-check coverage-bump testlint

all: bridge web

## --- bridge (Go) -----------------------------------------------------------
## Version stamped in the bridge (GET /api/version, --version): VERSION=v0.1.8
## or 0.1.8 (a leading v is dropped).
VERSION ?= dev
BRIDGE_VERSION := $(patsubst v%,%,$(VERSION))

bridge:
	cd bridge && go build -ldflags="-X main.version=$(BRIDGE_VERSION)" -o bin/kubiverse-bridge .

bridge-all:
	cd bridge && for t in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64 windows/arm64; do \
	  os=$${t%/*}; arch=$${t#*/}; ext=$$( [ $$os = windows ] && echo .exe ); \
	  GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w -X main.version=$(BRIDGE_VERSION)" -o bin/kubiverse-bridge-$$os-$$arch$$ext . ; done

## Single-file bridges that serve the game themselves (go:embed of build/web).
bridge-bundle: webdist
	$(MAKE) bridge-all

webdist: web
	find bridge/webdist -mindepth 1 ! -name README.md -delete
	cp -R build/web/. bridge/webdist/

run-bridge: bridge
	$(BRIDGE) --addr $(ADDR)

## --- game (Godot) ----------------------------------------------------------
game-import:
	$(GODOT) --headless --path game --import

web: game-import
	mkdir -p build/web && $(GODOT) --headless --path game --export-release "Web" ../build/web/index.html
	mkdir -p build/web/fonts && cp game/assets/fonts/*.ttf build/web/fonts/

macos: game-import
	mkdir -p build/macos && $(GODOT) --headless --path game --export-release "macOS" ../build/macos/Kubiverse.zip

linux: game-import
	mkdir -p build/linux && $(GODOT) --headless --path game --export-release "Linux" ../build/linux/kubiverse.x86_64

windows: game-import
	mkdir -p build/windows && $(GODOT) --headless --path game --export-release "Windows" ../build/windows/Kubiverse.exe

native: macos linux windows

## Run the game from source (native), auto-connecting to the bridge.
play:
	$(GODOT) --path game -- --connect

play-demo:
	$(GODOT) --path game -- --demo

## Bridge serves the web build on the same origin: open http://$(ADDR)
serve-web: bridge web
	$(BRIDGE) --addr $(ADDR) --web build/web

## Phones/tablets on the same Wi-Fi: random token, prints the URLs to open.
serve-lan: bridge web
	$(BRIDGE) --lan --web build/web

## --- tests ------------------------------------------------------------------
## Headless Godot runs under a timeout so a hung test fails instead of blocking
## (GNU timeout; on macOS gtimeout from coreutils, or no limit without it).
TIMEOUT := $(shell command -v timeout 2>/dev/null || command -v gtimeout 2>/dev/null)
GODOT_SCRIPT = $(if $(TIMEOUT),$(TIMEOUT) $(1) )$(GODOT) --headless --path game --script
COVERAGE := bin/coverage.out

test: test-go test-game

test-go:
	cd bridge && go test ./...

## A Godot test fails on a non-zero exit and also on any SCRIPT ERROR in its
## output: a script error doesn't stop Godot, the rest of the test goes on.
## With a third argument the harness's "<label>: OK" line must be there too
## (finish() really ran).
## $(call godot_test,<timeout s>,<res:// script>[,ok])
define godot_test
	@echo "$(2)"; out=$$($(call GODOT_SCRIPT,$(1)) $(2) 2>&1); rc=$$?; echo "$$out"; \
	if [ $$rc -ne 0 ] || echo "$$out" | grep -q "SCRIPT ERROR"; then echo "FAIL: $(2) (exit $$rc)"; exit 1; fi; \
	if [ -n "$(3)" ] && ! echo "$$out" | grep -Eq '^[A-Za-z0-9 _-]+: OK$$'; then echo "FAIL: $(2) never reported OK (finish() not reached)"; exit 1; fi
endef

## scripts/game-tests.sh: every test file runs here, checks and finishes, and
## the number of check( calls never goes below game/tests/checks-baseline.txt.
test-game:
	@scripts/game-tests.sh check
	$(call godot_test,300,res://tests/test_world.gd,ok)
	$(call godot_test,300,res://tests/test_logic.gd,ok)
	$(call godot_test,300,res://tests/test_invariants.gd,ok)

## Existing tests and baselines only get stronger (see CONTRIBUTING.md):
## what this branch changes since main; CI checks the pushed / PR range.
test-guard:
	scripts/test-guard.sh

## Opt-in local hooks: the same check on each commit (commit-msg) and push.
hooks:
	git config core.hooksPath scripts/hooks && echo "hooks on (undo: git config --unset core.hooksPath)"

## What CI runs on the bridge: formatting, vet (e2e too), tests with the race
## detector and a coverage summary line.
lint-go:
	@cd bridge && files=$$(gofmt -l .); [ -z "$$files" ] || { echo "gofmt needed:"; echo "$$files"; exit 1; }
	cd bridge && go vet ./... && go vet -tags e2e ./...
	@$(MAKE) --no-print-directory testlint

## Every Go TestXxx / FuzzXxx must be able to fail (tools/testlint, its own
## module: never in the bridge binary).
testlint:
	@cd tools/testlint && files=$$(gofmt -l .); [ -z "$$files" ] || { echo "gofmt needed:"; echo "$$files"; exit 1; }
	cd tools/testlint && go vet . && go test -count=1 . && go run . ../../bridge

## The total must stay within 0.2 points of bridge/coverage-baseline.txt.
test-race:
	cd bridge && mkdir -p bin && go test -race -coverprofile=$(COVERAGE) ./... && go tool cover -func=$(COVERAGE) | tail -1
	@scripts/coverage.sh check bridge/$(COVERAGE)

## Coverage ratchet without the race detector (faster).
coverage-check:
	cd bridge && mkdir -p bin && go test -coverprofile=$(COVERAGE) ./... >/dev/null
	@scripts/coverage.sh check bridge/$(COVERAGE)

## After adding tests: raise both ratchets (bridge coverage, game check( count).
## They never go down here; lowering one by hand needs a Test-Change: trailer.
coverage-bump:
	cd bridge && mkdir -p bin && go test -coverprofile=$(COVERAGE) ./... >/dev/null
	@scripts/coverage.sh bump bridge/$(COVERAGE)
	@scripts/game-tests.sh bump

## Benchmarks as a smoke test: they must finish (60 s) without script errors.
bench:
	$(call godot_test,60,res://tests/bench_world.gd)
	$(call godot_test,60,res://tests/bench_search.gd)

## --- sample workloads --------------------------------------------------------
demo-apply:
	kubectl apply -f deploy/demo.yaml

## --- multi-node playground (kind) -------------------------------------------
## 1 control-plane + 3 workers (one tainted "GPU" node) with a busy scenario.
KIND_CTX := kind-kubecraft

cluster:
	kind create cluster --config deploy/kind-cluster.yaml
	kubectl --context $(KIND_CTX) apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl --context $(KIND_CTX) -n kube-system patch deployment metrics-server --type=json \
	  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'
	$(MAKE) scenario

cluster-delete:
	kind delete cluster --name kubecraft

## High availability: 3 control-planes (etcd quorum) + 2 workers.
AUDIT_DIR := $(HOME)/.kubecraft/audit
cluster-ha:
	mkdir -p $(AUDIT_DIR)/kind-kubecraft-ha/cp1 $(AUDIT_DIR)/kind-kubecraft-ha/cp2 $(AUDIT_DIR)/kind-kubecraft-ha/cp3
	sed -e "s|@AUDIT@|$(AUDIT_DIR)/kind-kubecraft-ha|" -e "s|@POLICY@|$(CURDIR)/deploy/audit-policy.yaml|" deploy/kind-ha.yaml > $(AUDIT_DIR)/kind-ha.yaml
	kind create cluster --config $(AUDIT_DIR)/kind-ha.yaml
	kubectl --context kind-kubecraft-ha apply -f deploy/demo.yaml

cluster-ha-delete:
	kind delete cluster --name kubecraft-ha

scenario:
	kubectl --context $(KIND_CTX) apply -f bridge/scenarios/complex.yaml

scenario-delete:
	kubectl --context $(KIND_CTX) delete -f bridge/scenarios/complex.yaml --ignore-not-found

## Bridge + web build for the kind cluster on :8089 (open http://127.0.0.1:8089)
serve-web-kind: bridge web
	$(BRIDGE) --context $(KIND_CTX) --addr 127.0.0.1:8089 --web build/web

play-kind:
	$(GODOT) --path game -- --connect --bridge=http://127.0.0.1:8089

## Live CPU/memory usage for the stats panel (F3). --kubelet-insecure-tls is
## needed on local clusters (OrbStack, kind, minikube) with self-signed kubelets.
metrics-server:
	kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
	kubectl -n kube-system patch deployment metrics-server --type=json \
	  -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]'

demo-delete:
	kubectl delete -f deploy/demo.yaml --ignore-not-found

clean:
	rm -rf build bridge/bin game/.godot
	find bridge/webdist -mindepth 1 ! -name README.md -delete

# The README's screenshots, from the demo cluster (English, clear sky, no panels).
SHOT = $(GODOT) --path game -- --demo --readme --hour=16
readme-shots: game-import
	$(SHOT) --shot=$(CURDIR)/docs/plant.png --zoom=40
	$(SHOT) --shot=$(CURDIR)/docs/hall.png --level=ns:shop --inspect
	$(SHOT) --shot=$(CURDIR)/docs/energy.png --level=power --zoom=36
	$(SHOT) --shot=$(CURDIR)/docs/engine-room.png --lesson=rolling:2
	$(SHOT) --shot=$(CURDIR)/docs/pod.png --enter-pod=shop --inspect-container
	$(SHOT) --shot=$(CURDIR)/docs/library.png --level=library --zoom=40
	$(SHOT) --shot=$(CURDIR)/docs/bank.png --level=bank --zoom=34
	$(SHOT) --shot=$(CURDIR)/docs/underground.png --underground
