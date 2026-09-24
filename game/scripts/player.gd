class_name Player
extends Node3D
## The cluster operator: a little voxel astronaut with a kubectl blaster.
## Walks, runs Pokémon-style (hold SHIFT or toggle running shoes with X),
## jumps (SPACE), flies with a jetpack (Z, or double-tap SPACE) and
## respects the world's physical limits.

const WALK_SPEED := 5.5
const RUN_SPEED := 10.5
const JUMP_SPEED := 8.6
const GRAVITY := 24.0
const FLY_SPEED := 8.0
const FLY_RUN_SPEED := 13.0
const FLY_UP := 6.5
const FLY_DOWN := 7.5

var cam_yaw := 0.0
var input_enabled := true
var moving := false
var running := false
var world: World

var _body: Node3D
var _legs: Array[MeshInstance3D] = []
var _arms: Array[MeshInstance3D] = []
var _shadow: MeshInstance3D
var _walk := 0.0
var _facing := 0.0
var _vy := 0.0
var _grounded := true
var _ground := 0.0
var coins := 0
var last_safe := Vector3.ZERO   # where to respawn after falling
var frozen := false             # scripted animation (warp) in control
var _coyote := 0.0              # can still jump shortly after leaving an edge
var _jump_buffer := 0.0         # a jump pressed just before landing still counts

signal fell
signal coin
var _squash := 0.0
var _dust_cd := 0.0
var _lean := 0.0
var _first_person := false
var _gun_tip: MeshInstance3D

# Jetpack
var flying := false             # jetpack mode on (may be standing on the ground)
var thrust := 0.0               # 0 hover .. 1 full thrust (visual/sound)
var _jetpack: Node3D
var _jet_flames: Array[MeshInstance3D] = []
var _jet_fx_cd := 0.0
var _last_space := -1.0
signal flight_changed(on: bool)


func set_weapon_color(c: Color) -> void:
	if _gun_tip:
		_gun_tip.material_override = Vox.mat(c, 2.5, false)


func _ready() -> void:
	_shadow = MeshInstance3D.new()
	var sm := BoxMesh.new()
	sm.size = Vector3(0.7, 0.02, 0.6)
	_shadow.mesh = sm
	_shadow.material_override = Vox.unlit(Color(0, 0, 0, 0.35))
	_shadow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_shadow.position.y = 0.02
	add_child(_shadow)
	_body = Node3D.new()
	add_child(_body)
	for x in [-0.15, 0.15]:
		_legs.append(Vox.box(_body, Vector3(0.2, 0.4, 0.24), Vector3(x, 0.2, 0), Vox.NAVY))
	Vox.box(_body, Vector3(0.62, 0.55, 0.42), Vector3(0, 0.66, 0), Vox.WHITE)           # suit
	Vox.box(_body, Vector3(0.64, 0.1, 0.44), Vector3(0, 0.5, 0), Vox.BLUE)              # belt
	Vox.box(_body, Vector3(0.5, 0.45, 0.24), Vector3(0, 0.7, -0.3), Vox.SILVER)         # backpack
	Vox.box(_body, Vector3(0.12, 0.12, 0.05), Vector3(0.12, 0.8, -0.43), Vox.GREEN, 2.0, false)
	Vox.box(_body, Vector3(0.56, 0.5, 0.52), Vector3(0, 1.2, 0), Vox.WHITE)             # helmet
	Vox.box(_body, Vector3(0.44, 0.26, 0.06), Vector3(0, 1.2, 0.27), Vox.BLUE, 0.8, false)  # visor
	Vox.box(_body, Vector3(0.1, 0.1, 0.02), Vector3(-0.12, 1.26, 0.3), Vox.WHITE, 0.0, false)
	Vox.box(_body, Vector3(0.05, 0.3, 0.05), Vector3(0.2, 1.58, 0), Vox.SLATE, 0.0, false)  # antenna
	Vox.box(_body, Vector3(0.12, 0.12, 0.12), Vector3(0.2, 1.76, 0), Vox.RED, 2.0, false)
	# Arms swing while walking; the right one holds the blaster.
	for x in [-0.4, 0.4]:
		_arms.append(Vox.box(_body, Vector3(0.16, 0.42, 0.18), Vector3(x, 0.66, 0), Vox.WHITE))
	var gun := Vox.box(_arms[1], Vector3(0.14, 0.14, 0.5), Vector3(0, -0.12, 0.2), Vox.SLATE)
	_gun_tip = Vox.box(gun, Vector3(0.1, 0.1, 0.08), Vector3(0, 0, 0.28), Vox.YELLOW, 2.0, false)
	# Jetpack: two tanks with nozzles over the backpack, shown in flight mode.
	_jetpack = Node3D.new()
	_body.add_child(_jetpack)
	for x in [-0.17, 0.17]:
		Vox.box(_jetpack, Vector3(0.26, 0.62, 0.26), Vector3(x, 0.78, -0.48), Vox.RED)
		Vox.box(_jetpack, Vector3(0.28, 0.08, 0.28), Vector3(x, 1.1, -0.48), Vox.SILVER)
		Vox.box(_jetpack, Vector3(0.18, 0.14, 0.18), Vector3(x, 0.42, -0.48), Vox.SLATE)
		var fl := Vox.box(_jetpack, Vector3(0.14, 0.4, 0.14), Vector3(x, 0.15, -0.48), Vox.ORANGE, 4.0, false)
		fl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_jet_flames.append(fl)
		Vox.box(fl, Vector3(0.08, 0.5, 0.08), Vector3(0, -0.05, 0), Vox.YELLOW, 5.0, false)
	_jetpack.visible = false


func body() -> Node3D:
	return _body


func muzzle() -> Vector3:
	return _body.global_transform * Vector3(0.4, 0.6, 0.6)


func forward() -> Vector3:
	return Vector3(sin(_facing), 0, cos(_facing))


## Eye position for the first-person camera.
func head_position() -> Vector3:
	return global_position + Vector3(0, 1.3, 0)


## Places the player on whatever surface is at p (teleports, level changes).
func teleport(p: Vector3) -> void:
	var y := world.surface_y(Vector2(p.x, p.z)) if world else 0.0
	position = Vector3(p.x, y if y != -INF else 0.0, p.z)
	_vy = 0.0
	_grounded = true


func set_first_person(on: bool) -> void:
	_first_person = on
	_body.visible = not on


func set_facing(angle: float) -> void:
	_facing = angle


## In first person the body faces where the camera looks.
func face_look(yaw: float) -> void:
	_facing = yaw + PI


func on_ground() -> bool:
	return _grounded


## Turns the jetpack on/off. Off in mid-air means falling, as expected.
func set_flying(on: bool) -> void:
	if on == flying:
		return
	flying = on
	_jetpack.visible = on
	_sfx("jet_on" if on else "jet_off")
	if on:
		_vy = maxf(_vy, 3.0)  # a little hop to take off
		_grounded = false
		if world:
			world.poof(global_position + Vector3(0, 0.1, 0), Vox.SILVER)
	flight_changed.emit(on)


## Nozzle positions in world space (for flame particles).
func nozzles() -> Array[Vector3]:
	var out: Array[Vector3] = []
	for f in _jet_flames:
		out.append(f.global_position + Vector3(0, -0.2, 0))
	return out


var _fire_t := 0.0


## Iso view: raise the gun arm for a moment when firing.
func fire_pose() -> void:
	_fire_t = 0.35


func _sfx(name: String) -> void:
	var s := get_node_or_null("/root/Sfx")
	if s:
		s.play(name, global_position)


func jump() -> void:
	if not input_enabled:
		return
	# Double-tap SPACE toggles the jetpack (like creative-mode flying).
	var now := Time.get_ticks_msec() / 1000.0
	var double := now - _last_space < 0.3
	_last_space = -1.0 if double else now
	if double:
		set_flying(not flying)
		return
	if flying:
		return  # while flying SPACE is held to climb (see _process)
	if on_ground() or _coyote > 0.0:
		_do_jump()
	else:
		_jump_buffer = 0.15


func _do_jump() -> void:
	_coyote = 0.0
	_jump_buffer = 0.0
	_grounded = false
	_sfx("jump")
	if true:
		_vy = JUMP_SPEED
		_squash = -0.15
		if world:
			world.poof(global_position + Vector3(0, 0.1, 0), Vox.SILVER)


func _process(delta: float) -> void:
	if frozen:
		return
	var dir := Vector3.ZERO
	if input_enabled:
		var v := Vector2(
			Input.get_action_strength("ui_right") - Input.get_action_strength("ui_left"),
			Input.get_action_strength("ui_down") - Input.get_action_strength("ui_up"))
		if Input.is_physical_key_pressed(KEY_D): v.x += 1
		if Input.is_physical_key_pressed(KEY_A): v.x -= 1
		if Input.is_physical_key_pressed(KEY_S): v.y += 1
		if Input.is_physical_key_pressed(KEY_W): v.y -= 1
		v = v.limit_length(1.0)
		dir = Vector3(v.x, 0, v.y).rotated(Vector3.UP, cam_yaw)
	moving = dir.length() > 0.05
	# Running shoes: SHIFT inverts the "always run" setting.
	var shift := input_enabled and Input.is_physical_key_pressed(KEY_SHIFT)
	running = moving and (shift != Settings.always_run)
	var speed := RUN_SPEED if running else WALK_SPEED
	if flying and not _grounded:
		speed = FLY_RUN_SPEED if running else FLY_SPEED
	var step := dir * speed * delta
	var feet := position.y
	position = world.move_player(position, step, feet) if world else position + step

	# Gravity: stand on the highest surface under the feet, or fall.
	# Surfaces up to one step above the feet count as ground: walking onto a
	# slightly higher plank steps up instead of falling through it.
	_ground = world.ground_below(Vector2(position.x, position.z), feet + World.STEP) if world else 0.0
	if world and world.walk_rects.is_empty():
		_ground = 0.0  # level not loaded yet: don't fall through nothing
	if flying:
		_fly(delta)
	elif _vy > 0.0 or feet > _ground + 0.02 or _ground == -INF:
		_vy -= GRAVITY * delta
		position.y += _vy * delta
		_grounded = false
		if _ground != -INF and position.y <= _ground:
			position.y = _ground
			_vy = 0.0
			_grounded = true
			_squash = 0.2
			_sfx("land")
	else:
		position.y = _ground  # follows moving platforms
		_vy = 0.0
		_grounded = true
	_coyote = 0.12 if _grounded else maxf(0.0, _coyote - delta)
	if _grounded:
		last_safe = position
		if _jump_buffer > 0.0:
			_do_jump()
	_jump_buffer = maxf(0.0, _jump_buffer - delta)
	if position.y < -14.0 and world:
		fell.emit()
	if world and world.coins.size() > 0:
		var got := world.collect_coins(global_position)
		if got > 0:
			coins += got
			coin.emit()
	_squash = move_toward(_squash, 0.0, delta * 1.5)

	_jet_visuals(delta)
	if moving and not _first_person:
		_facing = lerp_angle(_facing, atan2(dir.x, dir.z), clampf(delta * 14.0, 0.0, 1.0))
	if moving:
		var before := int(_walk / PI)
		_walk += delta * (17.0 if running else 11.0)
		if int(_walk / PI) != before and on_ground():
			_sfx("step")
	else:
		_walk = lerpf(_walk, roundf(_walk / PI) * PI, clampf(delta * 10.0, 0.0, 1.0))
	var lean_to := 0.28 if running else 0.0
	if flying and not _grounded:
		lean_to = 0.45 if moving else 0.08
	_lean = lerpf(_lean, lean_to, clampf(delta * 8.0, 0.0, 1.0))

	# Dust puffs behind the feet while running
	_dust_cd -= delta
	if running and on_ground() and _dust_cd <= 0.0 and world:
		_dust_cd = 0.12
		world.smoke(global_position - forward() * 0.3 + Vector3(randf_range(-0.15, 0.15), 0.1, 0), Color("c8c2b4"))

	var amp := 0.3 if running else 0.15
	_body.rotation = Vector3(_lean, _facing, 0)
	_body.position.y = absf(sin(_walk)) * (0.12 if running else 0.07) if on_ground() else 0.0
	if flying and not _grounded:
		_body.position.y = sin(Time.get_ticks_msec() * 0.004) * 0.06  # hover bob
	_body.scale = Vector3(1.0 + _squash * 0.5, 1.0 - _squash, 1.0 + _squash * 0.5)
	if flying and not _grounded:
		amp = 0.05  # legs dangle
	_legs[0].position.z = sin(_walk) * amp
	_legs[1].position.z = -sin(_walk) * amp
	_arms[0].rotation.x = -sin(_walk) * amp * 2.2
	_arms[1].rotation.x = sin(_walk) * amp * 2.2 if moving else -0.3
	if _fire_t > 0.0:
		_fire_t -= delta
		_arms[1].rotation.x = -1.4
	# Shadow on the ground below (helps judging jumps); hidden over the void.
	var gy := world.ground_below(Vector2(position.x, position.z), position.y + 0.05) if world else 0.0
	_shadow.visible = gy != -INF
	if _shadow.visible:
		var hgt := position.y - gy
		_shadow.global_position.y = gy + 0.02
		var sh := clampf(1.0 - hgt * 0.25, 0.35, 1.0)
		_shadow.scale = Vector3(sh, 1, sh)


## Jetpack vertical control: hold SPACE to climb, CTRL to descend, nothing
## to hover. Lands on any floor or roof; can't go through the ceiling.
func _fly(delta: float) -> void:
	var up := input_enabled and Input.is_physical_key_pressed(KEY_SPACE)
	var down := input_enabled and (Input.is_physical_key_pressed(KEY_CTRL) or Input.is_physical_key_pressed(KEY_META))
	var target := 0.0
	if up:
		target = FLY_UP
	elif down:
		target = -FLY_DOWN
	_vy = move_toward(_vy, target, delta * 22.0)
	thrust = move_toward(thrust, 1.0 if up else (0.1 if down else 0.45), delta * 5.0)
	if _grounded and not up and _ground != -INF and position.y <= _ground + 0.02:
		thrust = 0.0
		position.y = _ground if _ground != -INF else position.y
		_vy = 0.0
		return
	position.y += _vy * delta
	var ceiling: float = world.fly_ceiling if world else 14.0
	if position.y > ceiling:
		position.y = ceiling
		_vy = minf(_vy, 0.0)
	_grounded = false
	if _ground != -INF and position.y <= _ground:
		position.y = _ground
		if _vy < -2.0:
			_squash = 0.15
			_sfx("land")
		_vy = 0.0
		_grounded = true


func _jet_visuals(delta: float) -> void:
	var airborne := flying and not _grounded
	var t := thrust if airborne else 0.0
	for f in _jet_flames:
		f.visible = airborne
		var flick := randf_range(0.8, 1.2)
		f.scale = Vector3(1.0, (0.5 + t * 1.3) * flick, 1.0)
		f.position.y = 0.3 - 0.2 * f.scale.y
	var s := get_node_or_null("/root/Sfx")
	if s:
		s.set_jet((1.0 + t) if airborne else 0.0)
	_jet_fx_cd -= delta
	if airborne and world and _jet_fx_cd <= 0.0:
		_jet_fx_cd = 0.05 if t > 0.6 else 0.1
		for n in nozzles():
			world.exhaust(n, 0.6 + t * 0.6)
			if randf() < 0.4:
				world.smoke(n + Vector3(0, -0.3, 0), Color("c8c2b4"))
