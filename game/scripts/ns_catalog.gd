class_name NsCatalog
extends RefCounted
## Recognises well-known namespaces (Kubernetes itself, platform tools,
## observability, typical app names) so the plant can group them into
## districts and give their halls a distinct shape and a pixel logo.
## Logos are simple generic pictograms, not the projects' trademarks.

# District order, west to east. "apps" is the user's own namespaces.
const DISTRICTS := ["system", "apps", "platform", "observe"]
const DISTRICT_INFO := {
	"system": {"title": "KUBERNETES QUARTER", "sub": "the cluster's own namespaces", "color": Color("5b6ee1"), "ground": Color("4a5068")},
	"apps": {"title": "YOUR APPS", "sub": "your namespaces", "color": Color("00e436"), "ground": Color("4a5a3a")},
	"platform": {"title": "PLATFORM PARK", "sub": "GitOps, secrets, certificates, ingress", "color": Color("ff77a8"), "ground": Color("5a4a62")},
	"observe": {"title": "OBSERVATORY HILL", "sub": "metrics, dashboards, logs", "color": Color("ffa300"), "ground": Color("3f5a5a")},
}

# [patterns (substring of the name), district, style, logo, tag]
# First match wins, so the specific ones go before the generic ones.
const RULES := [
	[["kube-system"], "system", "castle", "helm", "Kubernetes core"],
	[["kube-public", "kube-node-lease"], "system", "castle", "helm", "Kubernetes"],
	[["default"], "system", "factory", "helm", "default namespace"],
	[["local-path-storage", "kube-flannel", "calico", "cilium", "tigera", "metallb", "kube-proxy", "coredns"], "system", "castle", "helm", "cluster networking/storage"],
	[["argo-workflows", "argo-events", "workflows"], "platform", "tower", "octopus", "workflows"],
	[["argocd", "argo-cd", "argo", "gitops", "flux"], "platform", "tower", "octopus", "GitOps"],
	[["kubefirst", "konstruct"], "platform", "crane", "rocket", "platform builder"],
	[["vault", "external-secrets", "sealed-secrets", "secrets"], "platform", "vault", "key", "secrets"],
	[["cert-manager", "certs"], "platform", "factory", "lock", "certificates"],
	[["ingress", "nginx", "traefik", "gateway", "istio", "linkerd", "envoy", "contour", "kong"], "platform", "gatehouse", "arrows", "ingress / mesh"],
	[["external-dns", "dns"], "platform", "factory", "globe", "DNS"],
	[["crossplane", "terraform", "atlantis"], "platform", "crane", "cube", "infrastructure"],
	[["kyverno", "gatekeeper", "policy", "falco", "trivy", "security"], "platform", "castle", "shield", "policy / security"],
	[["velero", "backup"], "platform", "silo", "disk", "backups"],
	[["tekton", "jenkins", "gitlab", "runner", "actions", "ci", "cd"], "platform", "crane", "gear", "CI/CD"],
	[["grafana"], "observe", "screens", "spiral", "dashboards"],
	[["prometheus", "monitoring", "metrics", "thanos", "victoria", "mimir"], "observe", "dome", "flame", "metrics"],
	[["elastic", "opensearch", "kibana", "logging", "logs", "loki", "fluent", "vector"], "observe", "library", "search", "logs / search"],
	[["jaeger", "tempo", "otel", "opentelemetry", "tracing", "datadog", "newrelic"], "observe", "dome", "eye", "tracing"],
	[["shop", "store", "cart", "checkout", "catalog", "ecommerce"], "apps", "shop", "cart", "shop"],
	[["payment", "billing", "bank", "ledger", "wallet", "finance"], "apps", "bank", "coin", "payments"],
	[["postgres", "mysql", "mariadb", "mongo", "redis", "cassandra", "database", "db", "data", "kafka", "rabbit", "minio"], "apps", "silo", "db", "data"],
	[["ml", "ai", "gpu", "training", "kubeflow", "llm"], "apps", "factory", "brain", "machine learning"],
	[["auth", "keycloak", "dex", "identity", "sso"], "apps", "castle", "key", "identity"],
]

## 7x7 pictograms. One char per pixel: "." = empty, letters = palette below.
const LOGOS := {
	"helm": [".b.b.b.", "..bbb..", "bbwwwbb", ".bwbwb.", "bbwwwbb", "..bbb..", ".b.b.b."],
	"octopus": ["..ooo..", ".owowo.", ".ooooo.", "..ooo..", ".o.o.o.", "o.o.o.o", "......."],
	"rocket": ["...w...", "..wbw..", "..wbw..", "..www..", ".rwwwr.", ".r.y.r.", "...y..."],
	"key": [".yyy...", "y...y..", "y...y..", ".yyy...", "...y...", "...yy..", "...y..."],
	"lock": ["..sss..", ".s...s.", ".s...s.", "yyyyyyy", "yyykyyy", "yyykyyy", "yyyyyyy"],
	"arrows": ["...g...", "..ggg..", ".g.g.g.", "...g...", "...g...", ".ggggg.", "......."],
	"globe": ["..bbb..", ".bgbgb.", "bggbggb", "bbbbbbb", "bggbggb", ".bgbgb.", "..bbb.."],
	"cube": ["..ppp..", ".pwwwp.", "pwwwwwp", "ppwwwpp", "pppbppp", ".ppbpp.", "..ppp.."],
	"shield": ["bbbbbbb", "bwwwwwb", "bwwgwwb", "bwgggwb", ".bwgwb.", "..bwb..", "...b..."],
	"disk": [".sssss.", "sskkkss", "sskkkss", "sssssss", "swwwwws", "swwwwws", "sssssss"],
	"gear": ["..s.s..", ".sssss.", "sss.sss", "ss...ss", "sss.sss", ".sssss.", "..s.s.."],
	"spiral": [".ooooo.", "o.....o", "o.ooo.o", "o.o.o.o", "o.o...o", "o.ooooo", "......."],
	"flame": ["...r...", "..rr...", "..rrr..", ".rroor.", ".royor.", ".royyr.", "..rrr.."],
	"search": [".www...", "w...w..", "w...w..", "w...w..", ".www...", "....yy.", ".....yy"],
	"eye": ["..www..", ".wwwww.", "wwbkbww", "wwkkkww", "wwbkbww", ".wwwww.", "..www.."],
	"cart": ["y......", ".yyyyyy", ".y.y.y.", ".yyyyy.", ".y.....", ".yyyyy.", "..k..k."],
	"coin": ["..yyy..", ".yyyyy.", "yy.y.yy", "yyy.yyy", "yy.y.yy", ".yyyyy.", "..yyy.."],
	"db": [".sssss.", "swwwwws", ".sssss.", "swwwwws", ".sssss.", "swwwwws", ".sssss."],
	"brain": [".pp.pp.", "pwppwpp", "ppwppwp", "pwppwpp", "ppwppwp", ".pp.pp.", "...s..."],
}
const LOGO_PAL := {
	"b": Color("29adff"), "w": Color("fff1e8"), "o": Color("ff9d3c"), "r": Color("ff004d"), "y": Color("ffec27"),
	"g": Color("00e436"), "p": Color("83769c"), "s": Color("c2c3c7"), "k": Color("1d2b53"),
}

static var _cache := {}


## {district, style, logo, tag} for a namespace name.
static func info(ns: String) -> Dictionary:
	if _cache.has(ns):
		return _cache[ns]
	var out := {"district": "apps", "style": "factory", "logo": "", "tag": ""}
	var n := ns.to_lower()
	for r in RULES:
		for pat in r[0]:
			if _matches(n, pat):
				out = {"district": r[1], "style": r[2], "logo": r[3], "tag": r[4]}
				_cache[ns] = out
				return out
	_cache[ns] = out
	return out


## Short patterns ("ci", "db", "ai", "ml") only match a whole word of the
## name, so "circle" or "gaia" don't become CI or AI.
static func _matches(n: String, pat: String) -> bool:
	if pat.length() > 3:
		return n.contains(pat)
	for part in n.split("-", false):
		if part == pat:
			return true
	return n == pat


static func district_of(ns: String) -> String:
	return info(ns).district
