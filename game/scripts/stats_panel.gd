class_name StatsPanel
extends PanelContainer
## F3 overlay: game performance (FPS, RAM, VRAM, draw calls, GPU) and cluster
## capacity/usage (metrics-server when available, otherwise pod requests).

var _text: RichTextLabel
var _t := 0.0

# Process memory/CPU. Godot's own counter only works in debug builds, so
# release builds ask the OS (ps on macOS/Linux) or the browser (JS heap).
static var proc_rss := 0.0
static var proc_cpu := -1.0
static var _probe_t := 99.0


func setup(rich: RichTextLabel) -> void:
	_text = rich
	add_child(_text)


static func bar(frac: float, width := 16) -> String:
	frac = clampf(frac, 0.0, 1.0)
	var n := roundi(frac * width)
	var col := "#00e436" if frac < 0.6 else ("#ffec27" if frac < 0.85 else "#ff004d")
	return "[color=%s]%s[/color][color=#3a3f55]%s[/color] %3d%%" % [col, "|".repeat(n), "|".repeat(width - n), roundi(frac * 100)]


## Samples process memory (and CPU on unix) at most every 2 s.
static func probe(delta: float) -> void:
	_probe_t += delta
	if _probe_t < 2.0:
		return
	_probe_t = 0.0
	if OS.is_debug_build() and OS.get_static_memory_usage() > 0:
		proc_rss = OS.get_static_memory_usage()
	if OS.has_feature("web"):
		# WASM linear memory captured by a tiny script in the page (see
		# export_presets.cfg head_include), plus the JS heap when available.
		var v = JavaScriptBridge.eval("(window.__kcMem ? window.__kcMem.buffer.byteLength : 0) + (performance.memory ? performance.memory.usedJSHeapSize : 0)", true)
		if v != null and float(v) > 0:
			proc_rss = float(v)
		return
	if OS.get_name() in ["macOS", "Linux", "FreeBSD"]:
		var out := []
		if OS.execute("ps", ["-o", "rss=,%cpu=", "-p", str(OS.get_process_id())], out) == 0 and out.size() > 0:
			var parts := str(out[0]).strip_edges().split(" ", false)
			if parts.size() >= 2:
				proc_rss = float(parts[0]) * 1024.0
				proc_cpu = float(parts[1])


## One-line summary for the always-visible readout.
static func summary() -> String:
	var s := "%d fps" % Engine.get_frames_per_second()
	if proc_rss > 0:
		s += "  RAM %s" % mib(proc_rss)
	s += "  VRAM %s" % mib(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))
	return s


static func mib(b: float) -> String:
	if b >= 1024.0 * 1024 * 1024:
		return "%.1f GiB" % (b / (1024.0 * 1024 * 1024))
	return "%d MiB" % roundi(b / (1024.0 * 1024))


static func cores(m: float) -> String:
	return "%dm" % roundi(m) if m < 1000 else "%.1f" % (m / 1000.0)


func _process(delta: float) -> void:
	probe(delta)
	_t += delta
	if not visible or _t < 0.5:
		return
	_t = 0.0
	var L := PackedStringArray()
	var k := func(s): return "[color=#c2c3c7]%s[/color]" % tr(s).rpad(11)
	# ---- game
	L.append("[color=#83769c]%s[/color]" % tr("GAME"))
	var fps := Engine.get_frames_per_second()
	L.append("%s %d  (%.1f ms)" % [k.call("fps"), fps, Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0])
	var mi := OS.get_memory_info()
	var sys_ram := float(mi.get("physical", 0))
	L.append("%s %s%s" % [k.call("RAM"), mib(proc_rss) if proc_rss > 0 else "n/a", ("  (%s %s)" % [tr("system"), mib(sys_ram)]) if sys_ram > 0 else ""])
	if proc_cpu >= 0:
		L.append("%s %.0f%%" % [k.call("process CPU"), proc_cpu])
	L.append("%s %s" % [k.call("VRAM"), mib(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED))])
	L.append("%s %d  %s %d" % [k.call("draw calls"), Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		tr("objects"), Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	L.append("%s %s" % [k.call("GPU"), RenderingServer.get_video_adapter_name()])
	L.append("%s %s %s" % [k.call("renderer"), RenderingServer.get_video_adapter_vendor(), RenderingServer.get_video_adapter_api_version()])
	L.append("%s %s, %s %d" % [k.call("textures"), mib(Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED)),
		tr("primitives"), Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME)])
	# ---- cluster
	var s: Dictionary = K8s.state
	if not s.is_empty():
		var m = s.get("metrics", {})
		var live: bool = m != null and m.get("available", false)
		L.append("")
		L.append("[color=#83769c]%s[/color]  [color=#5f574f](%s)[/color]" % [tr("CLUSTER"), tr("live usage, metrics-server") if live else tr("reserved by pod requests")])
		var cap_cpu := 0.0
		var cap_mem := 0.0
		var use_cpu := 0.0
		var use_mem := 0.0
		var per_node := {}
		for n in s.nodes:
			cap_cpu += float(n.get("cpu_m", 0))
			cap_mem += float(n.get("mem_bytes", 0))
			per_node[n.name] = {"cpu": 0.0, "mem": 0.0, "pods": 0, "cap": n}
		for p in s.pods:
			if per_node.has(p.get("node", "")):
				per_node[p.node].pods += 1
				if not live:
					per_node[p.node].cpu += float(p.get("cpu_req_m", 0))
					per_node[p.node].mem += float(p.get("mem_req", 0))
		if live:
			for nn in m.nodes:
				if per_node.has(nn):
					per_node[nn].cpu = float(m.nodes[nn].cpu_m)
					per_node[nn].mem = float(m.nodes[nn].mem_bytes)
		for nn in per_node:
			use_cpu += per_node[nn].cpu
			use_mem += per_node[nn].mem
		L.append("%s %s  %s / %s" % [k.call("CPU"), bar(use_cpu / maxf(cap_cpu, 1.0)), cores(use_cpu), cores(cap_cpu)])
		L.append("%s %s  %s / %s" % [k.call("memory"), bar(use_mem / maxf(cap_mem, 1.0)), mib(use_mem), mib(cap_mem)])
		var running: int = s.pods.filter(func(p): return p.status == "Running").size()
		L.append("%s %d / %d   %s %d   %s %d" % [k.call("pods"), running, s.pods.size(), tr("namespaces"), s.namespaces.size(), tr("services"), s.services.size()])
		for nn in per_node:
			var pn: Dictionary = per_node[nn]
			L.append("[color=#ffec27]%s[/color]  %s %d/%d" % [nn, tr("pods"), pn.pods, int(pn.cap.get("pod_capacity", 110))])
			L.append("  cpu %s   mem %s" % [bar(pn.cpu / maxf(float(pn.cap.get("cpu_m", 1)), 1.0), 8), bar(pn.mem / maxf(float(pn.cap.get("mem_bytes", 1)), 1.0), 8)])
		if live and not m.pods.is_empty():
			var top: Array = m.pods.keys()
			top.sort_custom(func(a, b): return m.pods[a].cpu_m > m.pods[b].cpu_m)
			L.append("[color=#83769c]%s[/color]" % tr("top pods by CPU"))
			for pk in top.slice(0, 3):
				var name: String = pk if pk.length() <= 30 else pk.left(29) + "~"
				L.append("  %s  %s  %s" % [cores(m.pods[pk].cpu_m).lpad(5), mib(m.pods[pk].mem_bytes).lpad(8), name])
		elif not live:
			L.append("[color=#5f574f]%s[/color]" % tr("tip: install metrics-server for live usage (make metrics-server)"))
	_text.text = "\n".join(L)
