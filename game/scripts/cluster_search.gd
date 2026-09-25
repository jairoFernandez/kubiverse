class_name ClusterSearch
## Global search over the cluster state: namespaces, pods, workloads,
## services, nodes and ingress hosts, by name, IP, image, status or node.
## Words must all match; filters narrow it down:
##   ns:shop  node:worker-a  status:crash  kind:pod|svc|deploy|node|ns|ing
##   image:redis  ip:10.244.  bad (only what's broken)
## index() turns a state into lowercase rows once; find_in() runs a query on
## them. Pure data in, data out, so the tests can run it.

const KINDS := {
	"pod": "pod", "pods": "pod", "po": "pod",
	"svc": "service", "service": "service", "services": "service",
	"deploy": "workload", "deployment": "workload", "workload": "workload", "sts": "workload",
	"statefulset": "workload", "ds": "workload", "daemonset": "workload",
	"node": "node", "nodes": "node", "no": "node",
	"ns": "namespace", "namespace": "namespace", "namespaces": "namespace",
	"ing": "ingress", "ingress": "ingress", "host": "ingress",
}
const ORDER := {"namespace": 0, "workload": 1, "service": 2, "pod": 3, "node": 4, "ingress": 5}
# Row layout (arrays are much cheaper than dictionaries here).
enum { KIND, NAME, HAY, NS, NODE, STATUS, IMAGE, IPS, BAD, SRC, RULE }


## Results, best first: {kind, key, ns, title, detail, bad, score}. "kind" and
## "key" are what the world's goto understands (an ingress host goes to the
## service behind it).
static func find(s: Dictionary, query: String, limit := 30) -> Array:
	return find_in(index(s), query, limit)


static func index(s: Dictionary) -> Array:
	var rows: Array = []
	for n in _list(s, "namespaces"):
		rows.append(["namespace", str(n.name).to_lower(), str(n.get("phase", "")).to_lower(), str(n.name).to_lower(), "", "", "", [], false, n, null])
	for n in _list(s, "nodes"):
		var roles: Array = n.roles if n.get("roles") != null else []
		rows.append(["node", str(n.name).to_lower(), ("%s %s %s %s" % [" ".join(roles), n.get("kubelet", ""), n.get("os", ""), n.get("arch", "")]).to_lower(),
			"", str(n.name).to_lower(), "", "", [], not bool(n.get("ready", false)), n, null])
	for w in _list(s, "workloads"):
		rows.append(["workload", str(w.name).to_lower(), ("%s %s %s" % [w.ns, w.kind, w.get("image", "")]).to_lower(), str(w.ns).to_lower(), "", "",
			str(w.get("image", "")).to_lower(), [], int(w.get("ready", 0)) < int(w.get("desired", 0)), w, null])
	for sv in _list(s, "services"):
		var ext: Array = sv.external if sv.get("external") != null else []
		var ports: Array = sv.ports if sv.get("ports") != null else []
		var ips: Array = [str(sv.get("cluster_ip", ""))] + ext
		rows.append(["service", str(sv.name).to_lower(), ("%s %s %s %s" % [sv.ns, sv.get("type", ""), " ".join(ports), " ".join(ips)]).to_lower(),
			str(sv.ns).to_lower(), "", "", "", ips, int(sv.get("ready", 0)) == 0 and sv.get("selector") != null, sv, null])
	for p in _list(s, "pods"):
		var images: Array = p.images if p.get("images") != null else []
		var img := " ".join(images).to_lower()
		var status := str(p.get("status", ""))
		rows.append(["pod", str(p.name).to_lower(), ("%s %s %s %s %s %s" % [p.ns, status, p.get("node", ""), p.get("ip", ""), p.get("owner_name", ""), img]).to_lower(),
			str(p.ns).to_lower(), str(p.get("node", "")).to_lower(), status.to_lower(), img, [str(p.get("ip", ""))], _pod_bad(p), p, null])
	for ing in _list(s, "ingresses"):
		var rules: Array = ing.rules if ing.get("rules") != null else []
		for r in rules:
			var host := str(r.get("host", "")) if str(r.get("host", "")) != "" else "*"
			rows.append(["ingress", host.to_lower(), ("%s %s %s %s" % [ing.ns, ing.name, r.get("path", ""), r.get("service", "")]).to_lower(),
				str(ing.ns).to_lower(), "", "", "", [], false, ing, r])
	return rows


static func find_in(rows: Array, query: String, limit := 30) -> Array:
	var q := parse(query)
	if q.words.is_empty() and q.filters.is_empty() and not q.bad:
		return []
	var f: Dictionary = q.filters
	var want_kind: String = KINDS.get(f.kind, f.kind) if f.has("kind") else ""
	# One int per hit, sorted natively: best score, then kind, then the
	# bridge's order (by name).
	var hits := PackedInt64Array()
	for i in rows.size():
		var r: Array = rows[i]
		if q.bad and not r[BAD]:
			continue
		if want_kind != "" and r[KIND] != want_kind:
			continue
		if f.has("ns") and r[NS].find(f.ns) < 0:
			continue
		if f.has("node") and r[NODE].find(f.node) < 0:
			continue
		if f.has("status") and r[STATUS].find(f.status) < 0:
			continue
		if f.has("image") and r[IMAGE].find(f.image) < 0:
			continue
		if f.has("ip") and not (r[IPS] as Array).any(func(ip): return str(ip).begins_with(f.ip)):
			continue
		var score := 1
		var name: String = r[NAME]
		for w in q.words:
			if name == w:
				score += 100
			elif name.begins_with(w):
				score += 60
			elif name.find(w) >= 0:
				score += 30
			elif r[HAY].find(w) >= 0:
				score += 10
			else:
				score = 0
				break
		if score > 0:
			hits.append((100000 - score) * 10000000000 + int(ORDER[r[KIND]]) * 100000000 + i)
	hits.sort()
	var out: Array = []
	for h in hits.slice(0, limit):
		var res := _result(rows[h % 100000000])
		res["score"] = 100000 - h / 10000000000
		out.append(res)
	return out


## What a row shows and where it leads.
static func _result(r: Array) -> Dictionary:
	var d: Dictionary = r[SRC]
	match r[KIND]:
		"namespace":
			return {"kind": "namespace", "key": d.name, "ns": d.name, "title": d.name, "detail": "namespace", "bad": false}
		"node":
			var roles: Array = d.roles if d.get("roles") != null else []
			return {"kind": "node", "key": d.name, "ns": "", "title": d.name, "bad": r[BAD],
				"detail": "node · %s%s" % [", ".join(roles) if not roles.is_empty() else "worker", " · NotReady" if r[BAD] else ""]}
		"workload":
			return {"kind": "workload", "key": "%s/%s/%s" % [d.ns, d.kind, d.name], "ns": d.ns, "title": "%s/%s" % [d.ns, d.name], "bad": r[BAD],
				"detail": "%s · %d/%d ready" % [str(d.kind).to_lower(), int(d.get("ready", 0)), int(d.get("desired", 0))]}
		"service":
			var ext: Array = d.external if d.get("external") != null else []
			return {"kind": "service", "key": "%s/%s" % [d.ns, d.name], "ns": d.ns, "title": "%s/%s" % [d.ns, d.name], "bad": r[BAD],
				"detail": "service %s · %s%s" % [d.get("type", ""), d.get("cluster_ip", ""), (" · " + ", ".join(ext)) if not ext.is_empty() else ""]}
		"pod":
			return {"kind": "pod", "key": "%s/%s" % [d.ns, d.name], "ns": d.ns, "title": "%s/%s" % [d.ns, d.name], "bad": r[BAD],
				"detail": "pod · %s · %d/%d%s%s" % [d.get("status", ""), int(d.get("ready", 0)), int(d.get("total", 0)),
					(" · " + str(d.ip)) if str(d.get("ip", "")) != "" else "", (" · " + str(d.node)) if str(d.get("node", "")) != "" else ""]}
	# ingress host: to the service behind it
	var rule: Dictionary = r[RULE]
	return {"kind": "service", "key": "%s/%s" % [d.ns, rule.get("service", "")], "ns": d.ns, "bad": false,
		"title": r[NAME] + str(rule.get("path", "")), "detail": "ingress %s → %s:%s" % [d.name, rule.get("service", ""), rule.get("port", "")]}


static func parse(query: String) -> Dictionary:
	var q := {"words": [], "filters": {}, "bad": false}
	for tok in query.to_lower().split(" ", false):
		var i := tok.find(":")
		if i > 0 and i < tok.length() - 1:
			q.filters[tok.substr(0, i)] = tok.substr(i + 1)
		elif tok in ["bad", "broken", "failing", "roto", "rotos"]:
			q.bad = true
		else:
			q.words.append(tok)
	return q


static func _pod_bad(p: Dictionary) -> bool:
	var st := str(p.get("status", ""))
	if st in ["Completed", "Succeeded"]:
		return false
	return st != "Running" or int(p.get("ready", 0)) < int(p.get("total", 0))


static func _list(s: Dictionary, k: String) -> Array:
	return s.get(k, []) if s.get(k) != null else []
