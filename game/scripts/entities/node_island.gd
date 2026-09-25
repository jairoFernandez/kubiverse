class_name NodeIsland
extends Entity
## A Kubernetes Node rendered as a floating voxel island. Its pods stand on
## a grid of slots; the island grows with the number of pods.

const SLOT := 2.0
const MARGIN := 5.0   # free walking ring around the pods

var cols := 3
var size := 0.0
var slots := {}  # pod key -> slot index
var _geo: Node3D
var _beacon: MeshInstance3D
var _sig := ""
var _t := 0.0
# Requested resources on this node (what the scheduler counts) vs allocatable.
var used_cpu := 0.0
var used_mem := 0.0
var _gauges := []   # [fill MeshInstance3D for cpu, for mem]


func _init() -> void:
	kind = "node"


func update_data(d: Dictionary, pod_count: int) -> void:
	data = d
	key = d.name
	var need := maxi(3, ceili(sqrt(float(maxi(pod_count, 1)))))
	var sig := "%d|%s|%s|%s|%s" % [need, d.ready, d.unschedulable, d.get("roles", []), Look.current]
	if sig != _sig:
		_sig = sig
		cols = need
		_rebuild()


func is_control_plane() -> bool:
	var roles: Array = data.get("roles", [])
	return roles.has("control-plane") or roles.has("master")


func assign_slot(pod_key: String) -> int:
	if slots.has(pod_key):
		return slots[pod_key]
	var used := {}
	for v in slots.values():
		used[v] = true
	var i := 0
	while used.has(i):
		i += 1
	slots[pod_key] = i
	return i


func release_slot(pod_key: String) -> void:
	slots.erase(pod_key)


func slot_position(i: int) -> Vector3:
	var c := i % cols
	var r := i / cols
	var off := (cols - 1) * SLOT * 0.5
	return global_position + Vector3(c * SLOT - off, 0, r * SLOT - off)


func is_area() -> bool:
	return true


func contains_xz(p: Vector3) -> bool:
	var l := p - global_position
	return absf(l.x) <= size * 0.5 and absf(l.z) <= size * 0.5


func anchor() -> Vector3:
	return global_position + Vector3(-size * 0.5 + 0.8, 3.4 if is_control_plane() else 2.0, -size * 0.5 + 0.8)


func label_text() -> String:
	return tr("node %s") % key


func set_usage(cpu_m: float, mem: float) -> void:
	used_cpu = cpu_m
	used_mem = mem


func cpu_frac() -> float:
	return used_cpu / maxf(float(data.get("cpu_m", 0)), 1.0)


func mem_frac() -> float:
	return used_mem / maxf(float(data.get("mem_bytes", 0)), 1.0)


func label_sub() -> String:
	var tags := [tr("%d pods") % slots.size()]
	if float(data.get("cpu_m", 0)) > 0:
		tags.append("cpu %s/%s" % [Vox.fmt_cores(used_cpu), Vox.fmt_cores(float(data.cpu_m))])
		tags.append("mem %s/%s" % [Vox.fmt_mib(used_mem), Vox.fmt_mib(float(data.get("mem_bytes", 0)))])
	if not data.get("ready", true):
		tags.append(tr("NOT READY"))
	if data.get("unschedulable", false):
		tags.append(tr("cordoned"))
	if is_control_plane():
		tags.append("control-plane")
	return ", ".join(tags)


func label_color() -> Color:
	if not data.get("ready", true):
		return Vox.RED
	if data.get("unschedulable", false):
		return Vox.YELLOW
	return Vox.GREEN


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	# Capacity gauges: fill = requested / allocatable, colour by pressure.
	for i in _gauges.size():
		var f := clampf(cpu_frac() if i == 0 else mem_frac(), 0.0, 1.0)
		var g: MeshInstance3D = _gauges[i]
		g.scale.y = maxf(0.02, f)
		g.position.y = 0.15 + 1.6 * g.scale.y * 0.5
		g.material_override = Vox.mat(Vox.GREEN if f < 0.6 else (Vox.YELLOW if f < 0.85 else Vox.RED), 1.5, false)
	if _beacon:
		_beacon.visible = fmod(_t, 1.0) < 0.5


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	_beacon = null
	size = cols * SLOT + MARGIN
	var s := size
	var ready: bool = data.get("ready", true)
	var grass: Color = Look.v("island") if ready else Color("8a7a55")
	var grass_dark: Color = Look.v("island_dark") if ready else Color("5f574f")
	var rng := Vox.rng_for(key)

	# Top soil + dirt + a tapering rocky underside.
	Vox.box(_geo, Vector3(s, 0.3, s), Vector3(0, -0.15, 0), grass)
	Vox.box(_geo, Vector3(s - 0.3, 0.9, s - 0.3), Vector3(0, -0.75, 0), Vox.BROWN)
	for i in 3:
		var w := s * (0.72 - i * 0.2)
		var d := s * (0.72 - i * 0.2) * rng.randf_range(0.7, 1.0)
		var off := Vector3(rng.randf_range(-0.6, 0.6), 0, rng.randf_range(-0.6, 0.6))
		Vox.box(_geo, Vector3(w, 0.8, d), Vector3(0, -1.6 - i * 0.8, 0) + off, Vox.SLATE if i % 2 == 0 else Color("4a4350"))

	# Checkerboard pod slots.
	var off2 := (cols - 1) * SLOT * 0.5
	for r in cols:
		for c in cols:
			if (r + c) % 2 == 0:
				Vox.box(_geo, Vector3(SLOT, 0.04, SLOT), Vector3(c * SLOT - off2, 0.0, r * SLOT - off2), grass_dark, 0.0, false)

	# Flowers and tufts along the rim.
	for i in cols * 3:
		var side := rng.randi() % 4
		var along := rng.randf_range(-s * 0.45, s * 0.45)
		var edge := s * 0.5 - rng.randf_range(0.25, 0.7)
		var p := Vector3(along, 0.1, edge)
		match side:
			1: p = Vector3(along, 0.1, -edge)
			2: p = Vector3(edge, 0.1, along)
			3: p = Vector3(-edge, 0.1, along)
		var col: Color = [Vox.YELLOW, Vox.PINK, Vox.WHITE, Vox.FOREST][rng.randi() % 4] if ready else Vox.SLATE
		Vox.box(_geo, Vector3(0.18, 0.2, 0.18), p, col, 0.0, false)

	var corner := Vector3(-s * 0.5 + 0.8, 0, -s * 0.5 + 0.8)
	if is_control_plane():
		# Castle tower with a Kubernetes-blue flag.
		Vox.box(_geo, Vector3(1.1, 2.6, 1.1), corner + Vector3(0, 1.3, 0), Vox.SILVER)
		for dx in [-0.4, 0.4]:
			for dz in [-0.4, 0.4]:
				Vox.box(_geo, Vector3(0.3, 0.35, 0.3), corner + Vector3(dx, 2.78, dz), Vox.SILVER)
		Vox.box(_geo, Vector3(0.1, 1.2, 0.1), corner + Vector3(0, 3.2, 0), Vox.SLATE)
		Vox.box(_geo, Vector3(0.7, 0.45, 0.06), corner + Vector3(0.38, 3.55, 0), Vox.BLUE, 0.4)
		Vox.box(_geo, Vector3(0.4, 0.5, 0.06), corner + Vector3(0, 1.4, 0.56), Vox.NAVY, 0.0, false)
		if not ready:
			_beacon = Vox.box(_geo, Vector3(0.35, 0.35, 0.35), corner + Vector3(0, 4.0, 0), Vox.RED, 3.0)
	else:
		# Server rack hut with blinking LEDs.
		Vox.box(_geo, Vector3(1.0, 1.4, 0.9), corner + Vector3(0, 0.7, 0), Vox.NAVY)
		for i in 4:
			Vox.box(_geo, Vector3(0.12, 0.08, 0.04), corner + Vector3(-0.25 + (i % 2) * 0.2, 0.4 + i * 0.25, 0.46), Vox.GREEN if ready else Vox.RED, 2.0, false)
		if not ready:
			_beacon = Vox.box(_geo, Vector3(0.35, 0.35, 0.35), corner + Vector3(0, 1.8, 0), Vox.RED, 3.0)

	# Two capacity gauges (CPU, memory) beside the tower / rack.
	_gauges.clear()
	for gi in 2:
		var gp := corner + Vector3(1.2 + gi * 0.55, 0, 0)
		Vox.box(_geo, Vector3(0.42, 1.9, 0.42), gp + Vector3(0, 0.95, 0), Color("20243a"))
		var fill := MeshInstance3D.new()
		fill.mesh = Vox.box_mesh(Vector3(0.3, 1.6, 0.44))
		fill.position = gp + Vector3(0, 0.15, 0)
		fill.material_override = Vox.mat(Vox.GREEN, 1.5, false)
		_geo.add_child(fill)
		_gauges.append(fill)
		Vox.box(_geo, Vector3(0.3, 0.12, 0.46), gp + Vector3(0, 2.0, 0), Vox.BLUE if gi == 0 else Vox.PINK, 1.0, false)
	if data.get("unschedulable", false):
		# Hazard fence: the node is cordoned.
		var n := int(s / 1.1)
		for i in n + 1:
			var a := -s * 0.5 + 0.2 + i * (s - 0.4) / n
			for p in [Vector3(a, 0, -s * 0.5 + 0.2), Vector3(a, 0, s * 0.5 - 0.2), Vector3(-s * 0.5 + 0.2, 0, a), Vector3(s * 0.5 - 0.2, 0, a)]:
				Vox.box(_geo, Vector3(0.14, 0.7, 0.14), p + Vector3(0, 0.35, 0), Vox.YELLOW if i % 2 == 0 else Vox.BLACK, 0.0, false)
		for z in [-s * 0.5 + 0.2, s * 0.5 - 0.2]:
			Vox.box(_geo, Vector3(s - 0.4, 0.1, 0.08), Vector3(0, 0.55, z), Vox.YELLOW, 0.0, false)
		for x in [-s * 0.5 + 0.2, s * 0.5 - 0.2]:
			Vox.box(_geo, Vector3(0.08, 0.1, s - 0.4), Vector3(x, 0.55, 0), Vox.YELLOW, 0.0, false)
