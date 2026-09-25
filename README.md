# Kubiverse

Tu cluster de Kubernetes **real** convertido en un mundo 3D pixel‑art (voxel) que puedes recorrer y operar.

![Kubiverse conectado a un cluster real](docs/real-cluster.png)

- **Motor:** Godot 4.7 (GDScript, renderer *Compatibility*) → exporta a **Web (WASM)**, **macOS**, **Linux** y **Windows** desde el mismo proyecto.
- **Look pixel‑art 3D:** el mundo 3D se renderiza en un `SubViewport` a 1/3 de resolución y se escala con filtro *nearest*; materiales toon con paleta PICO‑8, contornos por *inverted hull*, cámara isométrica ortográfica con *pixel snapping*.
- **Conexión al cluster:** `k8s-bridge`, un binario Go (client-go) que lee tu kubeconfig, mantiene *informers* y habla con el juego por HTTP + WebSocket.

```
┌──────────────┐  WebSocket (snapshots + eventos)  ┌─────────────┐  client-go / informers  ┌──────────────┐
│  Kubiverse   │ ◄──────────────────────────────── │ k8s-bridge  │ ◄─────────────────────► │ kube-apiserver│
│ (web/nativo) │ ──── HTTP /api/action, /api/logs ─►│  (Go)       │     (tu kubeconfig)     │   (real)      │
└──────────────┘                                    └─────────────┘                         └──────────────┘
```

¿Por qué un bridge? Un navegador no puede hablar directamente con el API server (CORS, certificados cliente, plugins `exec` de EKS/GKE/AKS). Con el bridge, la versión web y la nativa usan exactamente el mismo protocolo y la autenticación queda en tu máquina.

## Intro

Al conectar un cluster, un vuelo de ~14 s presenta el mundo: el logo sobre el globo de Internet, la ciudad con tus dominios, la puerta Ingress y la planta; al final Kubi saluda. Cualquier tecla o toque la salta. En **VISTA** puedes desactivarla (**Intro al conectar**) o verla otra vez (**VER INTRO**). Los datos locales siguen en `~/.kubecraft` (nombre anterior del proyecto) para no perder configuraciones.

## La fábrica: niveles

| Nivel | Qué ves |
|---|---|
| **PLANTA** (vista general) | Una **nave industrial por Namespace** (también los vacíos) + la **planta de energía** (nodos). Monitor de un vistazo: ventanas encendidas = pods (verde ok, rojo fallando), luz del tejado = peor estado dentro, humo rojo = crashes. |
| **NAVE `<ns>`** (subnivel) | Cada **Deployment / StatefulSet / DaemonSet** es una **línea de montaje**: consola con lámparas por réplica (verde = ready) y cinta que solo corre si hay réplicas listas. Cada **Pod** es un **robot** en su estación (un bloque por contenedor, gema = estado). Cada **Service** es un **muelle de carga**; al pasar el ratón o seleccionar se dibujan las líneas de tráfico hacia sus pods. |
| **SALA DE ENERGÍA** | Cada **Node** es una isla-generador con los pods que corren físicamente en ella. Castillo = control-plane, valla = cordoned, luz roja = NotReady, nube = pods esperando al scheduler. |

Para entrar o salir basta con **pisar la alfombra de la puerta** (o pulsar E, hacer doble clic en una nave o usar la barra de niveles). Empiezas en la calle central, entre las naves, y al salir de una nave apareces delante de su puerta. Al pisar una isla o entrar en una nave aparece un **cartel de zona** que explica qué es (control-plane, worker o namespace), y la barra de niveles muestra dónde estás. Las tuberías warp y los quioscos se usan con E. El personaje respeta los límites físicos: camina solo por suelo real (terreno, suelo de la nave, islas y puentes) y no atraviesa naves, consolas, cintas ni muelles.

![Dentro de una nave](docs/hall.png)
![Sala de energía](docs/energy.png)

## Varios clusters y kubeconfigs

Un solo bridge sirve **todos los contextos** de tu kubeconfig y los kubeconfigs que añadas desde el juego. Cada cluster se conecta bajo demanda y el juego elige cuál con `?context=`.

En la pantalla de inicio:
- **Clusters guardados**: nombre, URL del bridge, contexto y token (se guardan en las preferencias del juego). Clic para conectar y X para borrar.
- **Nueva conexión**: URL del bridge y **CARGAR CONTEXTOS**. Elige uno y usa **GUARDAR Y CONECTAR**.
- **+ Añadir un kubeconfig**: pégalo, o **CARGAR ARCHIVO...** (selector nativo, o el del navegador en la versión web), ponle un nombre y **AÑADIR CLUSTER**. El kubeconfig se envía solo al bridge, que lo guarda en `~/.kubecraft/kubeconfigs/` con permisos 0600. El juego comprueba que el cluster responde, lo **guarda en la lista** y **se conecta**; si falla, muestra el error del servidor. Si alguno de sus contextos se llama igual que uno que ya tienes (típico: `default`, `kubernetes-admin@kubernetes`), aparece como `nombre-del-archivo/contexto` en lugar de ocultarse. Ojo: igual que con kubectl, un kubeconfig con plugins `exec` (aws, gke-gcloud-auth-plugin...) ejecuta ese comando en el host del bridge.

API: `GET /api/contexts`, `POST /api/kubeconfig {name, content}` y `DELETE /api/kubeconfig?name=`. Todas las rutas de cluster aceptan `?context=`.

## Escenario multinodo (kind)

```bash
make cluster         # kind: 1 control-plane + 3 workers (uno "GPU" con taint) + metrics-server + escenario
make serve-web-kind  # bridge en :8089 contra kind-kubecraft -> http://127.0.0.1:8089
make cluster-delete
make cluster-ha      # kind HA: 3 control-planes + 2 workers (plaza de etcd) + auditoría para el vigía
make cluster-ha-delete
```

### Varios control-planes (HA)

Con 2 o más control-planes la sala de energía muestra la **plaza de etcd**: un cristal por miembro (verde = Ready, rojo = caído) y un letrero con el quórum (`3 de 3 miembros activos, necesita 2, tolera 1 caída`). Lo típico son 3 o 5 (número impar para el quórum de etcd).

En el inspector de un control-plane hay un botón **+ CONTROL-PLANE**. En modo demo añade uno al momento; en un cluster real abre una guía con los pasos para kind, clusters gestionados (EKS/GKE/AKS: el proveedor los gestiona) y kubeadm (`kubeadm token create --print-join-command` + `kubeadm init phase upload-certs --upload-certs` + `kubeadm join ... --control-plane`). Añadir un control-plane es una operación de infraestructura: la API de Kubernetes no puede hacerlo, por eso el juego no finge hacerlo.

[`deploy/complex.yaml`](deploy/complex.yaml) crea cinco namespaces:

- **ecommerce**: tienda con réplicas repartidas entre nodos, API con sidecar, workers, Postgres con volumen y Redis.
- **data**: StatefulSet de 3 brokers, CronJob cada 2 min (pods Completed) y un Job.
- **ml**: entrenamiento forzado al nodo GPU (taint + toleration), un modelo con imagen rota y un pod que pide 64 CPUs y **nunca** se programa.
- **observability**: DaemonSet en todos los nodos y Prometheus.
- **chaos**: crashes aleatorios y un pod OOMKilled.

Tu contexto actual de kubectl no cambia.

## Sala de energía estilo Mario

Por defecto, **puentes de tablones** con escalones suaves llevan a cada isla sin saltar. El reto de plataformas estilo Mario se activa en **VISTA → Reto de saltos**. El **control-plane** es la isla central y es donde apareces; los workers orbitan a su alrededor a distintas alturas. Si el cluster no expone su control-plane (EKS, GKE...), el centro es una plataforma neutra. Cada isla tiene una **tubería warp** (E junto a ella; te hundes en ella, fundido y sales por la de la siguiente isla) y un **quiosco-terminal** (E) que abre la terminal ya ejecutando los comandos de ese nodo: sus pods y `describe node`, o `get nodes` y `cluster-info` en el control-plane. Para ir a pie hay que **saltar** por bloques "?", ladrillos y plataformas (algunas suben y bajan), recogiendo monedas. Si caes al vacío vuelves a la última plataforma donde estuviste. Hay *coyote time* (puedes saltar un instante después de salir del borde) y el salto pulsado justo antes de aterrizar también cuenta. La física es vertical de verdad: los bordes de una plataforma más alta hacen de pared y la sombra marca dónde vas a caer. Un test comprueba que cada isla es alcanzable con el salto del personaje.

## La ciudad Internet: cómo se conecta el cluster con el mundo

Al norte de la planta está **EL INTERNET**: una ciudad de rascacielos bajo un globo luminoso del que llueven paquetes de datos.

- Cada **dominio** de un Ingress es un **cartel de neón** (con candado dorado si usa HTTPS).
- Los **coches son peticiones**: salen del cartel, pasan por la **Puerta INGRESS** a la entrada de la planta y recorren las calles hasta la nave del namespace cuyo Service responde.
- Si el Service **no existe o no tiene pods listos**, el coche se para en la puerta con humo rojo y un **503**; la luz de la puerta se pone roja.
- Los Services **LoadBalancer** tienen su propia **carretera rosa con peaje**, que muestra la IP externa.
- Sin Ingress ni LoadBalancer, la barrera está bajada: nada del cluster es accesible desde fuera.
- Clic en la Puerta: controlador, dirección y cada ruta `dominio/ruta -> namespace/service:puerto` con su estado.

`make scenario` crea tres Ingress de ejemplo en el cluster kind, uno roto a propósito.

## Pods terminados (Completed)

Argo Workflows, los Jobs y los CronJobs dejan pods **Completed**. Kubernetes solo los recoge cuando el cluster supera los 12.500 pods terminados (`--terminated-pod-gc-threshold`), así que se acumulan.

- En el juego solo se dibujan los **8 más recientes por nave** (2 por nodo en la sala de energía); el resto va a una **pila de ARCHIVO** con contador. Para verlos todos: VISTA > Mostrar todos los pods terminados.
- Con 30 o más en un namespace, **Kubi** avisa ("Muchos pods terminados"): explica por qué pasa, da la configuración para que se limpien solos (Argo `podGC` / `ttlStrategy`, Jobs `ttlSecondsAfterFinished`, CronJobs `*HistoryLimit`) y ofrece **Limpiar pods terminados** (`kubectl delete pods --field-selector=status.phase==Succeeded`, con confirmación; los pods en marcha no se tocan).

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
| clic en el suelo | ir allí andando (esquiva obstáculos, corre si está lejos; clic en un objeto = inspeccionar e ir). Se desactiva en VISTA |
| SHIFT (mantener) / X (alternar) | correr con "zapatillas" estilo Pokémon: más rápido, inclinado y levantando polvo |
| ESPACIO | saltar |
| Z · ESPACIO dos veces | jetpack: mantén ESPACIO para subir, CTRL para bajar, sin tocar nada flota |
| Y · O | Kubi, el asistente · modo vigía |
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

## Modo caos y armas (C, 1-6, F)

Con el modo caos activado (C), **F** dispara el arma equipada contra lo que tengas delante. Cada arma es una operación real de Kubernetes y se desbloquea al completar la misión que enseña ese concepto:

| Tecla | Arma | Operación | Se desbloquea con |
|---|---|---|---|
| 1 | Pistola de pods | `delete pod` | desde el inicio |
| 2 | Martillo de rollout | `rollout restart` del workload | misión "Actualización continua" |
| 3 | Rayo reductor | `scale` −1 réplica | misión "Más producción" |
| 4 | Pistola de hielo | `cordon` / `uncordon` del nodo | misión "Mantenimiento" |
| 5 | Cortador de servicios | `delete service` | misión "Sigue el tráfico" |
| 6 | Bomba nuclear | `delete` del workload entero | misión "Recoge la fábrica" |

El cortador y la bomba piden confirmación siempre. Todo disparo aparece en la TERMINAL como su comando kubectl.

Cada arma tiene su animación, aunque no haya nada al alcance: el disparo sale igual y se pierde en el aire, sin ejecutar nada.
- **Pistola**: rayo con estela.
- **Martillo**: golpe y onda expansiva en el suelo.
- **Rayo reductor**: haz vibrante con anillos.
- **Hielo**: chorro de cristales que dejan hielo donde impactan.
- **Cortador**: cuchilla que va y vuelve como un bumerán.
- **Bomba**: cohete en parábola, explosión, hongo y temblor de cámara.

Cada arma tiene su tiempo de recarga, y la operación real se ejecuta cuando el disparo impacta.

## Audio

Todo el sonido se **genera por código** con un pequeño sintetizador chiptune ([`sfx.gd`](game/scripts/sfx.gd): ondas cuadrada, triangular, sierra y ruido, con barridos y envolventes), así que el juego no incluye ningún archivo de audio:
- **Efectos**: cada arma, pasos, salto, aterrizaje, monedas, tuberías, puertas, caídas, muerte de pods, clics de la interfaz, teclas de la terminal, misión completada y una alarma cuando un pod empieza a fallar.
- **Música**: dos bucles en la misma tonalidad, uno de día (animado) y otro de noche (tranquilo), que se funden según la hora del cluster.
- **Volumen**: música y efectos en **VISTA**.

## Capacidad de los nodos

Cada isla tiene dos medidores (CPU azul y memoria rosa) que muestran lo **reservado por los requests** de sus pods frente a lo asignable del nodo: verde, amarillo o rojo según la presión. Su letrero dice, por ejemplo, "cpu 700m/4.0, mem 896 MiB/8 GiB". El panel del nodo separa lo reservado (lo único que mira el scheduler), lo libre y el uso real (metrics-server). Un pod Pending muestra el mensaje del scheduler con el motivo exacto, por ejemplo "0/4 nodes are available: 2 Insufficient cpu, 2 node(s) had untolerated taint(s)", y lo que pide.

## Móvil y tablet (táctil)

En pantallas táctiles (o si la ventana es estrecha) el juego cambia a un **modo compacto**:

- Arriba solo el título, el estado y **MENÚ**, que abre todo en botones grandes: Kubi, vigía, mapa, misiones, alarmas, construir, caos, terminal, leyenda, stats, 1ª persona, jetpack, sonido, vista y salir.
- Los paneles (inspector, Kubi, vigía, editor, pantalla de inicio) usan todo el ancho. La terminal y las misiones se abren desde el menú. El minimapa es pequeño y va arriba a la izquierda.
- **Controles táctiles**:
  - joystick flotante: pon el pulgar abajo a la izquierda; empujar hasta el borde = correr
  - botones **SALTAR** (mantén pulsado para subir con el jetpack), **USAR**, **JET**, **BAJAR** (volando) y **FUEGO** (en modo caos)
  - **tocar** = inspeccionar e ir andando; **arrastrar** = mover la cámara; **pellizcar** = zoom; **girar con dos dedos** = rotar; en primera persona, arrastrar = mirar
  - **toca a Kubi** o su bocadillo para abrir su panel
- La escala de la UI se ajusta al teléfono (unas 460 unidades en el lado corto). En VISTA > "Controles táctiles" se elige automático / sí / no.

### Jugar desde el móvil (red local)

Por seguridad el bridge solo escucha en `127.0.0.1`: controla tu cluster con tus credenciales. Para abrirlo desde el móvil o la tablet en la misma Wi-Fi:

```bash
make serve-lan      # = k8s-bridge --lan --web build/web
```

`--lan` escucha en todas las interfaces, genera un **token aleatorio** (o usa `--token`), permite los orígenes de tu red local e imprime las URLs a abrir, del tipo `https://192.168.1.20:8088/?token=...` (solo las IPs de interfaces reales, no las de Docker/OrbStack). El juego conecta solo con ese token.

- Va por **HTTPS con un certificado autofirmado**, porque los navegadores solo ejecutan builds web de Godot en un contexto seguro. El móvil avisa una vez del certificado: acéptalo. Se guarda en `~/.kubecraft/tls` y se reutiliza mientras cubra tus IPs.
- El token viaja en la URL: compártela solo con quien quieras. Para solo mirar, añade `--readonly`.
- El bridge se niega a escuchar fuera de localhost sin token.
- En macOS puede aparecer el aviso del firewall para aceptar conexiones entrantes.

## Sonido (VOL)

El botón **VOL** de la barra superior abre volumen general, música y efectos, y **silenciar todo**. Se guarda en los ajustes.

## Editor de manifiestos estilo Matrix

**EDITAR YAML** en el inspector (pods, workloads, services, nodos), `kubectl edit <tipo>/<nombre> -n <ns>` en la terminal, o **Arreglar en el YAML** desde Kubi abren un editor retro: lluvia de código verde, el manifiesto se "descifra" línea a línea y aparece con resaltado. La columna **DECODER** explica cada línea (qué hace `replicas`, `requests.cpu`, `tolerations`...) y avisa de valores peligrosos: imagen `latest`, 1 réplica, contenedor `privileged`, límite de memoria muy bajo, secretos en texto plano. `~` marca las líneas cambiadas.

- **VALIDAR** = `kubectl replace --dry-run=server`: el API server comprueba el cambio sin aplicarlo.
- **APLICAR** reemplaza el objeto, con confirmación. No se puede cambiar el tipo, el nombre ni el namespace, y los Secrets no se pueden editar aquí (sus valores saldrían en pantalla). Se ocultan `status`, `managedFields` y la anotación last-applied, que se conserva al guardar.
- **PREGUNTAR A KUBI POR ESTA LÍNEA** y **pregúntale a Kubi por este error** le pasan el YAML o el error a Kubi.
- En modo demo, cambiar la imagen rota de `fraud-ai` o la CPU de `giant-experiment` arregla los pods de verdad.

## Jetpack (Z)

Z (o ESPACIO dos veces) enciende el jetpack: dos tanques con llamas en la mochila y sonido de motor. Mantén ESPACIO para subir, CTRL para bajar; soltando todo flota. Vuela por encima de naves, consolas y tuberías y se puede **aterrizar en los tejados**. Tiene un techo por nivel (más bajo dentro de las naves). Apagarlo en el aire = caer.

## Kubi, el asistente (Y)

Un dron tipo "Pokédex" que te sigue, mira hacia el problema más cercano (con una flecha) y avisa en un bocadillo cuando algo se rompe. Y abre su panel:

- **Problemas** del cluster, peor primero, con un **diagnóstico integrado** (funciona siempre, también en web/demo): por qué pasa (ImagePullBackOff, CrashLoopBackOff, OOMKilled, sin sitio en ningún nodo con los números de CPU/memoria, taints, selectores, PVC, readiness, nodos NotReady o acordonados...), pasos para arreglarlo y comandos. Los comandos de lectura se ejecutan en la terminal al hacer clic; los que cambian algo solo se escriben para que los revises y pulses Enter. Botones: ir allí, logs del contenedor que falló, reiniciar el workload, borrar el pod, uncordon (siempre con confirmación).
- **Chat libre** con memoria de la conversación: pregunta lo que quieras del cluster o de Kubernetes. El *tema* es el problema seleccionado o "todo el cluster" (el bridge le pasa estado, eventos, últimas líneas de log y el diagnóstico integrado). NUEVO CHAT borra la memoria. Lo que dice el modelo nunca se ejecuta solo.
- **Salidas de comandos en el chat**: los comandos de lectura que sugiere Kubi se ejecutan y su salida se **adjunta** sola a la siguiente pregunta (etiqueta `[x]` para quitarla, botón "¿Qué significa esta salida?"). Cualquier salida de la terminal, también de comandos que escribas tú, trae el enlace **-> enviar esta salida a Kubi**.
- **Comandos clicables**: en el diagnóstico y en las respuestas (código en línea o bloques ```), cada comando kubectl tiene **EJECUTAR** y **COPIAR**; los que tienen huecos `<...>`, **A LA TERMINAL**; otros comandos (docker, journalctl...) solo COPIAR. La terminal quita el `kubectl` inicial de lo que pegues.
- La **terminal** también se mueve (arrastrando su barra) y se redimensiona desde cualquier borde; doble clic en su barra la devuelve a su sitio.
- El panel se **arrastra** por la barra de título, se **redimensiona** desde cualquier borde o esquina y se **pliega** con `_` (o doble clic en el título).
- **AJUSTES**: motor (automático / Ollama / llama.cpp integrado / apagado), modelo, largo de las respuestas y estilo (preciso/creativo). Se guardan en `~/.kubecraft/assistant.json`.

### Motores de IA (todo local)

- **Ollama**, si lo tienes (`ollama serve`): usa el mejor modelo instalado (gemma4, qwen3.5, llama3.2...) y desde AJUSTES puedes descargar modelos sugeridos en tu Ollama con barra de progreso.
- **llama.cpp integrado**, sin instalar nada: desde AJUSTES Kubiverse descarga el build **oficial** de `github.com/ggml-org/llama.cpp` para tu sistema (~15 MB, verificado con el SHA256 que publica GitHub) y un modelo GGUF de una lista (Gemma 3 1B/4B/12B, Qwen 2.5 1.5B/3B/7B, Llama 3.2 3B) desde Hugging Face con **SHA256 fijado en el código**. Todo va a `~/.kubecraft/` y `llama-server` escucha solo en `127.0.0.1`; el bridge lo arranca al preguntar y lo para al salir.
- Nunca se usan modelos `:cloud` ni servidores remotos: el juego no puede cambiar la URL del motor (solo el flag `--llm-url`).

## Modo vigía (O)

Kubernetes no tiene una API de "quién está conectado". El vigía combina tres fuentes:

1. **Auditoría del API server** (identidad real: usuario, grupos, IP de origen, herramienta, verbo y recurso, y si fue denegado). Hay que activarla en el cluster; el bridge lee `~/.kubecraft/audit/<contexto>/**/audit.log` (`--audit-dir`). `make cluster-ha` crea un cluster kind con la auditoría ya activada ([`deploy/audit-policy.yaml`](deploy/audit-policy.yaml): solo metadatos, nunca el contenido de Secrets ni de las peticiones). En clusters gestionados la auditoría va al proveedor (EKS → CloudWatch, GKE → Cloud Audit Logs, AKS → Diagnostic settings).
2. **managedFields**: qué *herramienta* cambió algo (kubectl-edit, helm, argocd...), en cualquier cluster, sin identidad.
3. **Jugadores de Kubiverse** conectados a este bridge.

Con el vigía abierto cada identidad aparece como un **fantasma** que camina hacia lo que toca (a la puerta del namespace, al pod, a la isla del nodo) y lanza un rayo cuando escribe. Una identidad nueva, un acceso denegado (401/403) o tocar Secrets dispara una **alarma**. El panel se puede minimizar (`_`) sin apagar el modo. Filtra el ruido interno (nodos, controladores de kube-system); el propio bridge se marca como "este bridge" y se oculta.

## Primera persona (P)

Cámara en perspectiva a la altura del casco: el ratón mira (se captura; ESC lo libera), clic inspecciona lo que hay bajo la retícula, y se conservan el andar, correr, saltar y los límites físicos.

## Estadísticas (F3)

- **Juego**: FPS, tiempo de frame, RAM, VRAM, draw calls, objetos y GPU.
- **Cluster**: CPU y memoria totales y por nodo, pods por nodo frente a su capacidad y los pods que más CPU usan. Con **metrics-server** se muestra el uso real (`make metrics-server` lo instala; en clusters locales añade `--kubelet-insecure-tls`). Sin él, se muestra lo reservado por los *requests* de los pods.

## Día y noche

La iluminación sigue la **hora del cluster** (reloj del bridge, en tu zona horaria). El sol cruza el cielo, hay amanecer y atardecer anaranjados, y por la noche luna y estrellas. La hora se muestra en la barra de niveles. En modo demo (o con **VISTA → Ciclo día/noche acelerado**) un día dura 4 minutos.

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
--llm-url URL        Ollama para Kubi (por defecto http://127.0.0.1:11434; "" lo desactiva; si no es local, avisa)
--llm-model NAME     modelo de Ollama (auto = el mejor local instalado, nunca ":cloud")
--audit-dir DIR      logs de auditoría para el vigía (por defecto ~/.kubecraft/audit)
--lan                red local (móviles): HTTPS autofirmado + todas las interfaces + token aleatorio + imprime las URLs
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
| GET | `/api/ws` | WebSocket: `{"type":"state","data":Snapshot}` (≤3/s, coalescido), `{"type":"event","data":{...}}` y `{"type":"watch","data":{audit, visitors, actions}}` (vigía) |
| GET · POST | `/api/assistant` | estado de los motores, modelos, catálogo y descargas · `{"question","kind","ns","name","lang","diagnosis","history"}` → `{"ok","answer","model"}` |
| POST | `/api/assistant/config` · `/api/assistant/download` | ajustes de Kubi · descargar `{"kind":"llamacpp"\|"gguf"\|"ollama","id"}` |
| DELETE | `/api/assistant/model?id=` | borrar un modelo GGUF descargado |
| GET · POST | `/api/manifest` | YAML de un objeto (`?kind=&ns=&name=`) · reemplazarlo `{"kind","ns","name","yaml","dry_run"}` |
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
