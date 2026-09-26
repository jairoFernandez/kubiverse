class_name EngineLessons
## The ENGINE ROOM's course: from zero to expert on how Kubernetes works
## inside. Each lesson is a list of steps; each step moves a work order
## between the machines (api, etcd, controllers, scheduler, kubelet, dns,
## proxy, cni, you) and explains what just happened. A quiz closes it.
## Texts are [english, español]: the course is long, so it carries both.

const LEVELS := [["BEGINNER", "PRINCIPIANTE"], ["INTERMEDIATE", "INTERMEDIO"], ["ADVANCED", "AVANZADO"], ["EXPERT", "EXPERTO"]]

## {id, level, title, steps: [{flow, tag, col, text}], quiz: {q, options, answer, why}, live}
## flow: machine keys; "kubelet" is any node's kubelet.
const LESSONS := [
	# ------------------------------------------------------------ beginner
	{"id": "machines", "level": 0, "title": ["The machines of the control plane", "Las máquinas del control plane"], "steps": [
		{"flow": ["you", "api"], "tag": "kubectl", "col": "green", "text": [
			"Everything starts with you (kubectl, Helm, Argo CD, a CI). You never start containers yourself: you tell the API server what you WANT.",
			"Todo empieza contigo (kubectl, Helm, Argo CD, un CI). Tú nunca arrancas contenedores: le dices al API server lo que QUIERES."]},
		{"flow": ["api", "etcd"], "tag": "store", "col": "orange", "text": [
			"The API server is the only door. It stores the desired state in etcd, a small consistent database. If etcd is lost, the cluster forgets everything.",
			"El API server es la única puerta. Guarda el estado deseado en etcd, una pequeña base de datos consistente. Si se pierde etcd, el cluster lo olvida todo."]},
		{"flow": ["controllers", "api"], "tag": "watch", "col": "orange", "text": [
			"Controllers WATCH the API server and compare desired vs actual state. When they differ, they act. That loop never stops.",
			"Los controladores OBSERVAN el API server y comparan estado deseado y real. Si difieren, actúan. Ese bucle nunca para."]},
		{"flow": ["scheduler", "api"], "tag": "bind", "col": "yellow", "text": [
			"The scheduler only decides WHERE: it picks a node for each new pod and writes that choice. It starts nothing.",
			"El scheduler solo decide DÓNDE: elige un nodo para cada pod nuevo y escribe esa decisión. No arranca nada."]},
		{"flow": ["api", "kubelet"], "tag": "run", "col": "green", "text": [
			"The kubelet on each node watches for pods assigned to it and asks the container runtime to run them. Then it reports back.",
			"El kubelet de cada nodo vigila los pods asignados a él y le pide al runtime de contenedores que los ejecute. Luego informa."]},
		{"flow": ["dns", "proxy", "cni"], "tag": "network", "col": "blue", "text": [
			"On every node: kube-proxy turns Services into network rules, the CNI gives each pod an IP, and CoreDNS answers names like my-svc.my-ns.svc.",
			"En cada nodo: kube-proxy convierte los Services en reglas de red, el CNI da una IP a cada pod y CoreDNS resuelve nombres como mi-svc.mi-ns.svc."]},
	], "quiz": {"q": ["Which component talks to etcd?", "¿Qué componente habla con etcd?"], "options": [["Only the API server", "Solo el API server"], ["Every kubelet", "Todos los kubelets"], ["The scheduler", "El scheduler"]], "answer": 0,
		"why": ["Everything else goes through the API server's REST API.", "Todo lo demás pasa por la API REST del API server."]}},

	{"id": "pod-life", "level": 0, "live": true, "title": ["The life of a pod", "La vida de un pod"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "create deployment", "col": "green", "reason": "you", "text": [
			"You ask for a Deployment. The API server checks who you are (authentication), whether you may (RBAC) and validates it, then stores it in etcd.",
			"Pides un Deployment. El API server comprueba quién eres (autenticación), si puedes (RBAC) y lo valida; luego lo guarda en etcd."]},
		{"flow": ["controllers", "api", "etcd"], "tag": "ReplicaSet", "col": "orange", "reason": "ScalingReplicaSet", "text": [
			"The Deployment controller sees it and creates a ReplicaSet for it, through the API server.",
			"El controlador de Deployments lo ve y crea un ReplicaSet para él, a través del API server."]},
		{"flow": ["controllers", "api", "etcd"], "tag": "create pod", "col": "orange", "reason": "SuccessfulCreate", "text": [
			"The ReplicaSet controller sees 0 of 1 pods and creates a Pod object. It has no node yet: it is Pending.",
			"El controlador de ReplicaSets ve 0 de 1 pods y crea un objeto Pod. Aún no tiene nodo: está Pending."]},
		{"flow": ["scheduler", "api", "etcd", "kubelet"], "tag": "bind -> node", "col": "yellow", "reason": "Scheduled", "text": [
			"The scheduler sees a pod without a node, filters and scores the nodes (free CPU and memory, taints, affinity) and binds it to one.",
			"El scheduler ve un pod sin nodo, filtra y puntúa los nodos (CPU y memoria libres, taints, afinidad) y lo asigna a uno."]},
		{"flow": ["kubelet"], "tag": "pull image", "col": "blue", "reason": "Pulling", "text": [
			"The kubelet on that node sees a pod assigned to it and asks the container runtime to pull the image.",
			"El kubelet de ese nodo ve un pod asignado y le pide al runtime que descargue la imagen."]},
		{"flow": ["kubelet", "api", "etcd"], "tag": "Running", "col": "green", "reason": "Started", "text": [
			"The runtime starts the container; the kubelet reports Running and Ready to the API server. Done: desired = actual.",
			"El runtime arranca el contenedor; el kubelet informa Running y Ready al API server. Listo: deseado = real."]},
	], "quiz": {"q": ["Who picks the node a pod runs on?", "¿Quién elige el nodo donde corre un pod?"], "options": [["The kubelet", "El kubelet"], ["The scheduler", "El scheduler"], ["The Deployment controller", "El controlador de Deployments"]], "answer": 1,
		"why": ["The scheduler writes the binding; the kubelet of that node then runs it.", "El scheduler escribe la asignación; después el kubelet de ese nodo lo ejecuta."]}},

	{"id": "self-heal", "level": 0, "title": ["Self-healing: why a deleted pod comes back", "Autorreparación: por qué vuelve un pod borrado"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "delete pod", "col": "red", "text": [
			"You delete a pod. The API server marks it for deletion; the kubelet stops its containers (SIGTERM, then SIGKILL after the grace period).",
			"Borras un pod. El API server lo marca para borrar; el kubelet detiene sus contenedores (SIGTERM y, pasado el periodo de gracia, SIGKILL)."]},
		{"flow": ["api", "controllers"], "tag": "1 of 2", "col": "orange", "text": [
			"The ReplicaSet controller notices: 1 pod exists, 2 are wanted. The desired state didn't change: only the actual one did.",
			"El controlador de ReplicaSets lo nota: existe 1 pod y se quieren 2. El estado deseado no cambió: solo el real."]},
		{"flow": ["controllers", "api", "scheduler", "kubelet"], "tag": "new pod", "col": "green", "text": [
			"It creates a new pod (with a new name), the scheduler places it and a kubelet starts it. To really remove it, change the Deployment (scale it or delete it).",
			"Crea un pod nuevo (con otro nombre), el scheduler lo ubica y un kubelet lo arranca. Para quitarlo de verdad, cambia el Deployment (escálalo o bórralo)."]},
	], "quiz": {"q": ["You delete a pod of a 3-replica Deployment. What happens?", "Borras un pod de un Deployment de 3 réplicas. ¿Qué pasa?"], "options": [["It stays at 2", "Se queda en 2"], ["A new pod replaces it", "Un pod nuevo lo reemplaza"], ["The Deployment is deleted", "Se borra el Deployment"]], "answer": 1,
		"why": ["Controllers reconcile the actual state back to the desired one.", "Los controladores devuelven el estado real al deseado."]}},

	{"id": "scale", "level": 0, "title": ["Scaling", "Escalar"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "replicas: 5", "col": "green", "text": [
			"kubectl scale changes one number in the Deployment: spec.replicas. That's all you do.",
			"kubectl scale cambia un número del Deployment: spec.replicas. Es todo lo que haces."]},
		{"flow": ["controllers", "api"], "tag": "ReplicaSet 5", "col": "orange", "text": [
			"The Deployment controller passes it to its ReplicaSet; the ReplicaSet controller creates (or deletes) pods until there are exactly 5.",
			"El controlador del Deployment se lo pasa a su ReplicaSet; el del ReplicaSet crea (o borra) pods hasta que haya exactamente 5."]},
		{"flow": ["scheduler", "kubelet"], "tag": "place", "col": "yellow", "text": [
			"New pods go through the scheduler like any other. If no node has room they stay Pending: scaling pods doesn't add machines (the cluster autoscaler does).",
			"Los pods nuevos pasan por el scheduler como cualquiera. Si no hay nodo con espacio quedan Pending: escalar pods no añade máquinas (eso lo hace el cluster autoscaler)."]},
	], "quiz": {"q": ["You scale to 50 and 20 pods stay Pending. Why?", "Escalas a 50 y 20 pods quedan Pending. ¿Por qué?"], "options": [["The Deployment is broken", "El Deployment está roto"], ["No node has room for them", "Ningún nodo tiene espacio para ellos"], ["etcd is full", "etcd está lleno"]], "answer": 1,
		"why": ["The scheduler can't place a pod whose requests don't fit anywhere.", "El scheduler no puede ubicar un pod cuyos requests no caben en ningún sitio."]}},

	# -------------------------------------------------------- intermediate
	{"id": "rolling", "level": 1, "title": ["Rolling updates and rollbacks", "Actualizaciones graduales y rollbacks"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "new image", "col": "green", "text": [
			"You change the image. The pod template changed, so the Deployment controller creates a NEW ReplicaSet (a new revision) and keeps the old one.",
			"Cambias la imagen. La plantilla del pod cambió, así que el controlador crea un ReplicaSet NUEVO (una revisión nueva) y guarda el anterior."]},
		{"flow": ["controllers", "api", "scheduler", "kubelet"], "tag": "+1 new", "col": "orange", "text": [
			"It grows the new ReplicaSet and shrinks the old one step by step: maxSurge says how many extra pods may exist, maxUnavailable how many may be missing.",
			"Hace crecer el ReplicaSet nuevo y reduce el viejo paso a paso: maxSurge dice cuántos pods extra puede haber y maxUnavailable cuántos pueden faltar."]},
		{"flow": ["kubelet", "api", "controllers"], "tag": "Ready?", "col": "yellow", "text": [
			"It only continues when new pods are Ready (their readiness probe passes). A broken image never gets Ready: the rollout stops and the old pods keep serving.",
			"Solo sigue cuando los pods nuevos están Ready (pasa su readiness probe). Una imagen rota nunca llega a Ready: el rollout se detiene y los viejos siguen sirviendo."]},
		{"flow": ["you", "api", "controllers"], "tag": "rollout undo", "col": "red", "text": [
			"A rollback puts the old template back: the old ReplicaSet grows again. That's why you can undo in seconds (and why old ReplicaSets are kept).",
			"Un rollback vuelve a poner la plantilla anterior: el ReplicaSet viejo vuelve a crecer. Por eso puedes deshacer en segundos (y por eso se guardan los ReplicaSets viejos)."]},
	], "quiz": {"q": ["A new version never gets Ready. What serves traffic?", "Una versión nueva nunca llega a Ready. ¿Quién sirve el tráfico?"], "options": [["Nobody", "Nadie"], ["The old pods, the rollout is stuck", "Los pods viejos; el rollout se queda parado"], ["The new pods anyway", "Los nuevos igualmente"]], "answer": 1,
		"why": ["maxUnavailable keeps old pods until new ones are Ready.", "maxUnavailable mantiene los pods viejos hasta que los nuevos estén Ready."]}},

	{"id": "services", "level": 1, "title": ["Services, endpoints and DNS", "Services, endpoints y DNS"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "Service", "col": "green", "text": [
			"A Service is a stable name and IP in front of changing pods. Its selector (app=web) says which pods are behind it.",
			"Un Service es un nombre y una IP estables delante de pods que cambian. Su selector (app=web) dice qué pods hay detrás."]},
		{"flow": ["controllers", "api"], "tag": "EndpointSlice", "col": "orange", "text": [
			"The EndpointSlice controller keeps the list of READY pods that match: a pod failing its readiness probe drops out of the list.",
			"El controlador de EndpointSlices mantiene la lista de pods LISTOS que coinciden: un pod que falla su readiness probe sale de la lista."]},
		{"flow": ["api", "proxy"], "tag": "rules", "col": "blue", "text": [
			"kube-proxy on every node watches them and writes network rules: traffic to the Service IP goes to one of those pods.",
			"kube-proxy en cada nodo las observa y escribe reglas de red: el tráfico a la IP del Service va a uno de esos pods."]},
		{"flow": ["dns", "proxy", "cni"], "tag": "web.shop.svc", "col": "blue", "text": [
			"A pod asks CoreDNS for web.shop.svc.cluster.local, gets the Service IP, the rules pick a pod, and the CNI carries the packet there, even to another node.",
			"Un pod pregunta a CoreDNS por web.shop.svc.cluster.local, obtiene la IP del Service, las reglas eligen un pod y el CNI lleva el paquete allí, aunque sea otro nodo."]},
	], "quiz": {"q": ["A Service answers 'connection refused' and has 0 endpoints. Most likely?", "Un Service responde 'connection refused' y tiene 0 endpoints. ¿Lo más probable?"], "options": [["DNS is down", "El DNS está caído"], ["Its selector matches no Ready pod", "Su selector no coincide con ningún pod Ready"], ["kube-proxy is too slow", "kube-proxy es muy lento"]], "answer": 1,
		"why": ["No Ready pods behind the selector = nobody to send traffic to.", "Sin pods Ready detrás del selector no hay a quién enviar tráfico."]}},

	{"id": "config", "level": 1, "title": ["ConfigMaps and Secrets", "ConfigMaps y Secrets"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "Secret", "col": "green", "text": [
			"ConfigMaps and Secrets are stored in etcd like everything else. Secrets are base64, NOT encrypted, unless the cluster encrypts etcd at rest.",
			"ConfigMaps y Secrets se guardan en etcd como todo lo demás. Los Secrets van en base64, NO cifrados, salvo que el cluster cifre etcd en reposo."]},
		{"flow": ["api", "kubelet"], "tag": "mount", "col": "yellow", "text": [
			"When a pod uses one, the kubelet of its node reads it (only the ones its pods need) and gives it to the container as files or env variables.",
			"Cuando un pod usa uno, el kubelet de su nodo lo lee (solo los que necesitan sus pods) y se lo da al contenedor como archivos o variables de entorno."]},
		{"flow": ["you", "api", "kubelet"], "tag": "update", "col": "orange", "text": [
			"Change it: mounted files update in about a minute; env variables only on the next start. That's why a restart is usually needed after changing config.",
			"Si lo cambias, los archivos montados se actualizan en cerca de un minuto; las variables de entorno solo al siguiente arranque. Por eso suele hacer falta reiniciar tras cambiar configuración."]},
	], "quiz": {"q": ["You change a Secret used as env variables. When do pods see it?", "Cambias un Secret usado como variables de entorno. ¿Cuándo lo ven los pods?"], "options": [["Immediately", "Inmediatamente"], ["After about a minute", "Al cabo de un minuto"], ["When they restart", "Cuando reinician"]], "answer": 2,
		"why": ["Env variables are fixed when the container starts.", "Las variables de entorno se fijan al arrancar el contenedor."]}},

	{"id": "storage", "level": 1, "title": ["Persistent storage", "Almacenamiento persistente"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "PVC 10Gi", "col": "green", "text": [
			"A pod that needs to keep data asks for it with a PersistentVolumeClaim: a size, an access mode and a StorageClass.",
			"Un pod que necesita guardar datos los pide con un PersistentVolumeClaim: un tamaño, un modo de acceso y una StorageClass."]},
		{"flow": ["controllers", "api"], "tag": "provision", "col": "orange", "text": [
			"The StorageClass's provisioner (a CSI driver) creates a real disk and a PersistentVolume for it, and binds the claim to it. With WaitForFirstConsumer it waits until a pod is scheduled, to create the disk in the right zone.",
			"El aprovisionador de la StorageClass (un driver CSI) crea un disco real y un PersistentVolume, y le enlaza el claim. Con WaitForFirstConsumer espera a que se programe un pod para crear el disco en la zona correcta."]},
		{"flow": ["scheduler", "kubelet"], "tag": "attach+mount", "col": "yellow", "text": [
			"The pod is scheduled where the volume can reach, the disk is attached to that node and the kubelet mounts it into the container.",
			"El pod se programa donde el volumen es accesible, el disco se conecta a ese nodo y el kubelet lo monta en el contenedor."]},
		{"flow": ["you", "api"], "tag": "reclaim", "col": "red", "text": [
			"Delete the claim and the reclaim policy decides: Delete erases the disk, Retain keeps it (Released) for you to recover.",
			"Si borras el claim, la reclaim policy decide: Delete borra el disco y Retain lo conserva (Released) para que lo recuperes."]},
	], "quiz": {"q": ["A PVC stays Pending and its class doesn't exist. What will fix it?", "Un PVC queda Pending y su clase no existe. ¿Qué lo arregla?"], "options": [["Waiting", "Esperar"], ["Using an existing StorageClass", "Usar una StorageClass existente"], ["Restarting the pod", "Reiniciar el pod"]], "answer": 1,
		"why": ["No class means no provisioner will ever create the volume.", "Sin clase, ningún aprovisionador creará nunca el volumen."]}},

	# ------------------------------------------------------------ advanced
	{"id": "scheduling", "level": 2, "title": ["The scheduler, deeply", "El scheduler a fondo"], "steps": [
		{"flow": ["api", "scheduler"], "tag": "queue", "col": "yellow", "text": [
			"Pending pods wait in the scheduler's queue, ordered by priority (PriorityClass).",
			"Los pods Pending esperan en la cola del scheduler, ordenados por prioridad (PriorityClass)."]},
		{"flow": ["scheduler"], "tag": "filter", "col": "yellow", "text": [
			"Filter: drop nodes without room for the REQUESTS (not the real use), with taints the pod doesn't tolerate, or that break nodeSelector / affinity.",
			"Filtrar: descarta nodos sin espacio para los REQUESTS (no el uso real), con taints que el pod no tolera o que incumplen nodeSelector / afinidad."]},
		{"flow": ["scheduler"], "tag": "score", "col": "yellow", "text": [
			"Score: rank the rest (spread replicas across nodes and zones, prefer free resources, image already there) and pick the best.",
			"Puntuar: ordena los demás (repartir réplicas entre nodos y zonas, preferir recursos libres, imagen ya descargada) y elige el mejor."]},
		{"flow": ["scheduler", "api", "kubelet"], "tag": "preempt", "col": "red", "text": [
			"No node fits and the pod has high priority? Preemption: lower-priority pods are evicted to make room.",
			"¿No cabe en ningún nodo y el pod tiene prioridad alta? Preemption: se desalojan pods de menor prioridad para hacerle sitio."]},
	], "quiz": {"q": ["A node shows 20% real CPU use but the scheduler says 'Insufficient cpu'. Why?", "Un nodo usa 20% de CPU real pero el scheduler dice 'Insufficient cpu'. ¿Por qué?"], "options": [["Its pods' requests add up to its capacity", "Los requests de sus pods suman su capacidad"], ["metrics-server is wrong", "metrics-server se equivoca"], ["The node is NotReady", "El nodo está NotReady"]], "answer": 0,
		"why": ["The scheduler reserves by requests, not by real use.", "El scheduler reserva por requests, no por uso real."]}},

	{"id": "watch", "level": 2, "title": ["Watches and reconcile loops", "Watches y bucles de reconciliación"], "steps": [
		{"flow": ["controllers", "api"], "tag": "LIST", "col": "orange", "text": [
			"A controller starts by LISTing every object it cares about, and keeps a copy in memory (an informer cache).",
			"Un controlador empieza LISTANDO todos los objetos que le importan y guarda una copia en memoria (la caché de un informer)."]},
		{"flow": ["api", "controllers"], "tag": "WATCH", "col": "orange", "text": [
			"Then it WATCHes: the API server streams every change (added, modified, deleted) with a resourceVersion, so nothing is missed.",
			"Luego OBSERVA (watch): el API server le envía cada cambio (añadido, modificado, borrado) con un resourceVersion, para no perder nada."]},
		{"flow": ["controllers", "api", "etcd"], "tag": "reconcile", "col": "green", "text": [
			"Each change puts a key in a work queue; reconcile compares desired vs actual and acts. It's level-triggered: it looks at the whole state, so a missed event is fixed next time.",
			"Cada cambio mete una clave en una cola de trabajo; reconcile compara deseado y real y actúa. Es por nivel (level-triggered): mira el estado completo, así un evento perdido se corrige la siguiente vez."]},
		{"flow": ["api", "controllers"], "tag": "409 Conflict", "col": "red", "text": [
			"Two writers change the same object? The second gets 409 Conflict (its resourceVersion is old) and retries on fresh data: optimistic concurrency, no locks.",
			"¿Dos escritores cambian el mismo objeto? El segundo recibe 409 Conflict (su resourceVersion es viejo) y reintenta con datos frescos: concurrencia optimista, sin bloqueos."]},
	], "quiz": {"q": ["Why does a controller survive losing an event?", "¿Por qué un controlador sobrevive a perder un evento?"], "options": [["Events are stored forever", "Los eventos se guardan para siempre"], ["It reconciles the whole state, not the event", "Reconcilia el estado completo, no el evento"], ["It can't lose events", "No puede perder eventos"]], "answer": 1,
		"why": ["Level-triggered loops converge from any starting point.", "Los bucles por nivel convergen desde cualquier punto de partida."]}},

	{"id": "admission", "level": 2, "title": ["Admission: the checks before saving", "Admisión: los controles antes de guardar"], "steps": [
		{"flow": ["you", "api"], "tag": "authn", "col": "green", "text": [
			"Authentication: who are you? A client certificate, a token, OIDC from your company login... The API server learns your user and groups.",
			"Autenticación: ¿quién eres? Un certificado de cliente, un token, OIDC del login de tu empresa... El API server obtiene tu usuario y tus grupos."]},
		{"flow": ["api"], "tag": "RBAC", "col": "yellow", "text": [
			"Authorization: may this user do this verb on this resource in this namespace? RBAC Roles and RoleBindings answer. No rule, no access.",
			"Autorización: ¿puede este usuario hacer este verbo sobre este recurso en este namespace? Responden los Roles y RoleBindings de RBAC. Sin regla, sin acceso."]},
		{"flow": ["api"], "tag": "mutate", "col": "orange", "text": [
			"Mutating admission: defaults and injected sidecars (a service mesh adds its proxy here), LimitRange default requests.",
			"Admisión mutante: valores por defecto y sidecars inyectados (un service mesh añade aquí su proxy), requests por defecto del LimitRange."]},
		{"flow": ["api", "etcd"], "tag": "validate", "col": "red", "text": [
			"Validating admission: Pod Security, ResourceQuota, policy engines (Kyverno, Gatekeeper). One 'no' and nothing is stored.",
			"Admisión validante: Pod Security, ResourceQuota, motores de políticas (Kyverno, Gatekeeper). Un solo 'no' y no se guarda nada."]},
	], "quiz": {"q": ["'exceeded quota' when creating a pod. Which step said no?", "'exceeded quota' al crear un pod. ¿Qué paso dijo que no?"], "options": [["RBAC", "RBAC"], ["Validating admission", "La admisión validante"], ["The scheduler", "El scheduler"]], "answer": 1,
		"why": ["ResourceQuota is enforced at admission, before etcd.", "ResourceQuota se aplica en la admisión, antes de etcd."]}},

	{"id": "node-down", "level": 2, "title": ["When a node dies", "Cuando un nodo muere"], "steps": [
		{"flow": ["kubelet", "api"], "tag": "heartbeat", "col": "green", "text": [
			"Every kubelet renews a Lease every ~10 s: its heartbeat.",
			"Cada kubelet renueva un Lease cada ~10 s: su latido."]},
		{"flow": ["controllers", "api"], "tag": "NotReady", "col": "red", "text": [
			"No heartbeat for ~40 s: the node controller marks the node NotReady and taints it (unreachable).",
			"Sin latido durante ~40 s: el controlador de nodos lo marca NotReady y le pone un taint (unreachable)."]},
		{"flow": ["controllers", "api", "scheduler", "kubelet"], "tag": "evict", "col": "orange", "text": [
			"After the pods' toleration (5 min by default) they are evicted and their controllers create replacements on healthy nodes. StatefulSet pods wait: two copies with the same identity would be worse.",
			"Pasada la tolerancia de los pods (5 min por defecto) se desalojan y sus controladores crean reemplazos en nodos sanos. Los pods de StatefulSet esperan: dos copias con la misma identidad serían peor."]},
	], "quiz": {"q": ["How long until pods of a dead node move, by default?", "¿Cuánto tardan en moverse los pods de un nodo caído, por defecto?"], "options": [["Instantly", "Al instante"], ["About 40 s", "Unos 40 s"], ["About 5 minutes", "Unos 5 minutos"]], "answer": 2,
		"why": ["40 s to NotReady, then the default 300 s toleration.", "40 s hasta NotReady y después la tolerancia de 300 s por defecto."]}},

	{"id": "autoscaling", "level": 2, "title": ["Autoscaling", "Autoescalado"], "steps": [
		{"flow": ["kubelet", "api"], "tag": "metrics", "col": "blue", "text": [
			"metrics-server collects CPU and memory from every kubelet and serves them through the API (kubectl top).",
			"metrics-server recoge CPU y memoria de cada kubelet y los sirve por la API (kubectl top)."]},
		{"flow": ["controllers", "api"], "tag": "HPA", "col": "orange", "text": [
			"Every 15 s the HPA controller compares use against the target (e.g. 70% of the CPU request) and computes replicas = current x use / target.",
			"Cada 15 s el controlador del HPA compara el uso con el objetivo (p. ej. 70% del request de CPU) y calcula réplicas = actuales x uso / objetivo."]},
		{"flow": ["controllers", "api", "scheduler"], "tag": "scale 3->7", "col": "green", "text": [
			"It changes the Deployment's replicas (that's why a manual scale gets undone). If the new pods don't fit, the cluster autoscaler adds nodes.",
			"Cambia las réplicas del Deployment (por eso un escalado manual se deshace). Si los pods nuevos no caben, el cluster autoscaler añade nodos."]},
	], "quiz": {"q": ["The HPA ignores your pods' CPU. What's usually missing?", "El HPA ignora la CPU de tus pods. ¿Qué suele faltar?"], "options": [["CPU requests", "Los requests de CPU"], ["A Service", "Un Service"], ["A PodDisruptionBudget", "Un PodDisruptionBudget"]], "answer": 0,
		"why": ["Utilization is a percentage OF the request: no request, no percentage.", "La utilización es un porcentaje DEL request: sin request no hay porcentaje."]}},

	# -------------------------------------------------------------- expert
	{"id": "etcd-ha", "level": 3, "title": ["etcd, quorum and leader election", "etcd, quórum y elección de líder"], "steps": [
		{"flow": ["api", "etcd"], "tag": "raft", "col": "orange", "text": [
			"etcd members agree with Raft: a write counts when a majority (quorum) stores it. 3 members survive 1 failure, 5 survive 2.",
			"Los miembros de etcd se ponen de acuerdo con Raft: una escritura vale cuando la guarda una mayoría (quórum). 3 miembros aguantan 1 fallo, 5 aguantan 2."]},
		{"flow": ["etcd"], "tag": "no quorum", "col": "red", "text": [
			"Lose the majority and etcd refuses writes: the cluster keeps running what it has, but nothing can change. That's why an even number of members is useless.",
			"Si se pierde la mayoría, etcd rechaza escrituras: el cluster sigue ejecutando lo que tiene pero nada puede cambiar. Por eso un número par de miembros no sirve."]},
		{"flow": ["controllers", "api"], "tag": "Lease", "col": "yellow", "text": [
			"With several control-planes, controller managers and schedulers run on all of them but only the one holding a Lease acts: leader election. If it dies, another takes over in seconds.",
			"Con varios control-planes, los controller managers y schedulers corren en todos, pero solo actúa el que tiene el Lease: elección de líder. Si muere, otro toma el relevo en segundos."]},
	], "quiz": {"q": ["How many etcd members to survive 2 failures?", "¿Cuántos miembros de etcd para aguantar 2 fallos?"], "options": [["3", "3"], ["4", "4"], ["5", "5"]], "answer": 2,
		"why": ["Quorum of 5 is 3, so 2 can be lost.", "El quórum de 5 es 3: se pueden perder 2."]}},

	{"id": "gc", "level": 3, "title": ["Garbage collection and finalizers", "Recolección de basura y finalizers"], "steps": [
		{"flow": ["controllers", "api"], "tag": "ownerRefs", "col": "orange", "text": [
			"Every pod points to its ReplicaSet and the ReplicaSet to its Deployment (ownerReferences). Delete the owner and the garbage collector deletes what it owned.",
			"Cada pod apunta a su ReplicaSet y el ReplicaSet a su Deployment (ownerReferences). Si borras al dueño, el recolector de basura borra lo que le pertenecía."]},
		{"flow": ["you", "api", "etcd"], "tag": "finalizer", "col": "yellow", "text": [
			"A finalizer is a 'wait, I must clean up first' mark: deletion only sets deletionTimestamp and waits until every finalizer is removed by its controller.",
			"Un finalizer es una marca de 'espera, primero tengo que limpiar': borrar solo pone deletionTimestamp y espera a que cada controlador quite su finalizer."]},
		{"flow": ["api"], "tag": "Terminating", "col": "red", "text": [
			"Stuck Terminating = a finalizer whose controller is gone or failing. Fix the controller; removing the finalizer by hand skips its cleanup.",
			"Atascado en Terminating = un finalizer cuyo controlador desapareció o falla. Arregla el controlador; quitar el finalizer a mano se salta su limpieza."]},
	], "quiz": {"q": ["A namespace is stuck Terminating for hours. Most likely?", "Un namespace lleva horas en Terminating. ¿Lo más probable?"], "options": [["etcd is slow", "etcd va lento"], ["An object inside has a finalizer nobody removes", "Un objeto dentro tiene un finalizer que nadie quita"], ["RBAC", "RBAC"]], "answer": 1,
		"why": ["Often a CRD's operator was uninstalled before its objects.", "A menudo se desinstaló el operador de un CRD antes que sus objetos."]}},

	{"id": "operators", "level": 3, "title": ["CRDs and operators", "CRDs y operadores"], "steps": [
		{"flow": ["you", "api", "etcd"], "tag": "CRD", "col": "green", "text": [
			"A CustomResourceDefinition teaches the API server a new kind (Certificate, Application...). It is stored and served like any built-in object.",
			"Una CustomResourceDefinition enseña al API server un tipo nuevo (Certificate, Application...). Se guarda y se sirve como cualquier objeto nativo."]},
		{"flow": ["api", "controllers"], "tag": "operator", "col": "orange", "text": [
			"An operator is just a controller for that kind, running as pods: it watches its objects and reconciles the world (issue a certificate, sync git, create a database).",
			"Un operador es solo un controlador de ese tipo que corre como pods: observa sus objetos y reconcilia el mundo (emitir un certificado, sincronizar git, crear una base de datos)."]},
		{"flow": ["controllers", "api", "etcd"], "tag": "status", "col": "blue", "text": [
			"It writes status back (Ready, Synced, Healthy): that's what you read with kubectl get and what this game shows for Argo CD and cert-manager.",
			"Escribe el status de vuelta (Ready, Synced, Healthy): es lo que lees con kubectl get y lo que este juego muestra para Argo CD y cert-manager."]},
	], "quiz": {"q": ["What does an operator need to work?", "¿Qué necesita un operador para funcionar?"], "options": [["A patched API server", "Un API server modificado"], ["A CRD and a controller watching it", "Un CRD y un controlador que lo observe"], ["Direct access to etcd", "Acceso directo a etcd"]], "answer": 1,
		"why": ["The API server is extensible; operators are ordinary clients.", "El API server es extensible; los operadores son clientes normales."]}},
]


static func es() -> bool:
	return TranslationServer.get_locale().begins_with("es")


## A [english, español] pair in the current language.
static func t(pair) -> String:
	if pair is Array:
		return str(pair[1] if es() and pair.size() > 1 else pair[0])
	return str(pair)


static func by_id(id: String) -> Dictionary:
	for l in LESSONS:
		if l.id == id:
			return l
	return {}
