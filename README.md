# Kubiverse

Your **real** Kubernetes cluster turned into a pixel‑art (voxel) 3D world you can walk around and operate.

**[Play the demo in your browser](https://jairofernandez.github.io/kubiverse/?demo=1)** (simulated cluster) · **[Download the latest release](https://github.com/jairoFernandez/kubiverse/releases/latest)** (macOS, Linux, Windows and the bridge)

![Kubiverse connected to a real cluster](docs/real-cluster.png)

- **Engine:** Godot 4.7 (GDScript, *Compatibility* renderer) → exports to **Web (WASM)**, **macOS**, **Linux** and **Windows** from the same project.
- **3D pixel‑art look:** the 3D world renders into a `SubViewport` at 1/3 resolution and is upscaled with *nearest* filtering; toon materials with the PICO‑8 palette, *inverted hull* outlines, orthographic isometric camera with *pixel snapping*.
- **Cluster connection:** `k8s-bridge`, a Go binary (client-go) that reads your kubeconfig, keeps *informers* running and talks to the game over HTTP + WebSocket.

```
┌──────────────┐  WebSocket (snapshots + events)   ┌─────────────┐  client-go / informers  ┌──────────────┐
│  Kubiverse   │ ◄──────────────────────────────── │ k8s-bridge  │ ◄─────────────────────► │ kube-apiserver│
│(web/native)  │ ──── HTTP /api/action, /api/logs ─►│  (Go)       │     (your kubeconfig)   │   (real)      │
└──────────────┘                                    └─────────────┘                         └──────────────┘
```

Why a bridge? A browser can't talk to the API server directly (CORS, client certificates, EKS/GKE/AKS `exec` plugins). With the bridge, the web and native builds use exactly the same protocol and authentication stays on your machine.

## Play with your cluster

Run the bridge on your machine (it uses your kubeconfig, like kubectl). These commands download the latest release, check its SHA256 against the release's `SHA256SUMS.txt` and start it ([`get-bridge.sh`](bridge/get-bridge.sh), [`get-bridge.ps1`](bridge/get-bridge.ps1)); the binary is kept in `~/.kubecraft/bin/`:

```bash
curl -fsSL https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge.sh | sh
```

```powershell
& ([scriptblock]::Create((irm https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge.ps1)))
```

Then open **http://127.0.0.1:8088**: the bridge carries the game inside. To use the [online version](https://jairofernandez.github.io/kubiverse/) instead, add `--allow-origin https://jairofernandez.github.io` to the command (after `sh -s --` on macOS/Linux). The game's start screen shows these commands ready to copy, with the right origin.

## Intro

While loading, the web build shows its own screen ([`game/web/shell.html`](game/web/shell.html)): the logo, Kubi, a pixel-art city with requests flying around, a bar with the MB downloaded and rotating tips, in English or Spanish depending on the browser. The native build boots with [`game/assets/splash.png`](game/assets/splash.png).

When you connect a cluster, a ~14 s fly-through introduces the world: the logo over the Internet globe, the city with your domains, the Ingress gate and the plant; at the end Kubi says hi. Any key or tap skips it. In **VIEW** you can turn it off (**Intro when connecting**) or watch it again (**PLAY INTRO**). Local data still lives in `~/.kubecraft` (the project's former name) so no settings are lost.

## The factory: levels

| Level | What you see |
|---|---|
| **PLANT** (overview) | One **factory hall per Namespace** (empty ones too) + the **energy plant** (nodes). An at-a-glance monitor: lit windows = pods (green ok, red failing), roof light = worst state inside, red smoke = crashes. |
| **HALL `<ns>`** (sublevel) | Each **Deployment / StatefulSet / DaemonSet** is an **assembly line**: a console with one lamp per replica (green = ready) and a belt that only runs when replicas are ready. Each **Pod** is a **robot** at its station (one block per container, gem = status). Each **Service** is a **loading dock**; hovering or selecting it draws the traffic lines to its pods. |
| **ENERGY ROOM** | Each **Node** is a generator island with the pods physically running on it. Castle = control-plane, fence = cordoned, red light = NotReady, cloud = pods waiting for the scheduler. |

To go in or out, just **step on the door mat** (or press E, double-click a hall, or use the level bar). You start on the main street between the halls, and when you leave a hall you appear in front of its door. Stepping onto an island or entering a hall shows a **zone sign** explaining what it is (control-plane, worker or namespace), and the level bar shows where you are. Warp pipes and kiosks are used with E. The character respects physical limits: it only walks on real ground (terrain, hall floors, islands and bridges) and doesn't walk through halls, consoles, belts or docks.

![Inside a hall](docs/hall.png)
![Energy room](docs/energy.png)

## Multiple clusters and kubeconfigs

A single bridge serves **every context** in your kubeconfig plus the kubeconfigs you add from the game. Each cluster connects on demand and the game picks one with `?context=`.

On the start screen:
- **Saved clusters**: name, bridge URL, context and token (stored in the game preferences). Click to connect, X to delete.
- **New connection**: bridge URL and **LOAD CONTEXTS**. Pick one and use **SAVE & CONNECT**.
- **+ Add a kubeconfig**: paste it, or **LOAD FILE...** (native picker, or the browser's in the web build), give it a name and press **ADD CLUSTER**. The kubeconfig is only sent to the bridge, which stores it in `~/.kubecraft/kubeconfigs/` with 0600 permissions. The game checks that the cluster responds, **saves it to the list** and **connects**; if it fails, it shows the server error. If one of its contexts has the same name as one you already have (typically `default`, `kubernetes-admin@kubernetes`), it shows up as `file-name/context` instead of being hidden. Careful: just like with kubectl, a kubeconfig with `exec` plugins (aws, gke-gcloud-auth-plugin...) runs that command on the bridge host.

API: `GET /api/contexts`, `POST /api/kubeconfig {name, content}` and `DELETE /api/kubeconfig?name=`. Every cluster route accepts `?context=`.

## Multi-node scenario (kind)

```bash
make cluster         # kind: 1 control-plane + 3 workers (one tainted "GPU") + metrics-server + scenario
make serve-web-kind  # bridge on :8089 against kind-kubecraft -> http://127.0.0.1:8089
make cluster-delete
make cluster-ha      # kind HA: 3 control-planes + 2 workers (etcd plaza) + auditing for the watchtower
make cluster-ha-delete
```

### Multiple control-planes (HA)

With 2 or more control-planes the energy room shows the **etcd plaza**: one crystal per member (green = Ready, red = down) and a sign with the quorum (`3 of 3 members up, needs 2 to work, tolerates 1 failure`). The usual numbers are 3 or 5 (odd, for etcd quorum).

A control-plane's inspector has a **+ CONTROL-PLANE** button. In demo mode it adds one instantly; on a real cluster it opens a guide with the steps for kind, managed clusters (EKS/GKE/AKS: the provider manages them) and kubeadm (`kubeadm token create --print-join-command` + `kubeadm init phase upload-certs --upload-certs` + `kubeadm join ... --control-plane`). Adding a control-plane is an infrastructure operation: the Kubernetes API can't do it, so the game doesn't pretend to.

[`deploy/complex.yaml`](deploy/complex.yaml) creates five namespaces:

- **ecommerce**: a shop with replicas spread across nodes, an API with a sidecar, workers, Postgres with a volume, and Redis.
- **data**: a 3-broker StatefulSet, a CronJob every 2 min (Completed pods) and a Job.
- **ml**: training pinned to the GPU node (taint + toleration), a model with a broken image and a pod that asks for 64 CPUs and **never** gets scheduled.
- **observability**: a DaemonSet on every node and Prometheus.
- **chaos**: random crashes and an OOMKilled pod.

Your current kubectl context doesn't change.

## Mario-style energy room

By default, **plank bridges** with gentle steps lead to each island without jumping. The Mario-style platforming challenge is enabled in **VIEW → Jump challenge**. The **control-plane** is the central island and where you spawn; workers orbit around it at different heights. If the cluster doesn't expose its control-plane (EKS, GKE...), the center is a neutral platform. Each island has a **warp pipe** (E next to it; you sink into it, fade out and come out of the next island's pipe) and a **terminal kiosk** (E) that opens the terminal already running that node's commands: its pods and `describe node`, or `get nodes` and `cluster-info` on the control-plane. To go on foot you have to **jump** across "?" blocks, bricks and platforms (some move up and down), collecting coins. If you fall into the void you return to the last platform you stood on. There's *coyote time* (you can jump a moment after leaving an edge) and a jump pressed just before landing also counts. Physics are truly vertical: the edges of a higher platform act as walls, and the shadow marks where you'll land. A test checks that every island is reachable with the character's jump.

## Plant districts

The plant groups namespaces into districts, each with its own ground, entrance arch and sign:

- **Kubernetes Quarter** (west): `kube-system`, `kube-public`, `kube-node-lease`, `default` and cluster networking/storage (calico, cilium, metallb, local-path…). Fortress-shaped buildings.
- **Your Apps** (center, facing the Ingress gate): everything else.
- **Platform Park** (east): GitOps (argocd, flux), kubefirst/konstruct, secrets (vault, external-secrets), cert-manager, ingress/mesh (ingress-nginx, traefik, istio…), CI/CD, policies and backups.
- **Observatory Hill** (east): metrics (monitoring, prometheus), grafana, logs and search (elastic, loki…), tracing.

Known types have their own shape and pixel logo: a lighthouse for GitOps, a crane for kubefirst/konstruct and CI, a vault for secrets, an arch for ingress, an observatory dome for metrics, screens with charts for grafana, shelves for logs, a shop awning for `shop`, bank columns for `payments`, silos for data… The catalog lives in [`game/scripts/ns_catalog.gd`](game/scripts/ns_catalog.gd); the logos are generic pictograms, not each project's trademark.

## The Internet city: how the cluster connects to the world

North of the plant lies **THE INTERNET**: a city of skyscrapers under a glowing globe raining data packets.

- Each Ingress **domain** is a **neon sign** (with a golden padlock if it uses HTTPS).
- **Cars are requests**: they leave the sign, pass through the **INGRESS gate** at the plant entrance and drive the streets to the hall of the namespace whose Service answers.
- If the Service **doesn't exist or has no ready pods**, the car stops at the gate with red smoke and a **503**; the gate light turns red.
- **LoadBalancer** Services get their own **pink toll road**, showing the external IP.
- With no Ingress or LoadBalancer, the barrier is down: nothing in the cluster is reachable from outside.
- Click the gate: controller, address and every `domain/path -> namespace/service:port` route with its status.

`make scenario` creates three sample Ingresses in the kind cluster, one broken on purpose.

## Finished pods (Completed)

Argo Workflows, Jobs and CronJobs leave **Completed** pods behind. Kubernetes only collects them once the cluster exceeds 12,500 terminated pods (`--terminated-pod-gc-threshold`), so they pile up.

- The game only draws the **8 most recent per hall** (2 per node in the energy room); the rest go to an **ARCHIVE pile** with a counter. To see them all: VIEW > Show every finished pod.
- With 30 or more in a namespace, **Kubi** warns you ("Many finished pods"): explains why it happens, gives the config to clean them up automatically (Argo `podGC` / `ttlStrategy`, Jobs `ttlSecondsAfterFinished`, CronJobs `*HistoryLimit`) and offers **Clean finished pods** (`kubectl delete pods --field-selector=status.phase==Succeeded`, with confirmation; running pods are left alone).

## Missions (J)

11 guided missions to learn Kubernetes by doing: namespaces, pods, nodes, creating a Deployment, self-healing, scaling, Services/endpoints, debugging a CrashLoop with logs, rollouts, cordon/uncordon and cleanup. Each one explains the concept (**WHY?**) and the equivalent `kubectl` command. They're validated against the real cluster state. The ones that change things use the **`academia`** namespace, so your apps are never touched.

## Monitoring

- **ALARMS**: live problems (NotReady/cordoned nodes, crashing/imagepull/stuck pods, workloads below their replica count). One click takes you there.
- **TAB**: jumps to the next pod with problems anywhere in the cluster.
- **TERMINAL**: every action you take shows up as its `kubectl` command (click to copy), alongside cluster events.
- The inspector shows the `kubectl` commands to view that object and, when hovering a button, the command it will run.

## Controls

| Key | Action |
|---|---|
| WASD / arrows | walk |
| click on the ground | walk there (avoids obstacles, runs if far; click an object = inspect and walk to it). Can be turned off in VIEW |
| SHIFT (hold) / X (toggle) | Pokémon-style "running shoes": faster, leaning forward and kicking up dust |
| SPACE | jump |
| Z · SPACE twice | jetpack: hold SPACE to go up, CTRL to go down, release everything to hover |
| Y · O | Kubi, the assistant · watchtower mode |
| E | enter a door / use / inspect the nearest thing |
| click · drag · right-drag · wheel | inspect · pan camera · rotate · zoom |
| M / N | full map (click = fast travel) / minimap |
| P · F3 · / | first person · stats · type in the terminal |
| J | missions |
| TAB | next pod with problems |
| L · B · G · V | logs · build · legend · view menu |
| H · K · T | system namespaces · all lines · terminal |
| C + F | chaos mode + blaster |
| Q/R · BACKSPACE · HOME | rotate 90° · back to the plant · recenter |

## Working terminal

The TERMINAL panel (`/` to type) runs **real kubectl** on the bridge host, against the same context, with history (↑/↓) and `clear`. Clicking any command in the game pastes it into the terminal. Commands that change things (scale, delete pod, rollout restart, cordon, create deployment...) also count toward missions. Demo mode has a kubectl emulator.

Safety limits: no shell is used (`;`, `|`, `&`, `$`, backticks and redirections are rejected). Also not allowed: interactive or never-ending commands (`exec`, `edit`, `port-forward`, `-w`, `logs -f`), switching cluster or credentials (`--context`, `--kubeconfig`, `--token`...), reading local files (`-f`, `-k`, `cp`) and `config`. With `--readonly` only read verbs are accepted.

## Chaos mode and weapons (C, 1-6, F)

With chaos mode on (C), **F** fires the equipped weapon at whatever is in front of you. Each weapon is a real Kubernetes operation and unlocks when you complete the mission that teaches that concept:

| Key | Weapon | Operation | Unlocked by |
|---|---|---|---|
| 1 | Pod blaster | `delete pod` | from the start |
| 2 | Rollout hammer | `rollout restart` of the workload | "Rolling update" mission |
| 3 | Shrink ray | `scale` −1 replica | "More production" mission |
| 4 | Freeze gun | `cordon` / `uncordon` the node | "Maintenance" mission |
| 5 | Service cutter | `delete service` | "Follow the traffic" mission |
| 6 | Nuke | `delete` the whole workload | "Clean up the factory" mission |

The cutter and the nuke always ask for confirmation. Every shot shows up in the TERMINAL as its kubectl command.

Each weapon has its own animation, even with nothing in range: the shot fires anyway and fades into the air without running anything.
- **Blaster**: beam with a trail.
- **Hammer**: slam and a shockwave on the ground.
- **Shrink ray**: vibrating beam with rings.
- **Freeze**: a stream of crystals that leave ice where they hit.
- **Cutter**: a blade that flies out and back like a boomerang.
- **Nuke**: rocket on an arc, explosion, mushroom cloud and camera shake.

Each weapon has its own cooldown, and the real operation runs when the shot hits.

## Audio

All sound is **generated in code** by a small chiptune synth ([`sfx.gd`](game/scripts/sfx.gd): square, triangle, saw and noise waves, with sweeps and envelopes), so the game ships no audio files:
- **Effects**: each weapon, footsteps, jump, landing, coins, pipes, doors, falls, pod deaths, UI clicks, terminal keys, mission complete and an alarm when a pod starts failing.
- **Music**: two loops in the same key, an upbeat one for day and a calm one for night, crossfading with the cluster's time of day.
- **Volume**: music and effects in **VIEW**.

## Node capacity

Each island has two gauges (blue CPU and pink memory) showing what's **reserved by its pods' requests** against the node's allocatable: green, yellow or red depending on pressure. Its sign reads, for example, "cpu 700m/4.0, mem 896 MiB/8 GiB". The node panel separates reserved (the only thing the scheduler looks at), free and actual usage (metrics-server). A Pending pod shows the scheduler's message with the exact reason, e.g. "0/4 nodes are available: 2 Insufficient cpu, 2 node(s) had untolerated taint(s)", and what it asks for.

## Phone and tablet (touch)

On touch screens (or if the window is narrow) the game switches to a **compact mode**:

- The top shows only the title, the status and **MENU**, which opens everything as big buttons: Kubi, watchtower, map, missions, alarms, build, chaos, terminal, legend, stats, first person, jetpack, sound, view and quit.
- Panels (inspector, Kubi, watchtower, editor, start screen) use the full width. The terminal and missions open from the menu. The minimap is small and sits at the top left.
- **Touch controls**:
  - floating joystick: put your thumb at the bottom left; pushing to the edge = run
  - **JUMP** (hold to climb with the jetpack), **USE**, **JET**, **DOWN** (while flying) and **FIRE** (in chaos mode) buttons
  - **tap** = inspect and walk there; **drag** = pan the camera; **pinch** = zoom; **two-finger twist** = rotate; in first person, drag = look
  - **tap Kubi** or its speech bubble to open its panel
- The UI scale adapts to the phone (about 460 units on the short side). In VIEW > "Touch controls" choose automatic / on / off.

### Playing from your phone (local network)

For safety the bridge only listens on `127.0.0.1`: it controls your cluster with your credentials. To open it from a phone or tablet on the same Wi-Fi:

```bash
make serve-lan      # = k8s-bridge --lan --web build/web
```

`--lan` listens on all interfaces, generates a **random token** (or uses `--token`), allows origins from your local network and prints the URLs to open, like `https://192.168.1.20:8088/?token=...` (only IPs of real interfaces, not Docker/OrbStack ones). The game connects only with that token.

- It runs over **HTTPS with a self-signed certificate**, because browsers only run Godot web builds in a secure context. The phone warns about the certificate once: accept it. It's stored in `~/.kubecraft/tls` and reused as long as it covers your IPs.
- The token travels in the URL: only share it with people you trust. For view-only access, add `--readonly`.
- The bridge refuses to listen beyond localhost without a token.
- On macOS the firewall prompt to accept incoming connections may appear.

## Sound (VOL)

The **VOL** button in the top bar opens master volume, music and effects, plus **Mute everything**. It's saved in the settings.

## Matrix-style manifest editor

**EDIT YAML** in the inspector (pods, workloads, services, nodes), `kubectl edit <kind>/<name> -n <ns>` in the terminal, or **Fix in the YAML** from Kubi open a retro editor: green code rain, the manifest "decrypts" line by line and appears highlighted. The **DECODER** column explains each line (what `replicas`, `requests.cpu`, `tolerations`... do) and warns about dangerous values: `latest` image, 1 replica, `privileged` container, very low memory limit, plaintext secrets. `~` marks changed lines.

- **VALIDATE** = `kubectl replace --dry-run=server`: the API server checks the change without applying it.
- **APPLY** replaces the object, with confirmation. You can't change the kind, name or namespace, and Secrets can't be edited here (their values would show on screen). `status`, `managedFields` and the last-applied annotation are hidden; the latter is preserved on save.
- **ASK KUBI ABOUT THIS LINE** and **ask Kubi about this error** hand the YAML or the error to Kubi.
- In demo mode, changing `fraud-ai`'s broken image or `giant-experiment`'s CPU actually fixes the pods.

## Jetpack (Z)

Z (or SPACE twice) turns on the jetpack: two tanks with flames on the backpack and an engine sound. Hold SPACE to go up, CTRL to go down; release everything to hover. It flies over halls, consoles and pipes, and you can **land on rooftops**. There's a ceiling per level (lower inside halls). Turning it off mid-air = falling.

## Kubi, the assistant (Y)

A "Pokédex"-style drone that follows you, looks toward the nearest problem (with an arrow) and pops up a speech bubble when something breaks. Y opens its panel:

- Cluster **problems**, worst first, with a **built-in diagnosis** (always works, also on web/demo): why it happens (ImagePullBackOff, CrashLoopBackOff, OOMKilled, no room on any node with the CPU/memory numbers, taints, selectors, PVCs, readiness, NotReady or cordoned nodes...), steps to fix it and commands. Read commands run in the terminal when clicked; ones that change something are only typed in for you to review and press Enter. Buttons: go there, logs of the failed container, restart the workload, delete the pod, uncordon (always with confirmation).
- **Free chat** with conversation memory: ask anything about the cluster or Kubernetes. The *topic* is the selected problem or "the whole cluster" (the bridge passes it state, events, the last log lines and the built-in diagnosis). NEW CHAT clears the memory. Whatever the model says never runs on its own.
- **Command output in the chat**: read commands Kubi suggests run and their output is **attached** automatically to the next question (`[x]` tag to remove it, "What does this output mean?" button). Any terminal output, including from commands you type yourself, gets a **-> send this output to Kubi** link.
- **Clickable commands**: in the diagnosis and in answers (inline code or ``` blocks), every kubectl command gets **RUN** and **COPY**; those with `<...>` placeholders get **TO TERMINAL**; other commands (docker, journalctl...) only COPY. The terminal strips a leading `kubectl` from whatever you paste.
- The **terminal** can also be moved (drag its bar) and resized from any edge; double-click its bar to put it back.
- The panel **drags** by its title bar, **resizes** from any edge or corner and **collapses** with `_` (or double-click the title).
- **SETTINGS**: engine (automatic / Ollama / built-in llama.cpp / off), model, answer length and style (precise/creative). Saved to `~/.kubecraft/assistant.json`.

### AI engines (all local)

- **Ollama**, if you have it (`ollama serve`): uses the best installed model (gemma4, qwen3.5, llama3.2...), and from SETTINGS you can pull suggested models into your Ollama with a progress bar.
- **Built-in llama.cpp**, nothing to install: from SETTINGS Kubiverse downloads the **official** build from `github.com/ggml-org/llama.cpp` for your system (~15 MB, verified against the SHA256 GitHub publishes) and a GGUF model from a list (Gemma 3 1B/4B/12B, Qwen 2.5 1.5B/3B/7B, Llama 3.2 3B) from Hugging Face with the **SHA256 pinned in the code**. Everything goes to `~/.kubecraft/` and `llama-server` only listens on `127.0.0.1`; the bridge starts it when you ask and stops it on exit.
- `:cloud` models and remote servers are never used: the game can't change the engine URL (only the `--llm-url` flag can).

## Watchtower mode (O)

Kubernetes has no "who's connected" API. The watchtower combines three sources:

1. **API server auditing** (real identity: user, groups, source IP, tool, verb and resource, and whether it was denied). It has to be enabled on the cluster; the bridge reads `~/.kubecraft/audit/<context>/**/audit.log` (`--audit-dir`). `make cluster-ha` creates a kind cluster with auditing already on ([`deploy/audit-policy.yaml`](deploy/audit-policy.yaml): metadata only, never Secret or request contents). On managed clusters auditing goes to the provider (EKS → CloudWatch, GKE → Cloud Audit Logs, AKS → Diagnostic settings).
2. **managedFields**: which *tool* changed something (kubectl-edit, helm, argocd...), on any cluster, without identity.
3. **Kubiverse players** connected to this bridge.

With the watchtower open, each identity appears as a **ghost** that walks to what it touches (the namespace's door, the pod, the node's island) and fires a beam when it writes. A new identity, a denied access (401/403) or touching Secrets triggers an **alarm**. The panel can be minimized (`_`) without turning the mode off. It filters internal noise (nodes, kube-system controllers); the bridge itself is marked "this bridge" and hidden.

## First person (P)

Perspective camera at helmet height: the mouse looks around (it's captured; ESC releases it), clicking inspects what's under the crosshair, and walking, running, jumping and physical limits all still apply.

## Stats (F3)

- **Game**: FPS, frame time, RAM, VRAM, draw calls, objects and GPU.
- **Cluster**: total and per-node CPU and memory, pods per node against capacity, and the top CPU-consuming pods. With **metrics-server** actual usage is shown (`make metrics-server` installs it; on local clusters add `--kubelet-insecure-tls`). Without it, what's reserved by pod *requests* is shown.

## Day and night

Lighting follows the **cluster's time** (the bridge's clock, in your time zone). The sun crosses the sky, there are orange sunrises and sunsets, and at night a moon and stars. The time is shown in the level bar. In demo mode (or with **VIEW → Accelerated day/night cycle**) a day lasts 4 minutes.

## Halls on fire

A hall whose namespace has failing pods catches fire: voxel flames on the roof and windows, a flickering orange light and bursts of *glitch* (the building shakes, color stripes appear and the sign gets corrupted). The intensity grows with the number of failing pods.

## Languages

English and Spanish (the system language is detected; change it on the start screen or in **V > Language**). English is the source language; translations live in [`game/scripts/i18n.gd`](game/scripts/i18n.gd). To add another language: create another dictionary like `ES` and add it to `LANGS`.

## Map

- **Minimap** at the bottom left: follows you and shows the current level (halls, lines, docks, islands, pods by status, doors and your arrow). Clicking it opens the full map.
- **Full map (M)**: the whole level with names. Click a hall, line, dock, pod or spot on the ground to travel there, respecting physical limits.

## Quick start

Requirements: Go (version in `bridge/go.mod`), Godot 4.7 (`brew install --cask godot`), a working kubeconfig.

```bash
# 1. (optional) sample workloads: crashloop, imagepull, statefulset, daemonset, services...
make demo-apply

# 2a. Native from source
make run-bridge          # terminal 1: bridge on http://127.0.0.1:8088 (uses your current-context)
make play                # terminal 2: opens the game and connects

# 2b. Web: the bridge serves the web build on the same origin
make serve-web           # exports to build/web and opens http://127.0.0.1:8088

# No cluster: demo mode with a simulated cluster
make play-demo           # or on web: http://…/?demo=1
```

Builds:

```bash
make web                 # build/web/          (HTML5/WASM, no threads → no COOP/COEP needed)
make macos linux windows # build/<os>/          (needs Godot 4.7.2 export templates)
make bridge-all          # bridge/bin/k8s-bridge-<os>-<arch>
make bridge-bundle       # same, with the web build embedded (single file that serves the game)
make test                # bridge tests (Go) + world/collisions (headless Godot)
```

*Export templates* are installed from the editor (Editor → Manage Export Templates) or by unzipping `Godot_v4.7.2-stable_export_templates.tpz` into `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` (macOS).

### CI, releases and web deployment

[`.github/workflows/build.yml`](.github/workflows/build.yml) runs the tests, exports Web, macOS, Linux and Windows with Godot 4.7.2 and builds the bridges with the web build embedded; each one is uploaded as a workflow artifact. Pushing a `v*` tag publishes a GitHub Release with every archive and `SHA256SUMS.txt`. The macOS app is ad-hoc signed, not notarized: the first time, open it with right-click → Open.

There are two ways to play in the browser:

- **Bundled bridge (recommended for real clusters):** download `k8s-bridge-<os>-<arch>` from a release (or use the [one-line command](#play-with-your-cluster)), run it and open `http://127.0.0.1:8088`. The game comes inside the binary (`go:embed`), so there's no CORS or HTTPS to deal with. `--web DIR` still overrides the bundled build.
- **Static site (public demo):** on every push to `main` the web build is deployed to GitHub Pages (Settings → Pages → Source: "GitHub Actions"). It's plain static files (no threads, so no COOP/COEP headers needed) and works on any static host. Link `?demo=1` to jump straight into the simulated cluster. To manage a real cluster from there, the player runs a bridge locally that trusts the site: `k8s-bridge --allow-origin https://<user>.github.io`. On a public host the start screen suggests `http://127.0.0.1:8088` as the bridge URL and shows the [download-and-run command](#play-with-your-cluster) with that flag already set. Chrome and Firefox allow it (Chrome asks for local network access). Safari blocks `http://127.0.0.1` from an HTTPS page, so use the bundled bridge there.

### Bridge flags

```
--context NAME       kubeconfig context (defaults to current-context)
--kubeconfig PATH    alternate kubeconfig
--addr HOST:PORT     defaults to 127.0.0.1:8088
--readonly           rejects any mutating action ("look only" mode)
--token SECRET       requires X-Bridge-Token / ?token= (also K8SGAME_TOKEN)
--web DIR            serves the web build at / (overrides the one bundled into the binary)
--allow-origin URLS  extra allowed web origins (e.g. if you host the game elsewhere)
--llm-url URL        Ollama for Kubi (defaults to http://127.0.0.1:11434; "" disables it; warns if not local)
--llm-model NAME     Ollama model (auto = best locally installed, never ":cloud")
--audit-dir DIR      audit logs for the watchtower (defaults to ~/.kubecraft/audit)
--lan                local network (phones): self-signed HTTPS + all interfaces + random token + prints the URLs
```

Web build URL parameters: `?bridge=http://host:8088`, `?token=...`, `?demo=1`.

## Security

The game performs **real** actions with your kubeconfig's credentials.

- The bridge only listens on `127.0.0.1` and **rejects browser requests from other origins** and non-localhost hosts (so a random website you visit can't delete your pods via `localhost:8088`, and DNS rebinding is blocked).
- For important clusters use `--readonly`, or a kubeconfig/ServiceAccount with limited RBAC (`get/list/watch` + only the verbs you want to allow: `pods/delete`, `deployments/scale`, `nodes/patch`...).
- If you expose the bridge beyond localhost (`--addr 0.0.0.0:8088`), **always** use `--token` and `--allow-origin`.

## Bridge API

| Method | Route | Description |
|---|---|---|
| GET | `/api/ws` | WebSocket: `{"type":"state","data":Snapshot}` (≤3/s, coalesced), `{"type":"event","data":{...}}` and `{"type":"watch","data":{audit, visitors, actions}}` (watchtower) |
| GET · POST | `/api/assistant` | engine status, models, catalog and downloads · `{"question","kind","ns","name","lang","diagnosis","history"}` → `{"ok","answer","model"}` |
| POST | `/api/assistant/config` · `/api/assistant/download` | Kubi settings · download `{"kind":"llamacpp"\|"gguf"\|"ollama","id"}` |
| DELETE | `/api/assistant/model?id=` | delete a downloaded GGUF model |
| GET · POST | `/api/manifest` | an object's YAML (`?kind=&ns=&name=`) · replace it `{"kind","ns","name","yaml","dry_run"}` |
| GET | `/api/state` | current Snapshot as JSON |
| GET | `/api/logs?ns=&pod=&container=&tail=&previous=1` | container logs |
| POST | `/api/kubectl` | `{"line": "get pods -A"}` → `{"ok", "exit_code", "output"}` (real kubectl with the restrictions above) |
| POST | `/api/action` | `{"action": "delete_pod" \| "scale" \| "restart" \| "cordon" \| "uncordon" \| "create_deployment" \| "delete_workload", "kind", "ns", "name", "replicas", "image", "service"}` |

## Layout

```
bridge/                 Go: kubeconfig → informers → JSON snapshot, actions, logs, events
  main.go               HTTP/WS server, origin guard, publish loop
  snapshot.go           flat model for the game (nodes, pods, workloads, services)
  actions.go            mutating actions, logs, Events stream
  static.go · embed.go  serves the web build (gzipped), from --web or bundled in webdist/
game/                   Godot 4.7 project
  scripts/k8s_client.gd K8s autoload: WebSocket/HTTP to the bridge or simulated cluster
  scripts/mock_cluster.gd  simulated mini-Kubernetes for demo mode
  scripts/world.gd      levels (plant / hall / energy), layout, collisions, lines, FX
  scripts/entities/     FactoryBuilding, ProductionLine, PodBot, ServicePortal, NodeIsland
  scripts/missions.gd   guided missions
  scripts/kubectl.gd    equivalent kubectl command for each action / view
  scripts/settings.gd   preferences (text size, language, running, progress)
  scripts/i18n.gd       languages (EN source, ES translation)
  scripts/map_view.gd   minimap and full map with fast travel
  scripts/player.gd     character: walk, run, jump
  scripts/hud.gd        UI: bars, alarms, missions, inspector, terminal, logs, build, legend
  tests/test_world.gd   headless level and collision tests
  scripts/vox.gd        PICO-8 palette, toon + outline materials, voxel helpers
deploy/demo.yaml        sample workloads
```

Fonts: VT323 and Press Start 2P (SIL Open Font License, in `game/assets/fonts`).
