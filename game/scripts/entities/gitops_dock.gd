class_name GitOpsDock
extends Entity
## A GitOps app (Argo CD Application, Flux Kustomization / HelmRelease) as a
## loading dock in front of the hall it deploys to: a pad, a post with the
## tool's color and a lamp. In sync and healthy it is tidy; out of sync it
## has crates piled up waiting; degraded it smokes; while it syncs the lamp
## spins blue. New commits arrive by cargo drone from git (World.deliver).

const ARGO := Color("ef7b4d")
const FLUX := Color("5468ff")

var _geo: Node3D
var _lamp: MeshInstance3D
var _sig := ""
var _t := 0.0
var _smoke_cd := 0.0


func _init() -> void:
	kind = "app"


func update_data(d: Dictionary) -> void:
	data = d
	key = "%s/%s" % [d.ns, d.name]
	var sig := "%s|%s|%s|%s" % [d.get("tool", ""), d.get("sync", ""), d.get("health", ""), d.get("operation", "")]
	if sig != _sig:
		_sig = sig
		_rebuild()


static func tool_color(d: Dictionary) -> Color:
	return FLUX if str(d.get("tool", "")) == "flux" else ARGO


## "Argo CD app", "Flux Kustomization", "Flux HelmRelease".
static func what(d: Dictionary) -> String:
	if str(d.get("tool", "")) == "flux":
		return "Flux " + str(d.get("kind", "Kustomization"))
	return "Argo CD app"


func syncing() -> bool:
	return str(data.get("operation", "")) == "Running"


func label_text() -> String:
	return "%s %s" % [what(data).to_lower(), data.get("name", "")]


func label_sub() -> String:
	var rev := str(data.get("revision", ""))
	return "%s, %s%s" % [tr(str(data.get("sync", "?"))), tr(str(data.get("health", "?"))), ("  @" + rev) if rev != "" else ""]


func label_color() -> Color:
	match str(data.get("health", "")):
		"Degraded": return Vox.RED
		"Missing": return Vox.ORANGE
		"Progressing": return Vox.BLUE
		"Suspended": return Vox.SILVER
	return Vox.YELLOW if str(data.get("sync", "")) == "OutOfSync" else Vox.GREEN


func anchor() -> Vector3:
	return global_position + Vector3(0, 2.9, 0)


func pick_radius() -> float:
	return 26.0


func build_box() -> AABB:
	return AABB(Vector3(-0.9, 0, -0.9), Vector3(1.8, 2.2, 1.8))


## Where the cargo drone drops its crates.
func drop_point() -> Vector3:
	return global_position + Vector3(0.2, 0.35, 0.2)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var tc := tool_color(data)
	# Pad with hazard corners, and the post with the tool's color.
	Vox.box(_geo, Vector3(1.8, 0.14, 1.8), Vector3(0, 0.07, 0), Vox.SLATE)
	for c in [Vector3(-0.75, 0.16, -0.75), Vector3(0.75, 0.16, -0.75), Vector3(-0.75, 0.16, 0.75), Vector3(0.75, 0.16, 0.75)]:
		Vox.box(_geo, Vector3(0.24, 0.04, 0.24), c, Vox.YELLOW, 0.0, false)
	Vox.box(_geo, Vector3(0.18, 1.9, 0.18), Vector3(-0.7, 0.95, -0.7), Vox.SILVER)
	Vox.box(_geo, Vector3(0.9, 0.5, 0.1), Vector3(-0.3, 1.65, -0.7), tc, 0.6)
	# Its little logo: Argo's octopus head / Flux's double chevron, in voxels.
	if str(data.get("tool", "")) == "flux":
		for i in 2:
			Vox.box(_geo, Vector3(0.12, 0.12, 0.04), Vector3(-0.45 + i * 0.18, 1.7, -0.64), Vox.WHITE, 0.4, false)
			Vox.box(_geo, Vector3(0.12, 0.12, 0.04), Vector3(-0.39 + i * 0.18, 1.6, -0.64), Vox.WHITE, 0.4, false)
	else:
		Vox.box(_geo, Vector3(0.3, 0.24, 0.04), Vector3(-0.3, 1.68, -0.64), Vox.WHITE, 0.4, false)
		for i in 3:
			Vox.box(_geo, Vector3(0.06, 0.14, 0.04), Vector3(-0.4 + i * 0.1, 1.5, -0.64), Vox.WHITE, 0.4, false)
	_lamp = Vox.box(_geo, Vector3(0.3, 0.3, 0.3), Vector3(-0.7, 2.05, -0.7), label_color(), 2.5, false)
	_lamp.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# Out of sync: crates from git waiting to be applied.
	if str(data.get("sync", "")) == "OutOfSync":
		var spots := [Vector3(0.25, 0.39, 0.2), Vector3(0.65, 0.39, 0.2), Vector3(0.45, 0.39, 0.6), Vector3(0.45, 0.79, 0.4)]
		for i in spots.size():
			Vox.box(_geo, Vector3(0.38, 0.38, 0.38), spots[i], Color("c47a2c") if i % 2 == 0 else Color("a0612a"))
			Vox.box(_geo, Vector3(0.4, 0.06, 0.08), spots[i] + Vector3(0, 0.1, 0), tc, 0.0, false)


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 6.0, 0.0, 1.0)) if target != Vector3.ZERO else position
	if _lamp == null:
		return
	if syncing():
		_lamp.rotation.y += delta * 8.0
		_lamp.visible = fmod(_t, 0.5) < 0.35
	else:
		_lamp.visible = true
	if str(data.get("health", "")) == "Degraded" and world:
		_smoke_cd -= delta
		if _smoke_cd <= 0.0:
			_smoke_cd = 0.35
			world.smoke(global_position + Vector3(randf_range(-0.4, 0.6), 0.6, randf_range(-0.4, 0.6)))
