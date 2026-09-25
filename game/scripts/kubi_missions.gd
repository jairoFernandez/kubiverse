class_name KubiMissions
## Missions Kubi writes from the live cluster state. Each one is a real
## problem (or risk) with real names and four phases:
##   DIAGNOSE -> UNDERSTAND -> MITIGATE -> VERIFY
## Every step has a check the game can see (an inspect, logs, a kubectl
## line, a change, or the cluster state itself), so it advances on its own.
## Texts are [format, args] pairs, translated when shown.

const HOT := 80.0          # % of a node's allocatable reserved by requests
const OVER := 4.0          # requests this many times the real usage = oversized
const RESTARTS := 5

const PHASES := ["DIAGNOSE", "UNDERSTAND", "MITIGATE", "VERIFY"]


## Candidate missions, most urgent first (at most 10). Stable ids, so a
## mission keeps its progress while the snapshot updates.
static func generate(s: Dictionary) -> Array:
	var out := []
	var seen_owner := {}
	# 1) Failing pods (one mission per owner).
	for p in s.get("pods", []):
		var cat := PodBot.categorize(p)
		if not cat in ["crash", "pull", "failed", "pending"]:
			continue
		if cat == "pending" and float(p.get("age", 0)) < 30:
			continue
		var wkey := workload_key(s, p)
		var okey := wkey if wkey != "" else "%s/Pod/%s" % [p.ns, p.name]
		if seen_owner.has(okey):
			continue
		seen_owner[okey] = true
		out.append(_failing(p, wkey, cat, s))
	# 1b) The team's alerts (Alertmanager / Prometheus rules).
	for al in s.get("alerts", []):
		var tgt := _alert_wkey(s, al)
		if tgt != "" and seen_owner.has(tgt) and str(al.get("name", "")) in ["KubePodCrashLooping", "KubePodNotReady"]:
			continue  # the failing-pod mission already covers it
		out.append(_alert(al, tgt))
	# 2) Hot nodes.
	var load := node_load(s)
	var avg := 0.0
	for n in load.values():
		avg += n.cpu_pct
	avg /= maxf(1.0, float(load.size()))
	for name in load:
		var l: Dictionary = load[name]
		var pct := maxf(l.cpu_pct, l.mem_pct)
		if pct >= HOT and (load.size() == 1 or l.cpu_pct >= avg + 20.0 or pct >= 90.0):
			out.append(_hot_node(name, l, s))
	# 3) Services with no one behind, broken Ingress routes.
	for sv in s.get("services", []):
		var sel = sv.get("selector")
		if sel == null or (sel as Dictionary).is_empty() or _system(sv.ns):
			continue
		if int(sv.get("ready", 0)) == 0:
			out.append(_no_endpoints(sv))
	for ing in s.get("ingresses", []):
		for r in (ing.get("rules", []) if ing.get("rules") != null else []):
			if not _svc_ok(s, ing.ns, str(r.get("service", ""))):
				out.append(_broken_route(ing, r))
				break
	# 4) Anomalies: restarts that keep growing, oversized requests.
	for p in s.get("pods", []):
		if int(p.get("restarts", 0)) >= RESTARTS and PodBot.categorize(p) == "ok" and not _system(p.ns):
			var wk := workload_key(s, p)
			if not seen_owner.has(wk):
				seen_owner[wk] = true
				out.append(_restarts(p, wk))
	var m: Dictionary = s.get("metrics", {}) if s.get("metrics") != null else {}
	if m.get("available", false):
		var pods_m: Dictionary = m.get("pods", {}) if m.get("pods") != null else {}
		for p in s.get("pods", []):
			var req := float(p.get("cpu_req_m", 0))
			var use: Dictionary = pods_m.get("%s/%s" % [p.ns, p.name], {})
			if req >= 200.0 and not use.is_empty() and float(use.get("cpu_m", 0)) * OVER < req and not _system(p.ns):
				var wk := workload_key(s, p)
				if wk != "" and not seen_owner.has(wk):
					seen_owner[wk] = true
					out.append(_oversized(p, wk, float(use.cpu_m)))
	# 5) Reliability risks: single replica behind a Service, no requests.
	for w in s.get("workloads", []):
		if w.kind != "Deployment" or _system(w.ns):
			continue
		var wk := "%s/%s/%s" % [w.ns, w.kind, w.name]
		if seen_owner.has(wk):
			continue
		var served: bool = s.get("services", []).any(func(sv): return sv.ns == w.ns and sv.get("pods") != null and (sv.pods as Array).any(func(pn): return str(pn).begins_with(w.name + "-")))
		if int(w.desired) == 1 and served:
			seen_owner[wk] = true
			out.append(_single_replica(w, wk))
			continue
		var mine: Array = s.get("pods", []).filter(func(p): return workload_key(s, p) == wk)
		if not mine.is_empty() and mine.all(func(p): return float(p.get("cpu_req_m", 0)) == 0.0 and float(p.get("mem_req", 0)) == 0.0):
			seen_owner[wk] = true
			out.append(_no_requests(w, wk, mine[0]))
	out.sort_custom(func(a, b): return a.sev > b.sev if a.sev != b.sev else a.id < b.id)
	return out.slice(0, 10)


# ------------------------------------------------------------ detectors

static func _failing(p: Dictionary, wkey: String, cat: String, s: Dictionary) -> Dictionary:
	var pk := "%s/%s" % [p.ns, p.name]
	var who := wkey if wkey != "" else "%s/Pod/%s" % [p.ns, p.name]
	var wname: String = wkey.get_slice("/", 2) if wkey != "" else p.name
	var diag := Diagnose.pod(p, s)
	var m := _m("k:fail:" + who, 90 if cat != "pending" else 70)
	var what: String = {"crash": "keeps crashing", "pull": "can't pull its image", "failed": "failed", "pending": "can't be scheduled"}[cat]
	m.title = ["%s %s", [wname, what]]
	m.learn = ["%s", [str(diag.get("why", ""))]]
	m.target = {"pod": pk, "wkey": wkey}
	m.steps.append(_step(0, ["Click the failing robot %s and read its status and message.", [p.name]],
		"kubectl -n %s describe pod %s" % [p.ns, p.name], {"on": "inspect", "kind": "pod", "owner": who}))
	match cat:
		"crash", "failed":
			m.steps.append(_step(1, ["Open its logs (L) with 'previous' on: the last run shows how it died.", []],
				"kubectl -n %s logs %s --previous" % [p.ns, p.name], {"on": "logs", "owner": who, "previous": true}))
			m.steps.append(_step(1, ["Ask Kubi (Y) what the error means and what to change.", []], "", {"on": "kubi"}))
			m.steps.append(_step(2, ["Fix the cause in its YAML (EDIT YAML: image, env, memory limit, probe) or RESTART it if it was a one-off.", []],
				"kubectl -n %s edit %s" % [p.ns, _res(who)], {"on": "change", "wkey": who}))
		"pull":
			m.steps.append(_step(1, ["Check the image name and tag: does it exist, is the registry private (imagePullSecrets)?", []],
				"kubectl -n %s get pod %s -o jsonpath={.spec.containers[*].image}" % [p.ns, p.name], {"on": "kubectl", "prefix": ["-n %s get pod" % p.ns, "-n %s describe pod" % p.ns, "describe pod", "get pod"]}))
			m.steps.append(_step(2, ["Put the right image in its YAML (EDIT YAML) and APPLY.", []],
				"kubectl -n %s set image %s <container>=<image:tag>" % [p.ns, _res(who)], {"on": "change", "wkey": who}))
		"pending":
			m.steps.append(_step(1, ["Go to the ENERGY ROOM: does any node have that much free CPU / memory, or a taint the pod doesn't tolerate?", []],
				"kubectl describe nodes", {"on": "inspect", "kind": "node"}))
			m.steps.append(_step(2, ["Lower its requests (or fix its node selector / tolerations) in the YAML, or free room on a node.", []],
				"kubectl -n %s set resources %s --requests=cpu=100m,memory=128Mi" % [p.ns, _res(who)], {"on": "change", "wkey": who}))
	m.steps.append(_step(3, ["Wait until %s is healthy again.", [wname]], "kubectl -n %s get pods -w" % p.ns,
		{"on": "state", "cond": "healthy", "wkey": wkey, "pod": pk}))
	return m


static func _hot_node(name: String, l: Dictionary, s: Dictionary) -> Dictionary:
	var m := _m("k:hot:" + name, 60)
	var res := "CPU" if l.cpu_pct >= l.mem_pct else "memory"
	var pct := roundi(maxf(l.cpu_pct, l.mem_pct))
	m.title = ["Node %s is a bottleneck (%d%% %s reserved)", [name, pct, res]]
	m.learn = ["The scheduler places pods by their requests, not by real use. A node with %d%% reserved takes no more pods that ask for much, so they pile up on the others or stay Pending. Options: right-size requests to real use, spread replicas (topologySpreadConstraints / anti-affinity), scale down what isn't needed, or add a node (cluster autoscaler).", [pct]]
	var top := _top_reservers(s, name, res == "CPU")
	var names := ", ".join(top.map(func(p): return "%s (%s)" % [p.name, Vox.fmt_cores(float(p.get("cpu_req_m", 0))) if res == "CPU" else Vox.fmt_mib(float(p.get("mem_req", 0)))]))
	var big: Dictionary = top[0] if not top.is_empty() else {}
	var wkey := workload_key(s, big) if not big.is_empty() else ""
	m.target = {"node": name, "wkey": wkey}
	m.steps.append(_step(0, ["In the ENERGY ROOM, click the island %s: compare reserved and free.", [name]],
		"kubectl describe node %s" % name, {"on": "inspect", "kind": "node", "key": name}))
	if not big.is_empty():
		m.steps.append(_step(0, ["The pods reserving the most there: %s. Click the biggest one, %s.", [names, big.name]],
			"kubectl get pods -A --field-selector spec.nodeName=%s -o wide" % name, {"on": "inspect", "kind": "pod", "key": "%s/%s" % [big.ns, big.name]}))
	m.steps.append(_step(1, ["Reserved is not used: compare with real usage (F3 stats, or 'top pods' in the terminal).", []],
		"kubectl top pods -A --sort-by=cpu", {"on": "any", "of": [{"on": "stats"}, {"on": "kubectl", "prefix": ["top "]}]}))
	if wkey != "":
		m.steps.append(_step(2, ["Mitigate: lower the requests of %s to what it really uses (EDIT YAML), or scale it down if it has spare replicas.", [wkey.get_slice("/", 2)]],
			"kubectl -n %s set resources %s --requests=%s" % [wkey.get_slice("/", 0), _res(wkey), "cpu=<less>" if res == "CPU" else "memory=<less>"],
			{"on": "change", "wkey": wkey}))
	m.steps.append(_step(3, ["Verify: %s below %d%% reserved.", [name, int(HOT)]], "kubectl describe node %s" % name,
		{"on": "state", "cond": "node_below", "node": name, "pct": HOT}))
	return m


static func _no_endpoints(sv: Dictionary) -> Dictionary:
	var key := "%s/%s" % [sv.ns, sv.name]
	var m := _m("k:ep:" + key, 55)
	m.title = ["Service %s sends traffic nowhere", [sv.name]]
	m.learn = ["A Service only routes to ready pods whose labels match its selector. No ready endpoints = connection refused or 503 for everyone who calls it, even though the Service exists.", []]
	m.target = {"svc": key}
	var sel := ", ".join((sv.selector as Dictionary).keys().map(func(k): return "%s=%s" % [k, sv.selector[k]]))
	m.steps.append(_step(0, ["Click the loading dock %s in hall %s: no lines come out of it.", [sv.name, sv.ns]],
		"kubectl -n %s get endpointslices -l kubernetes.io/service-name=%s" % [sv.ns, sv.name], {"on": "inspect", "kind": "service", "key": key}))
	m.steps.append(_step(1, ["Look for pods with its labels (%s): are there none, or are they not ready?", [sel]],
		"kubectl -n %s get pods -l %s" % [sv.ns, sel.replace(", ", ",")], {"on": "any", "of": [{"on": "inspect", "kind": "pod"}, {"on": "inspect", "kind": "workload"}, {"on": "kubectl", "prefix": ["-n %s get pods" % sv.ns, "get pods"]}]}))
	m.steps.append(_step(2, ["Fix it: the selector in the Service YAML, the labels of the pods, or the pods themselves (they must be ready).", []],
		"kubectl -n %s edit service %s" % [sv.ns, sv.name], {"on": "any", "of": [{"on": "change", "svc": key}, {"on": "change"}]}))
	m.steps.append(_step(3, ["Verify: %s has ready pods behind it.", [sv.name]], "kubectl -n %s get endpointslices" % sv.ns,
		{"on": "state", "cond": "svc_ready", "svc": key}))
	return m


static func _broken_route(ing: Dictionary, r: Dictionary) -> Dictionary:
	var host := str(r.get("host", "")) if str(r.get("host", "")) != "" else "*"
	var m := _m("k:route:%s/%s" % [ing.ns, ing.name], 50)
	m.title = ["Route %s%s answers 503", [host, r.get("path", "/")]]
	m.learn = ["Ingress %s sends %s to Service %s, which doesn't exist or has no ready pods. Users get 503 from the ingress controller.", [ing.name, host, r.get("service", "")]]
	m.target = {"svc": "%s/%s" % [ing.ns, r.get("service", "")]}
	m.steps.append(_step(0, ["In THE INTERNET, click the INGRESS gate and find the red route.", []], "kubectl -n %s describe ingress %s" % [ing.ns, ing.name], {"on": "inspect", "kind": "gate"}))
	m.steps.append(_step(1, ["Check the Service it points to: kubectl -n %s get svc.", [ing.ns]], "kubectl -n %s get svc" % ing.ns, {"on": "any", "of": [{"on": "kubectl", "prefix": ["-n %s get svc" % ing.ns, "get svc"]}, {"on": "inspect", "kind": "service"}]}))
	m.steps.append(_step(3, ["Fix the rule or create / heal the Service; the route turns green.", []], "kubectl -n %s edit ingress %s" % [ing.ns, ing.name],
		{"on": "state", "cond": "svc_ready", "svc": "%s/%s" % [ing.ns, r.get("service", "")]}))
	return m


static func _restarts(p: Dictionary, wkey: String) -> Dictionary:
	var who := wkey if wkey != "" else "%s/Pod/%s" % [p.ns, p.name]
	var m := _m("k:rst:" + who, 45)
	m.title = ["%s restarted %d times", [p.name, int(p.restarts)]]
	m.learn = ["It runs now, but restarts that keep growing are an early warning: crashes under load, OOM kills or a liveness probe that is too strict. Find the pattern before it turns into an outage.", []]
	m.target = {"pod": "%s/%s" % [p.ns, p.name], "wkey": wkey, "restarts": int(p.restarts)}
	m.steps.append(_step(0, ["Click %s and look at its restarts and age.", [p.name]], "kubectl -n %s get pod %s" % [p.ns, p.name], {"on": "inspect", "kind": "pod", "owner": who}))
	m.steps.append(_step(1, ["Read the logs of the previous run (L, 'previous' on): how did it end?", []], "kubectl -n %s logs %s --previous" % [p.ns, p.name], {"on": "logs", "owner": who, "previous": true}))
	m.steps.append(_step(1, ["Check the last events: OOMKilled? probe failures?", []], "kubectl -n %s describe pod %s" % [p.ns, p.name], {"on": "any", "of": [{"on": "kubi"}, {"on": "kubectl", "prefix": ["-n %s describe pod" % p.ns, "describe pod", "get events", "-n %s get events" % p.ns]}]}))
	m.steps.append(_step(2, ["Mitigate in the YAML: more memory limit, a gentler liveness probe (initialDelaySeconds, failureThreshold), or fix the bug.", []], "kubectl -n %s edit %s" % [p.ns, _res(who)], {"on": "change", "wkey": who}))
	m.steps.append(_step(3, ["Verify: no new restarts for 3 minutes.", []], "kubectl -n %s get pods -w" % p.ns, {"on": "state", "cond": "quiet", "wkey": wkey, "pod": "%s/%s" % [p.ns, p.name], "secs": 180}))
	return m


static func _oversized(p: Dictionary, wkey: String, use_m: float) -> Dictionary:
	var req := float(p.get("cpu_req_m", 0))
	var m := _m("k:over:" + wkey, 25)
	m.title = ["%s reserves %s CPU but uses %s", [wkey.get_slice("/", 2), Vox.fmt_cores(req), Vox.fmt_cores(use_m)]]
	m.learn = ["Requests are reserved whether used or not: this app blocks CPU other pods could use and makes nodes look full. Right-size to real use plus some headroom (e.g. p95 x 1.3), or let a VPA recommend it.", []]
	m.target = {"wkey": wkey, "req": req}
	m.steps.append(_step(0, ["Click %s and compare its requests with its real usage.", [p.name]], "kubectl -n %s get pod %s -o jsonpath={.spec.containers[*].resources}" % [p.ns, p.name], {"on": "inspect", "kind": "pod", "owner": wkey}))
	m.steps.append(_step(1, ["Watch it over time: top pods (terminal) or F3.", []], "kubectl -n %s top pods" % p.ns, {"on": "any", "of": [{"on": "stats"}, {"on": "kubectl", "prefix": ["top ", "-n %s top" % p.ns]}]}))
	m.steps.append(_step(2, ["Lower its CPU request in the YAML to real use plus headroom.", []], "kubectl -n %s set resources %s --requests=cpu=%dm" % [p.ns, _res(wkey), maxi(50, roundi(use_m * 1.5))], {"on": "change", "wkey": wkey}))
	m.steps.append(_step(3, ["Verify: its request went down.", []], "", {"on": "state", "cond": "req_lower", "wkey": wkey, "req": req}))
	return m


static func _single_replica(w: Dictionary, wkey: String) -> Dictionary:
	var m := _m("k:one:" + wkey, 30)
	m.title = ["%s runs a single replica", [w.name]]
	m.learn = ["One pod behind a Service is a single point of failure: a node drain, an eviction or a crash takes the service down until it's back. Two or more replicas (spread across nodes) plus a PodDisruptionBudget keep it serving.", []]
	m.target = {"wkey": wkey}
	m.steps.append(_step(0, ["Click the line %s: 1 replica.", [w.name]], "kubectl -n %s get deploy %s" % [w.ns, w.name], {"on": "inspect", "kind": "workload", "key": wkey}))
	m.steps.append(_step(1, ["Click a loading dock of hall %s that sends traffic to it: everything depends on that one robot.", [w.ns]], "kubectl -n %s get svc" % w.ns, {"on": "inspect", "kind": "service"}))
	m.steps.append(_step(2, ["Scale it to 2 or more (SCALE +).", []], "kubectl -n %s scale deployment/%s --replicas=2" % [w.ns, w.name], {"on": "state", "cond": "replicas", "wkey": wkey, "n": 2}))
	m.steps.append(_step(3, ["Verify: 2 replicas ready.", []], "kubectl -n %s get deploy %s" % [w.ns, w.name], {"on": "state", "cond": "ready_at_least", "wkey": wkey, "n": 2}))
	return m


static func _no_requests(w: Dictionary, wkey: String, p: Dictionary) -> Dictionary:
	var m := _m("k:noreq:" + wkey, 20)
	m.title = ["%s has no CPU or memory requests", [w.name]]
	m.learn = ["Without requests its pods are BestEffort: the scheduler thinks they need nothing (so it can overload a node) and they are the first evicted under pressure. Set requests to typical use and a memory limit.", []]
	m.target = {"wkey": wkey}
	m.steps.append(_step(0, ["Click one of its robots, %s: requests are missing.", [p.name]], "kubectl -n %s get pod %s -o jsonpath={.status.qosClass}" % [p.ns, p.name], {"on": "inspect", "kind": "pod", "owner": wkey}))
	m.steps.append(_step(2, ["Add resources.requests (and a memory limit) in its YAML.", []], "kubectl -n %s set resources deployment/%s --requests=cpu=100m,memory=128Mi --limits=memory=256Mi" % [w.ns, w.name], {"on": "change", "wkey": wkey}))
	m.steps.append(_step(3, ["Verify: its pods now have requests.", []], "", {"on": "state", "cond": "has_requests", "wkey": wkey}))
	return m


# ------------------------------------------------------------ checks

## Does this event (or the state) complete the step?
static func _alert_wkey(s: Dictionary, al: Dictionary) -> String:
	if str(al.get("workload", "")) != "":
		return "%s/%s" % [al.ns, al.workload]
	if str(al.get("pod", "")) != "":
		for p in s.get("pods", []):
			if p.ns == al.ns and p.name == al.pod:
				return workload_key(s, p)
	return ""


static func _alert(al: Dictionary, wkey: String) -> Dictionary:
	var m := _m("k:alert:" + str(al.id), {"critical": 90, "warning": 60}.get(str(al.get("severity", "")), 30))
	var what := str(al.get("summary", "")) if str(al.get("summary", "")) != "" else str(al.get("description", ""))
	m.title = ["Alert %s: %s", [al.name, what]]
	var runbook := str(al.get("runbook", ""))
	m.learn = ["Your team's monitoring fired this (%s, %s). %s%s", [al.get("source", "alert"), al.get("severity", "?"), al.get("description", ""),
		(" Runbook: " + runbook) if runbook != "" else ""]]
	m.target = {"alert": al.id, "wkey": wkey, "pod": "%s/%s" % [al.get("ns", ""), al.get("pod", "")] if str(al.get("pod", "")) != "" else ""}
	var ns := str(al.get("ns", ""))
	if str(al.get("node", "")) != "":
		m.steps.append(_step(0, ["Click node %s: what is it running, how full is it?", [al.node]], "kubectl describe node %s" % al.node, {"on": "inspect", "kind": "node", "key": al.node}))
	elif wkey != "":
		m.steps.append(_step(0, ["Find %s (search: Ctrl/Cmd+F) and click it.", [wkey.get_slice("/", 2)]], "kubectl -n %s get %s" % [ns, _res(wkey)], {"on": "any", "of": [{"on": "inspect", "kind": "workload", "key": wkey}, {"on": "inspect", "kind": "pod", "owner": wkey}]}))
	m.steps.append(_step(1, ["Look at its HISTORY in the inspector: since when is it like this?", []], "# Prometheus: the query behind the alert", {"on": "history"}))
	if ns != "":
		m.steps.append(_step(1, ["Search the logs of all its pods at once (LOGS all pods, e.g. 'error').", []], "logcli query '{namespace=\"%s\"} |= \"error\"'" % ns, {"on": "any", "of": [{"on": "agglogs"}, {"on": "logs", "owner": wkey}]} if wkey != "" else {"on": "agglogs"}))
	m.steps.append(_step(2, ["Mitigate: follow the runbook, roll back a bad deploy, give it resources or fix it; or ask Kubi.", []], runbook if runbook != "" else "kubectl -n %s rollout undo %s" % [ns, _res(wkey)],
		{"on": "any", "of": [{"on": "change", "wkey": wkey}, {"on": "kubi"}]} if wkey != "" else {"on": "any", "of": [{"on": "change"}, {"on": "kubi"}]}))
	m.steps.append(_step(3, ["Verify: the alert stops firing.", []], "# Alertmanager: the alert is gone", {"on": "state", "cond": "alert_gone", "id": al.id}))
	return m


static func check(step: Dictionary, ev: String, a, b, s: Dictionary, flags: Dictionary) -> bool:
	return _match(step.check, ev, a, b, s, flags)


static func _match(c: Dictionary, ev: String, a, b, s: Dictionary, flags: Dictionary) -> bool:
	match str(c.on):
		"any":
			return c.of.any(func(x): return _match(x, ev, a, b, s, flags))
		"inspect":
			if ev != "inspect" or a != c.kind:
				return false
			if c.has("key"):
				var k := ""
				match str(c.kind):
					"node": k = str(b.get("name", ""))
					"workload": k = "%s/%s/%s" % [b.get("ns", ""), b.get("kind", ""), b.get("name", "")]
					_: k = "%s/%s" % [b.get("ns", ""), b.get("name", "")]
				return k == c.key
			if c.has("owner"):
				return _owns(s, c.owner, b)
			return true
		"logs":
			return ev == "logs" and (not c.get("previous", false) or b == true) and _owns(s, c.owner, a)
		"kubectl":
			if ev != "kubectl":
				return false
			var line := str(a).strip_edges().trim_prefix("kubectl ").strip_edges()
			return c.prefix.any(func(pf): return line.begins_with(pf))
		"stats", "kubi", "history", "agglogs":
			return ev == c.on
		"change":
			if ev == "manifest" and b:
				if c.has("svc"):
					return a.get("kind", "") == "Service" and "%s/%s" % [a.ns, a.name] == c.svc
				return not c.has("wkey") or "%s/%s/%s" % [a.ns, a.kind, a.name] == c.wkey or (str(c.wkey).contains("/Pod/") and a.get("kind", "") == "Pod")
			if ev == "action" and b and a.get("action", "") in ["restart", "scale", "delete_pod", "delete_workload", "rollout_undo", "resume"]:
				if not c.has("wkey"):
					return true
				var k := "%s/%s/%s" % [a.get("ns", ""), a.get("kind", ""), a.get("name", "")]
				return k == c.wkey or (a.action == "delete_pod" and _owns(s, c.wkey, {"ns": a.get("ns", ""), "name": a.get("name", "")}))
			return false
		"state":
			return ev == "state" and _cond(c, s, flags)
	return false


static func _cond(c: Dictionary, s: Dictionary, flags: Dictionary) -> bool:
	match str(c.cond):
		"healthy":
			if c.wkey != "":
				var w := _workload(s, c.wkey)
				return not w.is_empty() and int(w.desired) > 0 and int(w.ready) >= int(w.desired)
			for p in s.get("pods", []):
				if "%s/%s" % [p.ns, p.name] == c.pod:
					return PodBot.categorize(p) in ["ok", "done"]
			return true  # the bare pod is gone
		"node_below":
			var l: Dictionary = node_load(s).get(c.node, {})
			return l.is_empty() or maxf(l.cpu_pct, l.mem_pct) < float(c.pct)
		"svc_ready":
			for sv in s.get("services", []):
				if "%s/%s" % [sv.ns, sv.name] == c.svc:
					return int(sv.get("ready", 0)) > 0
			return false
		"replicas":
			var w := _workload(s, c.wkey)
			return not w.is_empty() and int(w.desired) >= int(c.n)
		"ready_at_least":
			var w := _workload(s, c.wkey)
			return not w.is_empty() and int(w.ready) >= int(c.n)
		"req_lower":
			var mine: Array = s.get("pods", []).filter(func(p): return workload_key(s, p) == c.wkey and PodBot.categorize(p) == "ok")
			return not mine.is_empty() and mine.all(func(p): return float(p.get("cpu_req_m", 0)) < float(c.req))
		"has_requests":
			var mine: Array = s.get("pods", []).filter(func(p): return workload_key(s, p) == c.wkey and PodBot.categorize(p) == "ok")
			return not mine.is_empty() and mine.all(func(p): return float(p.get("cpu_req_m", 0)) > 0.0 or float(p.get("mem_req", 0)) > 0.0)
		"alert_gone":
			return not s.get("alerts", []).any(func(al): return str(al.id) == str(c.id))
		"quiet":
			var total := 0
			for p in s.get("pods", []):
				if (c.wkey != "" and workload_key(s, p) == c.wkey) or "%s/%s" % [p.ns, p.name] == c.pod:
					total += int(p.get("restarts", 0))
			var now := Time.get_ticks_msec() / 1000.0
			if flags.get("q_total", -1) != total:
				flags["q_total"] = total
				flags["q_since"] = now
			return now - float(flags.get("q_since", now)) >= float(c.secs)
	return false


# ------------------------------------------------------------ helpers

static func _m(id: String, sev: int) -> Dictionary:
	return {"id": id, "sev": sev, "title": ["", []], "learn": ["", []], "steps": [], "target": {}, "dynamic": true}


static func _step(phase: int, text: Array, cmd: String, check: Dictionary) -> Dictionary:
	return {"phase": phase, "text": text, "cmd": cmd, "check": check}


static func _res(wkey: String) -> String:
	var k := wkey.get_slice("/", 1).to_lower()
	return "%s/%s" % [k if k != "" else "pod", wkey.get_slice("/", 2)]


static func _system(ns: String) -> bool:
	return ns in World.SYSTEM_NS or NsCatalog.district_of(ns) == "system"


static func _svc_ok(s: Dictionary, ns: String, name: String) -> bool:
	for sv in s.get("services", []):
		if sv.ns == ns and sv.name == name:
			return int(sv.get("ready", 0)) > 0 or sv.get("selector") == null or (sv.selector as Dictionary).is_empty()
	return false


static func _workload(s: Dictionary, key: String) -> Dictionary:
	for w in s.get("workloads", []):
		if "%s/%s/%s" % [w.ns, w.kind, w.name] == key:
			return w
	return {}


## "ns/Kind/name" of the workload owning a pod ("" for bare pods / Jobs).
static func workload_key(s: Dictionary, p: Dictionary) -> String:
	var kind: String = p.get("owner_kind", "")
	var owner: String = p.get("owner_name", "")
	if kind == "ReplicaSet":
		for w in s.get("workloads", []):
			if w.ns == p.ns and w.kind == "Deployment" and owner.begins_with(w.name + "-"):
				return "%s/Deployment/%s" % [w.ns, w.name]
		return ""
	if kind in ["Deployment", "StatefulSet", "DaemonSet"]:
		return "%s/%s/%s" % [p.ns, kind, owner]
	return ""


## Is pod (dict with ns, name) this owner's ("ns/Kind/name", or a bare pod)?
static func _owns(s: Dictionary, owner: String, p) -> bool:
	if typeof(p) != TYPE_DICTIONARY:
		return false
	if owner.contains("/Pod/"):
		return "%s/Pod/%s" % [p.get("ns", ""), p.get("name", "")] == owner
	for q in s.get("pods", []):
		if q.ns == p.get("ns", "") and q.name == p.get("name", ""):
			return workload_key(s, q) == owner
	return false


## Per node: % of allocatable CPU and memory reserved by pod requests.
static func node_load(s: Dictionary) -> Dictionary:
	var req := {}
	for p in s.get("pods", []):
		if p.get("node", "") == "" or PodBot.categorize(p) in ["done", "term"]:
			continue
		var r: Dictionary = req.get(p.node, {"cpu": 0.0, "mem": 0.0})
		r.cpu += float(p.get("cpu_req_m", 0))
		r.mem += float(p.get("mem_req", 0))
		req[p.node] = r
	var out := {}
	for n in s.get("nodes", []):
		var r: Dictionary = req.get(n.name, {"cpu": 0.0, "mem": 0.0})
		out[n.name] = {"cpu_pct": 100.0 * r.cpu / maxf(1.0, float(n.get("cpu_m", 0))),
			"mem_pct": 100.0 * r.mem / maxf(1.0, float(n.get("mem_bytes", 0)))}
	return out


static func _top_reservers(s: Dictionary, node: String, cpu: bool) -> Array:
	var mine: Array = s.get("pods", []).filter(func(p): return p.get("node", "") == node and not PodBot.categorize(p) in ["done", "term"])
	mine.sort_custom(func(a, b): return float(a.get("cpu_req_m" if cpu else "mem_req", 0)) > float(b.get("cpu_req_m" if cpu else "mem_req", 0)))
	return mine.slice(0, 3)
