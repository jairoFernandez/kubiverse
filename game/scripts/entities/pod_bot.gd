class_name PodBot
extends Entity
## A Pod as a little voxel creature. One body segment per container, a status
## gem on top, and behaviour that reflects its phase (bobbing, shaking,
## smoking when crash-looping, shrinking when terminating...).

var category := "ok"
var top_y := 1.0
var dying := false
var node_name := ""

var _body: Node3D
var _gem: MeshInstance3D
var _sig := ""
var _t := 0.0
var _hop := 0.0
var _hop_cd := 0.0
var _smoke_cd := 0.0
var _spawn := 0.0
var _yaw := 0.0
var _slump := 0.0     # Terminating: the robot powers down and leans forward
var _spark_cd := 0.0
var _flash := 0.0
var _knock := Vector3.ZERO


func _init() -> void:
	kind = "pod"
	_t = randf() * 10.0
	_yaw = randf() * TAU
	_hop_cd = randf_range(1.0, 5.0)


static func categorize(d: Dictionary) -> String:
	var st: String = d.get("status", "")
	if d.get("deleting", false) or st == "Terminating":
		return "term"
	if st in ["CrashLoopBackOff", "Error", "OOMKilled", "RunContainerError", "CreateContainerError", "Init:Error", "Init:CrashLoopBackOff"]:
		return "crash"
	if st in ["ErrImagePull", "ImagePullBackOff", "InvalidImageName", "Init:ErrImagePull", "Init:ImagePullBackOff"]:
		return "pull"
	if st in ["Completed", "Succeeded"]:
		return "done"
	if st in ["Failed", "Evicted", "Unknown", "NodeLost", "ContainerStatusUnknown"]:
		return "failed"
	if st == "Running":
		return "ok" if int(d.get("ready", 0)) >= int(d.get("total", 1)) else "warn"
	return "pending"


static func category_color(cat: String) -> Color:
	match cat:
		"ok": return Vox.GREEN
		"warn": return Vox.YELLOW
		"pending": return Vox.BLUE
		"crash": return Vox.RED
		"pull": return Vox.PINK
		"done": return Vox.SILVER
		"failed": return Vox.RED
	return Vox.SLATE


func update_data(d: Dictionary) -> void:
	data = d
	key = d.ns + "/" + d.name
	node_name = d.get("node", "")
	category = categorize(d)
	var sig := "%s|%s|%d" % [category, d.ns, int(d.get("total", 1))]
	if sig != _sig:
		_sig = sig
		_rebuild()


func label_text() -> String:
	return "pod " + str(data.get("name", ""))


func label_sub() -> String:
	var t := tr("%s  %d/%d ready") % [data.get("status", ""), int(data.get("ready", 0)), int(data.get("total", 0))]
	if int(data.get("restarts", 0)) > 0:
		t += tr("  %d restarts") % int(data.restarts)
	var msg: String = data.get("message", "")
	if node_name == "" and msg != "":
		t += "  - " + (msg.left(60) + "..." if msg.length() > 60 else msg)
	return t


func label_color() -> Color:
	return category_color(category)


func anchor() -> Vector3:
	return global_position + Vector3(0, top_y + 0.9, 0)


## The pod is gone from the cluster: flash and break into voxel pieces.
func die() -> void:
	dying = true
	if world:
		world.shatter(global_position, top_y, Vox.ns_color(data.get("ns", "")))
	queue_free()


## Hit by the blaster: a white flash and a knock back (the real deletion
## arrives a moment later through the cluster watch).
func hit(from: Vector3) -> void:
	_flash = 0.25
	var away := global_position - from
	away.y = 0
	_knock = away.normalized() * 0.6


func _rebuild() -> void:
	if _body:
		_body.queue_free()
	_body = Node3D.new()
	add_child(_body)
	var base := Vox.ns_color(data.get("ns", ""))
	match category:
		"pending": base = base.lerp(Vox.SILVER, 0.6)
		"done", "term": base = base.lerp(Vox.SLATE, 0.7)
	var n := clampi(int(data.get("total", 1)), 1, 4)
	# Feet
	for x in [-0.2, 0.2]:
		Vox.box(_body, Vector3(0.22, 0.18, 0.3), Vector3(x, 0.09, 0.02), Vox.NAVY)
	# Body segments (one per container)
	var y := 0.18
	for i in n:
		var seg_col := base if i % 2 == 0 else base.darkened(0.15)
		Vox.box(_body, Vector3(0.8, 0.42, 0.7), Vector3(0, y + 0.21, 0), seg_col)
		y += 0.42
	top_y = y
	# Face on the top segment
	var eye_y := y - 0.17
	match category:
		"pending", "done", "term":
			for x in [-0.18, 0.18]:
				Vox.box(_body, Vector3(0.16, 0.04, 0.04), Vector3(x, eye_y, 0.36), Vox.BLACK, 0.0, false)
		"crash", "failed":
			for x in [-0.18, 0.18]:
				Vox.box(_body, Vector3(0.14, 0.14, 0.04), Vector3(x, eye_y, 0.36), Vox.RED, 1.5, false)
		_:
			for x in [-0.18, 0.18]:
				Vox.box(_body, Vector3(0.12, 0.16, 0.04), Vector3(x, eye_y, 0.36), Vox.BLACK, 0.0, false)
				Vox.box(_body, Vector3(0.05, 0.05, 0.02), Vector3(x + 0.03, eye_y + 0.04, 0.385), Vox.WHITE, 0.0, false)
	# Antenna + status gem
	Vox.box(_body, Vector3(0.06, 0.3, 0.06), Vector3(0, y + 0.15, 0), Vox.SLATE, 0.0, false)
	_gem = Vox.box(_body, Vector3(0.24, 0.24, 0.24), Vector3(0, y + 0.45, 0), category_color(category), 2.0)
	_gem.rotation = Vector3(deg_to_rad(45), 0, deg_to_rad(35))
	Look.decorate_pod(_body, top_y)


func _process(delta: float) -> void:
	_t += delta
	if _spawn < 1.0:
		_spawn = minf(1.0, _spawn + delta * 3.0)
	var s := ease(_spawn, -2.0)

	var p := position.lerp(target, clampf(delta * 4.0, 0.0, 1.0))
	var bob := 0.0
	var shake := 0.0
	match category:
		"ok":
			bob = absf(sin(_t * 3.0)) * 0.05
			_hop_cd -= delta
			if _hop_cd <= 0.0:
				_hop_cd = randf_range(2.0, 7.0)
				_hop = 1.0
				_yaw += randf_range(-1.2, 1.2)
		"warn":
			bob = absf(sin(_t * 1.5)) * 0.03
		"pending":
			s *= 0.9 + sin(_t * 6.0) * 0.06
		"crash", "failed":
			if fmod(_t, 2.0) < 0.6:
				shake = sin(_t * 60.0) * 0.06
			_smoke_cd -= delta
			if _smoke_cd <= 0.0 and world:
				_smoke_cd = 0.35
				world.smoke(global_position + Vector3(randf_range(-0.2, 0.2), top_y, 0), Color("4a4350"))
		"pull":
			bob = sin(_t * 2.0) * 0.03
			_yaw += delta * 0.8
		"term":
			# Powering down: lean forward, twitch now and then, give off sparks.
			_slump = minf(1.0, _slump + delta * 0.8)
			if fmod(_t, 1.3) < 0.08:
				shake = sin(_t * 80.0) * 0.05
			_spark_cd -= delta
			if _spark_cd <= 0.0 and world:
				_spark_cd = randf_range(0.25, 0.6)
				if randf() < 0.3:
					world.poof(global_position + Vector3(randf_range(-0.3, 0.3), top_y, randf_range(-0.3, 0.3)), Vox.YELLOW)
				else:
					world.smoke(global_position + Vector3(0, top_y, 0), Color("6b6f80"))
	if _hop > 0.0:
		_hop = maxf(0.0, _hop - delta * 2.5)
		bob += sin((1.0 - _hop) * PI) * 0.45
	if category == "term":
		_spawn = 1.0
		scale = Vector3.ONE
	else:
		_slump = maxf(0.0, _slump - delta * 2.0)
		scale = Vector3.ONE * s
	if _body:
		_body.rotation.x = _slump * 0.45
		_body.position.y = -_slump * 0.08
	if _gem:
		_gem.visible = category != "term" or fmod(_t, 0.5) < 0.3
	# Blaster hit: knock back and flash
	if _knock.length() > 0.01:
		p += _knock * delta * 8.0
		_knock = _knock.lerp(Vector3.ZERO, clampf(delta * 6.0, 0.0, 1.0))
	if _flash > 0.0:
		_flash -= delta
		scale = Vector3.ONE * (1.0 + _flash * 0.6)
	position = Vector3(p.x + shake, target.y + bob, p.z)
	rotation.y = lerp_angle(rotation.y, _yaw, clampf(delta * 3.0, 0.0, 1.0))
	if _gem:
		_gem.rotation.y += delta * (6.0 if category == "pull" else 1.5)
