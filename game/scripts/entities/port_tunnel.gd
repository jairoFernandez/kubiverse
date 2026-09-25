class_name PortTunnel
extends Entity
## A port-forward as a pneumatic glass tube: from "your PC" (or from the
## hall ceiling) to the pod / Service it reaches. Glowing packets travel in
## it with the real traffic: cyan = answers coming to you, yellow = your
## requests going in. Red glass = the tunnel lost its pod.

const GLASS := Color("a8e6ff")
const SEGMENTS := 28

var _pts: PackedVector3Array = []
var _len := 1.0
var _geo: Node3D
var _glass_mat: StandardMaterial3D
var _core_mat: StandardMaterial3D
var _packets: Array = []        # [{node, t, dir}] dir 1 = in (to the cluster), -1 = out (to you)
var _spawn := {1: 0.0, -1: 0.0}  # packets per second each way
var _acc := {1: 0.0, -1: 0.0}
var _last := {}                  # previous counters, for the rate
var _last_t := 0.0
var _t := 0.0


func _init() -> void:
	kind = "forward"


## a: your end, b: the cluster end, lift: how high the arc goes.
func setup(f: Dictionary, a: Vector3, b: Vector3, lift: float) -> void:
	key = str(f.id)
	var sig := "%s|%s|%s" % [a, b, lift]
	if sig != get_meta("sig", ""):
		set_meta("sig", sig)
		_build(a, b, lift)
	_update_rate(f)
	data = f
	var col := GLASS
	match str(f.get("status", "")):
		"error": col = Vox.RED
		"connecting": col = Vox.YELLOW
	_glass_mat.albedo_color = Color(col, 0.45)
	_glass_mat.emission = col
	_core_mat.albedo_color = col
	_core_mat.emission = col


func _build(a: Vector3, b: Vector3, lift: float) -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var c1 := a + Vector3(0, lift, 0)
	var c2 := b + Vector3(0, lift, 0)
	_pts.clear()
	for i in SEGMENTS + 1:
		var t := float(i) / SEGMENTS
		_pts.append(a.bezier_interpolate(c1, c2, b, t))
	_len = 0.0
	for i in SEGMENTS:
		_len += _pts[i].distance_to(_pts[i + 1])
	_glass_mat = StandardMaterial3D.new()
	_glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_glass_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_glass_mat.emission_enabled = true
	_glass_mat.emission_energy_multiplier = 1.0
	_glass_mat.albedo_color = Color(GLASS, 0.45)
	_glass_mat.emission = GLASS
	_glass_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_core_mat = Vox.mat(GLASS, 2.5, false).duplicate()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.55
	cyl.bottom_radius = 0.55
	cyl.radial_segments = 8
	cyl.rings = 1
	for i in SEGMENTS:
		var p: Vector3 = _pts[i]
		var q: Vector3 = _pts[i + 1]
		var seg := MeshInstance3D.new()
		var m := cyl.duplicate() as CylinderMesh
		m.height = p.distance_to(q) + 0.05
		seg.mesh = m
		seg.material_override = _glass_mat
		seg.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_geo.add_child(seg)
		seg.global_transform = _orient((p + q) * 0.5, q - p)
		# A bright core so the tube still reads at the low pixel-art resolution.
		var core := MeshInstance3D.new()
		core.mesh = BoxMesh.new()
		(core.mesh as BoxMesh).size = Vector3(0.14, p.distance_to(q) + 0.05, 0.14)
		core.material_override = _core_mat
		core.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_geo.add_child(core)
		core.global_transform = seg.global_transform
		if i % 3 == 0:  # brass rings, voxel style
			var ring := Vox.box(_geo, Vector3(1.4, 0.3, 1.4), Vector3.ZERO, Vox.ORANGE, 1.0)
			ring.global_transform = _orient(p, q - p)
	# Coming up from the floor (inside a hall): a glowing hatch around it.
	if a.y < 0.5:
		Vox.box(_geo, Vector3(1.8, 0.12, 1.8), a + Vector3(0, 0.06, 0), Vox.SLATE)
		Vox.box(_geo, Vector3(1.3, 0.14, 1.3), a + Vector3(0, 0.1, 0), GLASS, 2.0, false)
	# Both ends: a funnel on your side, a docking capsule on the cluster side.
	var cap := Vox.box(_geo, Vector3(1.3, 0.5, 1.3), Vector3.ZERO, Vox.SILVER)
	cap.global_position = b + Vector3(0, 0.25, 0)
	Vox.box(_geo, Vector3(1.0, 0.18, 1.0), b + Vector3(0, 0.55, 0), GLASS, 2.0, false)


static func _orient(pos: Vector3, dir: Vector3) -> Transform3D:
	var up := dir.normalized()
	var side := up.cross(Vector3.FORWARD if absf(up.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT).normalized()
	var fwd := side.cross(up)
	return Transform3D(Basis(side, up, fwd), pos)


func _update_rate(f: Dictionary) -> void:
	var now := Time.get_ticks_msec() / 1000.0
	# Cluster snapshots also land here: only new counters (about 1/s) count.
	var same: bool = not _last.is_empty() and f.get("bytes_in", 0) == _last.get("bytes_in", 0) and f.get("bytes_out", 0) == _last.get("bytes_out", 0)
	if same and now - _last_t < 2.5:
		return
	if not _last.is_empty() and now > _last_t:
		var dt := now - _last_t
		var rin := maxf(0.0, float(f.get("bytes_in", 0)) - float(_last.get("bytes_in", 0))) / dt
		var rout := maxf(0.0, float(f.get("bytes_out", 0)) - float(_last.get("bytes_out", 0))) / dt
		# A few packets per request, more the more bytes flow (log scale).
		_spawn[-1] = 0.0 if rin <= 0.0 else clampf(1.0 + log(1.0 + rin / 512.0) * 1.6, 1.0, 14.0)
		_spawn[1] = 0.0 if rout <= 0.0 else clampf(1.0 + log(1.0 + rout / 512.0) * 1.2, 1.0, 8.0)
	_last = f.duplicate()
	_last_t = now


func _process(delta: float) -> void:
	_t += delta
	if _pts.is_empty():
		return
	var open := str(data.get("status", "")) == "open"
	for dir in [1, -1]:
		_acc[dir] += delta * float(_spawn[dir]) if open else 0.0
		while _acc[dir] >= 1.0:
			_acc[dir] -= 1.0
			_launch(dir)
	var speed := 16.0 / maxf(4.0, _len)  # ~16 world units per second
	for pk in _packets.duplicate():
		pk.t += delta * speed * pk.dir
		if pk.t < 0.0 or pk.t > 1.0:
			pk.node.queue_free()
			_packets.erase(pk)
			continue
		pk.node.position = _at(pk.t)
		pk.node.rotation.y += delta * 4.0
	# Idle but open: a slow shimmer so you can tell it's alive.
	if _glass_mat:
		_glass_mat.emission_energy_multiplier = 0.5 + 0.25 * sin(_t * 2.0) + (0.4 if not _packets.is_empty() else 0.0)


func _launch(dir: int) -> void:
	if _packets.size() > 40:
		return
	var col := Color("a8e6ff") if dir == -1 else Vox.YELLOW
	var n := Vox.box(self, Vector3(0.6, 0.6, 0.6), Vector3.ZERO, col, 4.0, false)
	n.top_level = true
	_packets.append({"node": n, "t": 1.0 if dir == -1 else 0.0, "dir": dir})
	n.global_position = _at(1.0 if dir == -1 else 0.0)


func _at(t: float) -> Vector3:
	var f := clampf(t, 0.0, 1.0) * SEGMENTS
	var i := mini(int(f), SEGMENTS - 1)
	return _pts[i].lerp(_pts[i + 1], f - i)


func label_text() -> String:
	return "localhost:%d → %s/%s:%d" % [int(data.get("local", 0)), data.get("ns", ""), data.get("name", ""), int(data.get("port", 0))]


func label_sub() -> String:
	match str(data.get("status", "")):
		"error": return tr("tunnel lost: %s") % str(data.get("error", "")).left(60)
		"connecting": return tr("connecting to the pod...")
	return tr("%d open · %s in · %s out") % [int(data.get("conns", 0)), _bytes(float(data.get("bytes_in", 0))), _bytes(float(data.get("bytes_out", 0)))]


static func _bytes(n: float) -> String:
	if n < 1024.0:
		return "%d B" % int(n)
	if n < 1048576.0:
		return "%.1f KB" % (n / 1024.0)
	return "%.1f MB" % (n / 1048576.0)


func label_color() -> Color:
	match str(data.get("status", "")):
		"error": return Vox.RED
		"connecting": return Vox.YELLOW
	return GLASS


func anchor() -> Vector3:
	return _at(0.5) + Vector3(0, 1.0, 0) if not _pts.is_empty() else global_position
