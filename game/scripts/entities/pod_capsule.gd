class_name PodCapsule
extends Entity
## A container inside the pod tank: a glass capsule anchored to the sand.
##   inner column  the app (its colour comes from the image name)
##   water level   memory in use against its limit (or request)
##   propeller     spins with CPU use
##   lamp          green running+ready, yellow waiting / not ready, red crash
##   heartbeat     a ring pulsing at the probe period (red when not ready)
##   red chips     one per restart (up to 8)
## Init containers are smaller and sealed; finished ones go grey.

const R := 1.15
const H := 3.4

var init := false
var pod_ns := ""
var pod_name := ""
var _geo: Node3D
var _glass: StandardMaterial3D
var _level: MeshInstance3D
var _prop: Node3D
var _lamp: MeshInstance3D
var _ring: MeshInstance3D
var _chips: Node3D
var _t := 0.0
var _period := 0.0


func _init() -> void:
	kind = "container"


func setup(c: Dictionary, ns: String, pod: String, is_init: bool) -> void:
	pod_ns = ns
	pod_name = pod
	init = is_init
	key = "%s/%s/%s" % [ns, pod, c.name]
	data = c.duplicate()
	data["ns"] = ns
	data["pod"] = pod
	data["init"] = is_init
	if _geo == null:
		_build()
	_refresh()


func _build() -> void:
	var sc := 0.62 if init and not data.get("sidecar", false) else 1.0
	scale = Vector3.ONE * sc
	_geo = Node3D.new()
	add_child(_geo)
	# Anchor block and pedestal.
	Vox.box(_geo, Vector3(3.0, 0.5, 3.0), Vector3(0, 0.25, 0), Vox.SLATE)
	Vox.box(_geo, Vector3(2.6, 0.25, 2.6), Vector3(0, 0.62, 0), Vox.SILVER)
	# The app: a column coloured by its image.
	var col: Color = Vox.NS_COLORS[absi(str(data.get("image", "")).get_slice(":", 0).hash()) % Vox.NS_COLORS.size()]
	Vox.box(_geo, Vector3(0.9, H * 0.8, 0.9), Vector3(0, 0.75 + H * 0.4, 0), col, 0.4)
	# Memory "water" rising inside the glass.
	_level = Vox.box(_geo, Vector3(1.6, 1.0, 1.6), Vector3(0, 0.75, 0), Vox.GREEN, 1.2, false)
	# Glass shell.
	_glass = StandardMaterial3D.new()
	_glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glass.albedo_color = Color(0.75, 0.95, 1.0, 0.22)
	_glass.cull_mode = BaseMaterial3D.CULL_DISABLED
	var cyl := CylinderMesh.new()
	cyl.top_radius = R
	cyl.bottom_radius = R
	cyl.height = H
	cyl.radial_segments = 10
	var shell := MeshInstance3D.new()
	shell.mesh = cyl
	shell.material_override = _glass
	shell.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	shell.position = Vector3(0, 0.75 + H * 0.5, 0)
	_geo.add_child(shell)
	# Brass bands and a cap.
	for y in [0.8, 0.75 + H]:
		Vox.box(_geo, Vector3(2.5, 0.22, 2.5), Vector3(0, y, 0), Vox.ORANGE, 0.3)
	if init and not data.get("sidecar", false):
		Vox.box(_geo, Vector3(2.2, 0.5, 2.2), Vector3(0, 1.0 + H, 0), Vox.SLATE)  # sealed lid
	else:
		_prop = Node3D.new()
		_prop.position = Vector3(0, 1.25 + H, 0)
		_geo.add_child(_prop)
		Vox.box(_prop, Vector3(0.3, 0.5, 0.3), Vector3.ZERO, Vox.SILVER)
		for a in 3:
			var blade := Vox.box(_prop, Vector3(1.3, 0.08, 0.35), Vector3(0.65, 0.2, 0), Vox.SILVER)
			blade.position = Vector3(0.65, 0.2, 0).rotated(Vector3.UP, a * TAU / 3.0)
			blade.rotation.y = a * TAU / 3.0
	_lamp = Vox.box(_geo, Vector3(0.45, 0.45, 0.45), Vector3(1.05, 0.95, 1.05), Vox.GREEN, 3.0, false)
	var torus := TorusMesh.new()
	torus.inner_radius = R + 0.15
	torus.outer_radius = R + 0.35
	_ring = MeshInstance3D.new()
	_ring.mesh = torus
	_ring.position = Vector3(0, 0.75 + H * 0.5, 0)
	_ring.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_geo.add_child(_ring)
	_chips = Node3D.new()
	_geo.add_child(_chips)


func _refresh() -> void:
	var st := state()
	var col: Color = {"ok": Vox.GREEN, "warn": Vox.YELLOW, "bad": Vox.RED, "done": Vox.SLATE}[st]
	_lamp.material_override = Vox.mat(col, 3.0, false)
	# Memory against the limit (or the request when there is no limit).
	var cap := float(data.get("mem_lim", 0)) if float(data.get("mem_lim", 0)) > 0.0 else float(data.get("mem_req", 0)) * 2.0
	var f := clampf(float(data.get("mem_use", 0)) / cap, 0.03, 1.0) if cap > 0.0 else 0.08
	if st == "done":
		f = 0.03
	var mcol := Vox.GREEN if f < 0.7 else (Vox.YELLOW if f < 0.9 else Vox.RED)
	_level.scale = Vector3(1, maxf(0.05, f * H), 1)
	_level.position.y = 0.75 + f * H * 0.5
	_level.material_override = Vox.mat(mcol, 1.2, false)
	_glass.albedo_color = Color(0.75, 0.95, 1.0, 0.22) if st != "bad" else Color(1.0, 0.5, 0.55, 0.28)
	# Heartbeat at the fastest probe period; none = no ring.
	var probes: Array = data.get("probes", []) if data.get("probes") != null else []
	_ring.visible = not probes.is_empty() and st != "done"
	_period = 0.0
	for p in probes:
		var per := float(p.get("period", 10))
		_period = per if _period == 0.0 else minf(_period, per)
	_ring.material_override = Vox.mat(Vox.GREEN if data.get("ready", false) else Vox.RED, 2.0, false)
	for c in _chips.get_children():
		c.queue_free()
	for i in mini(int(data.get("restarts", 0)), 8):
		Vox.box(_chips, Vector3(0.4, 0.14, 0.4), Vector3(-1.1, 0.58 + i * 0.16, 1.1), Vox.RED, 1.0)


## ok | warn | bad | done
func state() -> String:
	var s := str(data.get("state", ""))
	var reason := str(data.get("reason", ""))
	if s == "terminated":
		return "done" if int(data.get("exit_code", 0)) == 0 else "bad"
	if s == "waiting":
		return "bad" if reason in ["CrashLoopBackOff", "ErrImagePull", "ImagePullBackOff", "CreateContainerConfigError", "InvalidImageName", "RunContainerError"] else "warn"
	if s == "running":
		return "ok" if data.get("ready", false) or init else "warn"
	return "warn"


func _process(delta: float) -> void:
	_t += delta
	if _prop:
		var lim := float(data.get("cpu_lim_m", 0)) if float(data.get("cpu_lim_m", 0)) > 0.0 else maxf(100.0, float(data.get("cpu_req_m", 0)) * 2.0)
		var spin := 0.0 if state() in ["done", "bad"] else 1.0 + 14.0 * clampf(float(data.get("cpu_use_m", 0)) / lim, 0.0, 1.0)
		_prop.rotation.y += delta * spin
	if _ring and _ring.visible and _period > 0.0:
		# A quick pulse every probe period (sped up x4 so it is visible).
		var ph := fmod(_t, _period / 4.0) / (_period / 4.0)
		var s := 1.0 + 0.25 * maxf(0.0, 1.0 - ph * 4.0)
		_ring.scale = Vector3(s, 1, s)


## Where bubbles and log lines leave the capsule.
func top() -> Vector3:
	return global_position + Vector3(0, (1.6 + H) * scale.y, 0)


func label_text() -> String:
	var what := tr("INIT CONTAINER") if init and not data.get("sidecar", false) else (tr("SIDECAR") if data.get("sidecar", false) else tr("CONTAINER"))
	return "%s  %s" % [what, data.get("name", "")]


## Small signs on each part of the capsule, so you can tell what is what.
func callouts() -> Array:
	var out := []
	var s := scale.x
	var p := global_position
	var st := state()
	if _prop and st != "done":
		out.append({"pos": p + Vector3(1.9, (1.3 + H) * s, 0), "text": tr("CPU %s") % Vox.fmt_cores(float(data.get("cpu_use_m", 0))), "color": Vox.SILVER})
	if st != "done":
		var cap := float(data.get("mem_lim", 0))
		var mem := tr("MEM %s") % Vox.fmt_mib(float(data.get("mem_use", 0)))
		if cap > 0.0:
			mem += " / " + Vox.fmt_mib(cap)
		out.append({"pos": p + Vector3(-2.0, (0.9 + H * 0.3) * s, 0), "text": mem, "color": _level.material_override.albedo_color if _level and _level.material_override else Vox.GREEN})
	if _ring and _ring.visible:
		out.append({"pos": p + Vector3(2.1, (0.75 + H * 0.5) * s, 0), "text": tr("probes OK") if data.get("ready", false) else tr("probes FAILING"), "color": Vox.GREEN if data.get("ready", false) else Vox.RED})
	if int(data.get("restarts", 0)) > 0:
		out.append({"pos": p + Vector3(-2.0, 0.4 * s, 1.2), "text": tr("%d restarts") % int(data.restarts), "color": Vox.RED})
	return out


func label_sub() -> String:
	var st := state()
	var parts := []
	match str(data.get("state", "")):
		"running": parts.append(tr("running") + ("" if data.get("ready", false) or init else " · " + tr("not ready")))
		"terminated": parts.append("%s (exit %d)" % [data.get("reason", tr("finished")), int(data.get("exit_code", 0))])
		_: parts.append(str(data.get("reason", tr("waiting"))))
	if st != "done" and float(data.get("mem_use", 0)) > 0.0:
		parts.append("%s CPU · %s" % [Vox.fmt_cores(float(data.cpu_use_m)), Vox.fmt_mib(float(data.mem_use))])
	if int(data.get("restarts", 0)) > 0:
		parts.append(tr("%d restarts") % int(data.restarts))
	return "  ·  ".join(parts)


func label_color() -> Color:
	return {"ok": Vox.GREEN, "warn": Vox.YELLOW, "bad": Vox.RED, "done": Vox.SILVER}[state()]


func anchor() -> Vector3:
	return global_position + Vector3(0, (2.6 + H) * scale.y, 0)


func pick_radius() -> float:
	return 40.0
