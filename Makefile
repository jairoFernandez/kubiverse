GODOT  ?= godot
BRIDGE := bridge/bin/k8s-bridge
ADDR   ?= 127.0.0.1:8088

.PHONY: test metrics-server cluster cluster-delete scenario scenario-delete play-kind serve-web-kind all bridge bridge-all game-import web macos linux windows native run-bridge play play-demo serve-web demo-apply demo-delete clean

all: bridge web

## --- bridge (Go) -----------------------------------------------------------
bridge:
	cd bridge && go build -o bin/k8s-bridge .

bridge-all:
	cd bridge && for t in darwin/arm64 darwin/amd64 linux/amd64 linux/arm64 windows/amd64; do \
	  os=$${t%/*}; arch=$${t#*/}; ext=$$( [ $$os = windows ] && echo .exe ); \
	  GOOS=$$os GOARCH=$$arch CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o bin/k8s-bridge-$$os-$$arch$$ext . ; done

run-bridge: bridge
	$(BRIDGE) --addr $(ADDR)

## --- game (Godot) ----------------------------------------------------------
game-import:
	$(GODOT) --headless --path game --import

web: game-import
	mkdir -p build/web && $(GODOT) --headless --path game --export-release "Web" ../build/web/index.html

macos: game-import
	mkdir -p build/macos && $(GODOT) --headless --path game --export-release "macOS" ../build/macos/KubeCraft.zip

linux: game-import
	mkdir -p build/linux && $(GODOT) --headless --path game --export-release "Linux" ../build/linux/kubecraft.x86_64

windows: game-import
	mkdir -p build/windows && $(GODOT) --headless --path game --export-release "Windows" ../build/windows/KubeCraft.exe

native: macos linux windows

## Run the game from source (native), auto-connecting to the bridge.
play:
	$(GODOT) --path game -- --connect

play-demo:
	$(GODOT) --path game -- --demo

## Bridge serves the web build on the same origin: open http://$(ADDR)
serve-web: bridge web
	$(BRIDGE) --addr $(ADDR) --web build/web

## --- tests ------------------------------------------------------------------
test:
	cd bridge && go test ./...
	$(GODOT) --headless --path game --script res://tests/test_world.gd

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

scenario:
	kubectl --context $(KIND_CTX) apply -f deploy/complex.yaml

scenario-delete:
	kubectl --context $(KIND_CTX) delete -f deploy/complex.yaml --ignore-not-found

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
