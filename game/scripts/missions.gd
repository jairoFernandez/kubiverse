class_name Missions
extends Node
## Guided missions that teach Kubernetes by doing. Progress is checked
## against the live cluster state and what the player does in the game.
## Exercises that change things happen in their own namespace ("academia")
## so a real cluster's apps are never touched.

signal progress_changed
signal completed(m: Dictionary)

const NS := "academia"

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

var _flags := {}


func current() -> Dictionary:
	var i := Settings.mission_idx
	return LIST[i] if i < LIST.size() else {}


func index() -> int:
	return Settings.mission_idx


func all_done() -> bool:
	return Settings.mission_idx >= LIST.size()


func skip() -> void:
	_advance()


func restart() -> void:
	Settings.mission_idx = 0
	Settings.missions_done = []
	_flags.clear()
	Settings.save()
	progress_changed.emit()


func _advance() -> void:
	var m := current()
	if m.is_empty():
		return
	if not m.id in Settings.missions_done:
		Settings.missions_done.append(m.id)
	Settings.mission_idx += 1
	_flags.clear()
	Settings.save()
	completed.emit(m)
	progress_changed.emit()


## Called for everything interesting that happens:
##   level(level), inspect(kind, data), logs(data, previous),
##   action(req, ok), state(state)
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
	return false
