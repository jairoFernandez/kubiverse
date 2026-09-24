GODOT  ?= godot
BRIDGE := bridge/bin/k8s-bridge
ADDR   ?= 127.0.0.1:8088

.PHONY: test metrics-server all bridge bridge-all game-import web macos linux windows native run-bridge play play-demo serve-web demo-apply demo-delete clean

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
