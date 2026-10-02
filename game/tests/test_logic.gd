extends "res://tests/harness.gd"
## Headless checks of pure helpers (no world, no scene):
##   godot --headless --path game --script res://tests/test_logic.gd

## i18n: tr("...") literals with no Spanish entry that predate the check.
## Only NEW missing keys fail; shrink this list as they get translated.
const I18N_BASELINE := "res://tests/i18n_missing_baseline.txt"


## Counts its draws, to know the chart really drew (headless included).
class ChartProbe extends TrendChart:
	var drew := 0

	func _draw() -> void:
		super()
		drew += 1


func _init() -> void:
	_pod_categories()
	_gitops_dock()
	_rollouts()
	_trend_math()
	_search_kinds()
	_updates()
	_i18n()
	await _trend_draw()
	finish("logic tests")


func _pod_categories() -> void:
	var cases := [
		[{"status": "Running", "ready": 2, "total": 2}, "ok"],
		[{"status": "Running", "ready": 1, "total": 2}, "warn"],
		[{"status": "Running"}, "warn"],  # no ready count: not ready
		[{"status": "Running", "ready": 1, "total": 1, "deleting": true}, "term"],
		[{"status": "Terminating"}, "term"],
		[{"status": "CrashLoopBackOff"}, "crash"],
		[{"status": "OOMKilled"}, "crash"],
		[{"status": "Init:CrashLoopBackOff"}, "crash"],
		[{"status": "ImagePullBackOff"}, "pull"],
		[{"status": "Init:ErrImagePull"}, "pull"],
		[{"status": "Completed"}, "done"],
		[{"status": "Evicted"}, "failed"],
		[{"status": "Pending"}, "pending"],
		[{"status": "ContainerCreating"}, "pending"],
		[{}, "pending"],
	]
	for c in cases:
		var got := PodBot.categorize(c[0])
		check(got == c[1], "PodBot.categorize(%s) = %s, want %s" % [c[0], got, c[1]])
	for cat in ["ok", "warn", "pending", "crash", "pull", "done", "failed"]:
		check(PodBot.category_color(cat) != Vox.SLATE, "category %s has its own color" % cat)
	check(PodBot.category_color("term") == Vox.SLATE, "terminating pods are grey")


func _gitops_dock() -> void:
	check(GitOpsDock.what({"tool": "argocd"}) == "Argo CD app", "argo what")
	check(GitOpsDock.what({}) == "Argo CD app", "no tool = Argo CD")
	check(GitOpsDock.what({"tool": "flux"}) == "Flux Kustomization", "flux default kind")
	check(GitOpsDock.what({"tool": "flux", "kind": "HelmRelease"}) == "Flux HelmRelease", "flux helm release")
	check(GitOpsDock.tool_color({"tool": "flux"}) == GitOpsDock.FLUX, "flux color")
	check(GitOpsDock.tool_color({"tool": "argocd"}) == GitOpsDock.ARGO, "argo color")
	check(GitOpsDock.ARGO != GitOpsDock.FLUX, "tools look different")


func _rollouts() -> void:
	check(World.is_rolling({"kind": "Deployment", "desired": 3, "updated": 1}), "1/3 updated is rolling")
	check(World.is_rolling({"kind": "DaemonSet", "desired": 2, "updated": 0}), "daemonset rolling")
	check(not World.is_rolling({"kind": "Deployment", "desired": 3, "updated": 3}), "all updated")
	check(not World.is_rolling({"kind": "Deployment", "desired": 3}), "no updated count: not rolling")
	check(not World.is_rolling({"kind": "StatefulSet", "desired": 0, "updated": 0}), "scaled to zero")
	check(not World.is_rolling({"kind": "Job", "desired": 3, "updated": 0}), "only rollout kinds")
	check(not World.is_rolling({"kind": "Deployment", "desired": 2, "updated": 5}), "more updated than desired (scaling down)")


func _trend_math() -> void:
	var sq := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	check(is_equal_approx(TrendChart._area(sq), 100.0), "square area %f" % TrendChart._area(sq))
	sq.reverse()
	check(is_equal_approx(TrendChart._area(sq), -100.0), "clockwise area is negative")
	var flat := PackedVector2Array([Vector2(0, 5), Vector2(5, 5), Vector2(10, 5), Vector2(10, 5), Vector2(0, 5)])
	check(absf(TrendChart._area(flat)) <= 1.0, "a flat line has no area (no fill)")
	check(TrendChart._area(PackedVector2Array()) == 0.0, "empty polygon")
	check(TrendChart.fmt(0.25, "cores") == "250m", "cores " + TrendChart.fmt(0.25, "cores"))
	check(TrendChart.fmt(1.5, "cores") == "1.5", "cores " + TrendChart.fmt(1.5, "cores"))
	check(TrendChart.fmt(512.0 * 1048576.0, "bytes") == "512 MiB", "MiB")
	check(TrendChart.fmt(3.0 * 1073741824.0, "bytes") == "3.0 GiB", "GiB")
	check(TrendChart.fmt(7.9, "count") == "7", "count")
	check(TrendChart._mins(5) == "5 min" and TrendChart._mins(180) == "3 h", "minutes / hours")
	check(TrendChart.change_since([[0, 1.0], [60, 1.0], [120, 5.0]], "bytes") == 0.0, "too few points")
	var down := []
	for i in 10:
		down.append([i * 60.0, 10.0 - i])
	check(TrendChart.change_since(down, "bytes") == 0.0, "going down is not 'up since'")
	check(TrendChart.change_since(down, "count") == 0.0, "restarts never go down")


## A chart with flat-zero, NaN / Inf and single-point series must draw
## without script errors (make test-game fails on any SCRIPT ERROR). The
## headless renderer doesn't triangulate, so the "no fill for a flat line"
## guard is checked through _area above.
func _trend_draw() -> void:
	var chart := ChartProbe.new()
	chart.size = Vector2(320, 300)
	root.add_child(chart)
	var zero := []
	var noisy := []
	var climb := []
	for i in 30:
		zero.append([i * 60.0, 0.0])
		noisy.append([i * 60.0, NAN if i % 3 == 0 else (INF if i % 7 == 0 else float(i))])
		climb.append([i * 60.0, 100.0 if i < 20 else 100.0 + (i - 20) * 50.0])
	chart.set_rows([
		{"label": "cpu", "points": zero, "unit": "cores"},
		{"label": "mem", "points": noisy, "unit": "bytes"},
		{"label": "restarts", "points": [[0.0, NAN], [60.0, 1.0]], "unit": "count"},
		{"label": "leak", "points": climb, "unit": "bytes", "color": Color.RED},
	])
	check(chart.custom_minimum_size.y == 4 * TrendChart.ROW, "one row per series")
	await process_frame
	await process_frame
	check(chart.drew > 0, "the chart drew")
	var drawn := chart.drew
	chart.set_rows([], "no Prometheus")
	check(chart.custom_minimum_size.y == 34.0, "empty chart keeps a line for its message")
	await process_frame
	await process_frame
	check(chart.drew > drawn, "set_rows redraws")
	chart.queue_free()


func _search_kinds() -> void:
	var s := {"helm": [
			{"ns": "monitoring", "name": "kube-prometheus-stack", "chart": "kube-prometheus-stack-65.1.0", "status": "deployed", "revision": 7, "umbrella": true,
				"charts": [{"name": "kube-state-metrics", "version": "5.25.1"}, {"name": "grafana", "version": "8.5.0"}]},
			{"ns": "shop", "name": "redis", "chart": "", "status": "failed", "revision": 2, "charts": [{"name": "redis", "version": "17.3.2"}]}],
		"apps": [{"ns": "flux-system", "name": "apps", "tool": "flux", "kind": "Kustomization", "dest_ns": "", "sync": "Synced", "health": "Healthy"},
			{"ns": "argocd", "name": "payments", "dest_ns": "payments", "sync": "OutOfSync", "health": "Missing"}]}
	var h: Array = ClusterSearch.find(s, "grafana")
	check(h.size() == 1 and h[0].kind == "helm" and h[0].key == "monitoring/kube-prometheus-stack", "a subchart finds its release: %s" % [h])
	if h.size() == 1:
		check(str(h[0].detail).begins_with("umbrella helm release · kube-prometheus-stack-65.1.0 · rev 7"), "umbrella detail: " + str(h[0].detail))
	check(ClusterSearch.find(s, "kind:umbrella").size() == 2, "umbrella is an alias of helm")
	var bad: Array = ClusterSearch.find(s, "bad kind:release")
	check(bad.size() == 1 and bad[0].key == "shop/redis" and str(bad[0].detail).contains("1 charts"), "failed release is bad: %s" % [bad])
	var fx: Array = ClusterSearch.find(s, "kind:flux apps")
	check(fx.size() == 1 and fx[0].ns == "flux-system" and str(fx[0].detail).begins_with("Flux Kustomization"), "flux app with no dest ns: %s" % [fx])
	check(ClusterSearch.find(s, "kind:gitops bad").size() == 1, "a missing app is bad")
	check(ClusterSearch.find(s, "status:outofsync")[0].key == "argocd/payments", "status filter on apps")
	var q := ClusterSearch.parse("ns:shop  roto :x y:")
	check(q.filters == {"ns": "shop"} and q.bad and q.words == [":x", "y:"], "parse: %s" % [q])
	check(ClusterSearch.find({}, "   ").is_empty(), "an empty query finds nothing")
	check(ClusterSearch.find({"pods": null, "nodes": null}, "x").is_empty(), "null lists are empty")


func _updates() -> void:
	check(Updates.parse("v1.2.3+build.5") == ([1, 2, 3, 1] as Array[int]), "build metadata ignored")
	check(Updates.parse("1.2.3-rc.1") == ([1, 2, 3, 0] as Array[int]), "pre-release")
	check(Updates.parse("1.-2.3").is_empty() and Updates.parse(" ").is_empty(), "not versions")
	check(Updates.compare("dev", "1.0.0") == 0, "dev compares equal (no nagging)")
	check(not Updates.should_notify("v0.2.0", [] as Array[String], ""), "nothing behind")
	check(not Updates.should_notify("dev", ["bridge"] as Array[String], ""), "unknown latest")
	check(Updates.hints("nothing").is_empty(), "unknown target")
	check(Updates.hints("bridge").size() == 3 and not str(Updates.hints("bridge")[1].cmd).contains("allow-origin"), "bridge without origin")
	var long := "x".repeat(200)
	var sm := Updates.summary("<!-- hidden -->\n" + long, 8, 20)
	check(sm.length() == 20 and sm.ends_with("..."), "long lines are cut: " + sm)
	check(Updates.summary("a\nb\nc\nd", 2) == "a\nb", "max lines")


## Every tr("...") literal in the scripts that reads like text for people has
## a Spanish entry (I18n.ES or a mission's *_es fields).
func _i18n() -> void:
	# Read from the sources: i18n.gd and missions.gd use the Settings autoload,
	# and autoloads don't exist when Godot runs a --script.
	var lit := "\"((?:[^\"\\\\]|\\\\.)*)\""
	var known := {}
	var in_es := false
	var es_key := RegEx.create_from_string("^\\t" + lit + "\\s*:")
	for l in FileAccess.get_file_as_string("res://scripts/i18n.gd").split("\n"):
		if l.begins_with("const ES := {"):
			in_es = true
		elif in_es and l.begins_with("}"):
			break
		elif in_es:
			var m := es_key.search(l)
			if m:
				known[m.get_string(1).c_unescape()] = true
	var mission := RegEx.create_from_string("\"(?:title|goal|learn)\": " + lit)
	for m in mission.search_all(FileAccess.get_file_as_string("res://scripts/missions.gd")):
		known[m.get_string(1).c_unescape()] = true
	check(known.size() > 1000, "read I18n.ES (%d keys)" % known.size())
	var used := {}  # key -> "file:line" of its first use
	var re := RegEx.create_from_string("\\btr\\(" + lit)
	for path in _scripts("res://scripts"):
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			for m in re.search_all(lines[i]):
				var key := m.get_string(1).c_unescape()
				if not used.has(key):
					used[key] = "%s:%d" % [path.get_file(), i + 1]
	var baseline := {}
	for l in FileAccess.get_file_as_string(I18N_BASELINE).split("\n"):
		if l != "" and not l.begins_with("#"):
			baseline[l.c_unescape()] = true
	var missing := []
	var fixed := 0
	for key in used:
		if known.has(key) or not _reads_like_text(key):
			if baseline.has(key):
				fixed += 1
			continue
		if not baseline.has(key):
			missing.append(key)
			print("FAIL: no Spanish for tr(\"%s\") (%s): add it to I18n.ES" % [key.c_escape(), used[key]])
	fails += missing.size()
	check(used.size() > 100, "found the tr() calls (%d)" % used.size())
	print("i18n: %d tr() keys, %d still untranslated (baseline), %d new missing%s" % [used.size(), baseline.size() - fixed, missing.size(),
		(", %d baseline keys are done: remove them from %s" % [fixed, I18N_BASELINE.get_file()]) if fixed > 0 else ""])


## Text for people: has letters and is more than a symbol, unit or a name
## that reads the same in both languages ("CPU", "%s/%s", "kubectl").
static func _reads_like_text(s: String) -> bool:
	var letters := RegEx.create_from_string("[A-Za-z]{2,}")
	var plain := RegEx.create_from_string("%[-0-9.]*[sd]|\\{[a-z_]*\\}").sub(s, "", true)
	return plain.contains(" ") and letters.search(plain) != null


static func _scripts(dir: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") and f != "i18n.gd":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir.path_join(d)))
	return out
