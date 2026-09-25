class_name ManifestHelp
## Explains Kubernetes YAML line by line for the in-game editor: works out
## the path of every line (spec.template.spec.containers[].image) and looks
## up what that field does, plus warnings about risky values.
## Lookups go from the most specific path suffix to the bare key.

# path suffix -> [english, spanish]
const DOCS := {
	"apiVersion": ["API group and version of this object type", "grupo y versión de la API de este tipo de objeto"],
	"kind": ["type of object (Deployment, Service, Pod...)", "tipo de objeto (Deployment, Service, Pod...)"],
	"metadata": ["identity: name, namespace, labels, annotations", "identidad: nombre, namespace, etiquetas, anotaciones"],
	"metadata.name": ["unique name inside its namespace", "nombre único dentro de su namespace"],
	"metadata.namespace": ["namespace (the hall of the factory) it lives in", "namespace (la nave de la fábrica) donde vive"],
	"labels": ["key=value tags; selectors find objects by them", "etiquetas clave=valor; los selectores encuentran objetos con ellas"],
	"annotations": ["free notes for tools; don't affect scheduling", "notas libres para herramientas; no afectan al scheduling"],
	"uid": ["id given by the API server (read-only)", "id asignado por el API server (solo lectura)"],
	"resourceVersion": ["version for safe concurrent edits: don't touch", "versión para ediciones concurrentes seguras: no tocar"],
	"generation": ["counts spec changes (read-only)", "cuenta los cambios de spec (solo lectura)"],
	"creationTimestamp": ["when it was created (read-only)", "cuándo se creó (solo lectura)"],
	"ownerReferences": ["who owns it: deleted together with the owner", "quién es su dueño: se borra junto con él"],
	"finalizers": ["must be cleared before the object is really deleted", "deben limpiarse antes de que el objeto se borre de verdad"],
	"spec": ["DESIRED state: what you want Kubernetes to make true", "estado DESEADO: lo que quieres que Kubernetes haga realidad"],
	"spec.replicas": ["how many identical pods (robots) to keep running", "cuántos pods (robots) idénticos mantener corriendo"],
	"selector": ["which pods belong to it, by labels", "qué pods le pertenecen, por etiquetas"],
	"matchLabels": ["pods must have ALL these labels", "los pods deben tener TODAS estas etiquetas"],
	"template": ["mold for the pods it creates: change it = rollout", "molde de los pods que crea: cambiarlo = nuevo rollout"],
	"template.metadata.labels": ["labels of each new pod: must match the selector", "etiquetas de cada pod nuevo: deben encajar con el selector"],
	"strategy": ["how to replace old pods with new ones", "cómo se reemplazan los pods viejos por nuevos"],
	"rollingUpdate": ["replace pods little by little, no downtime", "reemplaza pods poco a poco, sin cortes"],
	"maxSurge": ["extra pods allowed during a rollout", "pods extra permitidos durante un rollout"],
	"maxUnavailable": ["pods that may be down during a rollout", "pods que pueden faltar durante un rollout"],
	"revisionHistoryLimit": ["old ReplicaSets kept for rollback", "ReplicaSets viejos guardados para rollback"],
	"progressDeadlineSeconds": ["time before a stuck rollout is reported", "tiempo antes de marcar un rollout atascado"],
	"serviceName": ["headless Service that gives each pod a stable DNS name", "Service headless que da a cada pod un nombre DNS estable"],
	"volumeClaimTemplates": ["one persistent disk per pod, created automatically", "un disco persistente por pod, creado automáticamente"],
	"containers": ["the programs that run inside each pod", "los programas que corren dentro de cada pod"],
	"initContainers": ["run to completion BEFORE the main containers", "corren hasta terminar ANTES de los contenedores principales"],
	"containers[].name": ["container name (used by logs -c)", "nombre del contenedor (se usa con logs -c)"],
	"image": ["container image to download and run", "imagen de contenedor que se descarga y ejecuta"],
	"imagePullPolicy": ["when to download the image again", "cuándo volver a descargar la imagen"],
	"imagePullSecrets": ["credentials for private registries", "credenciales para registries privados"],
	"command": ["replaces the image ENTRYPOINT", "reemplaza el ENTRYPOINT de la imagen"],
	"args": ["arguments for the command (image CMD)", "argumentos del comando (CMD de la imagen)"],
	"workingDir": ["directory the process starts in", "directorio donde arranca el proceso"],
	"env": ["environment variables for the process", "variables de entorno para el proceso"],
	"env[].name": ["variable name", "nombre de la variable"],
	"env[].value": ["variable value (plain text: never put secrets here)", "valor de la variable (texto plano: nunca pongas secretos aquí)"],
	"valueFrom": ["take the value from a Secret, ConfigMap or field", "toma el valor de un Secret, ConfigMap o campo"],
	"secretKeyRef": ["value read from a Secret key", "valor leído de una clave de un Secret"],
	"configMapKeyRef": ["value read from a ConfigMap key", "valor leído de una clave de un ConfigMap"],
	"envFrom": ["load ALL keys of a ConfigMap/Secret as variables", "carga TODAS las claves de un ConfigMap/Secret como variables"],
	"ports": ["network ports", "puertos de red"],
	"containerPort": ["port the app listens on inside the pod", "puerto en el que escucha la app dentro del pod"],
	"protocol": ["TCP, UDP or SCTP", "TCP, UDP o SCTP"],
	"resources": ["CPU / memory the container asks for and may use", "CPU / memoria que el contenedor pide y puede usar"],
	"requests": ["RESERVED on the node: the scheduler uses this to place the pod", "RESERVADO en el nodo: el scheduler lo usa para colocar el pod"],
	"limits": ["hard ceiling: over memory = OOMKilled, over CPU = throttled", "techo duro: pasarse de memoria = OOMKilled, de CPU = frenado"],
	"requests.cpu": ["CPU reserved (1000m = 1 core)", "CPU reservada (1000m = 1 núcleo)"],
	"requests.memory": ["memory reserved (Mi = mebibytes)", "memoria reservada (Mi = mebibytes)"],
	"limits.cpu": ["max CPU; above it the process is slowed down", "CPU máxima; por encima el proceso se frena"],
	"limits.memory": ["max memory; above it the container is killed (OOMKilled)", "memoria máxima; por encima se mata el contenedor (OOMKilled)"],
	"livenessProbe": ["health check: fails => container restarted", "chequeo de vida: si falla => se reinicia el contenedor"],
	"readinessProbe": ["ready check: fails => no traffic from Services", "chequeo de listo: si falla => los Services no le mandan tráfico"],
	"startupProbe": ["gives slow apps time to start before other probes", "da tiempo a apps lentas antes de las otras probes"],
	"httpGet": ["probe by calling an HTTP path", "probe llamando a una ruta HTTP"],
	"tcpSocket": ["probe by opening a TCP connection", "probe abriendo una conexión TCP"],
	"exec": ["probe by running a command in the container", "probe ejecutando un comando en el contenedor"],
	"path": ["HTTP path or file path", "ruta HTTP o de archivo"],
	"port": ["port number or name", "número o nombre de puerto"],
	"initialDelaySeconds": ["wait before the first check", "espera antes del primer chequeo"],
	"periodSeconds": ["seconds between checks", "segundos entre chequeos"],
	"timeoutSeconds": ["how long a check may take", "cuánto puede tardar un chequeo"],
	"failureThreshold": ["failed checks in a row before acting", "chequeos fallidos seguidos antes de actuar"],
	"successThreshold": ["good checks needed to be OK again", "chequeos buenos para volver a estar OK"],
	"volumeMounts": ["where volumes appear inside the container", "dónde aparecen los volúmenes dentro del contenedor"],
	"mountPath": ["folder inside the container", "carpeta dentro del contenedor"],
	"readOnly": ["mounted read-only", "montado en solo lectura"],
	"volumes": ["storage the pod can mount (disks, ConfigMaps, Secrets...)", "almacenamiento que el pod puede montar (discos, ConfigMaps, Secrets...)"],
	"emptyDir": ["scratch folder, deleted with the pod", "carpeta temporal, se borra con el pod"],
	"persistentVolumeClaim": ["a persistent disk that survives the pod", "un disco persistente que sobrevive al pod"],
	"configMap": ["files from a ConfigMap", "archivos desde un ConfigMap"],
	"secret": ["files from a Secret", "archivos desde un Secret"],
	"securityContext": ["privileges: user, capabilities, read-only filesystem", "privilegios: usuario, capabilities, filesystem de solo lectura"],
	"runAsNonRoot": ["refuse to run as root (safer)", "no permite correr como root (más seguro)"],
	"runAsUser": ["numeric user id of the process", "id numérico de usuario del proceso"],
	"privileged": ["full access to the node: dangerous", "acceso total al nodo: peligroso"],
	"allowPrivilegeEscalation": ["can the process gain more privileges", "si el proceso puede ganar más privilegios"],
	"readOnlyRootFilesystem": ["the container can't write its own files", "el contenedor no puede escribir sus propios archivos"],
	"nodeSelector": ["only nodes with these labels may run it", "solo nodos con estas etiquetas pueden ejecutarlo"],
	"nodeName": ["forced onto this node (skips the scheduler)", "forzado a este nodo (se salta el scheduler)"],
	"affinity": ["soft/hard rules about where to place pods", "reglas blandas/duras de dónde colocar los pods"],
	"tolerations": ["lets it run on nodes with matching taints", "le permite correr en nodos con taints que encajen"],
	"tolerations[].key": ["taint key it tolerates", "clave del taint que tolera"],
	"tolerations[].effect": ["NoSchedule / PreferNoSchedule / NoExecute", "NoSchedule / PreferNoSchedule / NoExecute"],
	"tolerations[].operator": ["Equal (key+value) or Exists (any value)", "Equal (clave+valor) o Exists (cualquier valor)"],
	"topologySpreadConstraints": ["spread replicas across nodes/zones", "reparte réplicas entre nodos/zonas"],
	"maxSkew": ["max difference of pods between nodes", "diferencia máxima de pods entre nodos"],
	"topologyKey": ["node label that defines the groups (e.g. hostname)", "etiqueta de nodo que define los grupos (p. ej. hostname)"],
	"restartPolicy": ["Always / OnFailure / Never", "Always / OnFailure / Never"],
	"serviceAccountName": ["identity the pod uses to talk to the API", "identidad con la que el pod habla con la API"],
	"terminationGracePeriodSeconds": ["time to shut down cleanly before being killed", "tiempo para apagarse limpio antes de ser matado"],
	"dnsPolicy": ["how the pod resolves names", "cómo resuelve nombres el pod"],
	"schedulerName": ["which scheduler places it", "qué scheduler lo coloca"],
	"priorityClassName": ["priority: may evict less important pods", "prioridad: puede desalojar pods menos importantes"],
	"hostNetwork": ["uses the node's network directly", "usa directamente la red del nodo"],
	# Service
	"spec.type": ["ClusterIP (inside), NodePort (node port), LoadBalancer (outside)", "ClusterIP (dentro), NodePort (puerto del nodo), LoadBalancer (fuera)"],
	"clusterIP": ["virtual IP inside the cluster (None = headless)", "IP virtual dentro del cluster (None = headless)"],
	"clusterIPs": ["virtual IPs (IPv4/IPv6)", "IPs virtuales (IPv4/IPv6)"],
	"spec.selector": ["picks pods by labels (a Service sends them traffic, a Deployment owns them)", "elige pods por etiquetas (un Service les manda tráfico, un Deployment los controla)"],
	"template.spec": ["the pod definition: containers, volumes, placement", "la definición del pod: contenedores, volúmenes, ubicación"],
	"ports[].port": ["port the Service exposes", "puerto que expone el Service"],
	"targetPort": ["port on the pod that receives the traffic", "puerto del pod que recibe el tráfico"],
	"nodePort": ["port opened on every node (30000-32767)", "puerto abierto en cada nodo (30000-32767)"],
	"sessionAffinity": ["ClientIP = same client, same pod", "ClientIP = mismo cliente, mismo pod"],
	"externalTrafficPolicy": ["Local keeps the client IP but only uses local pods", "Local conserva la IP del cliente pero solo usa pods locales"],
	"internalTrafficPolicy": ["Local = only pods on the same node", "Local = solo pods del mismo nodo"],
	"ipFamilies": ["IPv4 / IPv6", "IPv4 / IPv6"],
	"ipFamilyPolicy": ["single or dual stack", "stack simple o dual"],
	# ConfigMap / Job / CronJob / Node
	"data": ["configuration keys and values (plain text)", "claves y valores de configuración (texto plano)"],
	"schedule": ["cron: minute hour day month weekday", "cron: minuto hora día mes día-semana"],
	"completions": ["successful runs needed", "ejecuciones exitosas necesarias"],
	"parallelism": ["pods running at the same time", "pods corriendo a la vez"],
	"backoffLimit": ["retries before the Job is Failed", "reintentos antes de marcar el Job como Failed"],
	"successfulJobsHistoryLimit": ["finished Jobs kept", "Jobs terminados que se guardan"],
	"failedJobsHistoryLimit": ["failed Jobs kept", "Jobs fallidos que se guardan"],
	"concurrencyPolicy": ["Allow / Forbid / Replace overlapping runs", "Allow / Forbid / Replace ejecuciones solapadas"],
	"suspend": ["true = paused", "true = en pausa"],
	"jobTemplate": ["mold for each Job it creates", "molde de cada Job que crea"],
	"unschedulable": ["true = cordoned: no new pods", "true = acordonado: no recibe pods nuevos"],
	"taints": ["repel pods that don't tolerate them", "repelen a los pods que no los toleran"],
	"podCIDR": ["IP range for pods on this node", "rango de IPs para los pods de este nodo"],
	"providerID": ["id of the machine in the cloud provider", "id de la máquina en el proveedor cloud"],
}


static func _es() -> bool:
	return TranslationServer.get_locale().begins_with("es")


## Per line: {path, key, value, text, warn} (text "" if unknown / blank).
static func annotate(yaml: String) -> Array:
	var out := []
	var stack := []   # [{indent, key, list}]
	for raw in yaml.split("\n"):
		var line: String = raw
		var info := {"path": "", "key": "", "value": "", "text": "", "warn": ""}
		var stripped := line.strip_edges()
		if stripped == "" or stripped.begins_with("#"):
			out.append(info)
			continue
		var indent := line.length() - line.lstrip(" ").length()
		var body := stripped
		if body.begins_with("- ") or body == "-":
			# List item: belongs to the key at this indent (or above).
			while not stack.is_empty() and (stack[-1].indent > indent or (stack[-1].indent == indent and stack[-1].list)):
				stack.pop_back()
			stack.append({"indent": indent, "key": "[]", "list": true})
			body = body.substr(2).strip_edges()
			indent += 2
			if not body.contains(": ") and not body.ends_with(":"):
				info.path = _path(stack)
				info.value = body
				info.key = "[]"
				_explain(info)
				out.append(info)
				continue
		var colon := body.find(":")
		if colon <= 0:
			out.append(info)
			continue
		var key := body.substr(0, colon).strip_edges().trim_prefix("\"").trim_suffix("\"")
		var value := body.substr(colon + 1).strip_edges()
		while not stack.is_empty() and stack[-1].indent >= indent and not (stack[-1].list and stack[-1].indent < indent):
			stack.pop_back()
		var parent := _path(stack)
		info.key = key
		info.value = value
		info.path = (parent + "." + key) if parent != "" else key
		info.path = info.path.replace(".[]", "[]")
		if value == "" or value == "|" or value == ">" or value == "|-":
			stack.append({"indent": indent, "key": key, "list": false})
		_explain(info)
		out.append(info)
	return out


static func _path(stack: Array) -> String:
	var parts := []
	for s in stack:
		parts.append(s.key)
	return ".".join(parts).replace(".[]", "[]")


static func _explain(info: Dictionary) -> void:
	# "spec.template.spec.containers[].image" -> try "...containers[].image",
	# "containers[].image", "image" (and each without the [] markers).
	var segs: PackedStringArray = str(info.path).split(".", false)
	for i in segs.size():
		var suffix := ".".join(segs.slice(i))
		for c in [suffix, suffix.replace("[]", "")]:
			if DOCS.has(c):
				info.text = DOCS[c][1 if _es() else 0]
				info.warn = _warn(info)
				return
	if info.key == "[]":
		info.text = "list item" if not _es() else "elemento de la lista"
	elif segs.size() >= 2:
		# Entries of maps: labels, selectors, config data...
		var parent: String = segs[segs.size() - 2]
		var what := {"labels": ["label", "etiqueta"], "matchLabels": ["required label", "etiqueta requerida"],
			"annotations": ["annotation", "anotación"], "nodeSelector": ["required node label", "etiqueta de nodo requerida"],
			"data": ["config key", "clave de configuración"], "selector": ["selected label", "etiqueta seleccionada"]}
		if what.has(parent):
			info.text = "%s %s = %s" % [what[parent][1 if _es() else 0], info.key, info.value]
	info.warn = _warn(info)


static func _warn(info: Dictionary) -> String:
	var k: String = info.key
	var v: String = str(info.value).trim_prefix("\"").trim_suffix("\"")
	var es := _es()
	if k == "image" and v != "":
		if v.ends_with(":latest") or not v.get_slice("/", v.get_slice_count("/") - 1).contains(":"):
			return "'latest' / no tag: you don't know which version runs" if not es else "'latest' / sin tag: no sabes qué versión corre"
	if k == "replicas" and v == "0":
		return "0 replicas: nothing runs" if not es else "0 réplicas: no corre nada"
	if k == "replicas" and v == "1":
		return "a single replica: no high availability" if not es else "una sola réplica: sin alta disponibilidad"
	if k == "privileged" and v == "true":
		return "privileged container: full control of the node" if not es else "contenedor privilegiado: control total del nodo"
	if k == "hostNetwork" and v == "true":
		return "shares the node network" if not es else "comparte la red del nodo"
	if k == "value" and info.path.contains("env") and (info.path.to_lower().contains("password") or v.length() > 20 and v.to_lower().contains("secret")):
		return "looks like a secret in plain text: use a Secret" if not es else "parece un secreto en texto plano: usa un Secret"
	if k == "memory" and info.path.contains("limits") and v.ends_with("Mi") and int(v.trim_suffix("Mi")) < 32:
		return "very low memory limit: risk of OOMKilled" if not es else "límite de memoria muy bajo: riesgo de OOMKilled"
	if k == "cpu" and info.path.contains("requests"):
		var m := float(v.trim_suffix("m")) if v.ends_with("m") else float(v) * 1000.0
		if m > 8000:
			return "huge CPU request: may never fit on a node" if not es else "request de CPU enorme: puede no caber en ningún nodo"
	return ""


## The line that best matches a focus key ("image", "resources"...), or -1.
static func find_line(yaml: String, key: String) -> int:
	var lines := yaml.split("\n")
	for i in lines.size():
		var s := lines[i].strip_edges().trim_prefix("- ")
		if s.begins_with(key + ":"):
			return i
	return -1
