class_name Kubectl
## Equivalent kubectl commands for everything the game shows or does, so the
## game doubles as a way to learn the CLI.


static func _ns(ns: String) -> String:
	return "-n %s " % ns if ns != "" else ""


## The command that performs a K8s.action() request.
static func for_action(req: Dictionary) -> String:
	var ns: String = req.get("ns", "")
	var n: String = req.get("name", "")
	var kind := str(req.get("kind", "")).to_lower()
	match req.get("action", ""):
		"delete_pod":
			return "kubectl %sdelete pod %s" % [_ns(ns), n]
		"scale":
			return "kubectl %sscale %s/%s --replicas=%d" % [_ns(ns), kind, n, int(req.get("replicas", 0))]
		"restart":
			return "kubectl %srollout restart %s/%s" % [_ns(ns), kind, n]
		"cordon":
			return "kubectl cordon %s" % n
		"uncordon":
			return "kubectl uncordon %s" % n
		"create_deployment":
			var c := "kubectl create namespace %s  # if missing\nkubectl %screate deployment %s --image=%s --replicas=%d" % [
				ns, _ns(ns), n, req.get("image", "nginx:alpine"), int(req.get("replicas", 1))]
			if req.get("service", false):
				c += "\nkubectl %sexpose deployment %s --port=80" % [_ns(ns), n]
			return c
		"delete_workload":
			return "kubectl %sdelete %s/%s" % [_ns(ns), kind, n]
	return "# unknown action"


static func logs(ns: String, pod: String, container: String, previous: bool, follow: bool) -> String:
	var c := "kubectl %slogs %s" % [_ns(ns), pod]
	if container != "":
		c += " -c " + container
	c += " --tail=200"
	if previous:
		c += " --previous"
	if follow:
		c += " -f"
	return c


## Read-only commands to look at an object: [[description, command], ...]
static func for_view(kind: String, d: Dictionary) -> Array:
	var ns: String = d.get("ns", "")
	var n: String = d.get("name", "")
	match kind:
		"pod":
			var out := [
				["see it", "kubectl %sget pod %s -o wide" % [_ns(ns), n]],
				["details + events", "kubectl %sdescribe pod %s" % [_ns(ns), n]],
				["logs", "kubectl %slogs %s" % [_ns(ns), n]],
			]
			if PodBot.categorize(d) == "crash":
				out.append(["logs of the crashed run", "kubectl %slogs %s --previous" % [_ns(ns), n]])
			out.append(["open a shell", "kubectl %sexec -it %s -- sh" % [_ns(ns), n]])
			return out
		"workload":
			var k := str(d.get("kind", "")).to_lower()
			var out := [
				["see it", "kubectl %sget %s %s" % [_ns(ns), k, n]],
				["details + events", "kubectl %sdescribe %s %s" % [_ns(ns), k, n]],
			]
			if k != "daemonset":
				out.append(["watch the rollout", "kubectl %srollout status %s/%s" % [_ns(ns), k, n]])
			return out
		"service":
			var port := ""
			var ports = d.get("ports", [])
			if ports != null and not ports.is_empty():
				port = str(ports[0]).split("/")[0]
			var out := [
				["see it", "kubectl %sget svc %s -o wide" % [_ns(ns), n]],
				["pods it routes to (lines)", "kubectl %sget endpointslices -l kubernetes.io/service-name=%s" % [_ns(ns), n]],
				["details", "kubectl %sdescribe svc %s" % [_ns(ns), n]],
			]
			if port != "" and d.get("cluster_ip", "") != "None":
				out.append(["reach it locally", "kubectl %sport-forward svc/%s %s:%s" % [_ns(ns), n, port, port]])
			return out
		"namespace":
			if n == "@power":
				return [["all nodes", "kubectl get nodes -o wide"], ["pods per node", "kubectl get pods -A -o wide"]]
			return [
				["everything inside", "kubectl -n %s get all" % n],
				["its pods", "kubectl -n %s get pods -o wide" % n],
				["what happened lately", "kubectl -n %s get events --sort-by=.lastTimestamp" % n],
			]
		"node":
			return [
				["see it", "kubectl get node %s -o wide" % n],
				["details + conditions", "kubectl describe node %s" % n],
				["pods on this island", "kubectl get pods -A --field-selector spec.nodeName=%s" % n],
				["drain it", "kubectl drain %s --ignore-daemonsets" % n],
			]
	return []


## Splits a command line into arguments (quotes supported, no shell).
static func split_args(line: String) -> PackedStringArray:
	var out := PackedStringArray()
	var cur := ""
	var quote := ""
	var in_arg := false
	for ch in line:
		if quote != "":
			if ch == quote:
				quote = ""
			else:
				cur += ch
		elif ch == "'" or ch == "\"":
			quote = ch
			in_arg = true
		elif ch == " " or ch == "\t":
			if in_arg:
				out.append(cur)
				cur = ""
				in_arg = false
		else:
			cur += ch
			in_arg = true
	if in_arg:
		out.append(cur)
	if out.size() > 0 and out[0] == "kubectl":
		out.remove_at(0)
	return out


## Parsed command: {verb, pos: [positional args], ns, all_ns, flags: {name: value}}
static func parse(line: String) -> Dictionary:
	var args := split_args(line)
	var cmd := {"verb": "", "pos": [], "ns": "", "all_ns": false, "flags": {}}
	var i := 0
	while i < args.size():
		var a: String = args[i]
		if a == "-n" or a == "--namespace":
			i += 1
			cmd.ns = args[i] if i < args.size() else ""
		elif a.begins_with("--namespace="):
			cmd.ns = a.substr(12)
		elif a == "-A" or a == "--all-namespaces":
			cmd.all_ns = true
		elif a.begins_with("--") and a.contains("="):
			var kv := a.substr(2).split("=", true, 1)
			cmd.flags[kv[0]] = kv[1]
		elif a.begins_with("-") and a.length() > 1:
			var name := a.lstrip("-")
			# Flags that take a value as the next argument
			if name in ["o", "output", "l", "selector", "replicas", "image", "c", "container", "tail", "port"] and i + 1 < args.size():
				i += 1
				cmd.flags[name] = args[i]
			else:
				cmd.flags[name] = "true"
		elif cmd.verb == "":
			cmd.verb = a
		else:
			cmd.pos.append(a)
		i += 1
	return cmd


const KIND_ALIASES := {"deployment": "Deployment", "deployments": "Deployment", "deploy": "Deployment",
	"statefulset": "StatefulSet", "statefulsets": "StatefulSet", "sts": "StatefulSet",
	"daemonset": "DaemonSet", "daemonsets": "DaemonSet", "ds": "DaemonSet"}


## "deployment/x" or ["deployment", "x"] -> [Kind, name]
static func kind_name(pos: Array) -> Array:
	if pos.is_empty():
		return ["", ""]
	var first: String = pos[0]
	if first.contains("/"):
		var p := first.split("/", true, 1)
		return [KIND_ALIASES.get(p[0].to_lower(), ""), p[1]]
	if pos.size() > 1:
		return [KIND_ALIASES.get(first.to_lower(), first), pos[1]]
	return ["", first]


## The game action equivalent to a mutating kubectl command, or {} if none.
## Used so terminal commands count for missions (and to run them in demo).
static func to_action(line: String, default_ns := "default") -> Dictionary:
	var c := parse(line)
	var ns: String = c.ns if c.ns != "" else default_ns
	var pos: Array = c.pos
	match c.verb:
		"scale":
			var kn := kind_name(pos)
			var r = c.flags.get("replicas", "")
			if kn[0] != "" and str(r).is_valid_int():
				return {"action": "scale", "kind": kn[0], "ns": ns, "name": kn[1], "replicas": int(r)}
		"delete":
			if pos.size() >= 2 and pos[0] in ["pod", "pods", "po"]:
				return {"action": "delete_pod", "ns": ns, "name": pos[1]}
			if pos.size() == 1 and (pos[0].begins_with("pod/") or pos[0].begins_with("po/")):
				return {"action": "delete_pod", "ns": ns, "name": pos[0].split("/")[1]}
			var kn := kind_name(pos)
			if kn[0] in ["Deployment", "StatefulSet", "DaemonSet"]:
				return {"action": "delete_workload", "kind": kn[0], "ns": ns, "name": kn[1]}
		"rollout":
			if pos.size() >= 2 and pos[0] == "restart":
				var kn := kind_name(pos.slice(1))
				if kn[0] != "":
					return {"action": "restart", "kind": kn[0], "ns": ns, "name": kn[1]}
		"cordon", "uncordon":
			if pos.size() >= 1:
				return {"action": c.verb, "name": pos[0]}
		"create":
			if pos.size() >= 2 and pos[0] in ["deployment", "deploy"]:
				return {"action": "create_deployment", "ns": ns, "name": pos[1],
					"image": c.flags.get("image", "nginx:alpine"), "replicas": int(c.flags.get("replicas", "1"))}
	return {}
