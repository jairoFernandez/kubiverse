# KubeCraft

Tu cluster de Kubernetes **real** convertido en un mundo 3D pixel‑art (voxel) que puedes recorrer y operar.

![KubeCraft conectado a un cluster real](docs/real-cluster.png)

- **Motor:** Godot 4.7 (GDScript, renderer *Compatibility*) → exporta a **Web (WASM)**, **macOS**, **Linux** y **Windows** desde el mismo proyecto.
- **Look pixel‑art 3D:** el mundo 3D se renderiza en un `SubViewport` a 1/3 de resolución y se escala con filtro *nearest*; materiales toon con paleta PICO‑8, contornos por *inverted hull*, cámara isométrica ortográfica con *pixel snapping*.
- **Conexión al cluster:** `k8s-bridge`, un binario Go (client-go) que lee tu kubeconfig, mantiene *informers* y habla con el juego por HTTP + WebSocket.

```
┌──────────────┐  WebSocket (snapshots + eventos)  ┌─────────────┐  client-go / informers  ┌──────────────┐
│  KubeCraft   │ ◄──────────────────────────────── │ k8s-bridge  │ ◄─────────────────────► │ kube-apiserver│
│ (web/nativo) │ ──── HTTP /api/action, /api/logs ─►│  (Go)       │     (tu kubeconfig)     │   (real)      │
└──────────────┘                                    └─────────────┘                         └──────────────┘
```

¿Por qué un bridge? Un navegador no puede hablar directamente con el API server (CORS, certificados cliente, plugins `exec` de EKS/GKE/AKS). Con el bridge, la versión web y la nativa usan exactamente el mismo protocolo y la autenticación queda en tu máquina.

## La fábrica: niveles

| Nivel | Qué ves |
|---|---|
| **PLANTA** (vista general) | Una **nave industrial por Namespace** (también los vacíos) + la **planta de energía** (nodos). Monitor de un vistazo: ventanas encendidas = pods (verde ok, rojo fallando), luz del tejado = peor estado dentro, humo rojo = crashes. |
| **NAVE `<ns>`** (subnivel) | Cada **Deployment / StatefulSet / DaemonSet** es una **línea de montaje**: consola con lámparas por réplica (verde = ready) y cinta que solo corre si hay réplicas listas. Cada **Pod** es un **robot** en su estación (un bloque por contenedor, gema = estado). Cada **Service** es un **muelle de carga**; al pasar el ratón o seleccionar se dibujan las líneas de tráfico hacia sus pods. |
| **SALA DE ENERGÍA** | Cada **Node** es una isla-generador con los pods que corren físicamente en ella. Castillo = control-plane, valla = cordoned, luz roja = NotReady, nube = pods esperando al scheduler. |

Se entra por las puertas (**E**), con doble clic en una nave o desde la barra de niveles. El personaje respeta los límites físicos: camina solo por suelo real (terreno, suelo de la nave, islas y puentes) y no atraviesa naves, consolas, cintas ni muelles.

![Dentro de una nave](docs/hall.png)
![Sala de energía](docs/energy.png)

## Escenario multinodo (kind)

```bash
make cluster         # kind: 1 control-plane + 3 workers (uno "GPU" con taint) + metrics-server + escenario
make serve-web-kind  # bridge en :8089 contra kind-kubecraft -> http://127.0.0.1:8089
make cluster-delete
```

[`deploy/complex.yaml`](deploy/complex.yaml) crea cinco namespaces:

- **ecommerce**: tienda con réplicas repartidas entre nodos, API con sidecar, workers, Postgres con volumen y Redis.
- **data**: StatefulSet de 3 brokers, CronJob cada 2 min (pods Completed) y un Job.
- **ml**: entrenamiento forzado al nodo GPU (taint + toleration), un modelo con imagen rota y un pod que pide 64 CPUs y **nunca** se programa.
- **observability**: DaemonSet en todos los nodos y Prometheus.
- **chaos**: crashes aleatorios y un pod OOMKilled.

Tu contexto actual de kubectl no cambia.

## Sala de energía estilo Mario

Los nodos son islas flotantes a distintas alturas. Para llegar hay que **saltar** por bloques "?", ladrillos y plataformas (algunas suben y bajan), recogiendo monedas. Si caes al vacío vuelves al centro. La física es vertical de verdad: los bordes de una plataforma más alta hacen de pared y la sombra marca dónde vas a caer. Un test comprueba que cada isla es alcanzable con el salto del personaje.

## Misiones (J)

11 misiones guiadas para entender Kubernetes haciendo: namespaces, pods, nodos, crear un Deployment, autorreparación, escalar, Services/endpoints, depurar un CrashLoop con logs, rollout, cordon/uncordon y limpieza. Cada una explica el concepto (**WHY?**) y el comando `kubectl` equivalente. Se validan contra el estado real del cluster. Las que modifican cosas usan el namespace **`academia`**, para no tocar tus aplicaciones.

## Monitorización

- **ALARMAS**: problemas en vivo (nodos NotReady/cordoned, pods en crash/imagepull/atascados, workloads por debajo de réplicas). Un clic te lleva al sitio.
- **TAB**: salta al siguiente pod con problemas en todo el cluster.
- **TERMINAL**: cada acción que haces aparece como su comando `kubectl` (clic para copiar), junto con los eventos del cluster.
- El inspector muestra los comandos `kubectl` para ver ese objeto y, al pasar el ratón sobre un botón, el comando que ejecutará.

## Controles

| Tecla | Acción |
|---|---|
| WASD / flechas | andar |
| SHIFT (mantener) / X (alternar) | correr con "zapatillas" estilo Pokémon: más rápido, inclinado y levantando polvo |
| ESPACIO | saltar |
| E | entrar por una puerta / usar / inspeccionar lo más cercano |
| clic · arrastrar · arrastrar con botón derecho · rueda | inspeccionar · mover cámara · rotar · zoom |
| M / N | mapa completo (clic = viaje rápido) / minimapa |
| P · F3 · / | primera persona · estadísticas · escribir en la terminal |
| J | misiones |
| TAB | siguiente pod con problemas |
| L · B · G · V | logs · construir · leyenda · menú de vista |
| H · K · T | namespaces de sistema · todas las líneas · terminal |
| C + F | modo caos + blaster |
| Q/R · BACKSPACE · HOME | rotar 90° · volver a la planta · recentrar |

## Terminal funcional

El panel TERMINAL (tecla `/` para escribir) ejecuta **kubectl real** en el host del bridge, contra el mismo contexto, con historial (↑/↓) y `clear`. Un clic en cualquier comando del juego lo pega en la terminal. Los comandos que modifican (scale, delete pod, rollout restart, cordon, create deployment...) también cuentan para las misiones. En modo demo hay un emulador de kubectl.

Límites de seguridad: no se usa ninguna shell (se rechazan `;`, `|`, `&`, `$`, las comillas invertidas y las redirecciones). Tampoco se permiten comandos interactivos o que no terminan (`exec`, `edit`, `port-forward`, `-w`, `logs -f`), cambiar de cluster o credenciales (`--context`, `--kubeconfig`, `--token`...), leer ficheros locales (`-f`, `-k`, `cp`) ni `config`. Con `--readonly` solo se aceptan verbos de lectura.

## Primera persona (P)

Cámara en perspectiva a la altura del casco: el ratón mira (se captura; ESC lo libera), clic inspecciona lo que hay bajo la retícula, y se conservan el andar, correr, saltar y los límites físicos.

## Estadísticas (F3)

- **Juego**: FPS, tiempo de frame, RAM, VRAM, draw calls, objetos y GPU.
- **Cluster**: CPU y memoria totales y por nodo, pods por nodo frente a su capacidad y los pods que más CPU usan. Con **metrics-server** se muestra el uso real (`make metrics-server` lo instala; en clusters locales añade `--kubelet-insecure-tls`). Sin él, se muestra lo reservado por los *requests* de los pods.

## Naves en llamas

Una nave cuyo namespace tiene pods fallando arde: llamas voxel en el tejado y las ventanas, luz naranja parpadeante y ráfagas de *glitch* (el edificio tiembla, aparecen franjas de color y el letrero se corrompe). La intensidad crece con el número de pods fallando.

## Idiomas

Inglés y español (se detecta el idioma del sistema y se cambia en la pantalla de inicio o en **V > Idioma**). El inglés es el idioma fuente; las traducciones están en [`game/scripts/i18n.gd`](game/scripts/i18n.gd). Para añadir otro idioma: crea otro diccionario como `ES` y añádelo a `LANGS`.

## Mapa

- **Minimapa** abajo a la izquierda: te sigue y muestra el nivel actual (naves, líneas, muelles, islas, pods por estado, puertas y tu flecha). Si haces clic en él, abre el mapa completo.
- **Mapa completo (M)**: todo el nivel con nombres. Con un clic en una nave, línea, muelle, pod o punto del suelo viajas hasta allí respetando los límites físicos.

## Uso rápido

Requisitos: Go (versión en `bridge/go.mod`), Godot 4.7 (`brew install --cask godot`), un kubeconfig que funcione.

```bash
# 1. (opcional) cargas de ejemplo: crashloop, imagepull, statefulset, daemonset, servicios...
make demo-apply

# 2a. Nativo desde el código fuente
make run-bridge          # terminal 1: bridge en http://127.0.0.1:8088 (usa tu current-context)
make play                # terminal 2: abre el juego y conecta

# 2b. Web: el bridge sirve el build web en el mismo origen
make serve-web           # exporta a build/web y abre http://127.0.0.1:8088

# Sin cluster: modo demo con un cluster simulado
make play-demo           # o en web: http://…/?demo=1
```

Builds:

```bash
make web                 # build/web/          (HTML5/WASM, sin threads → no necesita COOP/COEP)
make macos linux windows # build/<os>/          (necesita export templates de Godot 4.7.2)
make bridge-all          # bridge/bin/k8s-bridge-<os>-<arch>
make test                # tests del bridge (Go) + mundo/colisiones (Godot headless)
```

Las *export templates* se instalan desde el editor (Editor → Manage Export Templates) o descomprimiendo `Godot_v4.7.2-stable_export_templates.tpz` en `~/Library/Application Support/Godot/export_templates/4.7.2.stable/` (macOS).

### Flags del bridge

```
--context NAME       contexto del kubeconfig (por defecto current-context)
--kubeconfig PATH    kubeconfig alternativo
--addr HOST:PORT     por defecto 127.0.0.1:8088
--readonly           rechaza cualquier acción mutante (modo "solo mirar")
--token SECRET       exige X-Bridge-Token / ?token= (también K8SGAME_TOKEN)
--web DIR            sirve el build web en /
--allow-origin URLS  orígenes web extra permitidos (p.ej. si publicas el juego en otro host)
```

Parámetros URL del build web: `?bridge=http://host:8088`, `?token=...`, `?demo=1`.

## Seguridad

El juego ejecuta acciones **reales** con las credenciales de tu kubeconfig.

- El bridge escucha solo en `127.0.0.1` y **rechaza peticiones de navegador de otros orígenes** y hosts que no sean localhost (evita que una web cualquiera que visites borre tus pods vía `localhost:8088`, y el DNS rebinding).
- Para clusters importantes usa `--readonly`, o un kubeconfig/ServiceAccount con RBAC limitado (`get/list/watch` + solo los verbos que quieras permitir: `pods/delete`, `deployments/scale`, `nodes/patch`...).
- Si expones el bridge fuera de localhost (`--addr 0.0.0.0:8088`), usa **siempre** `--token` y `--allow-origin`.

## API del bridge

| Método | Ruta | Descripción |
|---|---|---|
| GET | `/api/ws` | WebSocket: `{"type":"state","data":Snapshot}` (≤3/s, coalescido) y `{"type":"event","data":{...}}` |
| GET | `/api/state` | Snapshot actual en JSON |
| GET | `/api/logs?ns=&pod=&container=&tail=&previous=1` | Logs de un contenedor |
| POST | `/api/kubectl` | `{"line": "get pods -A"}` → `{"ok", "exit_code", "output"}` (kubectl real con las restricciones de arriba) |
| POST | `/api/action` | `{"action": "delete_pod" \| "scale" \| "restart" \| "cordon" \| "uncordon" \| "create_deployment" \| "delete_workload", "kind", "ns", "name", "replicas", "image", "service"}` |

## Estructura

```
bridge/                 Go: kubeconfig → informers → snapshot JSON, acciones, logs, eventos
  main.go               servidor HTTP/WS, guard de origen, publish loop
  snapshot.go           modelo plano para el juego (nodes, pods, workloads, services)
  actions.go            acciones mutantes, logs, stream de Events
game/                   Proyecto Godot 4.7
  scripts/k8s_client.gd autoload K8s: WebSocket/HTTP al bridge o cluster simulado
  scripts/mock_cluster.gd  mini‑Kubernetes simulado para el modo demo
  scripts/world.gd      niveles (planta / nave / energía), layout, colisiones, líneas, FX
  scripts/entities/     FactoryBuilding, ProductionLine, PodBot, ServicePortal, NodeIsland
  scripts/missions.gd   misiones guiadas
  scripts/kubectl.gd    comando kubectl equivalente a cada acción / vista
  scripts/settings.gd   preferencias (tamaño de texto, idioma, correr, progreso)
  scripts/i18n.gd       idiomas (EN fuente, traducción ES)
  scripts/map_view.gd   minimapa y mapa completo con viaje rápido
  scripts/player.gd     personaje: andar, correr, saltar
  scripts/hud.gd        UI: barras, alarmas, misiones, inspector, terminal, logs, build, leyenda
  tests/test_world.gd   tests headless de niveles y colisiones
  scripts/vox.gd        paleta PICO-8, materiales toon + contorno, helpers voxel
deploy/demo.yaml        cargas de ejemplo
```

Fuentes: VT323 y Press Start 2P (SIL Open Font License, en `game/assets/fonts`).
