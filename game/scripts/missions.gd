class_name Missions
extends Node
## Guided missions, checked against the live cluster state and what the player
## does in the game. Which ones apply depends on the kind of cluster:
##   prod      read-only: know the cluster, bottlenecks, anomalies, incidents,
##             observability. Nothing here changes the cluster.
##   sandbox   three levels: basic (the tour, in its own "academia"
##             namespace), intermediate (fix the sample scenario's
##             breakdowns) and advanced (break things on purpose, recover).

signal progress_changed
signal completed(m: Dictionary)

const NS := "academia"
const LEVELS := ["basic", "intermediate", "advanced"]
const TRACK_TITLES := {"prod": "PRODUCTION", "basic": "BASIC", "intermediate": "INTERMEDIATE", "advanced": "ADVANCED"}

## Sandbox, basic: the guided tour (also unlocks the chaos weapons).
const LIST := [
	{"id": "nave", "title": "The plant", "title_es": "La planta",
		"goal": "Enter any hall: walk to its door and press E (or click the hall and ENTER).",
		"goal_es": "Entra en cualquier nave: acércate a su puerta y pulsa E (o haz clic en la nave y ENTRAR).",
		"learn": "Each hall is a NAMESPACE: a logical folder that separates teams or apps inside the same cluster.",
		"learn_es": "Cada nave es un NAMESPACE: una carpeta lógica que separa equipos o aplicaciones dentro del mismo cluster.",
		"cmd": "kubectl get namespaces"},
	{"id": "robot", "title": "The robots", "title_es": "Los robots",
		"goal": "Inside a hall, click a robot (a pod) to inspect it.",
		"goal_es": "Dentro de una nave, haz clic en un robot (un pod) para inspeccionarlo.",
		"learn": "A POD is the smallest thing Kubernetes runs: one or more containers sharing a network. Each block of the robot's body is a container.",
		"learn_es": "Un POD es la unidad mínima que Kubernetes ejecuta: uno o varios contenedores que comparten red. Cada bloque del robot es un contenedor.",
		"cmd": "kubectl get pods -n <namespace> -o wide"},
	{"id": "energia", "title": "The energy room", "title_es": "La sala de energía",
		"goal": "Go back to the plant, enter the ENERGY PLANT and click an island (a node).",
		"goal_es": "Vuelve a la planta, entra en la PLANTA DE ENERGÍA y haz clic en una isla (un nodo).",
		"learn": "NODES are the real machines (VMs or servers). The scheduler decides which node runs each pod; here you see pods standing on their node.",
		"learn_es": "Los NODOS son las máquinas reales (VMs o servidores). El scheduler decide en qué nodo corre cada pod; aquí ves a los pods de pie sobre su nodo.",
		"cmd": "kubectl get nodes -o wide"},
	{"id": "linea", "title": "Build your line", "title_es": "Construye tu línea",
		"goal": "Press B and create a Deployment in the 'academia' namespace (already filled in).",
		"goal_es": "Pulsa B y crea un Deployment en el namespace 'academia' (ya viene rellenado).",
		"learn": "A DEPLOYMENT declares the desired state ('I want 2 copies of nginx'). Kubernetes creates a ReplicaSet, which creates the pods, and keeps it that way.",
		"learn_es": "Un DEPLOYMENT declara el estado deseado ('quiero 2 copias de nginx'). Kubernetes crea un ReplicaSet que a su vez crea los pods, y lo mantiene así.",
		"cmd": "kubectl -n academia create deployment hola --image=nginx:alpine --replicas=2"},
	{"id": "autorreparacion", "title": "Self-healing", "title_es": "Autorreparación",
		"goal": "Enter the 'academia' hall and delete one pod of your line (DELETE POD). Watch another one appear.",
		"goal_es": "Entra en la nave 'academia' y borra un pod de tu línea (BORRAR POD). Observa cómo aparece otro.",
		"learn": "Controllers reconcile: if the real state (1 pod) doesn't match the desired one (2), they create what's missing. That's why deleting a pod is rarely a big deal.",
		"learn_es": "Los controladores reconcilian: si el estado real (1 pod) no coincide con el deseado (2), crean lo que falta. Por eso borrar un pod casi nunca es grave.",
		"cmd": "kubectl -n academia delete pod <pod>"},
	{"id": "escala", "title": "More production", "title_es": "Más producción",
		"goal": "Scale your 'academia' line to 4 replicas (SCALE +) and wait until all 4 are ready.",
		"goal_es": "Escala tu línea de 'academia' a 4 réplicas (ESCALAR +) y espera a que las 4 estén listas.",
		"learn": "Scaling only changes the desired number; the Deployment creates or deletes pods to match it. 'ready' counts the ones already passing their checks.",
		"learn_es": "Escalar solo cambia el número deseado; el Deployment crea o borra pods hasta llegar a él. 'ready' indica los que ya pasan sus comprobaciones.",
		"cmd": "kubectl -n academia scale deployment/<name> --replicas=4"},
	{"id": "trafico", "title": "Follow the traffic", "title_es": "Sigue el tráfico",
		"goal": "Click a loading dock (a Service) in any hall and see which robots it sends traffic to.",
		"goal_es": "Haz clic en un muelle (un Service) de cualquier nave y mira a qué robots manda tráfico.",
		"learn": "A SERVICE gives a stable IP and DNS name and spreads traffic across the pods matching its label selector (its endpoints). Pods come and go; the Service stays.",
		"learn_es": "Un SERVICE da una IP y nombre DNS fijos y reparte el tráfico entre los pods que coinciden con su selector de labels (sus endpoints). Los pods cambian; el Service no.",
		"cmd": "kubectl get endpointslices -n <namespace>"},
	{"id": "averia", "title": "Breakdown detective", "title_es": "Detective de averías",
		"goal": "Find a red or pink (failing) robot and open its logs (L). If there is none, you can skip this mission.",
		"goal_es": "Encuentra un robot rojo o rosa (con fallos) y abre sus logs (L). Si no hay ninguno, puedes saltar esta misión.",
		"learn": "CrashLoopBackOff = the container starts and dies again and again. ImagePullBackOff = the image can't be downloaded. Logs (and --previous) usually say why.",
		"learn_es": "CrashLoopBackOff = el contenedor arranca y muere una y otra vez. ImagePullBackOff = no puede descargar la imagen. Los logs (y --previous) suelen decir por qué.",
		"cmd": "kubectl logs <pod> --previous"},
	{"id": "rollout", "title": "Rolling update", "title_es": "Actualización continua",
		"goal": "RESTART your 'academia' line and watch the robots get replaced one by one.",
		"goal_es": "Haz REINICIAR en tu línea de 'academia' y mira cómo se reemplazan los robots uno a uno.",
		"learn": "A rollout replaces pods gradually (rolling update) so the service never goes down. It's what happens when you change a Deployment's image.",
		"learn_es": "Un rollout reemplaza pods gradualmente (rolling update) para que el servicio no se caiga. Es lo que pasa al cambiar la imagen de un Deployment.",
		"cmd": "kubectl -n academia rollout restart deployment/<name>"},
	{"id": "mantenimiento", "title": "Maintenance", "title_es": "Mantenimiento",
		"goal": "In the energy room, CORDON a node and then UNCORDON it.",
		"goal_es": "En la sala de energía, haz CORDON a un nodo y después UNCORDON.",
		"learn": "Cordon marks a node as unavailable for new pods (existing ones keep running). It's the first step before 'drain' for maintenance.",
		"learn_es": "Cordon marca un nodo como no disponible para pods nuevos (los actuales siguen). Es el primer paso antes de 'drain' para hacer mantenimiento.",
		"cmd": "kubectl cordon <node> && kubectl uncordon <node>"},
	{"id": "limpieza", "title": "Clean up the factory", "title_es": "Recoge la fábrica",
		"goal": "Delete your 'academia' line (DELETE button on its console).",
		"goal_es": "Borra tu línea de 'academia' (botón BORRAR en su consola).",
		"learn": "Deleting the Deployment cascades to its ReplicaSet and pods. To remove the namespace too: kubectl delete namespace academia.",
		"learn_es": "Borrar el Deployment borra en cascada su ReplicaSet y sus pods. Si también quieres borrar el namespace: kubectl delete namespace academia.",
		"cmd": "kubectl -n academia delete deployment/<name>"},
]


## Production: read-only. Know the cluster, find bottlenecks and anomalies,
## respond to incidents, check observability.
const PROD := [
	{"id": "p_census", "title": "Census", "title_es": "Censo",
		"goal": "Open the stats (F3): how many nodes, pods and how much CPU and memory does this cluster have?",
		"goal_es": "Abre las estadísticas (F3): ¿cuántos nodos, pods, CPU y memoria tiene este cluster?",
		"learn": "Before touching anything, know the size of what you run: nodes, pods per node against their capacity, and the total CPU and memory.",
		"learn_es": "Antes de tocar nada, conoce el tamaño de lo que corres: nodos, pods por nodo frente a su capacidad y la CPU y memoria totales.",
		"cmd": "kubectl get nodes -o wide && kubectl get pods -A"},
	{"id": "p_nodes", "title": "The machines", "title_es": "Las máquinas",
		"goal": "Go to the ENERGY ROOM and click an island (a node): read its capacity, what is reserved and its version.",
		"goal_es": "Ve a la SALA DE ENERGÍA y haz clic en una isla (un nodo): mira su capacidad, lo reservado y su versión.",
		"learn": "Each node has allocatable CPU and memory. The scheduler places pods by their requests, not by real usage: a node can be 'full' while idle.",
		"learn_es": "Cada nodo tiene CPU y memoria asignables. El scheduler coloca pods según sus requests, no según el uso real: un nodo puede estar 'lleno' sin hacer nada.",
		"cmd": "kubectl describe node <node>"},
	{"id": "p_bottleneck", "title": "Bottleneck hunt", "title_es": "Caza del cuello de botella",
		"goal": "Find and click the node with the most CPU reserved (its blue gauge is the fullest).",
		"goal_es": "Encuentra y haz clic en el nodo con más CPU reservada (su medidor azul es el más lleno).",
		"learn": "When one node is much fuller than the rest (see 'Allocated resources' in describe nodes), new pods pile up on the others or stay Pending. Spread them with requests that match reality, anti-affinity or topology spread constraints.",
		"learn_es": "Cuando un nodo está mucho más lleno que el resto (mira 'Allocated resources' en describe nodes), los pods nuevos se amontonan en los demás o se quedan Pending. Repártelos con requests realistas, anti-afinidad o topology spread constraints.",
		"cmd": "kubectl describe nodes"},
	{"id": "p_pending", "title": "The waiting room", "title_es": "La sala de espera",
		"goal": "Click a pod that is waiting for the scheduler (Pending) and read why. If there is none, this completes by itself.",
		"goal_es": "Haz clic en un pod que espera al scheduler (Pending) y lee por qué. Si no hay ninguno, se completa solo.",
		"learn": "A Pending pod means no node fits it: not enough CPU or memory, a taint it doesn't tolerate, a node selector or a volume that can't attach. The scheduler's message says which.",
		"learn_es": "Un pod Pending significa que ningún nodo le sirve: falta CPU o memoria, un taint que no tolera, un node selector o un volumen que no se puede montar. El mensaje del scheduler dice cuál.",
		"cmd": "kubectl get pods -A --field-selector=status.phase=Pending"},
	{"id": "p_restarts", "title": "Restart anomaly", "title_es": "Anomalía de reinicios",
		"goal": "Open the logs (L) of the pod with the most restarts, with 'previous' on. If nothing restarts, this completes by itself.",
		"goal_es": "Abre los logs (L) del pod con más reinicios, con 'previous' marcado. Si nada se reinicia, se completa solo.",
		"learn": "Restarts that keep growing are an early warning: crashes, OOM kills or failing liveness probes. The previous container's logs show how it died.",
		"learn_es": "Los reinicios que no paran de crecer son una alerta temprana: crashes, OOM o liveness probes que fallan. Los logs del contenedor anterior muestran cómo murió.",
		"cmd": "kubectl get pods -A --sort-by='.status.containerStatuses[0].restartCount'"},
	{"id": "p_incident", "title": "Incident response", "title_es": "Respuesta a incidentes",
		"goal": "When something fails (ALARMS turns red), open Kubi (Y) and read its diagnosis. If all is healthy, wait for an incident or skip.",
		"goal_es": "Cuando algo falle (ALARMAS en rojo), abre a Kubi (Y) y lee su diagnóstico. Si todo está sano, espera a un incidente o salta.",
		"learn": "First understand, then act: what fails, since when, what changed. Kubi's diagnosis gives the likely cause and the read-only commands to confirm it before any fix.",
		"learn_es": "Primero entender, luego actuar: qué falla, desde cuándo, qué cambió. El diagnóstico de Kubi da la causa probable y los comandos de lectura para confirmarla antes de arreglar nada.",
		"cmd": "kubectl get events -A --sort-by=.lastTimestamp"},
	{"id": "p_hotspots", "title": "Hot spots", "title_es": "Puntos calientes",
		"goal": "In the terminal (/), run 'top pods -A' (needs metrics-server) or 'get events -A'.",
		"goal_es": "En la terminal (/), ejecuta 'top pods -A' (necesita metrics-server) o 'get events -A'.",
		"learn": "Real usage (top) against requests shows over- and under-sized apps; events show what the cluster itself is complaining about.",
		"learn_es": "El uso real (top) frente a los requests muestra apps sobredimensionadas o cortas; los eventos muestran de qué se queja el propio cluster.",
		"cmd": "kubectl top pods -A --sort-by=cpu"},
	{"id": "p_front", "title": "The front door", "title_es": "La puerta principal",
		"goal": "Go north to THE INTERNET and click the INGRESS gate: check every route and its status.",
		"goal_es": "Ve al norte, a EL INTERNET, y haz clic en la puerta INGRESS: revisa cada ruta y su estado.",
		"learn": "Users reach you through Ingress and LoadBalancers. A route to a Service with no ready pods answers 503 even if everything else looks fine.",
		"learn_es": "Los usuarios llegan por el Ingress y los LoadBalancers. Una ruta a un Service sin pods listos responde 503 aunque todo lo demás parezca bien.",
		"cmd": "kubectl get ingress -A"},
	{"id": "p_watch", "title": "Who touches the cluster", "title_es": "Quién toca el cluster",
		"goal": "Open the WATCHTOWER (O) and see who and what is changing the cluster.",
		"goal_es": "Abre el VIGÍA (O) y mira quién y qué está cambiando el cluster.",
		"learn": "Audit logs give real identities (user, IP, verb); managedFields tell which tool changed each object. Unexpected writes or 403s are worth a look.",
		"learn_es": "Los logs de auditoría dan identidades reales (usuario, IP, verbo); managedFields dice qué herramienta cambió cada objeto. Escrituras inesperadas o 403 merecen una mirada.",
		"cmd": "kubectl get deploy <name> -o jsonpath='{.metadata.managedFields[*].manager}'"},
]

## Sandbox, intermediate: fix the breakdowns of the sample scenario (the demo
## cluster has them already; on a real sandbox use DEPLOY SCENARIO).
const INTERMEDIATE := [
	{"id": "i_image", "title": "Wrong image", "title_es": "Imagen equivocada",
		"goal": "A line has pods stuck pulling their image (pink). Open its YAML (EDIT YAML), fix the image and APPLY until its pods are ready.",
		"goal_es": "Una línea tiene pods atascados descargando su imagen (rosa). Abre su YAML (EDITAR YAML), corrige la imagen y APLICA hasta que sus pods estén listos.",
		"learn": "ErrImagePull / ImagePullBackOff: the image name or tag doesn't exist, or the registry needs credentials (imagePullSecrets). Changing the image makes the Deployment roll out new pods.",
		"learn_es": "ErrImagePull / ImagePullBackOff: el nombre o tag de la imagen no existe, o el registry pide credenciales (imagePullSecrets). Cambiar la imagen hace que el Deployment despliegue pods nuevos.",
		"cmd": "kubectl -n <ns> set image deployment/<name> <container>=<image:tag>"},
	{"id": "i_room", "title": "No room", "title_es": "No hay sitio",
		"goal": "A pod waits forever (Pending) because it asks for more CPU than any node has. Lower its CPU request in the YAML until it runs.",
		"goal_es": "Un pod espera para siempre (Pending) porque pide más CPU de la que tiene cualquier nodo. Baja su request de CPU en el YAML hasta que corra.",
		"learn": "Requests are a reservation: a pod only fits on a node with that much free allocatable. Ask for what the app really needs; limits cap it, requests place it.",
		"learn_es": "Los requests son una reserva: un pod solo cabe en un nodo con ese hueco libre. Pide lo que la app necesita de verdad; los limits la limitan, los requests la colocan.",
		"cmd": "kubectl -n <ns> set resources deployment/<name> --requests=cpu=100m"},
	{"id": "i_crash", "title": "Crash loop", "title_es": "Bucle de caídas",
		"goal": "Find a pod in CrashLoopBackOff (red) and open its logs (L) with 'previous' on to see why it dies.",
		"goal_es": "Encuentra un pod en CrashLoopBackOff (rojo) y abre sus logs (L) con 'previous' marcado para ver por qué muere.",
		"learn": "The current container may have just started; the previous one holds the crash. Exit code 137 = killed (OOM or liveness), 1 = the app failed.",
		"learn_es": "El contenedor actual puede acabar de arrancar; el anterior guarda el crash. Código 137 = matado (OOM o liveness), 1 = la app falló.",
		"cmd": "kubectl -n <ns> logs <pod> --previous"},
	{"id": "i_endpoints", "title": "Service with no one behind", "title_es": "Service sin nadie detrás",
		"goal": "Click a loading dock (a Service) with no ready pods behind it: its traffic goes nowhere.",
		"goal_es": "Haz clic en un muelle (un Service) sin pods listos detrás: su tráfico no llega a ningún sitio.",
		"learn": "A Service only sends traffic to ready pods matching its selector. No endpoints = connection refused or 503, even though the Service exists.",
		"learn_es": "Un Service solo manda tráfico a pods listos que coinciden con su selector. Sin endpoints = conexión rechazada o 503, aunque el Service exista.",
		"cmd": "kubectl -n <ns> get endpointslices -l kubernetes.io/service-name=<svc>"},
	{"id": "i_route", "title": "Broken route", "title_es": "Ruta rota",
		"goal": "In THE INTERNET, click the INGRESS gate and find the route whose car stops with a 503.",
		"goal_es": "En EL INTERNET, haz clic en la puerta INGRESS y encuentra la ruta cuyo coche se para con un 503.",
		"learn": "An Ingress rule pointing to a Service that doesn't exist, or has no ready pods, answers 503. Fix the rule or the Service it points to.",
		"learn_es": "Una regla de Ingress que apunta a un Service inexistente, o sin pods listos, responde 503. Arregla la regla o el Service al que apunta.",
		"cmd": "kubectl describe ingress -A"},
]

## Sandbox, advanced: break things on purpose (chaos mode) and recover.
const ADVANCED := [
	{"id": "a_chaos", "title": "Chaos monkey", "title_es": "Mono del caos",
		"goal": "Turn on CHAOS mode (C), shoot a pod of any line (F) and watch its line bring it back.",
		"goal_es": "Activa el modo CAOS (C), dispara a un pod de cualquier línea (F) y mira cómo su línea lo recupera.",
		"learn": "Chaos engineering: kill things on purpose to prove the system heals. Pods owned by a Deployment or StatefulSet come back; bare pods don't.",
		"learn_es": "Ingeniería del caos: romper cosas a propósito para comprobar que el sistema se cura. Los pods de un Deployment o StatefulSet vuelven; los pods sueltos no.",
		"cmd": "kubectl -n <ns> delete pod <pod>"},
	{"id": "a_drain", "title": "Drain drill", "title_es": "Simulacro de drain",
		"goal": "CORDON a node, delete one of its pods (it will be recreated on another node) and UNCORDON it.",
		"goal_es": "Haz CORDON a un nodo, borra uno de sus pods (se recreará en otro nodo) y haz UNCORDON.",
		"learn": "That's what 'kubectl drain' does for maintenance: cordon, then evict every pod so they move elsewhere. PodDisruptionBudgets limit how many can go at once.",
		"learn_es": "Es lo que hace 'kubectl drain' para mantenimiento: cordon y después desalojar cada pod para que se muevan. Los PodDisruptionBudgets limitan cuántos pueden irse a la vez.",
		"cmd": "kubectl drain <node> --ignore-daemonsets && kubectl uncordon <node>"},
	{"id": "a_zero", "title": "Lights out", "title_es": "Apagón",
		"goal": "Scale a line to 0 replicas (shrink ray or SCALE -) and then bring it back until it's ready.",
		"goal_es": "Escala una línea a 0 réplicas (rayo reductor o ESCALAR -) y luego recupérala hasta que esté lista.",
		"learn": "Scale to zero stops a service without deleting its config: its Service and Ingress answer 503 meanwhile. Useful for maintenance windows or saving money in dev.",
		"learn_es": "Escalar a cero para un servicio sin borrar su configuración: mientras, su Service e Ingress responden 503. Útil en ventanas de mantenimiento o para ahorrar en dev.",
		"cmd": "kubectl -n <ns> scale deployment/<name> --replicas=0"},
	{"id": "a_badimage", "title": "Bad deploy, then fix", "title_es": "Despliegue roto y arreglo",
		"goal": "In the YAML of a healthy Deployment, set an image that doesn't exist and APPLY; when its new pods fail, put the right image back until it is ready.",
		"goal_es": "En el YAML de un Deployment sano, pon una imagen que no existe y APLICA; cuando sus pods nuevos fallen, vuelve a poner la buena hasta que esté listo.",
		"learn": "A rolling update keeps old pods while the new ones aren't ready, so a bad image rarely takes everything down. 'kubectl rollout undo' goes back to the previous version.",
		"learn_es": "Un rolling update mantiene los pods viejos mientras los nuevos no están listos, así que una imagen mala rara vez tumba todo. 'kubectl rollout undo' vuelve a la versión anterior.",
		"cmd": "kubectl -n <ns> rollout undo deployment/<name>"},
	{"id": "a_rebuild", "title": "Nuke and rebuild", "title_es": "Destruir y reconstruir",
		"goal": "Delete a whole line (nuke or DELETE) and build a new one in the same namespace (B).",
		"goal_es": "Borra una línea entera (bomba o BORRAR) y construye otra en el mismo namespace (B).",
		"learn": "Everything in Kubernetes is declarative: if your manifests live in git (GitOps), rebuilding after a disaster is 'kubectl apply' away.",
		"learn_es": "Todo en Kubernetes es declarativo: si tus manifiestos viven en git (GitOps), reconstruir tras un desastre está a un 'kubectl apply'.",
		"cmd": "kubectl apply -f <your-manifests>/"},
]

var _flags := {}


## Every mission of every track (translations, weapon hints).
static func all() -> Array:
	return LIST + PROD + INTERMEDIATE + ADVANCED


## The track that applies now: production clusters only get the read-only one.
func track() -> String:
	if K8s.is_prod():
		return "prod"
	return Settings.mission_level if Settings.mission_level in LEVELS else "basic"


func list() -> Array:
	match track():
		"prod": return PROD
		"intermediate": return INTERMEDIATE
		"advanced": return ADVANCED
	return LIST


func set_level(level: String) -> void:
	if level == Settings.mission_level or not level in LEVELS:
		return
	Settings.mission_level = level
	_flags.clear()
	Settings.save()
	progress_changed.emit()


## Called when the cluster kind is set or changes (prod <-> sandbox).
func kind_changed() -> void:
	_flags.clear()
	progress_changed.emit()


func current() -> Dictionary:
	var l := list()
	var i := index()
	return l[i] if i < l.size() else {}


func index() -> int:
	return int(Settings.mission_progress.get(track(), 0))


func all_done() -> bool:
	return index() >= list().size()


func skip() -> void:
	_advance()


## Restarts the current track only.
func restart() -> void:
	for m in list():
		Settings.missions_done.erase(m.id)
	Settings.mission_progress[track()] = 0
	_flags.clear()
	Settings.save()
	progress_changed.emit()


func _advance() -> void:
	var m := current()
	if m.is_empty():
		return
	if not m.id in Settings.missions_done:
		Settings.missions_done.append(m.id)
	Settings.mission_progress[track()] = index() + 1
	_flags.clear()
	Settings.save()
	completed.emit(m)
	progress_changed.emit()


## Called for everything interesting that happens:
##   level(level), inspect(kind, data), logs(data, previous),
##   action(req, ok), state(state), stats, watch, kubi, chaos,
##   kubectl(line, ok), manifest({kind, ns, name}, ok)
func notify(ev: String, a = null, b = null) -> void:
	var m := current()
	if m.is_empty():
		return
	if _check(m.id, ev, a, b):
		_advance()


func _academy_workloads(s: Dictionary) -> Array:
	return s.get("workloads", []).filter(func(w): return w.ns == NS)


func _check(id: String, ev: String, a, b) -> bool:
	var s: Dictionary = K8s.state
	match id:
		"nave":
			return ev == "level" and str(a).begins_with("ns:")
		"robot":
			return ev == "inspect" and a == "pod"
		"energia":
			return ev == "inspect" and a == "node"
		"linea":
			return not _academy_workloads(s).is_empty()
		"autorreparacion":
			if ev == "action" and b and a.action == "delete_pod" and a.ns == NS:
				_flags["deleted"] = a.name
			if _flags.has("deleted") and ev == "state":
				var names: Array = s.pods.filter(func(p): return p.ns == NS).map(func(p): return p.name)
				var healed := _academy_workloads(s).any(func(w): return int(w.ready) >= int(w.desired) and int(w.desired) > 0)
				return not _flags.deleted in names and healed
		"escala":
			return _academy_workloads(s).any(func(w): return int(w.desired) >= 4 and int(w.ready) >= 4)
		"trafico":
			return ev == "inspect" and a == "service"
		"averia":
			return ev == "logs" and PodBot.categorize(a) in ["crash", "pull", "failed"]
		"rollout":
			return ev == "action" and b and a.action == "restart" and a.ns == NS
		"mantenimiento":
			if ev == "action" and b and a.action == "cordon":
				_flags["cordoned"] = a.name
			return ev == "action" and b and a.action == "uncordon" and _flags.has("cordoned")
		"limpieza":
			if ev == "state" and not _academy_workloads(s).is_empty():
				_flags["had"] = true
			return (ev == "action" and b and a.action == "delete_workload" and a.ns == NS) or \
				(ev == "state" and _flags.get("had", false) and _academy_workloads(s).is_empty())

		# ---- production (read-only)
		"p_census":
			return ev == "stats"
		"p_nodes":
			return ev == "inspect" and a == "node"
		"p_bottleneck":
			return ev == "inspect" and a == "node" and str(b.get("name", "")) == _fullest_node(s)
		"p_pending":
			var pending: Array = s.get("pods", []).filter(func(p): return p.get("phase", "") == "Pending" and not p.get("deleting", false))
			return (ev == "state" and pending.is_empty()) or \
				(ev == "inspect" and a == "pod" and b.get("phase", "") == "Pending")
		"p_restarts":
			var top := _most_restarts(s)
			if ev == "state" and top.is_empty():
				return true
			return ev == "logs" and b == true and not top.is_empty() and a.get("name", "") == top.name and a.get("ns", "") == top.ns
		"p_incident":
			return ev == "kubi" and _broken_pods(s) > 0
		"p_hotspots":
			var line := str(a).strip_edges().trim_prefix("kubectl ").strip_edges()
			return ev == "kubectl" and (line.begins_with("top ") or line.begins_with("get events") or line.begins_with("events"))
		"p_front":
			return ev == "inspect" and a == "gate"
		"p_watch":
			return ev == "watch"

		# ---- sandbox, intermediate: fix the sample scenario
		"i_image":
			return _fixed(s, ev, "pull")
		"i_room":
			return _fixed(s, ev, "unschedulable")
		"i_crash":
			return ev == "logs" and b == true and PodBot.categorize(a) == "crash"
		"i_endpoints":
			return ev == "inspect" and a == "service" and int(b.get("ready", 0)) == 0
		"i_route":
			return ev == "inspect" and a == "gate"

		# ---- sandbox, advanced: break and recover
		"a_chaos":
			if ev == "action" and b and a.action == "delete_pod":
				var owner := _owner_of(s, a.get("ns", ""), a.get("name", ""))
				if not owner.is_empty():
					_flags["shot"] = owner
			if _flags.has("shot") and ev == "state":
				var w := _workload(s, _flags.shot)
				return not w.is_empty() and int(w.desired) > 0 and int(w.ready) >= int(w.desired)
		"a_drain":
			if ev == "action" and b and a.action == "cordon":
				_flags["cordoned"] = a.name
			if ev == "action" and b and a.action == "delete_pod" and _flags.has("cordoned"):
				for p in s.get("pods", []):
					if p.name == a.get("name", "") and p.get("node", "") == _flags.cordoned:
						_flags["evicted"] = true
			return ev == "action" and b and a.action == "uncordon" and _flags.has("evicted")
		"a_zero":
			if ev == "state" and not _flags.has("zero"):
				for w in s.get("workloads", []):
					if w.kind != "DaemonSet" and int(w.desired) == 0:
						_flags["zero"] = "%s/%s/%s" % [w.ns, w.kind, w.name]
			if _flags.has("zero") and ev == "state":
				var w := _workload(s, _flags.zero)
				return not w.is_empty() and int(w.desired) >= 1 and int(w.ready) >= 1
		"a_badimage":
			if ev == "manifest" and b and a.get("kind", "") == "Deployment":
				_flags["edited"] = "%s/Deployment/%s" % [a.ns, a.name]
			if _flags.has("edited") and ev == "state":
				var key: String = _flags.edited
				var broken: bool = s.get("pods", []).any(func(p): return PodBot.categorize(p) == "pull" and _pod_workload_key(s, p) == key)
				if broken:
					_flags["broke"] = true
				var w := _workload(s, key)
				return _flags.has("broke") and not broken and not w.is_empty() and int(w.ready) >= int(w.desired) and int(w.desired) > 0
		"a_rebuild":
			if ev == "action" and b and a.action == "delete_workload":
				_flags["nuked_ns"] = a.get("ns", "")
			return ev == "action" and b and a.action == "create_deployment" and _flags.has("nuked_ns") and a.get("ns", "") == _flags.nuked_ns
	return false


## Node with the highest share of its CPU reserved by pod requests.
func _fullest_node(s: Dictionary) -> String:
	var req := {}
	for p in s.get("pods", []):
		if p.get("node", "") != "" and PodBot.categorize(p) != "done":
			req[p.node] = int(req.get(p.node, 0)) + int(p.get("cpu_req_m", 0))
	var best := ""
	var best_r := -1.0
	for n in s.get("nodes", []):
		var r := float(req.get(n.name, 0)) / maxf(1.0, float(n.get("cpu_m", 0)))
		if r > best_r:
			best_r = r
			best = n.name
	return best


func _most_restarts(s: Dictionary) -> Dictionary:
	var top := {}
	for p in s.get("pods", []):
		if int(p.get("restarts", 0)) > int(top.get("restarts", 0)):
			top = p
	return top


func _broken_pods(s: Dictionary) -> int:
	return s.get("pods", []).filter(func(p): return PodBot.categorize(p) in ["crash", "pull", "failed"]).size()


func _workload(s: Dictionary, key: String) -> Dictionary:
	for w in s.get("workloads", []):
		if "%s/%s/%s" % [w.ns, w.kind, w.name] == key:
			return w
	return {}


## "ns/Kind/name" of the workload that owns a pod (through its ReplicaSet).
func _pod_workload_key(s: Dictionary, p: Dictionary) -> String:
	var kind: String = p.get("owner_kind", "")
	var owner: String = p.get("owner_name", "")
	if kind == "ReplicaSet":
		for w in s.get("workloads", []):
			if w.ns == p.ns and w.kind == "Deployment" and owner.begins_with(w.name + "-"):
				return "%s/Deployment/%s" % [w.ns, w.name]
		return ""
	return "%s/%s/%s" % [p.ns, kind, owner]


func _owner_of(s: Dictionary, ns: String, pod: String) -> String:
	for p in s.get("pods", []):
		if p.ns == ns and p.name == pod:
			var key := _pod_workload_key(s, p)
			return key if not _workload(s, key).is_empty() else ""
	return ""


## Fix-it missions: remember the first workload broken that way, done when it
## is healthy again. how = "pull" (image) | "unschedulable" (no room).
func _fixed(s: Dictionary, ev: String, how: String) -> bool:
	if ev != "state":
		return false
	if not _flags.has("target"):
		for p in s.get("pods", []):
			var hit: bool = PodBot.categorize(p) == "pull" if how == "pull" else \
				(p.get("phase", "") == "Pending" and str(p.get("message", "")).contains("Insufficient"))
			if hit:
				var key := _pod_workload_key(s, p)
				if not _workload(s, key).is_empty():
					_flags["target"] = key
					break
		return false
	var w := _workload(s, _flags.target)
	return not w.is_empty() and int(w.desired) > 0 and int(w.ready) >= int(w.desired)


## What the current fix-it mission is about, for the panel ("ns/Kind/name").
func target() -> String:
	return str(_flags.get("target", ""))
