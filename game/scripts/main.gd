extends Node
## Wires everything together. The 3D world renders into a low-resolution
## SubViewport that is upscaled with nearest filtering (the "3D pixel art"
## look), while the UI renders crisp on top, scaled by Settings.ui_factor().
##
## Coordinates: "px" = physical window pixels, "ui" = canvas units (px / ui
## factor). The 3D layer is counter-scaled so it always works in px.

const PITCH := -35.264       # classic isometric angle
const DRAG_THRESHOLD := 6.0  # px before a click becomes a drag
const ZOOM_MIN := 10.0
const ZOOM_MAX := 70.0

const LEVEL_ZOOM := {"plant": 34.0, "power": 30.0}

var world: World
var player: Player
var hud: Hud
var missions: Missions

var _vpc: SubViewportContainer
var _vp: SubViewport
var _pivot: Node3D
var _cam: Camera3D
var _fcam: Camera3D           # first-person camera
var _fpv := false
var _fyaw := 0.0
var _fpitch := 0.0
var _bob := 0.0
var _yaw := 45.0
var _yaw_target := 45.0
var _zoom := 30.0
var _zoom_target := 30.0
var _hovered: Entity
var _cycle_idx := 0
var _px := 3                 # 3D pixel size in physical pixels
var _ui := 1.0               # UI factor
var _world_layer: CanvasLayer
var _pan := Vector3.ZERO     # camera offset from the player (mouse drag)
var _press_pos := Vector2.ZERO
var _press_button := 0
var _dragging := false


func _ready() -> void:
	# On HiDPI screens the default 1280x720 px window is tiny: grow it.
	var dpi := Settings.dpi()
	if not OS.has_feature("web") and dpi > 1.0 and DisplayServer.window_get_size().x <= 1280 and not "--shot" in " ".join(OS.get_cmdline_user_args()):
		var want := Vector2i(Vector2(1280, 760) * dpi)
		var screen := DisplayServer.screen_get_usable_rect()
		want = want.min(screen.size * 9 / 10)
		DisplayServer.window_set_size(want)
		DisplayServer.window_set_position(screen.position + (screen.size - want) / 2)
	_world_layer = CanvasLayer.new()
	_world_layer.layer = -1
	add_child(_world_layer)
	_vpc = SubViewportContainer.new()
	_vpc.stretch = true
	_vpc.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_vpc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_world_layer.add_child(_vpc)
	_vp = SubViewport.new()
	_vp.msaa_3d = Viewport.MSAA_DISABLED
	_vp.positional_shadow_atlas_size = 0
	_vpc.add_child(_vp)

	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("1d2b53")
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color("8fa0d8")
	env.ambient_light_energy = 0.55
	env.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	env.fog_enabled = true
	env.fog_light_color = Color("1d2b53")
	env.fog_density = 0.006
	var we := WorldEnvironment.new()
	we.environment = env
	_vp.add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-55, -30, 0)
	sun.light_color = Color("fff1e8")
	sun.light_energy = 1.1
	sun.shadow_enabled = true
	sun.shadow_bias = 0.05
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_ORTHOGONAL
	sun.directional_shadow_max_distance = 120.0
	_vp.add_child(sun)

	_add_stars()

	world = World.new()
	_vp.add_child(world)
	player = Player.new()
	player.world = world
	_vp.add_child(player)
	player.fell.connect(func():
		player.teleport(world.spawn)
		world.poof(player.global_position + Vector3(0, 1, 0), Vox.WHITE)
		hud.toast(tr("You fell into the void! Back to the hub."), false))
	player.coin.connect(func(): hud.toast(tr("Coins: %d") % player.coins, true))

	_pivot = Node3D.new()
	_vp.add_child(_pivot)
	_cam = Camera3D.new()
	_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_cam.size = _zoom
	_cam.near = 0.1
	_cam.far = 400.0
	_cam.rotation_degrees = Vector3(PITCH, 0, 0)
	_cam.position = Vector3(0, 0, 100).rotated(Vector3.RIGHT, deg_to_rad(PITCH))
	_pivot.add_child(_cam)
	_cam.current = true
	_fcam = Camera3D.new()
	_fcam.fov = 72.0
	_fcam.near = 0.05
	_fcam.far = 220.0
	_vp.add_child(_fcam)

	hud = Hud.new()
	hud.world = world
	add_child(hud)
	hud.disconnect_requested.connect(func():
		K8s.disconnect_all()
		hud.show_connect(true))
	hud.recenter_requested.connect(func(): _pan = Vector3.ZERO)
	hud.fpv_requested.connect(_toggle_fpv)
	hud.level_requested.connect(_go_level)
	hud.goto_requested.connect(_goto)

	missions = Missions.new()
	add_child(missions)
	hud.missions = missions
	missions.progress_changed.connect(hud.refresh_missions)
	missions.completed.connect(func(m):
		hud.toast(tr("MISSION COMPLETE: %s") % tr(m.title), true)
		for i in 3:
			world.poof(player.global_position + Vector3(randf_range(-1, 1), 2.0 + i * 0.4, randf_range(-1, 1)), [Vox.YELLOW, Vox.GREEN, Vox.PINK][i]))
	hud.refresh_missions()
	for m in [hud.map_mini, hud.map_full]:
		m.world = world
		m.player = player
	hud.map_full.travel.connect(_travel)

	world.level_changed.connect(_on_level_changed)
	K8s.state_updated.connect(func(s):
		world.apply_state(s)
		missions.notify("state"))
	K8s.action_done.connect(func(ok, _m, req):
		if ok:
			world.poof(player.global_position + Vector3(0, 2.2, 0), Vox.GREEN)
		missions.notify("action", req, ok))
	_on_level_changed(world.level)

	get_tree().root.size_changed.connect(_apply_scale)
	Settings.changed.connect(_apply_scale)
	_apply_scale()

	# Web: ?demo=1 jumps straight into demo mode; ?bridge=... auto-connects.
	if K8s.web_query_param("demo") == "1" or "--demo" in OS.get_cmdline_user_args():
		K8s.start_demo()
		hud.show_connect(false)
	elif K8s.web_query_param("bridge") != "" or "--connect" in OS.get_cmdline_user_args():
		var url := K8s.default_bridge_url()
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--bridge="):
				url = arg.substr(9)
		K8s.connect_bridge(url, K8s.web_query_param("token"))

	# Dev helper: `godot --path game -- --demo --shot=/tmp/x.png [--inspect]`
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_screenshot_and_quit(arg.substr(7))


func _screenshot_and_quit(path: String) -> void:
	await get_tree().create_timer(4.0).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lang="):
			I18n.set_lang(arg.substr(7))
		if arg.begins_with("--level="):
			_go_level(arg.substr(8))
			await get_tree().create_timer(2.5).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--near="):
			var b: FactoryBuilding = world.buildings.get(arg.substr(7))
			if b:
				player.teleport(_standable_near(b.door_position() + Vector3(0, 0, 2.5)))
				_zoom_target = 24.0
				await get_tree().create_timer(1.5).timeout
		if arg.begins_with("--goto="):
			var key := arg.substr(7)
			_goto("pod", key, key.split("/")[0])
			await get_tree().create_timer(1.0).timeout
		if arg.begins_with("--term="):
			hud._term_submit(arg.substr(7))
			hud.focus_terminal()
			await get_tree().create_timer(1.5).timeout
	if "--stats" in OS.get_cmdline_user_args():
		hud.toggle_stats()
		await get_tree().create_timer(1.0).timeout
	if "--build" in OS.get_cmdline_user_args():
		hud.open_build()
		await get_tree().create_timer(0.5).timeout
	if "--map" in OS.get_cmdline_user_args():
		hud.toggle_map()
		await get_tree().create_timer(0.5).timeout
	if "--jump" in OS.get_cmdline_user_args():
		player.jump()
		await get_tree().create_timer(0.25).timeout
	if "--inspect" in OS.get_cmdline_user_args():
		_cycle_pods()
		_zoom_target = 18.0
		await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(path)
	get_tree().quit()


## UI canvas = window / ui factor (crisp fonts at any size); the 3D layer is
## counter-scaled so its pixel size only depends on the screen DPI.
func _apply_scale() -> void:
	var root := get_tree().root
	var win := Vector2(root.size)
	if win.x < 2 or win.y < 2:
		return
	_ui = Settings.ui_factor(win)
	_px = maxi(2, roundi(3.0 * Settings.dpi()))
	var want := Vector2i(maxi(1, roundi(win.x / _ui)), maxi(1, roundi(win.y / _ui)))
	root.content_scale_aspect = Window.CONTENT_SCALE_ASPECT_EXPAND
	if root.content_scale_size != want:
		root.content_scale_size = want
	_world_layer.transform = Transform2D().scaled(Vector2.ONE / _ui)
	_vpc.stretch_shrink = _px
	_vpc.position = Vector2.ZERO
	_vpc.size = win


func _go_level(l: String) -> void:
	hud.inspect(null)
	world.set_level(l)


func _on_level_changed(l: String) -> void:
	hud.close_modals()
	player.teleport(world.spawn)
	_fyaw = deg_to_rad(_yaw)
	_pan = Vector3.ZERO
	_zoom_target = LEVEL_ZOOM.get(l, 26.0)
	hud.set_level_title(world.level_title())
	missions.notify("level", l)


## Jump to any object in the cluster: switch level, walk next to it, inspect.
func _goto(kind: String, key: String, ns: String) -> void:
	var l := "power" if kind == "node" else "ns:" + ns
	if world.level != l:
		_go_level(l)
	var e := world.find_entity(kind, key)
	if e == null:
		hud.toast(tr("Not visible here (maybe filtered)"), false)
		return
	player.teleport(_standable_near(e.target))
	_pan = Vector3.ZERO
	hud.inspect(e)


## Closest place around p where the player can stand (spiral search).
func _standable_near(p: Vector3) -> Vector3:
	if world.can_stand(p):
		return p
	for r in [1.6, 2.4, 3.2, 4.5, 6.0, 8.0, 11.0]:
		for i in 16:
			var q: Vector3 = p + Vector3(cos(TAU * i / 16.0), 0, sin(TAU * i / 16.0)) * r
			if world.can_stand(q):
				return q
	return world.spawn


## Fast travel from the full map.
func _travel(pos: Vector3, target: Entity) -> void:
	world.poof(player.global_position + Vector3(0, 0.8, 0), Vox.WHITE)
	if target is FactoryBuilding:
		player.teleport(_standable_near(target.door_position() + Vector3(0, 0, 0.8)))
	elif target != null:
		player.teleport(_standable_near(target.target + Vector3(0, 0, 1.6)))
	else:
		player.teleport(_standable_near(pos))
	_pan = Vector3.ZERO
	hud.toggle_map()
	world.poof(player.global_position + Vector3(0, 0.8, 0), Vox.YELLOW)
	if target != null:
		hud.inspect(target)


func _add_stars() -> void:
	var stars := Node3D.new()
	_vp.add_child(stars)
	var rng := Vox.rng_for("stars")
	for i in 140:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.9, 0.2), rng.randf_range(-1, 1)).normalized()
		var s := Vox.box(stars, Vector3.ONE * rng.randf_range(0.2, 0.5), d * 150.0 + Vector3(0, -40, 0), [Vox.WHITE, Vox.PEACH, Vox.BLUE][i % 3], 2.0, false)
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(delta: float) -> void:
	var busy := hud.is_modal_open() or get_viewport().gui_get_focus_owner() is LineEdit
	player.input_enabled = not busy
	if _fpv and busy and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Camera: smooth yaw/zoom, follow player, snap to the pixel grid so the
	# low-res image does not shimmer while moving.
	_yaw = lerpf(_yaw, _yaw_target, clampf(delta * 10.0, 0.0, 1.0))
	_zoom = lerpf(_zoom, _zoom_target, clampf(delta * 10.0, 0.0, 1.0))
	_cam.size = _zoom
	_pivot.rotation_degrees.y = _yaw
	player.cam_yaw = deg_to_rad(_yaw)
	if player.moving:
		_pan = _pan.lerp(Vector3.ZERO, clampf(delta * 3.0, 0.0, 1.0))
	var focus := player.global_position + _pan + Vector3(0, 0.8, 0)
	var basis := _pivot.global_basis * _cam.basis
	var local := basis.inverse() * focus
	var px := _zoom / maxf(1.0, float(_vp.size.y))
	local.x = roundf(local.x / px) * px
	local.y = roundf(local.y / px) * px
	_pivot.global_position = basis * local

	if _fpv:
		_update_fpv(delta)
		# In first person you aim with the crosshair at the screen center.
		_hovered = _pick(Vector2(_vp.size) * _px * 0.5) if not busy else null
	else:
		_hovered = _pick(_mouse_px()) if not busy and not _dragging else null
	world.hovered = _hovered
	if not _fpv:
		Input.set_default_cursor_shape(Input.CURSOR_DRAG if _dragging else (Input.CURSOR_POINTING_HAND if _hovered else Input.CURSOR_ARROW))
	_update_labels()


func _active_cam() -> Camera3D:
	return _fcam if _fpv else _cam


func _toggle_fpv() -> void:
	_fpv = not _fpv
	hud.fpv = _fpv
	hud.overlay.crosshair = _fpv
	player.set_first_person(_fpv)
	if _fpv:
		# Look where the isometric camera was looking.
		_fyaw = deg_to_rad(_yaw)
		_fpitch = -0.12
		_fcam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.toast(tr("First person: move the mouse to look, click to inspect, ESC frees the mouse, P to go back."), true)
	else:
		_cam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_yaw_target = rad_to_deg(_fyaw)
		_yaw = _yaw_target
	hud._sync_view()


func _update_fpv(delta: float) -> void:
	player.cam_yaw = _fyaw
	player.face_look(_fyaw)
	if player.moving and player.on_ground():
		_bob += delta * (14.0 if player.running else 9.0)
	var bob := sin(_bob) * (0.07 if player.running else 0.04) if player.moving else 0.0
	_fcam.global_position = player.head_position() + Vector3(0, bob, 0)
	_fcam.rotation = Vector3(_fpitch, _fyaw, 0)


func _mouse_px() -> Vector2:
	return get_viewport().get_mouse_position() * _ui


func _update_labels() -> void:
	var items := []
	if not hud.is_connect_visible():
		var cam := _active_cam()
		for l in world.labels(player.global_position):
			if cam.is_position_behind(l.pos):
				continue
			if _fpv and l.pos.distance_to(player.global_position) > 28.0:
				continue
			l.screen = cam.unproject_position(l.pos) * _px / _ui
			items.append(l)
	hud.overlay.items = items
	hud.overlay.queue_redraw()


## Screen-space picking: nearest small entity under the cursor, otherwise
## the node island under the cursor's ground point.
func _pick(mouse: Vector2) -> Entity:
	var cam := _active_cam()
	var best: Entity = null
	var best_d := 1e9
	for e in world.all_entities():
		if e.is_area():
			continue
		var wp: Vector3 = e.global_position + Vector3(0, 0.6, 0)
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp) * _px
		var top := cam.unproject_position(e.anchor()) * _px
		# Distance to the vertical segment between feet and head.
		var seg := Geometry2D.get_closest_point_to_segment(mouse, sp, top)
		var d := seg.distance_to(mouse)
		if d < e.pick_radius() * _ui * 0.5 and d < best_d:
			best_d = d
			best = e
	if best:
		return best
	var vp_mouse := mouse / _px
	var from := cam.project_ray_origin(vp_mouse)
	var dir := cam.project_ray_normal(vp_mouse)
	if absf(dir.y) < 0.001:
		return null
	var t := -from.y / dir.y
	var ground := from + dir * t
	for e in world.all_entities():
		if e.is_area() and e.contains_xz(ground):
			return e
	return null


func _unhandled_input(event: InputEvent) -> void:
	if hud.is_connect_visible():
		return
	if _fpv and _fpv_input(event):
		return
	if event is InputEventMouseButton:
		match event.button_index:
			MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE:
				if event.pressed and event.double_click and event.button_index == MOUSE_BUTTON_LEFT and _hovered is FactoryBuilding:
					_go_level("power" if _hovered.is_power else "ns:" + _hovered.key)
					_press_button = 0
					return
				if event.pressed:
					_press_pos = event.position * _ui
					_press_button = event.button_index
					_dragging = false
				elif event.button_index == _press_button:
					if not _dragging and _press_button == MOUSE_BUTTON_LEFT and not hud.is_modal_open():
						hud.inspect(_hovered)
					_dragging = false
					_press_button = 0
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_target = clampf(_zoom_target * 0.9, ZOOM_MIN, ZOOM_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_target = clampf(_zoom_target * 1.1, ZOOM_MIN, ZOOM_MAX)
	elif event is InputEventMouseMotion and _press_button != 0:
		var px_pos: Vector2 = event.position * _ui
		if not _dragging and px_pos.distance_to(_press_pos) > DRAG_THRESHOLD:
			_dragging = true
		if _dragging:
			var rel: Vector2 = event.relative * _ui
			if _press_button == MOUSE_BUTTON_LEFT:
				_drag_pan(rel)
			else:
				_yaw_target -= rel.x * 0.35
				_yaw = _yaw_target
	elif event is InputEventPanGesture:
		# Two-finger trackpad scroll pans the camera.
		_drag_pan(-event.delta * 12.0)
	elif event is InputEventMagnifyGesture:
		_zoom_target = clampf(_zoom_target / event.factor, ZOOM_MIN, ZOOM_MAX)
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_ESCAPE:
			if not hud.close_modals():
				hud.inspect(null)
			return
		if event.physical_keycode == KEY_M and hud.is_modal_open() and not get_viewport().gui_get_focus_owner() is LineEdit:
			hud.close_modals()
			return
		if hud.is_modal_open() or get_viewport().gui_get_focus_owner() is LineEdit:
			return
		match event.physical_keycode:
			KEY_Q: _yaw_target = roundf(_yaw_target / 90.0) * 90.0 - 90.0
			KEY_R: _yaw_target = roundf(_yaw_target / 90.0) * 90.0 + 90.0
			KEY_E: _interact()
			KEY_M: hud.toggle_map()
			KEY_J: hud.toggle_missions()
			KEY_BACKSPACE: _go_level("plant")
			KEY_EQUAL, KEY_KP_ADD: _zoom_target = clampf(_zoom_target * 0.85, ZOOM_MIN, ZOOM_MAX)
			KEY_MINUS, KEY_KP_SUBTRACT: _zoom_target = clampf(_zoom_target * 1.15, ZOOM_MIN, ZOOM_MAX)
			KEY_SPACE: player.jump()
			KEY_P: _toggle_fpv()
			KEY_F3: hud.toggle_stats()
			KEY_SLASH, KEY_QUOTELEFT:
				hud.focus_terminal()
				get_viewport().set_input_as_handled()
			KEY_X:
				Settings.always_run = not Settings.always_run
				Settings.save()
				hud.toast(tr("Run mode: ON") if Settings.always_run else tr("Run mode: OFF"), true)
			KEY_N: hud.toggle_minimap()
			KEY_TAB: _cycle_pods()
			KEY_H: hud.toggle_system()
			KEY_C: hud.toggle_chaos()
			KEY_B: hud.open_build()
			KEY_G: hud.toggle_legend()
			KEY_V: hud.toggle_view()
			KEY_K: hud.toggle_lines()
			KEY_T: hud.toggle_terminal()
			KEY_HOME: _pan = Vector3.ZERO
			KEY_L:
				var e := hud.inspected()
				if e is PodBot:
					hud.open_logs(e.data)
			KEY_F: _blast()


## First-person mouse handling. Returns true if the event was consumed.
func _fpv_input(event: InputEvent) -> bool:
	var captured := Input.mouse_mode == Input.MOUSE_MODE_CAPTURED
	if event is InputEventMouseMotion and captured:
		_fyaw -= event.relative.x * 0.0035
		_fpitch = clampf(_fpitch - event.relative.y * 0.0035, -1.35, 1.2)
		return true
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if not captured:
			if not hud.is_modal_open():
				Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			return true
		if event.double_click and _hovered is FactoryBuilding:
			_go_level("power" if _hovered.is_power else "ns:" + _hovered.key)
		else:
			hud.inspect(_hovered)
		return true
	if event is InputEventMouseButton and event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		return true
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and captured:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return true
	return false


## Moves the camera so the ground under the cursor follows the mouse.
func _drag_pan(rel_px: Vector2) -> void:
	var units := _zoom / maxf(1.0, float(_vp.size.y) * _px)
	var yaw := deg_to_rad(_yaw)
	var right := Vector3(cos(yaw), 0, -sin(yaw))
	var fwd := Vector3(-sin(yaw), 0, -cos(yaw))
	_pan -= right * rel_px.x * units
	_pan += fwd * rel_px.y * units / sin(deg_to_rad(-PITCH))


func _nearest(max_dist: float, kind: String) -> Entity:
	var best: Entity = null
	var best_d := max_dist
	for e in world.all_entities():
		if e.is_area() or (kind != "" and e.kind != kind):
			continue
		var d := Vector2(e.global_position.x - player.global_position.x, e.global_position.z - player.global_position.z).length()
		if d < best_d:
			best_d = d
			best = e
	return best


## Jump to the next unhealthy pod anywhere in the cluster.
func _cycle_pods() -> void:
	var list: Array = K8s.state.get("pods", []).filter(func(p):
		return world.ns_visible(p.ns) and PodBot.categorize(p) in ["crash", "pull", "failed", "warn", "pending"])
	if list.is_empty():
		list = K8s.state.get("pods", []).filter(func(p): return world.ns_visible(p.ns))
	if list.is_empty():
		return
	list.sort_custom(func(a, b): return a.ns + a.name < b.ns + b.name)
	_cycle_idx = (_cycle_idx + 1) % list.size()
	var p: Dictionary = list[_cycle_idx]
	_goto("pod", p.ns + "/" + p.name, p.ns)


## E: go through a door if one is close, otherwise inspect the nearest thing.
func _interact() -> void:
	var d := world.door_near(player.global_position, 2.2)
	if not d.is_empty():
		_go_level(d.to)
		return
	var e := hud.inspected()
	if e is FactoryBuilding:
		_go_level("power" if e.is_power else "ns:" + e.key)
		return
	hud.inspect(_nearest(3.5, ""))


func _blast() -> void:
	if not hud.chaos:
		hud.toast(tr("Blaster locked. Press C to enable CHAOS MODE."), false)
		return
	# Prefer the pod in front of the player, else the nearest one.
	var best: PodBot = null
	var best_score := 1e9
	for p in world.pods.values():
		if p.dying or p.category == "term":
			continue
		var to: Vector3 = p.global_position - player.global_position
		to.y = 0
		var d := to.length()
		if d > 7.0:
			continue
		var facing := to.normalized().dot(player.forward())
		var score := d - facing * 3.0
		if score < best_score:
			best_score = score
			best = p
	if best == null:
		hud.toast(tr("No pod in range"), false)
		return
	world.zap(player.muzzle(), best.global_position + Vector3(0, best.top_y * 0.5, 0))
	K8s.action({"action": "delete_pod", "ns": best.data.ns, "name": best.data.name})
