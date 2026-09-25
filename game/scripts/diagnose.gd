class_name Diagnose
## Kubi's built-in knowledge: why something is unhealthy and how to fix it,
## worked out from the snapshot alone (so it also works offline, in demo mode
## and on the web). Every text is an English source string for tr().
##
## A diagnosis is {title, why, steps: [String], cmds: [String],
## acts: [{label, id}], sev: 0..3, kind, ns, name}.

const READ_VERBS := ["get", "describe", "logs", "top", "events", "explain", "auth", "api-resources", "version", "cluster-info"]


## True if a kubectl line only reads (Kubi may run it straight away).
static func is_read_only(cmd: String) -> bool:
	var parts := cmd.trim_prefix("kubectl ").strip_edges().split(" ", false)
	var skip := false
	for p in parts:
		if skip:  # value of -n / --namespace / --context...
			skip = false
			continue
		if p in ["-n", "--namespace"]:
			skip = true
			continue
		if not p.begins_with("-"):
			return p in READ_VERBS
	return false


static func _t(s: String) -> String:
	return TranslationServer.translate(s)


## Everything that needs attention, worst first.
static func problems(state: Dictionary) -> Array:
	var out := []
	for n in state.get("nodes", []):
		if not n.get("ready", true) or n.get("unschedulable", false):
			var d := node(n, state)
			out.append(d)
	var finished := {}   # ns -> {count, owners}
	for p in state.get("pods", []):
		var cat := PodBot.categorize(p)
		if cat == "done":
			var f: Dictionary = finished.get(p.ns, {"count": 0, "owners": {}})
			f.count += 1
			var ok: String = p.get("owner_kind", "")
			f.owners[ok] = f.owners.get(ok, 0) + 1
			finished[p.ns] = f
		if cat in ["ok", "done"]:
			continue
		if cat == "term" and float(p.get("age", 0)) < 60:
			continue
		out.append(pod(p, state))
	for ns in finished:
		if finished[ns].count >= FINISHED_WARN:
			out.append(too_many_finished(ns, finished[ns].count, finished[ns].owners))
	out.sort_custom(func(a, b): return a.sev > b.sev if a.sev != b.sev else a.name < b.name)
	return out


const FINISHED_WARN := 30


## Housekeeping (severity 0): finished pods nobody cleans up.
static func too_many_finished(ns: String, n: int, owners: Dictionary) -> Dictionary:
	var d := _base("Namespace", ns, ns)
	d.sev = 0
	d.title = _t("Many finished pods (%d)") % n
	var argo: bool = owners.has("Workflow")
	var jobs: bool = owners.has("Job")
	d.why = _t("%d pods in %s already finished (Completed). It's normal that they stay: Kubernetes only garbage-collects finished pods when the whole cluster has more than 12,500 (kube-controller-manager --terminated-pod-gc-threshold). They use no CPU or memory, but they clutter kubectl and the API and slow down tools.") % [n, ns]
	if argo:
		d.why += "\n" + _t("They come from Argo Workflows: Argo keeps the pod of every step while its Workflow exists, unless podGC or a TTL is configured.")
	d.steps = []
	if argo:
		d.steps.append(_t("Argo, for every workflow: in the workflow-controller-configmap set workflowDefaults.spec.podGC.strategy: OnPodSuccess (deletes each step's pod when it succeeds; failed ones stay for debugging) and ttlStrategy.secondsAfterCompletion: 86400 (deletes finished workflows after a day)."))
		d.steps.append(_t("Or per workflow template: spec.podGC.strategy: OnPodCompletion / OnWorkflowSuccess."))
		d.steps.append(_t("Want to keep the history? Enable the Argo workflow archive (a database) and let the pods go."))
	if jobs or not argo:
		d.steps.append(_t("Jobs: set spec.ttlSecondsAfterFinished (e.g. 3600). CronJobs: successfulJobsHistoryLimit / failedJobsHistoryLimit (defaults 3 and 1)."))
	d.steps.append(_t("Clean up what is there now (running pods are not touched)."))
	d.cmds = ["kubectl -n %s get pods --field-selector=status.phase==Succeeded --no-headers" % ns,
		"kubectl -n %s delete pods --field-selector=status.phase==Succeeded" % ns]
	if argo:
		d.cmds.append("kubectl -n %s get configmap workflow-controller-configmap -o yaml" % ns)
		d.cmds.append("argo -n %s delete --completed --older 7d" % ns)
	d.acts = [{"label": "Clean finished pods", "id": "clean_finished"}]
	return d


static func _base(kind: String, ns: String, name: String) -> Dictionary:
	return {"kind": kind, "ns": ns, "name": name, "title": "", "why": "", "steps": [], "cmds": [], "acts": [], "sev": 0}


static func _owner_ref(p: Dictionary) -> String:
	var k: String = p.get("owner_kind", "")
	var n: String = p.get("owner_name", "")
	if k in ["Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"] and n != "":
		return "%s/%s" % [k.to_lower(), n]
	return ""


static func pod(p: Dictionary, state: Dictionary) -> Dictionary:
	var ns: String = p.get("ns", "")
	var name: String = p.get("name", "")
	var d := _base("Pod", ns, name)
	var st: String = p.get("status", "")
	var msg: String = p.get("message", "")
	var owner := _owner_ref(p)
	var image: String = (p.get("images", []) + [""])[0]
	var container: String = (p.get("containers", []) + ["app"])[0]
	var restarts := int(p.get("restarts", 0))
	var nsf := "-n %s " % ns
	var describe := "kubectl %sdescribe pod %s" % [nsf, name]
	d.acts.append({"label": "Go there", "id": "goto"})
	match PodBot.categorize(p):
		"pull":
			d.sev = 3
			d.title = _t("Can't download the image")
			d.why = _t("The node could not pull the image %s. Usual causes: a typo in the name or tag, a private registry without imagePullSecrets, or no network to the registry.") % image
			d.steps = [_t("Read the exact error in the pod events (describe)."),
				_t("Fix the image name or tag in the workload."),
				_t("If the registry is private, create a docker-registry Secret and add it to imagePullSecrets.")]
			d.cmds = [describe]
			if owner != "":
				d.cmds.append("kubectl %sset image %s %s=<image>:<tag>" % [nsf, owner, container])
			d.cmds.append("kubectl %screate secret docker-registry regcred --docker-server=<registry> --docker-username=<user> --docker-password=<password>" % nsf)
			d.acts.append({"label": "Describe", "id": "describe"})
			if owner != "":
				d.acts.append({"label": "Fix in the YAML", "id": "edit:image"})
		"crash":
			d.sev = 3
			if st == "OOMKilled":
				d.title = _t("Out of memory (OOMKilled)")
				d.why = _t("The container used more memory than its limit and the kernel killed it (exit code 137). It restarts and may be killed again.")
				d.steps = [_t("Check how much memory it really uses (top) and its limit (describe)."),
					_t("Raise the memory limit, or fix the leak in the app."),
					_t("If it happens on every node, the limit is simply too low.")]
				d.cmds = ["kubectl %stop pod %s" % [nsf, name], describe]
				if owner != "":
					d.cmds.append("kubectl %sset resources %s --limits=memory=256Mi" % [nsf, owner])
					d.acts.append({"label": "Fix in the YAML", "id": "edit:resources"})
			else:
				d.title = _t("The app starts and crashes")
				d.why = _t("The container keeps exiting (%d restarts) and Kubernetes restarts it with longer and longer waits (CrashLoopBackOff). The reason is inside the app: read the logs of the crashed container.") % restarts
				d.steps = [_t("Read the logs of the PREVIOUS (crashed) container: the error is usually in the last lines."),
					_t("Check the exit code in describe: 1 = app error, 137 = killed (memory), 127 = command not found."),
					_t("Typical causes: bad config or environment variable, missing Secret/ConfigMap, a database it can't reach."),
					_t("After fixing it, restart the workload (hammer) so new pods start clean.")]
				d.cmds = ["kubectl %slogs %s --previous" % [nsf, name], describe]
				if owner != "":
					d.cmds.append("kubectl %srollout restart %s" % [nsf, owner])
			d.acts.append({"label": "Logs (crashed)", "id": "logs_prev"})
			if owner != "" and not owner.begins_with("job"):
				d.acts.append({"label": "Restart workload", "id": "restart"})
		"failed":
			d.sev = 2
			d.title = _t("The pod failed")
			d.why = _t("Status %s. Evicted pods were thrown out by the node (it ran out of memory or disk); Failed ones ended with an error.") % st
			d.steps = [_t("Look at the reason in describe."),
				_t("If the node is under pressure, free resources or add capacity."),
				_t("Failed pods are not restarted: delete them, the workload will create new ones.")]
			d.cmds = [describe, "kubectl %sdelete pod %s" % [nsf, name]]
			d.acts.append({"label": "Delete pod", "id": "delete_pod"})
		"warn":
			d.sev = 1
			d.title = _t("Running but not ready")
			d.why = _t("%d of %d containers are ready. The readiness probe is failing, so Services send it no traffic.") % [int(p.get("ready", 0)), int(p.get("total", 1))]
			d.steps = [_t("Look for 'Readiness probe failed' in the events."),
				_t("Check that the probe port and path match what the app listens on."),
				_t("Read the logs: the app may still be starting or waiting for a dependency.")]
			d.cmds = [describe, "kubectl %slogs %s" % [nsf, name]]
			d.acts.append({"label": "Logs", "id": "logs"})
		"term":
			d.sev = 1
			d.title = _t("Stuck terminating")
			d.why = _t("The pod was deleted but has not finished. Usually a finalizer or a node that stopped answering.")
			d.steps = [_t("Check finalizers and the node in describe."), _t("As a last resort, force delete it.")]
			d.cmds = [describe, "kubectl %sdelete pod %s --grace-period=0 --force" % [nsf, name]]
		_:
			_pending(d, p, state, describe, owner, nsf)
	return d


static func _pending(d: Dictionary, p: Dictionary, state: Dictionary, describe: String, owner: String, nsf: String) -> void:
	var msg: String = p.get("message", "")
	var st: String = p.get("status", "")
	if st == "CreateContainerConfigError":
		d.sev = 3
		d.title = _t("Missing configuration")
		d.why = _t("The container can't be created: it references a ConfigMap, Secret or key that does not exist. %s") % msg
		d.steps = [_t("Find the missing name in describe."), _t("Create it (or fix the reference) and the pod will start by itself.")]
		d.cmds = [describe, "kubectl %sget configmaps,secrets" % nsf]
		return
	if p.get("node", "") != "":
		d.sev = 1
		d.title = _t("Starting up")
		d.why = _t("The pod is on node %s and its containers are being created (%s): usually the image is still downloading.") % [p.node, st]
		d.steps = [_t("Wait a little. If it stays like this for minutes, check the events.")]
		d.cmds = [describe]
		return
	d.sev = 2
	d.title = _t("Waiting for the scheduler")
	d.why = _t("No node has been chosen for this pod yet.") + (" " + _t("The scheduler says: %s") % msg if msg != "" else "")
	var lines := []
	if msg.contains("Insufficient cpu") or msg.contains("Insufficient memory"):
		d.title = _t("No node has room")
		var cpu := float(p.get("cpu_req_m", 0))
		var mem := float(p.get("mem_req", 0))
		var best_cpu := 0.0
		var best_mem := 0.0
		for n in state.get("nodes", []):
			best_cpu = maxf(best_cpu, float(n.get("cpu_m", 0)))
			best_mem = maxf(best_mem, float(n.get("mem_bytes", 0)))
		lines.append(_t("It requests %s CPU and %s memory; the biggest node has %s CPU and %s in total.") % [
			Vox.fmt_cores(cpu), Vox.fmt_mib(mem), Vox.fmt_cores(best_cpu), Vox.fmt_mib(best_mem)])
		if cpu > best_cpu or mem > best_mem:
			lines.append(_t("It asks for more than ANY node has: it will never fit as it is."))
		d.steps = [_t("Lower the requests to something realistic."),
			_t("Or add a bigger node (or more nodes) to the cluster."),
			_t("Or free room by scaling down other workloads.")]
		if owner != "":
			d.cmds.append("kubectl %sset resources %s --requests=cpu=100m,memory=128Mi" % [nsf, owner])
			d.acts.append({"label": "Fix in the YAML", "id": "edit:resources"})
		else:
			d.acts.append({"label": "See the YAML", "id": "edit:resources"})
		d.cmds.append("kubectl describe nodes")
	if msg.contains("taint"):
		lines.append(_t("Some nodes have taints (like the GPU island) that this pod does not tolerate."))
		d.steps.append(_t("Add a matching toleration to the pod, or remove the taint from the node."))
		d.cmds.append("kubectl describe nodes | grep -i taint")
	if msg.contains("affinity") or msg.contains("selector"):
		lines.append(_t("Its nodeSelector / affinity matches no node."))
		d.steps.append(_t("Label a node so it matches, or fix the selector."))
		d.cmds.append("kubectl get nodes --show-labels")
	if msg.contains("PersistentVolumeClaim"):
		lines.append(_t("It waits for a volume (PersistentVolumeClaim) that is not bound."))
		d.steps.append(_t("Check the PVC and that the cluster has a StorageClass that can provision it."))
		d.cmds.append("kubectl %sget pvc" % nsf)
	if not lines.is_empty():
		d.why += "\n" + "\n".join(lines)
	if d.steps.is_empty():
		d.steps = [_t("Read the scheduler's message in the events (describe).")]
	d.cmds.push_front(describe)


static func node(n: Dictionary, _state: Dictionary) -> Dictionary:
	var d := _base("Node", "", n.name)
	d.acts.append({"label": "Go there", "id": "goto"})
	if not n.get("ready", true):
		d.sev = 3
		d.title = _t("Node not ready")
		d.why = _t("The kubelet on %s stopped reporting. Its pods will be moved elsewhere after a few minutes.") % n.name
		d.steps = [_t("Look at the node conditions (MemoryPressure, DiskPressure, network)."),
			_t("On the machine itself, check the kubelet service and its logs."),
			_t("Is the machine up? In kind it is a container: docker ps.")]
		d.cmds = ["kubectl describe node %s" % n.name, "sudo journalctl -u kubelet --since '10 min ago'"]
	else:
		d.sev = 1
		d.title = _t("Node cordoned")
		d.why = _t("%s is marked unschedulable: no new pods will land there (the ones running stay). Somebody cordoned it, usually for maintenance.") % n.name
		d.steps = [_t("If the maintenance is over, uncordon it.")]
		d.cmds = ["kubectl uncordon %s" % n.name]
		d.acts.append({"label": "Uncordon", "id": "uncordon"})
	return d


## Short sentence for Kubi's speech bubble.
static func bubble(problems_list: Array, touch := false) -> String:
	if problems_list.is_empty():
		return _t("All good!")
	if touch:
		return _t("%d problem(s). Tap me") % problems_list.size()
	if problems_list.size() == 1:
		return _t("1 problem: %s. Press Y") % problems_list[0].title
	return _t("%d problems. Press Y") % problems_list.size()


## Plain text of a diagnosis (sent to the LLM as a hint).
static func as_text(d: Dictionary) -> String:
	var t: String = "%s %s/%s: %s\n%s\n" % [d.kind, d.ns, d.name, d.title, d.why]
	for i in d.steps.size():
		t += "%d. %s\n" % [i + 1, d.steps[i]]
	return t
