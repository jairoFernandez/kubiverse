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
const ZOOM_MAX := 70.0         # desktop; touch screens can zoom out twice as far

const LEVEL_ZOOM := {"plant": 34.0, "power": 38.0, "engine": 40.0}

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
var _viewmodel: Node3D        # first-person weapon in the corner of the screen
const VM_POS := Vector3(0.24, -0.23, -0.6)
var _recoil := 0.0            # spring: 0 = at rest, >0 = kicked back
var _recoil_v := 0.0
var _vm_shake := 0.0          # seconds of weapon vibration left (ray, freeze)
var _vm_dip := 0.0            # 1 = lowered out of view (reload)
var _vm_parts := {}           # "flash", "blade", "warhead" -> Node3D
var _fpv_light: OmniLight3D   # muzzle light on the surroundings
# Kubi, the assistant drone, and the WATCHTOWER ghosts
var _kubi: Kubi
var _kubi_sig := ""           # problem list signature (refresh the panel on change)
var _kubi_count := 0
var _kubi_t := 0.0
var _kubi_seen: Entity        # last inspected entity Kubi commented on
var _ghosts := {}             # visitor key -> VisitorGhost
# Click-to-move
var _path: Array[Vector3] = []
var _path_stuck := 0.0
var _path_prev := Vector3.ZERO
var _click_marker: Node3D
# Touch: fingers on the world (not on the controls) for pinch / twist / look
var _touches := {}            # index -> position
var _multi_touch := false
var _kubi_tap_ms := 0
var _base_px := 3             # pixel-art scale at normal zoom
# Day/night cycle driven by the cluster clock
var _env: Environment
var weather: Weather
var _sun: DirectionalLight3D
var _moon: DirectionalLight3D
var _stars: Node3D
var _clock_base := 0.0      # unix time of the last snapshot
var _clock_local := 0.0     # seconds since that snapshot
var _fast_t := 0.0
var _yaw := 45.0
var _pitch := PITCH           # camera tilt: isometric, or low and frontal inside a pod
var _pitch_target := PITCH
var _yaw_before_pod := 45.0
const POD_PITCH := -14.0      # inside a pod: look at the tank through its front glass
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
var _screen := -1             # monitor the window is on


func _ready() -> void:
	# The project's 1280x720 px window is tiny on Retina and on big screens:
	# open at a comfortable size of the screen the window is on, centered.
	if not OS.has_feature("web") and not OS.has_feature("mobile") and not "--shot" in " ".join(OS.get_cmdline_user_args()):
		_fit_window.call_deferred()
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
	_env = env
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
	_sun = sun
	_moon = DirectionalLight3D.new()
	_moon.light_color = Color("9fb4ff")
	_moon.light_energy = 0.0
	_moon.rotation_degrees = Vector3(-60, 150, 0)
	_vp.add_child(_moon)

	_add_stars()

	world = World.new()
	_vp.add_child(world)
	player = Player.new()
	player.world = world
	_vp.add_child(player)
	_kubi = Kubi.new()
	_kubi.target = player
	_vp.add_child(_kubi)
	player.fell.connect(func():
		if hud.is_connect_visible() or world.walk_rects.is_empty():
			player.teleport(world.spawn)
			return
		# Back to the last platform you stood on (a bit inward), not the start.
		var back: Vector3 = player.last_safe
		player.teleport(_standable_near(back) if world.can_stand(back) else world.spawn)
		world.poof(player.global_position + Vector3(0, 1, 0), Vox.WHITE)
		Sfx.play("fall")
		hud.toast(tr("You fell into the void! Back to the hub."), false))
	player.flight_changed.connect(func(on: bool):
		hud.flying = on
		hud._sync_view()
		hud.toast(tr("Jetpack ON: hold SPACE to climb, CTRL to descend, Z to switch off") if on else tr("Jetpack OFF"), true))
	player.coin.connect(func():
		Sfx.play("coin")
		hud.toast(tr("Coins: %d") % player.coins, true))

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
	_viewmodel = Node3D.new()
	_fcam.add_child(_viewmodel)
	_fpv_light = OmniLight3D.new()
	_fpv_light.position = Vector3(0.2, -0.1, -1.0)
	_fpv_light.omni_range = 4.5
	_fpv_light.light_energy = 0.0
	_fcam.add_child(_fpv_light)
	_build_viewmodel(0)

	hud = Hud.new()
	hud.world = world
	add_child(hud)
	# Touch controls (phones/tablets), above the HUD but below dialogs.
	hud.touch = _want_touch()
	hud.touch_ctl = TouchControls.new()
	hud.touch_ctl.font = hud._font
	hud.touch_ctl.blockers = hud.ui_rects
	hud.add_child(hud.touch_ctl)
	hud.move_child(hud.touch_ctl, hud._modal_layer.get_index())
	hud.touch_ctl.action.connect(_on_touch_action)
	hud.touch_mode_changed.connect(func():
		hud.touch = _want_touch()
		_apply_scale())
	hud.disconnect_requested.connect(func():
		_need_spawn = true
		K8s.disconnect_all()
		hud.show_connect(true))
	hud.recenter_requested.connect(func(): _pan = Vector3.ZERO)
	hud.fpv_requested.connect(_toggle_fpv)
	hud.jetpack_requested.connect(func(): player.set_flying(not player.flying))
	hud.add_cp_requested.connect(func():
		if K8s.mode == K8s.Mode.DEMO:
			K8s.action({"action": "add_control_plane"})
			hud.banner(tr("NEW CONTROL-PLANE"), tr("A new castle joins the etcd plaza. With 2 members etcd still needs both (no fault tolerance yet); with 3 it survives the loss of 1."))
		else:
			hud.show_cp_guide())
	hud.level_requested.connect(_go_level)
	hud.intro_requested.connect(func():
		if world.level != "plant":
			_go_level("plant")
		_start_intro.call_deferred())
	hud.goto_requested.connect(_goto)

	weather = Weather.new()
	world.add_child(weather)
	K8s.forwards_updated.connect(world.set_forwards)
	K8s.connection_changed.connect(func(_st, _d): world.demo = K8s.is_demo())
	missions = Missions.new()
	add_child(missions)
	hud.missions = missions
	missions.progress_changed.connect(hud.refresh_missions)
	missions.kubi_found.connect(func(m): hud.toast(tr("Kubi found a new mission: %s") % m.title, false))
	missions.completed.connect(func(m):
		Sfx.play("jingle")
		for wi in Weapons.LIST.size():
			if Weapons.LIST[wi].unlock == m.id:
				hud.banner(tr("NEW WEAPON: %s") % tr(Weapons.LIST[wi].name), tr(Weapons.LIST[wi].desc) + "  " + tr("Press %d to equip it (chaos mode, F to fire).") % (wi + 1))
		hud.set_weapon(_weapon)
		hud.toast(tr("MISSION COMPLETE: %s") % tr(m.title), true)
		for i in 3:
			world.poof(player.global_position + Vector3(randf_range(-1, 1), 2.0 + i * 0.4, randf_range(-1, 1)), [Vox.YELLOW, Vox.GREEN, Vox.PINK][i]))
	hud.refresh_missions()
	hud.set_weapon(0)
	for m in [hud.map_mini, hud.map_full]:
		m.world = world
		m.player = player
	hud.map_full.travel.connect(_travel)

	world.level_changed.connect(_on_level_changed)
	world.shake_requested.connect(func(a): _shake = maxf(_shake, a))
	K8s.state_updated.connect(func(s):
		if float(s.get("time", 0)) > 0.0:
			_clock_base = float(s.time)
			_clock_local = 0.0
		world.challenge = Settings.challenge
		world.apply_state(s)
		if _need_spawn:
			# The level only exists once the first snapshot arrives.
			_need_spawn = false
			player.teleport(world.spawn)
			if Settings.intro and not "--shot" in " ".join(OS.get_cmdline_user_args()) or "--intro" in OS.get_cmdline_user_args():
				_start_intro.call_deferred()
		missions.notify("state")
		_kubi_state(s))
	K8s.watch_updated.connect(func(w):
		hud.watch.update(w)
		_update_ghosts(w.get("actions", [])))
	hud.watch.intruder.connect(_on_intruder)
	hud.kubi.act.connect(_kubi_act)
	hud.kubi.thinking.connect(func(on: bool):
		_kubi.mood = "thinking" if on else "ok"
		if on:
			_kubi.say("...", 60.0, Vox.BLUE))
	hud.kubi.answered.connect(func(text: String):
		_kubi.mood = "talking"
		_kubi.say(text.get_slice("\n", 0).left(80), 8.0)
		get_tree().create_timer(8.0).timeout.connect(func(): _kubi.mood = "alert" if _kubi_count > 0 else "ok"))
	K8s.action_done.connect(func(ok, _m, req):
		if ok:
			world.poof(player.global_position + Vector3(0, 2.2, 0), Vox.GREEN)
		missions.notify("action", req, ok))
	_on_level_changed(world.level)

	get_tree().root.size_changed.connect(_apply_scale)
	Settings.changed.connect(_apply_scale)
	Settings.changed.connect(func():
		if world.challenge != Settings.challenge:
			world.challenge = Settings.challenge
			if world.level == "power":
				world.set_level("plant")
				world.set_level("power"))
	_apply_scale()

	if K8s.web_query_param("vol") != "":  # dev: ?vol=0 sets the master volume
		Settings.master_volume = float(K8s.web_query_param("vol"))
	# Web: ?demo=1 jumps straight into demo mode; ?bridge=... auto-connects.
	if K8s.web_query_param("demo") == "1" or "--demo" in OS.get_cmdline_user_args():
		K8s.start_demo()
		hud.show_connect(false)
	elif K8s.web_query_param("bridge") != "" or K8s.web_query_param("token") != "" or "--connect" in OS.get_cmdline_user_args():
		# ?token=... comes from `k8s-bridge --lan` (the link printed for phones).
		var url := K8s.default_bridge_url()
		var ctx := K8s.web_query_param("context")
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--bridge="):
				url = arg.substr(9)
			if arg.begins_with("--context="):
				ctx = arg.substr(10)
		K8s.connect_bridge(url, K8s.web_query_param("token"), ctx)

	# Dev helper: `godot --path game -- --demo --shot=/tmp/x.png [--inspect]`
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			_screenshot_and_quit(arg.substr(7))


func _screenshot_and_quit(path: String) -> void:
	if "--pf-demo" in OS.get_cmdline_user_args():
		# Two port-forward tubes with simulated traffic.
		await get_tree().create_timer(1.5).timeout
		for sv in K8s.state.get("services", []).slice(0, 12):
			if sv.ns == "shop":
				K8s.port_forward("service", sv.ns, sv.name, 80)
				break
		for p in K8s.state.get("pods", []):
			if p.ns == "payments" and p.get("phase", "") == "Running":
				K8s.port_forward("pod", p.ns, p.name, 9000)
				break
	await get_tree().create_timer(4.0).timeout
	if "--debug-connect" in OS.get_cmdline_user_args():
		print("CONNECT root ", hud._connect_root.size, " v ", hud._connect_v.custom_minimum_size, " vis ", hud._connect_root.visible, " cols ", hud._connect_grid.columns)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--lang="):
			I18n.set_lang(arg.substr(7))
		if arg.begins_with("--level="):
			_go_level(arg.substr(8))
			await get_tree().create_timer(2.5).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--enter-pod="):
			# The running pod with the most containers in that namespace.
			var best := {}
			for p in K8s.state.pods:
				if p.ns == arg.substr(12) and p.get("phase", "") == "Running" and (best.is_empty() or p.containers.size() > best.containers.size()):
					best = p
			if not best.is_empty():
				_go_level("pod:%s/%s" % [best.ns, best.name])
				await get_tree().create_timer(7.0).timeout
				hud._terminal.visible = false
				hud._mission_panel.visible = false
				var caps := world.capsules.values()
				if "--inspect-container" in OS.get_cmdline_user_args() and not caps.is_empty():
					hud.inspect(caps[0])
				await get_tree().create_timer(1.0).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--weather="):
			Settings.weather = arg.substr(10)
		if arg.begins_with("--look="):
			hud.set_look(arg.substr(7), false)
			hud._terminal.visible = false
			hud._mission_panel.visible = false
			await get_tree().create_timer(1.5).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--fpv-weapon="):
			hud._terminal.visible = false
			hud._mission_panel.visible = false
			_toggle_fpv()
			_select_weapon(int(arg.substr(13)))
			await get_tree().create_timer(1.0).timeout
	if "--belt-test" in OS.get_cmdline_user_args():
		var line: ProductionLine = null
		for l in world.lines.values():
			if int(l.data.get("ready", 0)) > 0:
				line = l
				break
		if line:
			player.teleport(line.target + Vector3(2.2, 0.62, 0))
			print("BT start %s y=%.2f on_belt=%s end_x=%.1f" % [player.global_position.round(), player.global_position.y, world.belt_under(player.global_position) != null, line.target.x + line.length])
			var launched := false
			for i in 80:
				await get_tree().create_timer(0.1).timeout
				if player.push.length() > 1.0:
					launched = true
			print("BT after x=%.1f y=%.2f launched=%s" % [player.global_position.x, player.global_position.y, launched])
	if "--engine-demo" in OS.get_cmdline_user_args():
		_go_level("engine")
		await get_tree().create_timer(1.5).timeout
		hud._terminal.visible = false
		hud.engine.teach()
		await get_tree().create_timer(0.3).timeout
		hud._confirm_yes()
		hud.engine._list.visible = false
		await get_tree().create_timer(11.0).timeout
	if "--traffic-demo" in OS.get_cmdline_user_args():
		for sv in K8s.state.services:
			if sv.ns == world.current_ns() and sv.get("pods") != null and not (sv.pods as Array).is_empty():
				hud.traffic.start(sv)
				var dock: ServicePortal = world.services.get("%s/%s" % [sv.ns, sv.name])
				if dock:
					player.teleport(_standable_near(dock.target + Vector3(-2.5, 0, 3.0)))
				break
		hud._terminal.visible = false
		hud._mission_panel.visible = false
		await get_tree().create_timer(9.0).timeout
	if "--kubi-test" in OS.get_cmdline_user_args():
		missions.set_level("kubi")
		await get_tree().create_timer(3.0).timeout
		for km in missions.dynamic:
			var v := missions.view(km)
			print("KT %s | %s | steps=%d" % [km.id, v.title, km.steps.size()])
		var cur := missions.current()
		print("KT current=%s step=%s goal=%s" % [cur.get("id", ""), cur.get("step", -1), cur.get("goal", "")])
		# Walk the first step of the current one: inspect what it asks for.
		var km0: Dictionary = missions.dynamic[missions.index()] if not missions.dynamic.is_empty() else {}
		if not km0.is_empty():
			var c: Dictionary = km0.steps[0].check
			for p in K8s.state.pods:
				if c.get("kind", "") == "pod" and KubiMissions._owns(K8s.state, str(c.get("owner", "")), p):
					missions.notify("inspect", "pod", p)
					break
			print("KT after inspect step=%s" % missions.current().get("step", -1))
			missions.notify("kubectl", "-n payments describe pod x", true)
			print("KT after describe step=%s" % missions.current().get("step", -1))
			var t := str(km0.target.get("wkey", "")).split("/")
			if t.size() == 3:
				K8s.get_manifest(t[1], t[0], t[2], func(ok: bool, yaml: String, _ro: bool):
					var fixed := RegEx.create_from_string("(?m)^(\\s*-?\\s*image:\\s*).+$").sub(yaml, "$1busybox:1.36")
					K8s.prod_ok = true
					K8s.put_manifest(t[1], t[0], t[2], fixed, false, func(ok2: bool, _m: String):
						if ok2:
							missions.notify("manifest", {"kind": t[1], "ns": t[0], "name": t[2]}, true))
					K8s.prod_ok = false)
			for i in 40:
				await get_tree().create_timer(0.5).timeout
				if missions.current().get("id", "") != km0.id:
					break
			print("KT after fix: current=%s done=%s" % [missions.current().get("id", ""), km0.id in Settings.missions_done])
		hud._mission_panel.visible = true
		hud._terminal.visible = false
	if "--mission-log" in OS.get_cmdline_user_args():
		hud.open_mission_log("intermediate")
		await get_tree().create_timer(0.5).timeout
	if "--pf-demo" in OS.get_cmdline_user_args():
		# Frame the tubes: panels away, stand where they are visible.
		hud._terminal.visible = false
		hud._mission_panel.visible = false
		var t: PortTunnel = world.tunnels.values()[0] if not world.tunnels.is_empty() else null
		if t:
			var at: Vector3 = t._at(0.5) if world.level == "plant" else t._at(1.0)
			player.teleport(at * Vector3(1, 0, 1) + Vector3(2, 0, 3))
			_pan = Vector3.ZERO
		if "--inspect-home" in OS.get_cmdline_user_args() and world.home:
			hud.inspect(world.home)
		await get_tree().create_timer(1.5).timeout
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--near="):
			var b: FactoryBuilding = world.buildings.get(arg.substr(7))
			if b:
				player.teleport(_standable_near(b.door_position() + Vector3(0, 0, 2.5)))
				_zoom_target = 24.0
				await get_tree().create_timer(1.5).timeout
		if arg.begins_with("--node="):
			_goto("node", arg.substr(7), "")
			await get_tree().create_timer(1.5).timeout
		if arg.begins_with("--goto="):
			var key := arg.substr(7)
			_goto("pod", key, key.split("/")[0])
			await get_tree().create_timer(1.0).timeout
		if arg.begins_with("--term="):
			hud._term_submit(arg.substr(7))
			hud.focus_terminal()
			await get_tree().create_timer(1.5).timeout
	for d in world.doors:
		if "--warp" in OS.get_cmdline_user_args() and str(d.to).begins_with("warp:"):
			_warp(d.pos - Vector3(0, 0, 0.9), str(d.to).substr(5))
			await get_tree().create_timer(0.55).timeout
			await RenderingServer.frame_post_draw
			var shot_path := ""
			for x in OS.get_cmdline_user_args():
				if x.begins_with("--shot="):
					shot_path = x.substr(7).replace(".png", "_mid.png")
			get_viewport().get_texture().get_image().save_png(shot_path)
			await get_tree().create_timer(1.5).timeout
			break
		if "--kiosk" in OS.get_cmdline_user_args() and str(d.to).begins_with("term:") and not world.islands[str(d.to).substr(5)].is_control_plane():
			player.teleport(d.pos)
			hud.node_terminal(str(d.to).substr(5), false)
			await get_tree().create_timer(2.0).timeout
			break
	if "--fire-all" in OS.get_cmdline_user_args():
		# Dev: fire every weapon into the air (no Kubernetes action) and
		# capture a frame of each animation.
		var base := ""
		for x in OS.get_cmdline_user_args():
			if x.begins_with("--shot="):
				base = x.substr(7)
		_zoom_target = 16.0
		_zoom = 16.0
		# Face the screen's right so the shots stay in view.
		var right := (_pivot.global_basis * _cam.basis).x
		player.set_facing(atan2(right.x, right.z))
		if "--fpv" in OS.get_cmdline_user_args():
			_toggle_fpv()
			await get_tree().create_timer(0.4).timeout
		for i in Weapons.LIST.size():
			var w: Dictionary = Weapons.LIST[i]
			_weapon = i
			player.set_weapon_color(w.color)
			_build_viewmodel(i)
			await get_tree().process_frame
			var from := player.muzzle()
			if _fpv:
				from = _fpv_muzzle()
			_fire_anim(w, from, _miss_point(), func(): pass)
			if _fpv:
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(base.replace(".png", "_%s_0.png" % w.id))
			var wait := {"blaster": 0.12, "hammer": 0.3, "ray": 0.25, "freeze": 0.2, "cutter": 0.2, "nuke": 0.75}
			await get_tree().create_timer(wait[w.id]).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(base.replace(".png", "_%s.png" % w.id))
			await get_tree().create_timer(1.2).timeout
		get_tree().quit()
		return
	if "--fly" in OS.get_cmdline_user_args():
		# Dev: take off with the jetpack, climb, capture iso + first person.
		var base := ""
		for x in OS.get_cmdline_user_args():
			if x.begins_with("--shot="):
				base = x.substr(7)
		_zoom_target = 8.0
		_zoom = 8.0
		player.set_flying(true)
		player.thrust = 1.0
		for i in 50:
			player.position.y += 0.06
			await get_tree().process_frame
		await get_tree().create_timer(0.3).timeout
		print("FLY y=%.2f flying=%s" % [player.position.y, player.flying])
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_iso.png"))
		# Land on the roof of the first hall.
		var bl: FactoryBuilding = world.buildings.values()[0]
		player.position = bl.target + Vector3(0, 6.0, 0)
		var ctrl := InputEventKey.new()
		ctrl.physical_keycode = KEY_CTRL
		ctrl.pressed = true
		Input.parse_input_event(ctrl)
		for i in 90:
			await get_tree().process_frame
		ctrl = ctrl.duplicate()
		ctrl.pressed = false
		Input.parse_input_event(ctrl)
		print("ROOF y=%.2f expected %.2f grounded=%s" % [player.position.y, bl.h + 0.2, player.on_ground()])
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_roof.png"))
		_toggle_fpv()
		await get_tree().create_timer(0.5).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(base.replace(".png", "_fpv.png"))
		get_tree().quit()
		return
	if "--weapon-test" in OS.get_cmdline_user_args():
		hud.chaos = true
		hud._update_chaos_btn()
		for i in Weapons.LIST.size():
			var t := _aim(Weapons.LIST[i].target)
			print("WEAPON %s unlocked=%s target=%s" % [Weapons.LIST[i].id, Weapons.unlocked(i), "none" if t.is_empty() else str(t.keys())])
		if "--fpv" in OS.get_cmdline_user_args():
			_toggle_fpv()
			await get_tree().create_timer(0.4).timeout
		_select_weapon(0)
		if "--death-shots" in OS.get_cmdline_user_args():
			_zoom_target = 9.0
			_zoom = 9.0
		_blast()
		if "--death-shots" in OS.get_cmdline_user_args():
			var base := ""
			for x in OS.get_cmdline_user_args():
				if x.begins_with("--shot="):
					base = x.substr(7)
			for t in [[0.9, "_term"], [0.85, "_shatter"]]:
				await get_tree().create_timer(t[0]).timeout
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(base.replace(".png", t[1] + ".png"))
		await get_tree().create_timer(0.8).timeout
	if "--autodoor-test" in OS.get_cmdline_user_args():
		var b: FactoryBuilding = world.buildings.get("shop")
		player.teleport(b.door_position() + Vector3(0, 0, 3.0))
		await get_tree().create_timer(0.3).timeout
		player.teleport(b.door_position())
		await get_tree().create_timer(0.5).timeout
		print("AUTODOOR entered: ", world.level)
		await get_tree().create_timer(0.5).timeout
		var ex: Dictionary = world.doors.filter(func(d): return d.to == "plant")[0]
		player.teleport(ex.pos + Vector3(0, 0, -2.5))
		await get_tree().create_timer(0.3).timeout
		player.teleport(ex.pos)
		await get_tree().create_timer(0.5).timeout
		var b2: FactoryBuilding = world.buildings.get("shop")
		print("AUTODOOR exited: ", world.level, " near shop door: ", player.global_position.distance_to(b2.door_position()) < 3.0)
		get_tree().quit()
		return
	if "--cp-guide" in OS.get_cmdline_user_args():
		hud.show_cp_guide()
		await get_tree().create_timer(0.5).timeout
	if "--add-cp" in OS.get_cmdline_user_args():
		hud.add_cp_requested.emit()
		await get_tree().create_timer(1.5).timeout
	if "--stats" in OS.get_cmdline_user_args():
		hud.toggle_stats()
		await get_tree().create_timer(1.0).timeout
	if "--build" in OS.get_cmdline_user_args():
		hud.open_build()
		await get_tree().create_timer(0.5).timeout
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--edit="):
			# Dev: --edit=Kind/ns/name[/focus], shots of the boot animation.
			var p := x.substr(7).split("/")
			hud.open_editor(p[0], p[1], p[2], p[3] if p.size() > 3 else "")
			var base := ""
			for y in OS.get_cmdline_user_args():
				if y.begins_with("--shot="):
					base = y.substr(7)
			for t in [[0.5, "_rain"], [0.9, "_decode"], [2.0, "_edit"]]:
				await get_tree().create_timer(t[0]).timeout
				await RenderingServer.frame_post_draw
				get_viewport().get_texture().get_image().save_png(base.replace(".png", t[1] + ".png"))
			if "--edit-apply" in OS.get_cmdline_user_args():
				var line := hud.editor._code.text.find("registry.invalid/fraud-ai:v9")
				hud.editor._code.text = hud.editor._code.text.replace("registry.invalid/fraud-ai:v9", "nginx:1.27")
				hud.editor._annotate()
				hud.editor._submit(true)
				await get_tree().create_timer(0.5).timeout
				print("DRY: ", hud.editor._result.get_parsed_text())
				hud.editor._submit(false)
				await get_tree().create_timer(0.3).timeout
				hud._confirm_cb.call()
				hud._confirm_panel.visible = false
				await get_tree().create_timer(0.5).timeout
				print("APPLY: ", hud.editor._result.get_parsed_text(), " found=", line >= 0)
				await get_tree().create_timer(4.0).timeout
				print("PODS: ", K8s.state.pods.filter(func(q): return q.ns == "payments" and str(q.name).begins_with("fraud")).map(func(q): return q.status))
	if "--mouse-move-test" in OS.get_cmdline_user_args():  # dev: real clicks through the input pipeline
		var vs := get_viewport().get_visible_rect().size
		var xf := get_tree().root.get_final_transform()
		for fy in [0.35, 0.5, 0.65]:
			for fx in [0.3, 0.5, 0.7]:
				var p := vs * Vector2(fx, fy)
				for pressed in [true, false]:
					var ev := InputEventMouseButton.new()
					ev.button_index = MOUSE_BUTTON_LEFT
					ev.pressed = pressed
					ev.position = xf * p
					ev.global_position = ev.position
					Input.parse_input_event(ev)
					await get_tree().process_frame
					await get_tree().process_frame
				print("MOUSE %s hovered=%s path=%d intro=%.1f modal=%s" % [p.round(), _hovered.key if _hovered else "-", _path.size(), _intro_t, hud.is_modal_open()])
				_cancel_path()
	if "--click-test" in OS.get_cmdline_user_args():
		var center := get_viewport().get_visible_rect().size * 0.5 * _ui
		var gp := _ground_point(center)
		print("GROUND under screen centre ", gp.round(), " player ", player.global_position.round(), " focus ", (player.global_position + _pan).round())
		for lvl in ["plant", "power", "ns:shop"]:
			if world.level != lvl:
				_go_level(lvl)
				await get_tree().create_timer(0.6).timeout
			var goal: Vector3
			if lvl == "plant":
				goal = world.buildings["data"].door_position() + Vector3(0, 0, 1.0)
			elif lvl == "power":
				goal = world.islands["worker-c"].target
			else:
				goal = world.spawn + Vector3(-8, 0, -6)
			goal = _standable_near(goal)
			var t0 := Time.get_ticks_msec()
			var cpath := _find_path(player.global_position, goal)
			print("  pts ", cpath)
			print("PATH %s: %d points in %d ms, start=%s goal=%s" % [lvl, cpath.size(), Time.get_ticks_msec() - t0, player.global_position.round(), goal.round()])
			_path = cpath
			_show_click_marker(goal)
			var t1 := Time.get_ticks_msec()
			for i in 900:
				await get_tree().process_frame
				if i == 20:
					print("  running=", player.running)
				if _path.is_empty():
					break
			print("  took %.1f s" % ((Time.get_ticks_msec() - t1) / 1000.0))
			print("  ARRIVED %s dist=%.2f" % [lvl, Vector2(player.global_position.x - goal.x, player.global_position.z - goal.z).length()])
		get_tree().quit()
		return
	if "--touch-test" in OS.get_cmdline_user_args():
		var tc := hud.touch_ctl
		var sz := tc.size
		var send := func(ev: InputEvent): Input.parse_input_event(ev)
		# 1) joystick: press in the lower-left, drag right
		var p0 := player.global_position
		var t := InputEventScreenTouch.new()
		t.index = 0
		t.pressed = true
		t.position = Vector2(sz.x * 0.2, sz.y * 0.8)
		send.call(t)
		await get_tree().process_frame
		for i in 40:
			var d := InputEventScreenDrag.new()
			d.index = 0
			d.position = t.position + Vector2(min(100, i * 10), 0)
			d.relative = Vector2(10, 0)
			send.call(d)
			await get_tree().process_frame
		print("STICK=", tc.stick, " moved=", player.global_position.distance_to(p0) > 1.0, " running=", player.running, " path=", _path.size())
		var up := t.duplicate()
		up.pressed = false
		send.call(up)
		await get_tree().process_frame
		print("STICK after release=", tc.stick)
		# 2) jump button
		var b: Array = tc._buttons()[0]
		var jt := InputEventScreenTouch.new()
		jt.index = 1
		jt.pressed = true
		jt.position = b[2]
		send.call(jt)
		await get_tree().create_timer(0.1).timeout
		print("JUMP on_ground=", player.on_ground(), " y=", snappedf(player.global_position.y, 0.01))
		jt = jt.duplicate()
		jt.pressed = false
		send.call(jt)
		await get_tree().create_timer(0.8).timeout
		# 3) pinch zoom with two fingers in the middle of the world
		var z0 := _zoom_target
		var a := InputEventScreenTouch.new()
		a.index = 0
		a.pressed = true
		a.position = Vector2(sz.x * 0.5, sz.y * 0.35)
		var c := InputEventScreenTouch.new()
		c.index = 1
		c.pressed = true
		c.position = Vector2(sz.x * 0.5, sz.y * 0.5)
		send.call(a)
		send.call(c)
		await get_tree().process_frame
		for i in 10:
			var d := InputEventScreenDrag.new()
			d.index = 1
			d.position = c.position + Vector2(0, i * 8)
			d.relative = Vector2(0, 8)
			send.call(d)
			await get_tree().process_frame
		print("PINCH zoom ", snappedf(z0, 0.1), " -> ", snappedf(_zoom_target, 0.1), " pan=", _pan.round())
		for e in [a, c]:
			var u: InputEventScreenTouch = e.duplicate()
			u.pressed = false
			send.call(u)
		await get_tree().process_frame
		# 4) tap on the world = walk there
		var tap := InputEventScreenTouch.new()
		tap.index = 0
		tap.pressed = true
		tap.position = Vector2(sz.x * 0.6, sz.y * 0.4)
		send.call(tap)
		await get_tree().process_frame
		tap = tap.duplicate()
		tap.pressed = false
		send.call(tap)
		await get_tree().process_frame
		print("TAP path=", _path.size(), " multi=", _multi_touch)
		get_tree().quit()
		return
	if "--kubi-tap" in OS.get_cmdline_user_args():
		await get_tree().create_timer(2.0).timeout
		var cam := _active_cam()
		var bp := cam.unproject_position(_kubi.global_position + Vector3(0, 0.7, 0)) * _px / _ui + Vector2(0, -18)
		print("KUBI bubble='", _kubi.bubble, "' at ", bp, " on_kubi=", _on_kubi(bp))
		for pressed in [true, false]:
			var e := InputEventMouseButton.new()
			e.button_index = MOUSE_BUTTON_LEFT
			e.pressed = pressed
			e.position = bp
			Input.parse_input_event(e)
			await get_tree().process_frame
		await get_tree().process_frame
		print("KUBI panel visible=", hud.kubi.visible)
	if "--door-test" in OS.get_cmdline_user_args():
		var changes := []
		world.level_changed.connect(func(l): changes.append(l))
		for key in ["shop", "@power"]:
			if world.level != "plant":
				_go_level("plant")
				await get_tree().create_timer(0.8).timeout
			changes.clear()
			player.teleport(world.spawn)
			await get_tree().create_timer(0.3).timeout
			_click_move(Vector2.ZERO, world.buildings[key])
			print("CLICK on hall %s -> path=%d (must be 0: only inspect)" % [key, _path.size()])
			_path = _find_path(player.global_position, _standable_near(world.buildings[key].door_position()))
			print("DOOR %s: path=%d" % [key, _path.size()])
			for i in 1100:
				await get_tree().process_frame
				if i % 120 == 0 and not _path.is_empty():
					print("    t=%d pos=%s next=%s goal=%s run=%s" % [i, player.global_position.round(), _path[0].round(), _path[-1].round(), player.running])
			print("  level=%s changes=%s path_left=%d" % [world.level, changes, _path.size()])
		get_tree().quit()
		return
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--zoom="):
			_zoom_target = float(x.substr(7))
			_zoom = _zoom_target
			await get_tree().create_timer(1.0).timeout
			print("ZOOM ", _zoom, " px=", _px, " base=", _base_px, " vp=", _vp.size)
	if "--clean-test" in OS.get_cmdline_user_args():
		for t in ["kubectl get pods -A", "$ kubectl -n ml describe pod x", "get pods", "  kubectl logs a", "kubectl get pods\nkubectl get nodes", "kubectl", "kube"]:
			print("CLEAN '%s' -> '%s'" % [t.c_escape(), Hud.clean_kubectl(t)])
		# RUN / COPY links in a Kubi answer
		hud.toggle_kubi()
		var f2: String = hud.kubi._format("Haz esto:\n```bash\n# ver el pod\nkubectl -n ml describe pod giant-experiment\n$ kubectl get nodes -o wide\ndocker ps\n```\nY luego `get pods -A` o `kubectl logs x`. Es **importante** y *fácil*.")
		print("FENCE refs=", hud.kubi._cmd_refs, " runs=", f2.count("run:"), " copies=", f2.count("copy:"), " bold=", f2.contains("[b]importante[/b]"), " raw_fences=", f2.contains("```"))
		hud.kubi._cmd_refs.clear()
		var f: String = hud.kubi._format("Try `kubectl -n ml describe pod giant-experiment` then `kubectl get nodes`.")
		print("FMT ", f.contains("run:"), " ", f.contains("copy:"), " refs=", hud.kubi._cmd_refs)
		hud.kubi._on_cmd("copy:1")
		print("CLIP ", DisplayServer.clipboard_get())
		get_tree().quit()
		return
	if "--vol-slider-test" in OS.get_cmdline_user_args():
		hud.toggle_volume()
		await get_tree().process_frame
		var sliders := hud._vol_panel.find_children("*", "HSlider", true, false)
		print("SLIDERS ", sliders.size(), " values ", sliders.map(func(x): return x.value))
		var gen: HSlider = sliders[0]
		gen.value = 0.0
		await get_tree().process_frame
		print("AFTER master=", Settings.master_volume, " gain=", Settings.master_gain(), " music_db=", Sfx._music_day.volume_db)
		gen.value = 1.0
		get_tree().quit()
		return
	if "--missions-test" in OS.get_cmdline_user_args():
		# Demo: sandbox tracks, fix the broken image for real, production guard.
		print("MT kind=%s track=%s sizes=%s" % [K8s.cluster_kind, missions.track(),
			[Missions.LIST.size(), Missions.PROD.size(), Missions.INTERMEDIATE.size(), Missions.ADVANCED.size()]])
		Settings.mission_progress["intermediate"] = 0
		missions.set_level("intermediate")
		await get_tree().create_timer(2.0).timeout
		print("MT current=%s target=%s" % [missions.current().get("id", ""), missions.target()])
		var t := missions.target().split("/")
		K8s.get_manifest(t[1], t[0], t[2], func(ok: bool, yaml: String, _ro: bool):
			var re := RegEx.create_from_string("(?m)^(\\s*-?\\s*image:\\s*).+$")
			var fixed := re.sub(yaml, "$1busybox:1.36")
			K8s.prod_ok = true
			K8s.put_manifest(t[1], t[0], t[2], fixed, false, func(ok2: bool, msg: String): print("MT fix ok=%s %s" % [ok2, msg]))
			K8s.prod_ok = false)
		for i in 60:
			await get_tree().create_timer(0.5).timeout
			if missions.current().get("id", "") != "i_image":
				break
		print("MT after fix current=%s" % missions.current().get("id", ""))
		var asked := [false]
		K8s.prod_confirm_requested.connect(func(_r): asked[0] = true)
		K8s.cluster_kind = "prod"
		missions.kind_changed()
		K8s.action({"action": "delete_pod", "ns": "shop", "name": "x"})
		hud.toggle_chaos()
		print("MT prod track=%s guard_asked=%s confirm_visible=%s chaos=%s" % [missions.track(), asked[0], hud._confirm_panel.visible, hud.chaos])
		get_tree().quit()
		return
	if "--vol-test" in OS.get_cmdline_user_args():
		var old := [Settings.master_volume, Settings.muted]
		for mv in [1.0, 0.3, 0.0]:
			Settings.master_volume = mv
			await get_tree().process_frame
			print("VOL master=%.1f music_db=%.1f gain=%.2f" % [mv, Sfx._music_day.volume_db, Settings.master_gain()])
		Settings.master_volume = 1.0
		Settings.muted = true
		await get_tree().process_frame
		print("VOL muted music_db=%.1f gain=%.2f" % [Sfx._music_day.volume_db, Settings.master_gain()])
		Settings.master_volume = old[0]
		Settings.muted = old[1]
		get_tree().quit()
		return
	if "--term-drag-test" in OS.get_cmdline_user_args():
		var d: DragResize = hud._term_drag
		var t: Control = hud._terminal
		var before := Rect2(t.position, t.size)
		var ev := InputEventMouseButton.new()
		ev.button_index = MOUSE_BUTTON_LEFT
		ev.pressed = true
		d._handle_input(ev)
		var mv := InputEventMouseMotion.new()
		mv.relative = Vector2(-500, -300)
		d._handle_input(mv)
		ev = ev.duplicate()
		ev.pressed = false
		d._handle_input(ev)
		await get_tree().process_frame
		await get_tree().process_frame
		var moved := Rect2(t.position, t.size)
		# resize from the bottom-right corner
		var ep := InputEventMouseButton.new()
		ep.button_index = MOUSE_BUTTON_LEFT
		ep.pressed = true
		ep.position = t.size - Vector2(4, 4)
		d._panel_input(ep)
		var m2 := InputEventMouseMotion.new()
		m2.relative = Vector2(150, 220)
		d._panel_input(m2)
		ep = ep.duplicate()
		ep.pressed = false
		d._panel_input(ep)
		await get_tree().process_frame
		await get_tree().process_frame
		print("TERM before=", before, " moved=", moved, " resized=", Rect2(t.position, t.size))
		var shot := ""
		for x in OS.get_cmdline_user_args():
			if x.begins_with("--shot="):
				shot = x.substr(7)
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png(shot)
		var dc := InputEventMouseButton.new()
		dc.button_index = MOUSE_BUTTON_LEFT
		dc.pressed = true
		dc.double_click = true
		d._handle_input(dc)
		await get_tree().process_frame
		await get_tree().process_frame
		print("TERM docked=", Rect2(t.position, t.size), " floating=", d.is_floating())
		get_tree().quit()
		return
	for x in OS.get_cmdline_user_args():
		if x.begins_with("--kc-test="):
			var saved := Settings.servers.duplicate(true)
			hud.show_connect(true)
			hud._kc_text.text = FileAccess.get_file_as_string(x.substr(10))
			hud._kc_name.text = "kctest"
			hud._upload_kubeconfig()
			for i in 60:
				await get_tree().create_timer(0.5).timeout
				if K8s.mode == K8s.Mode.BRIDGE and not K8s.state.is_empty():
					break
			print("KC status='", hud._connect_status.text, "'")
			print("KC connected context=", K8s.context, " state_ctx=", K8s.state.get("context"), " nodes=", K8s.state.get("nodes", []).size())
			print("KC saved=", Settings.servers.filter(func(v): return v.name.begins_with("kctest")))
			Settings.servers = saved
			Settings.save()
			get_tree().quit()
			return
	if "--kubi-touch-test" in OS.get_cmdline_user_args():
		hud.toggle_kubi()
		await get_tree().create_timer(0.5).timeout
		var k: KubiPanel = hud.kubi
		var p0 := k.position
		var at := get_tree().root.get_final_transform() * (k.get_global_transform() * Vector2(k.size.x * 0.45, 20))
		var t := InputEventScreenTouch.new()
		t.index = 0
		t.pressed = true
		t.position = at
		Input.parse_input_event(t)
		await get_tree().process_frame
		for i in 10:
			var d := InputEventScreenDrag.new()
			d.index = 0
			d.position = at + Vector2(i * 8, i * 6)
			d.relative = Vector2(8, 6)
			Input.parse_input_event(d)
			await get_tree().process_frame
		t = t.duplicate()
		t.pressed = false
		Input.parse_input_event(t)
		await get_tree().process_frame
		await get_tree().process_frame
		print("KUBI moved from ", p0, " to ", k.position)
		get_tree().quit()
		return
	if "--overview" in OS.get_cmdline_user_args():  # dev: the whole plant, no panels
		_zoom_target = 80.0
		_zoom = 80.0
		_pan = Vector3(0, 0, -14)
		hud._mission_panel.visible = false
		hud._terminal.visible = false
		hud.map_mini.visible = false
		await get_tree().create_timer(3.0).timeout
	if "--city-shot" in OS.get_cmdline_user_args():
		if world.gate:
			player.teleport(world.gate.global_position + Vector3(0, 0, 6))
		_zoom_target = 34.0
		_zoom = 34.0
		_yaw_target += 90.0
		_yaw = _yaw_target
		_pan = Vector3(0, 0, -12)
		hud._mission_panel.visible = false
		hud._terminal.visible = false
		await get_tree().create_timer(4.0).timeout
		if "--inspect-gate" in OS.get_cmdline_user_args():
			hud.inspect(world.gate)
			await get_tree().create_timer(0.6).timeout
	if "--clean-finished-test" in OS.get_cmdline_user_args():
		var count := func(): return K8s.state.pods.filter(func(p): return p.ns == "ci" and PodBot.categorize(p) == "done").size()
		var probs := Diagnose.problems(K8s.state).filter(func(d): return d.sev == 0)
		print("HYG items=", probs.map(func(d): return d.title), " done_before=", count.call())
		hud._clean_finished("ci")
		await get_tree().process_frame
		hud._confirm_cb.call()
		hud._confirm_panel.visible = false
		await get_tree().create_timer(1.0).timeout
		print("HYG done_after=", count.call(), " problems_left=", Diagnose.problems(K8s.state).filter(func(d): return d.sev == 0).size())
		get_tree().quit()
		return
	if "--island-size-test" in OS.get_cmdline_user_args():
		_go_level("power")
		await get_tree().create_timer(1.0).timeout
		for k in world.islands:
			print("ISLAND ", k, " cols=", world.islands[k].cols, " slots=", world.islands[k].slots.size())
		get_tree().quit()
		return
	if "--menu-open" in OS.get_cmdline_user_args():
		hud.toggle_menu()
		await get_tree().create_timer(0.4).timeout
	if "--kubi" in OS.get_cmdline_user_args():
		hud.toggle_kubi()
		await get_tree().create_timer(1.0).timeout
		if "--kubi-fence" in OS.get_cmdline_user_args():
			hud.kubi.custom_rect = Rect2(20, 100, 700, 600)
			hud.kubi._chat.append_text("[color=#ff004d]Kubi:[/color] " + hud.kubi._format("Para ver por qué no arranca:\n```bash\n# eventos del pod\nkubectl -n ml describe pod giant-experiment\nkubectl get nodes -o wide\ndocker ps\n```\nO en corto: `get pods -A`."))
			await get_tree().create_timer(0.5).timeout
		if "--kubi-cmds" in OS.get_cmdline_user_args():
			hud.kubi.custom_rect = Rect2(20, 100, 700, 600)
			hud.kubi.select(Diagnose.problems(K8s.state)[0])
			await get_tree().process_frame
			hud.kubi._scroll.scroll_vertical = 330
			await get_tree().create_timer(0.5).timeout
		if "--kubi-resize" in OS.get_cmdline_user_args():
			var k: KubiPanel = hud.kubi
			var before := k.size
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = true
			ev.position = Vector2(k.size.x - 4, k.size.y * 0.5)
			k._gui_input(ev)
			var mv := InputEventMouseMotion.new()
			mv.position = ev.position
			mv.relative = Vector2(120, 0)
			k._gui_input(mv)
			ev = ev.duplicate()
			ev.pressed = false
			k._gui_input(ev)
			ev = ev.duplicate()
			ev.pressed = true
			ev.position = Vector2(k.size.x * 0.5, 3)
			k._gui_input(ev)
			mv = mv.duplicate()
			mv.relative = Vector2(0, -60)
			k._gui_input(mv)
			await get_tree().process_frame
			await get_tree().process_frame
			print("RESIZE before=", before, " after=", k.size, " pos=", k.position)
		if "--kubi-attach" in OS.get_cmdline_user_args():
			for d in Diagnose.problems(K8s.state):
				if d.name.begins_with("giant"):
					hud.kubi.select(d)
			hud.kubi._on_cmd("kubectl -n ml describe pod giant-experiment")
			await get_tree().create_timer(3.0).timeout
		if "--kubi-settings" in OS.get_cmdline_user_args():
			hud.kubi.custom_rect = Rect2(300, 130, 620, 560)  # as if dragged
			hud.kubi.toggle_settings()
			await get_tree().create_timer(2.5).timeout
			print("KUBI min ", hud.kubi.get_combined_minimum_size(), " size ", hud.kubi.size, " pos ", hud.kubi.position, " screen ", hud.kubi.get_parent().size)
		for x in OS.get_cmdline_user_args():
			if x.begins_with("--kubi-ask="):
				for d in Diagnose.problems(K8s.state):
					if d.name.begins_with("giant"):
						hud.kubi.select(d)
				hud.kubi.ask(x.substr(11))
				await get_tree().create_timer(30.0).timeout
	if "--watch" in OS.get_cmdline_user_args():
		hud.toggle_watch()
		_update_ghosts([])
		await get_tree().create_timer(12.0).timeout
		print("WATCH audit=%s " % hud.watch.data.get("audit"), hud.watch.data.visitors.map(func(v): return "%s|%s|%s|denied=%d" % [v.user, v.agent, v.source, int(v.get("denied", 0))]))
		if "--collapse" in OS.get_cmdline_user_args():
			hud.watch.set_collapsed(true)
			hud.toggle_kubi()
			hud.toggle_kubi()
			var gp: Vector3 = _ghosts.values()[0].goal if not _ghosts.is_empty() else world.spawn
			player.teleport(_standable_near(gp + Vector3(2, 0, 3)))
			_pan = Vector3.ZERO
			_zoom_target = 14.0
			await get_tree().create_timer(2.5).timeout
			print("GHOSTS ", _ghosts.size(), " ", _ghosts.values().map(func(g): return g.global_position.round()))
			print("KUBI ", _kubi.global_position.round(), " player ", player.global_position.round(), " visible ", _kubi.visible)
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
func _fit_window() -> void:
	if DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_WINDOWED:
		return
	var screen := DisplayServer.window_get_current_screen()
	var area := DisplayServer.screen_get_usable_rect(screen)
	var want := Vector2i(Vector2(1280, 760) * Settings.dpi())
	want = want.min(Vector2i(Vector2(area.size) * 0.9))
	DisplayServer.window_set_size(want)
	DisplayServer.window_set_position(area.position + (area.size - want) / 2)
	_apply_scale()


func _apply_scale() -> void:
	var root := get_tree().root
	var win := Vector2(root.size)
	if win.x < 2 or win.y < 2:
		return
	_ui = Settings.ui_factor(win, hud != null and hud.touch)
	_base_px = maxi(2, roundi(3.0 * Settings.dpi()))
	if hud != null and hud.touch:
		# Phones have 3x density: 3*dpi would render at 1/9 of the screen.
		# Aim at ~400 world pixels on the short side instead.
		_base_px = clampi(roundi(minf(win.x, win.y) / 400.0), 2, 6)
	_px = _pixel_scale()
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
	_cancel_path()  # the clicked target belonged to the previous level
	var keep := [hud.kubi.visible, hud.watch.visible]
	hud.close_modals()
	hud.kubi.visible = keep[0]
	hud.watch.visible = keep[1]
	for g in _ghosts.values():
		g.queue_free()
	_ghosts.clear()
	player.teleport(world.spawn)
	# Coming back to the plant: stand in front of the door you came out of.
	if l == "plant" and _prev_level == "engine" and world.engine_hall:
		player.teleport(_standable_near(world.engine_hall.door_position() + Vector3(0, 0, 1.8)))
	elif l == "plant" and _prev_level != "plant":
		var key := "@power" if _prev_level == "power" else _prev_level.substr(3)
		var b: FactoryBuilding = world.buildings.get(key)
		if b:
			player.teleport(_standable_near(b.door_position() + Vector3(0, 0, 1.8)))
	hud.engine.visible = l == "engine"
	if l == "engine":
		hud._mission_panel.visible = false
		hud.banner(tr("ENGINE ROOM"), tr("The control plane at work. Every event of your cluster travels between the machines as a work order. Click a machine to see what it does, or TEACH ME to follow the life of a pod."))
	# Out of a pod: back next to its robot in the hall.
	if l.begins_with("ns:") and _prev_level.begins_with("pod:"):
		var bot: PodBot = world.pods.get(_prev_level.substr(4))
		if bot:
			player.teleport(_standable_near(bot.target + Vector3(1.2, 0, 1.6)))
	# Inside a pod the camera looks at the tank from the front, low, so the
	# containers stand side by side with their labels; outside, isometric.
	if l.begins_with("pod:") and _pitch_target != POD_PITCH:
		_yaw_before_pod = _yaw_target
		_yaw_target = 0.0
		_pitch_target = POD_PITCH
	elif not l.begins_with("pod:") and _pitch_target != PITCH:
		_yaw_target = _yaw_before_pod
		_pitch_target = PITCH
	if l.begins_with("pod:"):
		if player.flying:
			player.set_flying(false)
		_pod_t = 99.0
		_pod_logs = {}
		hud.banner(tr("INSIDE POD %s") % l.substr(4).get_slice("/", 1), tr("G: what is what. SPACE swims up, CTRL down."))
		hud.show_pod_legend(true)
	elif _prev_level.begins_with("pod:"):
		hud.show_pod_legend(false)
	_prev_level = l
	_door_armed = false
	_zone = ""
	_fyaw = deg_to_rad(_yaw)
	_pan = Vector3.ZERO
	_zoom_target = _pod_zoom() if l.begins_with("pod:") else LEVEL_ZOOM.get(l, 26.0)
	hud.set_level_title(world.level_title())
	missions.notify("level", l)


## Conveyor belts: stand on one and it carries you to its end, then flings
## you off with a somersault (just for fun). Stopped belts don't move.
var _belt_cd := 0.0
func _ride_belt(delta: float) -> void:
	_belt_cd = maxf(0.0, _belt_cd - delta)
	if player.flying:
		return
	var line := world.belt_under(player.global_position)
	if line == null or not player.on_ground():
		return
	var ready := int(line.data.get("ready", 0))
	if ready <= 0:
		return
	var speed := maxf(2.2, 3.0 * float(ready) / maxf(1.0, float(line.data.get("desired", 1))))
	player.position.x += speed * delta
	var end_x := line.target.x + line.length - 0.3
	if player.position.x >= end_x and _belt_cd <= 0.0:
		_belt_cd = 1.0
		player.launch(Vector3(7.5, 0, randf_range(-1.5, 1.5)), 10.5)
		world.poof(player.global_position + Vector3(0, 0.6, 0), Vox.YELLOW)
		world.poof(player.global_position + Vector3(0.4, 1.0, 0), Vox.PINK)
		Sfx.play("coin")
		hud.toast(tr("Wheee! Shipped by %s") % line.data.get("name", ""), true)


## Frame the whole tank front: its width across the screen.
func _pod_zoom() -> float:
	var aspect := float(_vp.size.x) / maxf(1.0, float(_vp.size.y))
	return clampf((world.pod_width + 4.0) / maxf(1.0, aspect), 11.0, 26.0)


## Inside a pod: refresh its detail every 5 s and turn new log lines into
## bubbles every 3 s (the last few lines of each running container).
func _pod_tick(delta: float) -> void:
	var key := world.pod_key()
	var ns := key.get_slice("/", 0)
	var pod := key.get_slice("/", 1)
	_pod_t += delta
	if _pod_t > 5.0:
		_pod_t = 0.0
		K8s.get_pod(ns, pod, func(ok: bool, d):
			if world.pod_key() != key:
				return
			if ok:
				world.set_pod_detail(d)
				_zoom_target = _pod_zoom()
			else:
				hud.toast(tr("This pod is gone: back to the hall."), false)
				_go_level("ns:" + ns))
	_pod_log_t += delta
	if _pod_log_t < 3.0:
		return
	_pod_log_t = 0.0
	for cn in world.capsules:
		var cap: PodCapsule = world.capsules[cn]
		if cap.init or cap.state() == "done":
			continue
		K8s.fetch_logs(ns, pod, str(cap.data.name), false, func(ok: bool, text: String):
			if not ok or world.pod_key() != key or not is_instance_valid(cap):
				return
			var lines := Array(text.strip_edges().split("\n", false)).slice(-5)
			var last: String = _pod_logs.get(cn, "")
			var start := lines.find(last) + 1 if last != "" and lines.has(last) else maxi(0, lines.size() - 2)
			for i in range(start, lines.size()):
				var line: String = str(lines[i]).strip_edges()
				# Drop a leading RFC3339 timestamp: the bubble has little room.
				if line.length() > 20 and line[4] == "-" and line[10] == "T":
					line = line.substr(line.find(" ") + 1)
				world.bubble(cap.top() + Vector3(randf_range(-0.3, 0.3), 0.2 * (i - start), 0), line.left(70))
			if start >= lines.size() and K8s.is_demo() and not lines.is_empty():
				world.bubble(cap.top(), str(lines.pick_random()).substr(20).left(70))  # the demo's logs don't grow
			if not lines.is_empty():
				_pod_logs[cn] = lines[-1], 5)


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
	_stars = stars
	_vp.add_child(stars)
	var rng := Vox.rng_for("stars")
	for i in 140:
		var d := Vector3(rng.randf_range(-1, 1), rng.randf_range(-0.9, 0.2), rng.randf_range(-1, 1)).normalized()
		var s := Vox.box(stars, Vector3.ONE * rng.randf_range(0.2, 0.5), d * 150.0 + Vector3(0, -40, 0), [Vox.WHITE, Vox.PEACH, Vox.BLUE][i % 3], 2.0, false)
		s.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func _process(delta: float) -> void:
	_cooldown = maxf(0.0, _cooldown - delta)
	if world.swim_level:
		_pod_tick(delta)
	if weather:
		weather.tick(delta, player.global_position, K8s.state, world.level in ["plant", "power"] and not Look.always_night())
		hud.weather_why = weather.why
	_ride_belt(delta)
	# Dragged to another monitor (Retina <-> 1x): its density changes the scale.
	var screen := DisplayServer.window_get_current_screen()
	if screen != _screen:
		_screen = screen
		_apply_scale()
	# Camera shake (explosions, hammer)
	_shake = move_toward(_shake, 0.0, delta * 2.0)
	var sh := Vector2(randf_range(-1, 1), randf_range(-1, 1)) * _shake * 0.4
	_cam.h_offset = sh.x
	_cam.v_offset = sh.y
	_fcam.h_offset = sh.x * 0.2
	_fcam.v_offset = sh.y * 0.2
	Sfx.set_listener(player.global_position)
	_update_daylight(delta)
	_auto_doors()
	_update_zone()
	_kubi_tick(delta)
	_follow_path(delta)
	# Zoomed out, the pixel-art gets finer so things stay readable.
	var want_px := _pixel_scale()
	if want_px != _px:
		_px = want_px
		_vpc.stretch_shrink = _px
	_touch_tick()
	var busy := hud.is_modal_open() or get_viewport().gui_get_focus_owner() is LineEdit
	player.input_enabled = not busy
	if _fpv and busy and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE

	# Camera: smooth yaw/zoom, follow player, snap to the pixel grid so the
	# low-res image does not shimmer while moving.
	_yaw = lerpf(_yaw, _yaw_target, clampf(delta * 10.0, 0.0, 1.0))
	_zoom = lerpf(_zoom, _zoom_target, clampf(delta * 10.0, 0.0, 1.0))
	_cam.size = _zoom
	if absf(_pitch - _pitch_target) > 0.01:
		_pitch = lerpf(_pitch, _pitch_target, clampf(delta * 6.0, 0.0, 1.0))
		_cam.rotation_degrees.x = _pitch
		_cam.position = Vector3(0, 0, 100).rotated(Vector3.RIGHT, deg_to_rad(_pitch))
	_pivot.rotation_degrees.y = _yaw
	player.cam_yaw = deg_to_rad(_yaw)
	if player.moving:
		_pan = _pan.lerp(Vector3.ZERO, clampf(delta * 3.0, 0.0, 1.0))
	var focus := player.global_position + _pan + Vector3(0, 0.8, 0)
	if world.swim_level:
		# Keep the whole tank height (capsules and their labels) in view.
		focus.y = clampf(player.global_position.y + 0.8, 4.2, World.TANK_TOP - 3.0)
	if _intro_t >= 0.0:
		focus = _intro_tick(delta)
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
	_viewmodel.visible = _fpv
	world.fpv = _fpv
	if _fpv:
		# Look where the isometric camera was looking.
		_fyaw = deg_to_rad(_yaw)
		_fpitch = -0.12
		_fcam.current = true
		if not hud.touch:  # on touch screens you look around by dragging
			Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
		hud.toast(tr("First person: move the mouse to look, click to inspect, ESC frees the mouse, P to go back."), true)
	else:
		_cam.current = true
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		_yaw_target = rad_to_deg(_fyaw)
		_yaw = _yaw_target
	hud._sync_view()


## Voxel model of the equipped weapon, held in the lower-right corner of
## the first-person view. Each weapon gets its own attachment.
func _build_viewmodel(i: int) -> void:
	for c in _viewmodel.get_children():
		c.queue_free()
	var w: Dictionary = Weapons.LIST[i]
	var col: Color = w.color
	var g := Node3D.new()
	_viewmodel.add_child(g)
	_vm_parts.clear()
	var metal := Color("4a5068")
	var dark := Color("2a2f45")
	var trim := Color("8b93b0")
	# Sleeve and glove wrapped around an angled grip.
	Vox.box(g, Vector3(0.2, 0.2, 0.55), Vector3(0.04, -0.2, 0.42), Vox.WHITE)
	Vox.box(g, Vector3(0.22, 0.08, 0.22), Vector3(0.04, -0.12, 0.16), Vox.BLUE)
	var grip := Vox.box(g, Vector3(0.11, 0.26, 0.13), Vector3(0, -0.1, 0.06), dark)
	grip.rotation.x = -0.35
	var glove := Vox.box(g, Vector3(0.17, 0.17, 0.17), Vector3(0.0, -0.08, 0.08), Vox.BLUE.darkened(0.2))
	glove.rotation.x = -0.35
	for k in 3:  # fingers around the grip
		Vox.box(g, Vector3(0.05, 0.05, 0.08), Vector3(-0.07, -0.05 - k * 0.06, 0.0 - k * 0.02), Vox.BLUE.lightened(0.1))
	Vox.box(g, Vector3(0.06, 0.05, 0.12), Vector3(0.0, -0.04, -0.02), trim)  # trigger guard
	# Receiver with side panels and a rail on top.
	Vox.box(g, Vector3(0.17, 0.16, 0.42), Vector3(0, 0.06, -0.06), metal)
	for sx in [-1.0, 1.0]:
		Vox.box(g, Vector3(0.02, 0.1, 0.3), Vector3(sx * 0.095, 0.06, -0.06), dark)
		for k in 3:  # charge bars (lit)
			var bar := Vox.box(g, Vector3(0.015, 0.03, 0.06), Vector3(sx * 0.106, 0.04, -0.14 + k * 0.08), col, 2.5, false)
			_vm_parts["bar%d%d" % [int(sx), k]] = bar
	Vox.box(g, Vector3(0.06, 0.03, 0.36), Vector3(0, 0.155, -0.06), trim)
	# Energy cell on top: the weapon's colour, glowing.
	Vox.box(g, Vector3(0.1, 0.08, 0.14), Vector3(0, 0.2, 0.04), dark)
	Vox.box(g, Vector3(0.07, 0.06, 0.11), Vector3(0, 0.215, 0.04), col, 3.0, false)
	# Barrel: shroud with vents, coils, muzzle.
	Vox.box(g, Vector3(0.13, 0.13, 0.26), Vector3(0, 0.07, -0.36), dark)
	for k in 3:
		Vox.box(g, Vector3(0.15, 0.03, 0.02), Vector3(0, 0.12, -0.28 - k * 0.06), trim)
	for k in 2:
		Vox.box(g, Vector3(0.16, 0.16, 0.035), Vector3(0, 0.07, -0.3 - k * 0.1), col, 2.0, false)
	Vox.box(g, Vector3(0.08, 0.08, 0.1), Vector3(0, 0.07, -0.52), metal)
	Vox.box(g, Vector3(0.05, 0.05, 0.02), Vector3(0, 0.07, -0.575), col, 4.0, false)
	match w.id:
		"hammer":
			Vox.box(g, Vector3(0.4, 0.22, 0.2), Vector3(0, 0.1, -0.58), col, 1.0)
			Vox.box(g, Vector3(0.44, 0.06, 0.22), Vector3(0, 0.22, -0.58), trim)
		"ray":
			Vox.box(g, Vector3(0.32, 0.32, 0.04), Vector3(0, 0.07, -0.6), col, 1.5)
			Vox.box(g, Vector3(0.2, 0.2, 0.05), Vector3(0, 0.07, -0.62), dark)
			Vox.box(g, Vector3(0.04, 0.04, 0.16), Vector3(0, 0.07, -0.7), Vox.WHITE, 3.0, false)
		"freeze":
			for sx in [-1.0, 1.0]:
				Vox.box(g, Vector3(0.1, 0.24, 0.1), Vector3(sx * 0.15, 0.14, -0.02), col, 1.2)
				Vox.box(g, Vector3(0.11, 0.03, 0.11), Vector3(sx * 0.15, 0.27, -0.02), trim)
		"cutter":
			var blade := Vox.box(g, Vector3(0.03, 0.3, 0.3), Vector3(0, 0.1, -0.6), col, 2.0, false)
			blade.rotation.x = 0.6
			_vm_parts.blade = blade
		"nuke":
			Vox.box(g, Vector3(0.24, 0.24, 0.62), Vector3(0, 0.12, -0.24), Vox.FOREST)
			for k in 3:
				Vox.box(g, Vector3(0.26, 0.03, 0.03), Vector3(0, 0.25, -0.05 - k * 0.18), Vox.YELLOW)
			_vm_parts.warhead = Vox.box(g, Vector3(0.18, 0.18, 0.2), Vector3(0, 0.12, -0.64), col, 2.0)
	# Muzzle flash: a star of glowing blocks, shown for a couple of frames.
	var fl := Node3D.new()
	fl.position = Vector3(0, 0.07, -0.66 if w.id != "nuke" else -0.8)
	g.add_child(fl)
	Vox.box(fl, Vector3(0.2, 0.2, 0.2), Vector3.ZERO, Vox.WHITE, 5.0, false)
	Vox.box(fl, Vector3(0.6, 0.07, 0.07), Vector3.ZERO, col, 5.0, false)
	Vox.box(fl, Vector3(0.07, 0.6, 0.07), Vector3.ZERO, col, 5.0, false)
	Vox.box(fl, Vector3(0.09, 0.09, 0.45), Vector3(0, 0, -0.22), col.lightened(0.4), 5.0, false)
	fl.visible = false
	_vm_parts.flash = fl
	# Drawn on top of everything (no depth test) so it never clips into walls;
	# parts are painted back to front by their depth, so they cover each other
	# the right way.
	for mi in g.find_children("*", "MeshInstance3D", true, false):
		var m: StandardMaterial3D = mi.material_override.duplicate()
		m.no_depth_test = true
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		var zc: float = g.to_local(mi.global_position).z if mi.is_inside_tree() else mi.position.z
		m.render_priority = clampi(20 + int(zc * 60.0), 1, 120)
		m.next_pass = null
		mi.material_override = m
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_viewmodel.scale = Vector3.ONE * 0.5
	_viewmodel.position = VM_POS
	_viewmodel.rotation = Vector3(0.04, 0.07, 0)
	_viewmodel.visible = _fpv


func _update_fpv(delta: float) -> void:
	player.cam_yaw = _fyaw
	player.face_look(_fyaw)
	if player.moving and player.on_ground():
		_bob += delta * (14.0 if player.running else 9.0)
	var bob := sin(_bob) * (0.07 if player.running else 0.04) if player.moving else 0.0
	_fcam.global_position = player.head_position() + Vector3(0, bob, 0)
	_fcam.rotation = Vector3(_fpitch, _fyaw, 0)
	# Weapon sway while walking; recoil is a damped spring (snappy kick,
	# smooth settle) instead of a linear slide.
	_recoil_v += (-170.0 * _recoil - 18.0 * _recoil_v) * delta
	_recoil += _recoil_v * delta
	_fcam.rotation.x += _recoil * 0.03
	var sway := Vector3(sin(_bob * 0.5) * 0.015, absf(sin(_bob)) * 0.015, 0) if player.moving else Vector3.ZERO
	if player.flying and not player.on_ground():
		sway = Vector3(0, sin(Time.get_ticks_msec() * 0.004) * 0.01, 0)
	var jitter := Vector3.ZERO
	if _vm_shake > 0.0:
		_vm_shake -= delta
		jitter = Vector3(randf_range(-1, 1), randf_range(-1, 1), 0) * 0.006
	_viewmodel.position = VM_POS + sway + jitter + Vector3(0, _recoil * 0.025 - _vm_dip * 0.3, _recoil * 0.09)
	if not _viewmodel.has_meta("swing"):
		_viewmodel.rotation.x = 0.04 + _recoil * 0.35 - _vm_dip * 0.6
	_fpv_light.light_energy = move_toward(_fpv_light.light_energy, 0.0, delta * 40.0)


## Hour of day (0-24) from the cluster clock in the player's time zone.
## Real time by default; the "accelerated" option runs a day in 4 minutes.
func _cluster_hour(delta: float) -> float:
	_clock_local += delta
	var t := _clock_base + _clock_local if _clock_base > 0.0 else Time.get_unix_time_from_system()
	var bias: int = Time.get_time_zone_from_system().get("bias", 0)
	var hour := fposmod((t + bias * 60.0) / 3600.0, 24.0)
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--hour="):
			return float(arg.substr(7))
	if Settings.fast_day:
		_fast_t += delta
		hour = fposmod(hour + _fast_t * 24.0 / 240.0, 24.0)
	return hour


func _update_daylight(delta: float) -> void:
	var h := _cluster_hour(delta)
	hud.clock_text = "%02d:%02d" % [int(h), int(fmod(h, 1.0) * 60.0)]
	# Sun elevation: >0 between 06:00 and 18:00, peaks at noon.
	var elev := sin((h - 6.0) / 12.0 * PI)
	var day := clampf(elev * 2.5, 0.0, 1.0)            # 0 night .. 1 full day
	var golden := clampf(1.0 - absf(elev) * 4.0, 0.0, 1.0) * (1.0 if elev > -0.25 else 0.0)
	if Look.always_night():
		day = 0.25  # space: starry black, lit a little by the station
		golden = 0.0
	_sun.rotation_degrees = Vector3(-clampf(elev * 80.0, 4.0, 80.0), -30.0 + (h - 12.0) * 12.0, 0)
	_sun.light_energy = 1.15 * day
	_sun.light_color = Color("fff1e8").lerp(Color("ff9a4a"), golden)
	_sun.visible = day > 0.01
	_moon.light_energy = 0.6 * (1.0 - day)
	var night_sky: Color = Look.v("sky_night")
	var day_sky: Color = Look.v("sky_day")
	var dusk_sky: Color = Look.v("sky_dusk")
	var sky := night_sky.lerp(day_sky, day).lerp(dusk_sky, golden * 0.6)
	_env.background_color = sky
	_env.fog_light_color = sky
	_env.ambient_light_color = Color("5a6aa8").lerp(Color("8fa0d8"), day).lerp(Color("c98b7a"), golden * 0.4)
	_env.ambient_light_energy = lerpf(0.55, 0.6, day)
	# Weather on top: dimmer sun, greyer sky, thicker fog, lightning flashes.
	var wl: Array = weather.light() if weather else [1.0, Color.WHITE, 0.0, 0.006]
	_sun.light_energy *= float(wl[0])
	_env.background_color = sky.lerp(wl[1], float(wl[2]))
	_env.fog_light_color = _env.background_color
	_env.fog_density = float(wl[3])
	_env.ambient_light_energy += weather.flash() * 1.5 if weather else 0.0
	if weather and weather.kind != "clear":
		hud.clock_text += "  " + tr(weather.kind.to_upper())
	Sfx.set_night(1.0 - day)
	_stars.visible = day < 0.35


func _mouse_px() -> Vector2:
	return get_viewport().get_mouse_position() * _ui


func _update_labels() -> void:
	var items := []
	if not hud.is_connect_visible():
		var cam := _active_cam()
		var me := player.global_position
		# Phones: only what is close (or selected / in trouble), a few at most;
		# zoomed far out: titles without the second line.
		var near_r := 14.0 + _zoom * 0.25
		var kept := 0
		var all: Array = world.labels(me)
		if hud.compact:
			all.sort_custom(func(a, b): return a.pos.distance_to(me) < b.pos.distance_to(me))
		for l in all:
			if cam.is_position_behind(l.pos):
				continue
			if _fpv and l.pos.distance_to(me) > 28.0:
				continue
			var e = l.get("entity")
			var pinned: bool = e != null and (e == world.hovered or e == world.selected or e == hud.inspected())
			if hud.compact and e != null and not pinned:
				var d: float = Vector2(l.pos.x - me.x, l.pos.z - me.z).length()
				if d > near_r or kept >= 7:
					continue
				kept += 1
				if d > 7.0:
					l.sub = ""
			if _zoom > 40.0 and not pinned:
				l.sub = ""
			l.screen = cam.unproject_position(l.pos) * _px / _ui
			items.append(l)
		# Kubi's speech bubble and the watchtower ghosts' name tags.
		var extra := []
		if _kubi.visible and _kubi.bubble != "":
			extra.append({"pos": _kubi.global_position + Vector3(0, 0.7, 0), "text": _kubi.bubble.left(80), "color": _kubi.bubble_color, "big": false})
		for g in _ghosts.values():
			extra.append({"pos": g.global_position + Vector3(0, 1.9, 0), "text": g.label, "color": g.color, "big": false, "small": true})
		for l in extra:
			if not cam.is_position_behind(l.pos):
				l.screen = cam.unproject_position(l.pos) * _px / _ui
				items.append(l)
	hud.overlay.items = items
	hud.overlay.queue_redraw()


## Screen-space picking: nearest small entity under the cursor, otherwise
## the node island under the cursor's ground point.
func _pick(mouse: Vector2) -> Entity:
	var cam := _active_cam()
	# Label plates are clickable too (they are the easiest target).
	var ui_mouse := mouse / _ui
	for i in range(hud.overlay.hits.size() - 1, -1, -1):
		var h: Array = hud.overlay.hits[i]
		if h[0].has_point(ui_mouse) and is_instance_valid(h[1]):
			return h[1]
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
	if hud.touch and _touch_input(event):
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
					if not _dragging and _press_button == MOUSE_BUTTON_LEFT and not hud.is_modal_open() and _on_kubi(event.position):
						# A tap can arrive twice on mobile browsers: ignore the echo.
						if Time.get_ticks_msec() - _kubi_tap_ms > 400:
							_kubi_tap_ms = Time.get_ticks_msec()
							hud.toggle_kubi()
						_dragging = false
						_press_button = 0
						return
					if not _dragging and _press_button == MOUSE_BUTTON_LEFT and not hud.is_modal_open():
						hud.inspect(_hovered)
						if Settings.click_to_move and not _fpv:
							_click_move(event.position * _ui, _hovered)
					_dragging = false
					_press_button = 0
			MOUSE_BUTTON_WHEEL_UP:
				if event.pressed:
					_zoom_target = clampf(_zoom_target * 0.9, ZOOM_MIN, _zoom_max())
			MOUSE_BUTTON_WHEEL_DOWN:
				if event.pressed:
					_zoom_target = clampf(_zoom_target * 1.1, ZOOM_MIN, _zoom_max())
	# Native trackpads (macOS) send gestures, not wheel clicks: two-finger
	# scroll zooms like the wheel, pinch zooms like on a phone. Browsers turn
	# both into wheel events, so the web build never sees these.
	elif event is InputEventPanGesture:
		_zoom_target = clampf(_zoom_target * pow(1.1, clampf(event.delta.y, -4.0, 4.0) * 0.5), ZOOM_MIN, _zoom_max())
	elif event is InputEventMagnifyGesture:
		_zoom_target = clampf(_zoom_target / maxf(0.2, event.factor), ZOOM_MIN, _zoom_max())
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
		_zoom_target = clampf(_zoom_target / event.factor, ZOOM_MIN, _zoom_max())
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
			KEY_EQUAL, KEY_KP_ADD: _zoom_target = clampf(_zoom_target * 0.85, ZOOM_MIN, _zoom_max())
			KEY_MINUS, KEY_KP_SUBTRACT: _zoom_target = clampf(_zoom_target * 1.15, ZOOM_MIN, _zoom_max())
			KEY_SPACE: player.jump()
			KEY_Z: player.set_flying(not player.flying)
			KEY_Y: hud.toggle_kubi()
			KEY_O:
				hud.toggle_watch()
				_update_ghosts([])
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
			KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6:
				_select_weapon(event.physical_keycode - KEY_1)


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
	_pan += fwd * rel_px.y * units / sin(deg_to_rad(-_pitch))


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


var _warping := false
var _door_armed := false      # doors only trigger after you have stepped off one
var _prev_level := "plant"
var _zone := ""               # area the player is in, for the zone banner
var _need_spawn := true       # place the player once the level has been built
# Opening fly-through (Internet -> Ingress gate -> the plant). -1 = not playing.
var _intro_t := -1.0
var _intro_keys: Array = []   # [{t, focus, zoom, yaw}]
var _intro_ui: IntroOverlay
var _intro_layer: CanvasLayer
const INTRO_CAPTIONS := [
	{"from": 3.8, "to": 6.6, "text": "The Internet: every request to your domains starts here"},
	{"from": 6.8, "to": 9.4, "text": "The Ingress gate sends each domain to its Service"},
	{"from": 9.6, "to": 12.6, "text": "Inside, your cluster: each building is a namespace, each robot a pod"},
]


## Mario-style warp: hop onto the pipe, sink into it spinning, fade out,
## pop out of the destination pipe and hop onto the island.
func _warp(from_pipe: Vector3, to_node: String) -> void:
	if _warping:
		return
	_warping = true
	player.frozen = true
	Sfx.play("pipe")
	var b := player.body()
	var top := from_pipe + Vector3(0, 1.25, 0)
	var tw := create_tween()
	tw.tween_property(player, "position", top, 0.22).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw.finished
	world.poof(top, Vox.GREEN)
	tw = create_tween().set_parallel(true)
	tw.tween_property(player, "position", top - Vector3(0, 1.3, 0), 0.45).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_IN)
	tw.tween_property(b, "scale", Vector3(0.5, 1.1, 0.5), 0.45)
	tw.tween_property(b, "rotation:y", b.rotation.y + TAU * 1.5, 0.45)
	hud.fade(1.0, 0.35)
	await tw.finished
	# Travel
	var dest_top := world.pipe_top(to_node)
	player.position = dest_top - Vector3(0, 1.3, 0)
	_pan = Vector3.ZERO
	await get_tree().create_timer(0.15).timeout
	hud.fade(0.0, 0.3)
	tw = create_tween().set_parallel(true)
	tw.tween_property(player, "position", dest_top + Vector3(0, 1.4, 0), 0.4).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(b, "scale", Vector3.ONE, 0.4)
	await tw.finished
	world.poof(dest_top + Vector3(0, 0.4, 0), Vox.GREEN)
	# Hop down next to the pipe
	var land := _standable_near(world.warp_target(to_node))
	tw = create_tween()
	tw.tween_property(player, "position", land, 0.35).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	player.teleport(land)
	player.frozen = false
	_warping = false


## Explains where you are: a banner when you step onto a node island or
## into a hall, plus the path in the level bar.
func _update_zone() -> void:
	if hud.is_connect_visible() or K8s.state.is_empty():
		return
	var zone := world.level
	var title := ""
	var body := ""
	if world.level == "power":
		var isl := world.island_at(player.global_position)
		if isl:
			zone = "node:" + isl.key
			var here: int = isl.slots.size()
			if isl.is_control_plane():
				title = tr("CONTROL-PLANE: %s") % isl.key
				body = tr("The brain of the cluster. It runs the API server (every kubectl talks to it), etcd (the cluster's database), the scheduler (picks a node for each pod) and the controller-manager (makes reality match the desired state). Its components are pods in kube-system: %d here.") % here
			else:
				title = tr("WORKER NODE: %s") % isl.key
				body = tr("A machine that runs your workloads. Its kubelet starts the containers the scheduler assigns here and reports their health to the control-plane. %d pods here.") % here
			if isl.data.get("unschedulable", false):
				body += " " + tr("It is CORDONED: no new pods will be scheduled here.")
	elif world.level.begins_with("pod:") or world.level == "engine":
		zone = world.level
	elif world.level.begins_with("ns:"):
		var ns := world.current_ns()
		title = tr("NAMESPACE: %s") % ns
		body = tr("A space inside the cluster. %d assembly lines (workloads) make %d pods (robots); %d loading docks (services) send them traffic.") % [
			world.lines.size(), world.pods.size(), world.services.size()]
	if zone == _zone:
		return
	_zone = zone
	var path := world.level_title()
	if zone.begins_with("node:"):
		path += "  >  " + zone.substr(5)
	hud.set_level_title(path)
	if title != "":
		hud.banner(title, body)


## Walking onto a door mat (hall doors, exits) goes through it, no key
## needed. Warp pipes and terminals stay on E: they are things you "use".
func _auto_doors() -> void:
	if _warping or hud.is_connect_visible() or hud.is_modal_open():
		return
	var p := player.global_position
	var near := world.door_near(p, 0.9)
	if near.is_empty():
		if world.door_near(p, 1.6).is_empty():
			_door_armed = true
		return
	var to := str(near.to)
	# Walking a clicked path: only the door you clicked counts, not the
	# ones you brush past on the way.
	if not _path.is_empty():
		var goal: Vector3 = _path[-1]
		if Vector2(goal.x - near.pos.x, goal.z - near.pos.z).length() > 1.5:
			return
	if _door_armed and not to.begins_with("warp:") and not to.begins_with("term:") and player.on_ground():
		_door_armed = false
		Sfx.play("door")
		_go_level(to)


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
		if str(d.to).begins_with("warp:"):
			_warp(d.pos - Vector3(0, 0, 0.9), str(d.to).substr(5))
			return
		if str(d.to).begins_with("term:"):
			var nn := str(d.to).substr(5)
			var isl: NodeIsland = world.islands.get(nn)
			if isl:
				hud.inspect(isl)
			hud.node_terminal(nn, isl != null and isl.is_control_plane())
			return
		_go_level(d.to)
		return
	var e := hud.inspected()
	if e is FactoryBuilding:
		_go_level("power" if e.is_power else "ns:" + e.key)
		return
	if e is EngineHall:
		_go_level("engine")
		return
	if e is PodBot and not world.swim_level:
		_go_level("pod:" + e.key)
		return
	hud.inspect(_nearest(3.5, ""))


var _weapon := 0
var _pod_t := 0.0          # inside a pod: seconds since the last detail refresh
var _pod_log_t := 0.0
var _pod_logs := {}        # container -> last log line seen (new ones become bubbles)
var _cooldown := 0.0
var _shake := 0.0


func _select_weapon(i: int) -> void:
	if i >= Weapons.LIST.size():
		return
	if not Weapons.unlocked(i):
		hud.toast(tr("Locked: complete the mission \"%s\"") % tr(Weapons.unlock_title(i)), false)
		return
	_weapon = i
	var w: Dictionary = Weapons.LIST[i]
	player.set_weapon_color(w.color)
	_build_viewmodel(i)
	hud.set_weapon(i)
	hud.toast("%d  %s: %s" % [i + 1, tr(w.name), tr(w.desc)], true)


## Fires the current weapon. It always animates (even with nothing in
## range); only a hit on a real target performs the Kubernetes operation,
## at the moment the shot lands.
func _blast() -> void:
	if not hud.chaos:
		hud.toast(tr("Blaster locked. Press C to enable CHAOS MODE."), false)
		return
	if _cooldown > 0.0:
		return
	var w: Dictionary = Weapons.LIST[_weapon]
	_cooldown = w.cooldown
	var tgt := _aim(w.target)
	var from := player.muzzle()
	if _fpv:
		from = _fpv_muzzle()
	var to: Vector3 = tgt.pos if not tgt.is_empty() else _miss_point()
	if tgt.is_empty():
		_fire_anim(w, from, to, func(): world.sfx("miss", to))
		return
	var req: Dictionary = tgt.req
	match w.id:
		"hammer":
			req = {"action": "restart", "kind": tgt.w.kind, "ns": tgt.w.ns, "name": tgt.w.name}
		"ray":
			if tgt.w.kind == "DaemonSet":
				hud.toast(tr("A DaemonSet runs one pod per node: it cannot be scaled"), false)
				_fire_anim(w, from, to, func(): pass)
				return
			req = {"action": "scale", "kind": tgt.w.kind, "ns": tgt.w.ns, "name": tgt.w.name, "replicas": maxi(0, int(tgt.w.desired) - 1)}
		"freeze":
			req = {"action": "uncordon" if tgt.n.get("unschedulable", false) else "cordon", "name": tgt.n.name}
		"cutter":
			req = {"action": "delete_service", "ns": tgt.s.ns, "name": tgt.s.name}
		"nuke":
			req = {"action": "delete_workload", "kind": tgt.w.kind, "ns": tgt.w.ns, "name": tgt.w.name}
	var act := func(): K8s.action(req)
	if w.id == "blaster":
		act = func():
			for p in world.pods.values():
				if p.global_position.distance_to(to) < 1.5:
					p.hit(from)
					break
			K8s.action(req)
	if w.id in ["cutter", "nuke"]:
		# The two irreversible ones always ask, even in chaos mode.
		_cooldown = 0.0
		hud.confirm(tr("%s: %s") % [tr(w.name), Kubectl.for_action(req)], func():
			_cooldown = w.cooldown
			_fire_anim(w, from, to, act), Kubectl.for_action(req))
		return
	_fire_anim(w, from, to, act)


## First person: shots start a little ahead of the camera, lined up with
## the gun's muzzle on screen (starting at the muzzle itself, a few cm
## from the lens, made projectiles fill the whole screen).
func _fpv_muzzle() -> Vector3:
	var b := _fcam.global_basis
	return _fcam.global_position - b.z * 1.7 + b.x * 0.42 - b.y * 0.32


## Where a shot goes when nothing is in range: straight ahead, as far as
## that weapon reaches (the hammer hits the ground right in front of you).
func _miss_point() -> Vector3:
	var reach: float = {"blaster": 9.0, "hammer": 2.2, "ray": 6.0, "freeze": 4.5, "cutter": 6.0, "nuke": 9.0}.get(Weapons.LIST[_weapon].id, 8.0)
	if _fpv:
		return _fcam.global_position - _fcam.global_basis.z * reach
	return player.global_position + Vector3(0, 0.7, 0) + player.forward() * reach


## Per-weapon animation + sound; on_impact runs when the shot lands.
func _fire_anim(w: Dictionary, from: Vector3, to: Vector3, on_impact: Callable) -> void:
	var col: Color = w.color
	player.fire_pose()
	match w.id:
		"blaster":
			_kick(0.9, col)
			world.sfx("blaster")
			world.bolt(from, to, col, func():
				world.sfx("hit", to)
				on_impact.call())
		"hammer":
			_swing()
			world.sfx("hammer")
			await get_tree().create_timer(0.15).timeout
			var ground := Vector3(to.x, world.surface_y(Vector2(to.x, to.z)) if world.surface_y(Vector2(to.x, to.z)) != -INF else player.global_position.y, to.z)
			world.shockwave(ground, col)
			on_impact.call()
		"ray":
			_kick(0.35, col)
			_vm_shake = 0.5
			world.sfx("ray")
			world.beam(from, to, col, 0.5)
			await get_tree().create_timer(0.4).timeout
			world.flash(to, col, 0.8)
			on_impact.call()
		"freeze":
			_kick(0.4, col)
			_vm_shake = 0.35
			world.sfx("freeze")
			world.spray(from, to, col)
			await get_tree().create_timer(0.35).timeout
			world.ice(Vector3(to.x, player.global_position.y if world.surface_y(Vector2(to.x, to.z)) == -INF else world.surface_y(Vector2(to.x, to.z)), to.z), col)
			on_impact.call()
		"cutter":
			_kick(0.6, col)
			_throw_blade()
			world.sfx("cutter")
			world.boomerang(from, to, col, on_impact)
		"nuke":
			_kick(1.8, col)
			_reload_nuke()
			world.sfx("nuke_launch")
			world.rocket(from, to, func():
				world.sfx("explosion", to)
				on_impact.call())


## First person: recoil impulse + muzzle flash + a flash of light.
func _kick(strength: float, col: Color) -> void:
	_recoil_v += strength * 9.0
	if not _fpv:
		return
	var fl: Node3D = _vm_parts.get("flash")
	if fl:
		fl.visible = true
		fl.rotation.z = randf() * TAU
		fl.scale = Vector3.ONE * randf_range(0.8, 1.2) * (1.4 if strength > 1.0 else 1.0)
		get_tree().create_timer(0.06).timeout.connect(func():
			if is_instance_valid(fl):
				fl.visible = false)
	_fpv_light.light_color = col
	_fpv_light.light_energy = 1.0 + strength * 0.8


## Hammer: wind up, slam down, then bring it back.
func _swing() -> void:
	_viewmodel.set_meta("swing", true)
	var tw := create_tween()
	tw.tween_property(_viewmodel, "rotation:x", 0.7, 0.1).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_QUAD)
	tw.tween_property(_viewmodel, "rotation:x", -1.25, 0.07).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func(): _recoil_v -= 4.0)
	tw.tween_interval(0.08)
	tw.tween_property(_viewmodel, "rotation:x", 0.04, 0.28).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)
	tw.tween_callback(func(): _viewmodel.remove_meta("swing"))


## Cutter: the blade leaves the gun and snaps back when the boomerang returns.
func _throw_blade() -> void:
	var b: Node3D = _vm_parts.get("blade")
	if b == null:
		return
	b.visible = false
	await get_tree().create_timer(0.6).timeout
	if is_instance_valid(b):
		b.visible = true
		_recoil_v += 3.0


## Nuke: the warhead is gone after launch; lower the tube, reload, raise it.
func _reload_nuke() -> void:
	var wh: Node3D = _vm_parts.get("warhead")
	if wh:
		wh.visible = false
	var tw := create_tween()
	tw.tween_interval(0.35)
	tw.tween_property(self, "_vm_dip", 1.0, 0.25).set_ease(Tween.EASE_IN).set_trans(Tween.TRANS_QUAD)
	tw.tween_callback(func():
		if is_instance_valid(wh):
			wh.visible = true
		Sfx.play("click"))
	tw.tween_property(self, "_vm_dip", 0.0, 0.35).set_ease(Tween.EASE_OUT).set_trans(Tween.TRANS_BACK)


func _boom(p: Vector3, col: Color, big: bool) -> void:
	for k in (14 if big else 4):
		world.poof(p + Vector3(randf_range(-1.5, 1.5), randf_range(0, 2), randf_range(-1.5, 1.5)) * (1.5 if big else 0.6), col)


## Finds what the weapon would hit: {pos, req, w?, n?, s?} or {}.
func _aim(kind: String) -> Dictionary:
	var me := player.global_position
	var fwd := player.forward()
	# Lambdas capture locals by value: keep the running best in a dictionary.
	var st := {"best": {}, "score": 1e9}
	var consider := func(pos: Vector3, reach: float, info: Dictionary):
		var to := pos - me
		to.y = 0
		var d := to.length()
		if d > reach:
			return
		var score := d - to.normalized().dot(fwd) * 3.0
		if score < st.score:
			st.score = score
			info["pos"] = pos
			st.best = info
	match kind:
		"pod":
			for p in world.pods.values():
				if not p.dying and p.category != "term":
					consider.call(p.global_position + Vector3(0, p.top_y * 0.5, 0), 7.0,
						{"req": {"action": "delete_pod", "ns": p.data.ns, "name": p.data.name}})
		"workload":
			# Lines (inside a hall) or the owner of a pod you hit (anywhere).
			for l in world.lines.values():
				consider.call(l.global_position + Vector3(0.6, 1.0, 0), 7.0, {"req": {}, "w": l.data})
			for p in world.pods.values():
				if p.dying:
					continue
				var w := _workload_of(p.data)
				if not w.is_empty():
					consider.call(p.global_position + Vector3(0, p.top_y * 0.5, 0), 7.0, {"req": {}, "w": w})
		"node":
			for isl in world.islands.values():
				var c: Vector3 = isl.global_position
				consider.call(c + Vector3(0, 0.5, 0), isl.size * 0.5 + 6.0, {"req": {}, "n": isl.data})
		"service":
			for dk in world.services.values():
				consider.call(dk.global_position + Vector3(0, 1.0, 0), 8.0, {"req": {}, "s": dk.data})
	return st.best


func _workload_of(pod: Dictionary) -> Dictionary:
	for w in K8s.state.get("workloads", []):
		if w.ns == pod.ns and w.kind == pod.get("owner_kind", "") and w.name == pod.get("owner_name", ""):
			return w
	return {}



# ------------------------------------------------------------ Kubi

## New snapshot: count problems, refresh the panel, speak up when it gets worse.
func _kubi_state(s: Dictionary) -> void:
	var probs := Diagnose.problems(s).filter(func(d): return d.sev > 0)  # housekeeping isn't an alarm
	var sig := ",".join(probs.map(func(d): return "%s/%s/%s/%s" % [d.kind, d.ns, d.name, d.title]))
	if sig != _kubi_sig:
		_kubi_sig = sig
		if hud.kubi.visible:
			hud.kubi.refresh(s)
	if probs.size() > _kubi_count and not hud.is_connect_visible():
		_kubi.say(Diagnose.bubble(probs, hud.touch), 7.0, Vox.ORANGE)
		Sfx.play("alarm")
	elif probs.is_empty() and _kubi_count > 0:
		_kubi.say(tr("All good!"), 4.0, Vox.GREEN)
	_kubi_count = probs.size()
	if _kubi.mood in ["ok", "alert"]:
		_kubi.mood = "alert" if _kubi_count > 0 else "ok"


func _kubi_tick(delta: float) -> void:
	_kubi.visible = not hud.is_connect_visible()
	_kubi_t -= delta
	if _kubi_t > 0.0:
		return
	_kubi_t = 0.4
	# Point at the closest problem on this level.
	var best := Vector3.INF
	var best_d := 1e9
	var me := player.global_position
	for d in Diagnose.problems(K8s.state).filter(func(x): return x.sev > 0):
		var e: Entity = null
		match world.level:
			"plant": e = world.buildings.get(d.ns) if d.ns != "" else null
			"power": e = world.islands.get(d.name) if d.kind == "Node" else world.islands.get(_pod_node(d))
			_: e = world.pods.get(d.ns + "/" + d.name) if d.kind == "Pod" else null
		if e == null or not is_instance_valid(e):
			continue
		var dist := me.distance_to(e.global_position)
		if dist < best_d:
			best_d = dist
			best = e.global_position
	_kubi.look_at_pos = best
	# Comment on what you are inspecting, if it is broken.
	var ins := hud.inspected()
	if ins != _kubi_seen:
		_kubi_seen = ins
		var d := {}
		if ins is PodBot:
			d = Diagnose.pod(ins.data, K8s.state)
		elif ins is NodeIsland:
			var nd: Dictionary = ins.data
			if not nd.get("ready", true) or nd.get("unschedulable", false):
				d = Diagnose.node(nd, K8s.state)
		if not d.is_empty() and d.sev >= 1:
			_kubi.say(("%s  " + (tr("(tap me)") if hud.touch else "[Y]")) % d.title, 6.0, Vox.ORANGE)
			if hud.kubi.visible:
				hud.kubi.select(d)


func _pod_node(d: Dictionary) -> String:
	for p in K8s.state.get("pods", []):
		if p.ns == d.ns and p.name == d.name:
			return p.get("node", "")
	return ""


## Buttons in Kubi's panel.
func _kubi_act(id: String, d: Dictionary) -> void:
	var pod := {}
	for p in K8s.state.get("pods", []):
		if p.ns == d.ns and p.name == d.name:
			pod = p
	if id.begins_with("edit:"):
		var focus := id.substr(5)
		var ok_kind: String = pod.get("owner_kind", "")
		if d.kind == "Pod" and ok_kind in ["Deployment", "StatefulSet", "DaemonSet"]:
			hud.open_editor(ok_kind, d.ns, pod.get("owner_name", ""), focus)
		elif d.kind == "Node":
			hud.open_editor("Node", "", d.name, "unschedulable")
		else:
			hud.open_editor(d.kind, d.ns, d.name, focus)
		return
	if id == "clean_finished":
		hud._clean_finished(d.ns)
		return
	match id:
		"goto":
			if d.kind == "Node":
				_goto("node", d.name, "")
			else:
				_goto("pod", d.ns + "/" + d.name, d.ns)
		"logs", "logs_prev":
			if not pod.is_empty():
				hud.open_logs(pod)
		"describe":
			if not Settings.terminal:
				hud.toggle_terminal()
			hud.term_run("-n %s describe pod %s" % [d.ns, d.name], func(entry: Dictionary): hud.kubi.attach(entry))
		"restart":
			var ok_kind: String = pod.get("owner_kind", "")
			var req := {"action": "restart", "kind": ok_kind, "ns": d.ns, "name": pod.get("owner_name", "")}
			hud.confirm(tr("Restart %s %s?") % [ok_kind, req.name], func(): K8s.action(req), Kubectl.for_action(req))
		"delete_pod":
			var req := {"action": "delete_pod", "ns": d.ns, "name": d.name}
			hud.confirm(tr("Delete pod %s?") % d.name, func(): K8s.action(req), Kubectl.for_action(req))
		"uncordon":
			var req := {"action": "uncordon", "name": d.name}
			hud.confirm(tr("Uncordon node %s?") % d.name, func(): K8s.action(req), Kubectl.for_action(req))


# ------------------------------------------------------------ watchtower

func _on_intruder(v: Dictionary, why: String) -> void:
	var who: String = v.get("user", "?")
	var tool := WatchPanel.tool_name(str(v.get("agent", "")))
	var ip: String = v.get("ip", "") if v.has("ip") else ", ".join(v.get("ips", []))
	hud.banner(tr("WATCHTOWER: %s") % why.to_upper(), "%s (%s) %s\n%s %s %s" % [who, tool, ip,
		v.get("verb", v.get("last_action", "")), v.get("resource", v.get("last_resource", "")), v.get("ns", v.get("last_ns", ""))])
	Sfx.play("alarm")
	_kubi.say(tr("Watch out! %s: %s") % [why, who], 6.0, Vox.RED)
	var g: VisitorGhost = _ghosts.get(v.get("key", ""))
	if g:
		g.alarm()


## Ghosts for the people using the cluster (only while the tower is open).
func _update_ghosts(actions: Array) -> void:
	if not hud.watch.visible:
		for g in _ghosts.values():
			g.queue_free()
		_ghosts.clear()
		return
	var alive := {}
	for v in hud.watch.visible_visitors():
		if v.get("source", "") == "player" or alive.size() >= 8:
			continue
		var goal := _watch_goal(v)
		if goal == Vector3.INF:
			continue
		alive[v.key] = true
		var g: VisitorGhost = _ghosts.get(v.key)
		if g == null:
			g = VisitorGhost.new()
			_vp.add_child(g)
			g.setup(v.key, WatchPanel.color_for(v.key), "")
			g.global_position = goal + Vector3(6, 0, 6).rotated(Vector3.UP, randf() * TAU)
			_ghosts[v.key] = g
			world.poof(g.global_position + Vector3(0, 1, 0), g.color)
		g.goal = goal
		var who: String = v.user if v.user != "" else "?"
		g.set_text("%s · %s" % [who.get_slice(":", who.get_slice_count(":") - 1), WatchPanel.tool_name(v.agent)])
	for k in _ghosts.keys():
		if not alive.has(k):
			world.poof(_ghosts[k].global_position + Vector3(0, 1, 0), Vox.WHITE)
			_ghosts[k].queue_free()
			_ghosts.erase(k)
	# Writes: the ghost zaps what it changed.
	for a in actions:
		var g: VisitorGhost = _ghosts.get(a.get("key", ""))
		if g and a.get("write", false):
			world.zap(g.global_position + Vector3(0, 1.2, 0), g.goal + Vector3(0, 0.8, 0))
		elif g and int(a.get("code", 0)) in [401, 403]:
			g.alarm()


## Where a visitor's ghost stands on the current level (INF = not here).
func _watch_goal(v: Dictionary) -> Vector3:
	var ns: String = v.get("last_ns", "")
	var res: String = v.get("last_resource", "")
	var name: String = v.get("last_name", "")
	var jitter := Vector3(1.4, 0, 0).rotated(Vector3.UP, float(abs(str(v.key).hash()) % 628) / 100.0)
	var p := Vector3.INF
	match world.level:
		"plant":
			if world.buildings.has(ns):
				p = world.buildings[ns].door_position() + Vector3(0, 0, 1.5) + jitter
			elif res.begins_with("nodes") and world.buildings.has("@power"):
				p = world.buildings["@power"].door_position() + Vector3(0, 0, 1.5) + jitter
			else:
				p = world.spawn + jitter * 2.0
		"power":
			if res.begins_with("nodes") and world.islands.has(name):
				p = world.islands[name].target + jitter
			else:
				p = jitter * 1.5
		_:
			if "ns:" + ns != world.level:
				return Vector3.INF
			var e: Entity = world.pods.get(ns + "/" + name)
			if e == null:
				for k in world.lines:
					if str(k).ends_with("/" + name):
						e = world.lines[k]
			p = (e.target + Vector3(0, 0, 1.8) if e else world.spawn) + jitter
	var y := world.floor_y(Vector2(p.x, p.z))
	p.y = y if y != -INF else 0.0
	return p


func _first_bad_pod() -> String:
	for p in K8s.state.get("pods", []):
		if PodBot.categorize(p) == "crash":
			return p.ns + "/" + p.name
	return ""


# ------------------------------------------------------------ click-to-move

## Point of the walkable ground under the mouse (INF if none): the ray is
## tested against every floor height, highest first (islands, bridges...).
func _ground_point(mouse: Vector2) -> Vector3:
	var cam := _active_cam()
	var vp_mouse := mouse / _px
	var from := cam.project_ray_origin(vp_mouse)
	var dir := cam.project_ray_normal(vp_mouse)
	if absf(dir.y) < 0.001:
		return Vector3.INF
	var hs := {0.0: true}
	for h in world.walk_heights:
		hs[snappedf(h, 0.01)] = true
	var keys := hs.keys()
	keys.sort()
	keys.reverse()
	for h in keys:
		var t: float = (float(h) - from.y) / dir.y
		if t < 0.0:
			continue
		var p := from + dir * t
		var f := world.floor_y(Vector2(p.x, p.z))
		if f != -INF and absf(f - float(h)) < 0.06:
			return Vector3(p.x, f, p.z)
	return Vector3.INF


## Click on empty ground = walk there. Clicking something (a hall, a pod,
## an island...) only inspects it: you may just want to look at it. To go
## in, double-click a hall or walk onto its door.
func _click_move(mouse: Vector2, target: Entity) -> void:
	if target != null and not (target is NodeIsland):
		return
	var goal := _ground_point(mouse)
	if goal == Vector3.INF:
		return
	var path := _find_path(player.global_position, goal)
	if path.is_empty():
		hud.toast(tr("Can't walk there from here"), false)
		return
	_path = path
	_path_stuck = 0.0
	_show_click_marker(path[-1])


## True if you can walk in a straight line from a to b (floor all along,
## nothing solid, no step up higher than a stair).
func _walkable_line(a: Vector3, b: Vector3) -> bool:
	var d := Vector2(b.x - a.x, b.z - a.z)
	var n := int(ceilf(d.length() / 0.25))
	var prev := a.y
	for i in range(1, n + 1):
		var q := Vector2(a.x, a.z) + d * (float(i) / n)
		var f := world.floor_y(q)
		if f == -INF or f > prev + World.STEP or world._blocked(q, f):
			return false
		prev = f
	return true


## Path on a small grid around both points (A*); straight line if clear.
func _find_path(from: Vector3, to: Vector3) -> Array[Vector3]:
	var out: Array[Vector3] = []
	if _walkable_line(from, to):
		out.append(to)
		return out
	const C := 0.6
	for margin in [8.0, 24.0]:
		var lo := Vector2(minf(from.x, to.x), minf(from.z, to.z)) - Vector2(margin, margin)
		var hi := Vector2(maxf(from.x, to.x), maxf(from.z, to.z)) + Vector2(margin, margin)
		var w := int((hi.x - lo.x) / C) + 1
		var h := int((hi.y - lo.y) / C) + 1
		if w * h > 40000:
			break
		var g := AStarGrid2D.new()
		g.region = Rect2i(0, 0, w, h)
		g.cell_size = Vector2(C, C)
		g.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
		g.update()
		var fy := PackedFloat32Array()
		fy.resize(w * h)
		for x in w:
			for y in h:
				var q := lo + Vector2(x, y) * C
				var f := world.floor_y(q)
				fy[y * w + x] = f
				if f == -INF or world._blocked(q, f):
					g.set_point_solid(Vector2i(x, y))
		var a := Vector2i(roundi((from.x - lo.x) / C), roundi((from.z - lo.y) / C))
		var b := Vector2i(roundi((to.x - lo.x) / C), roundi((to.z - lo.y) / C))
		g.set_point_solid(a, false)
		if g.is_point_solid(b):
			continue
		var ids := g.get_id_path(a, b)
		if ids.is_empty():
			continue
		# Keep only the corners: skip points reachable in a straight line.
		var pts: Array[Vector3] = []
		for id in ids:
			var y := fy[id.y * w + id.x]
			pts.append(Vector3(lo.x + id.x * C, y if y != -INF else from.y, lo.y + id.y * C))
		pts[-1] = to
		var cur := from
		var i := 0
		while i < pts.size():
			var j := pts.size() - 1
			while j > i and not _walkable_line(cur, pts[j]):
				j -= 1
			out.append(pts[j])
			cur = pts[j]
			i = j + 1
		return out
	return out


func _follow_path(delta: float) -> void:
	if _path.is_empty():
		player.auto_dir = Vector3.ZERO
		return
	if player.manual or _fpv or _warping or hud.is_modal_open():
		_cancel_path()
		return
	var p := player.global_position
	var nxt: Vector3 = _path[0]
	var d := Vector3(nxt.x - p.x, 0, nxt.z - p.z)
	if d.length() < 0.3:
		_path.pop_front()
		if _path.is_empty():
			_cancel_path()
		return
	var left := d.length()
	for i in range(1, _path.size()):
		left += _path[i - 1].distance_to(_path[i])
	player.auto_dir = d.normalized()
	player.auto_run = left > 14.0
	# Stuck against something: hop once, then give up.
	if p.distance_to(_path_prev) < 0.5 * delta:
		_path_stuck += delta
		if _path_stuck > 0.5 and _path_stuck - delta <= 0.5:
			player.jump()
		elif _path_stuck > 1.4:
			_cancel_path()
	else:
		_path_stuck = 0.0
	_path_prev = p


func _cancel_path() -> void:
	if "--click-test" in OS.get_cmdline_user_args() and not _path.is_empty():
		print("  CANCEL at ", player.global_position, " next ", _path[0], " stuck ", _path_stuck, " manual ", player.manual)
	_path.clear()
	player.auto_dir = Vector3.ZERO
	if _click_marker:
		_click_marker.visible = false


func _show_click_marker(at: Vector3) -> void:
	if _click_marker == null:
		_click_marker = Node3D.new()
		_vp.add_child(_click_marker)
		for i in 8:
			var a := TAU * i / 8.0
			var m := Vox.box(_click_marker, Vector3(0.16, 0.06, 0.16), Vector3(cos(a), 0.04, sin(a)) * 0.45, Vox.GREEN, 3.0, false)
			m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_click_marker.global_position = at
	_click_marker.visible = true
	_click_marker.scale = Vector3.ONE * 1.6
	create_tween().tween_property(_click_marker, "scale", Vector3.ONE, 0.25).set_trans(Tween.TRANS_BACK)
	world.poof(at + Vector3(0, 0.1, 0), Vox.GREEN)


# ------------------------------------------------------------ touch

## Touch controls: on for touch screens (Settings.touch: auto/on/off).
func _want_touch() -> bool:
	if "--touch" in OS.get_cmdline_user_args():
		return true
	match Settings.touch:
		"on": return true
		"off": return false
	return DisplayServer.is_touchscreen_available() and (OS.has_feature("mobile") or OS.has_feature("web_android") or OS.has_feature("web_ios") or OS.has_feature("web"))


func _touch_tick() -> void:
	var tc := hud.touch_ctl
	var show := hud.touch and not hud.is_connect_visible() and not hud.is_modal_open() and not hud._menu_panel.visible
	if tc.visible != show:
		tc.visible = show
		tc.reset()
	player.touch_dir = tc.stick if show else Vector2.ZERO
	player.touch_up = tc.jump_held and show
	player.touch_down = tc.down_held and show
	tc.show_fire = hud.chaos
	if tc.flying != player.flying:
		tc.flying = player.flying
		tc.queue_redraw()


func _on_touch_action(id: String) -> void:
	match id:
		"jump": player.jump()
		"use": _interact()
		"jet": player.set_flying(not player.flying)
		"fire": _blast()


## Fingers on the world: two = pinch zoom + twist rotate; one in first
## person = look around. Returns true if the event was consumed.
func _touch_input(event: InputEvent) -> bool:
	# Mouse events emulated from a finger on the joystick/buttons are theirs.
	if (event is InputEventMouseButton or event is InputEventMouseMotion) and (hud.touch_ctl.owns(event.position) or _multi_touch):
		if event is InputEventMouseButton and not event.pressed:
			_press_button = 0
			_dragging = false
		return true
	if event is InputEventScreenTouch:
		if event.pressed:
			_touches[event.index] = event.position
			if _touches.size() >= 2:
				_multi_touch = true
				_press_button = 0
				_dragging = false
		else:
			_touches.erase(event.index)
			if _touches.is_empty():
				_multi_touch = false
		return false
	if event is InputEventScreenDrag and _touches.has(event.index):
		var old: Vector2 = _touches[event.index]
		if _touches.size() >= 2:
			var ids := _touches.keys()
			var other: Vector2 = _touches[ids[1] if ids[0] == event.index else ids[0]]
			var d0 := old.distance_to(other)
			var d1 := (event.position as Vector2).distance_to(other)
			if d0 > 10.0 and d1 > 10.0:
				_zoom_target = clampf(_zoom_target * d0 / d1, ZOOM_MIN, _zoom_max())
			var a0 := (old - other).angle()
			var a1 := ((event.position as Vector2) - other).angle()
			_yaw_target += rad_to_deg(angle_difference(a0, a1)) * -1.0
			_yaw = _yaw_target
		elif _fpv:
			_fyaw -= event.relative.x * 0.008
			_fpitch = clampf(_fpitch - event.relative.y * 0.008, -1.35, 1.2)
		_touches[event.index] = event.position
		return _touches.size() >= 2 or _fpv
	return false


## True if a click/tap (UI units) is on Kubi or its speech bubble.
func _on_kubi(ui_pos: Vector2) -> bool:
	if not _kubi.visible:
		return false
	var cam := _active_cam()
	if cam.is_position_behind(_kubi.global_position):
		return false
	var sp := cam.unproject_position(_kubi.global_position) * _px / _ui
	var bubble := cam.unproject_position(_kubi.global_position + Vector3(0, 0.7, 0)) * _px / _ui
	return ui_pos.distance_to(sp) < 36.0 or (_kubi.bubble != "" and ui_pos.distance_to(bubble + Vector2(0, -20)) < 50.0)


func _zoom_max() -> float:
	return ZOOM_MAX * (2.0 if hud != null and hud.touch else 1.0)


## World pixel scale: the base one, finer when zoomed far out.
func _pixel_scale() -> int:
	return maxi(1, roundi(_base_px * clampf(26.0 / maxf(_zoom, 1.0), 0.34, 1.0)))


## Starts the opening fly-through: from the Internet globe, along the road
## through the Ingress gate, down to the player. Any key or tap skips it.
func _start_intro() -> void:
	if world.level != "plant" or world.gate == null or _fpv:
		return
	var globe: Vector3 = world.internet._globe.global_position if world.internet and world.internet._globe else world.gate.global_position + Vector3(0, 10, -30)
	var gate: Vector3 = world.gate.global_position
	var home := player.global_position + Vector3(0, 0.8, 0)
	var y0 := _yaw_target
	_intro_keys = [
		{"t": 0.0, "focus": globe + Vector3(0, -2, 0), "zoom": 30.0, "yaw": y0 - 70.0},
		{"t": 3.6, "focus": Vector3(gate.x, 5.0, gate.z - 16.0), "zoom": 36.0, "yaw": y0 - 40.0},
		{"t": 6.6, "focus": Vector3(gate.x, 2.0, gate.z - 7.0), "zoom": 30.0, "yaw": y0 - 20.0},
		{"t": 9.4, "focus": gate + Vector3(0, 2, 0), "zoom": 22.0, "yaw": y0 - 5.0},
		{"t": 12.6, "focus": home.lerp(gate, 0.25), "zoom": 30.0, "yaw": y0},
		{"t": 14.0, "focus": home, "zoom": _zoom_target, "yaw": y0},
	]
	_intro_t = 0.0
	for a in OS.get_cmdline_user_args():  # dev: --intro-at=SECONDS jumps into the fly-through
		if a.begins_with("--intro-at="):
			_intro_t = float(a.substr(11))
	_pan = Vector3.ZERO
	_cancel_path()
	hud.visible = false
	if _intro_layer == null:
		_intro_layer = CanvasLayer.new()
		_intro_layer.layer = 20
		add_child(_intro_layer)
		_intro_ui = IntroOverlay.new()
		_intro_ui.title_font = hud._title_font
		_intro_ui.font = hud._font
		_intro_ui.captions = INTRO_CAPTIONS
		_intro_layer.add_child(_intro_ui)
	_intro_ui.total = _intro_keys[-1].t
	_intro_layer.visible = true
	Sfx.play("jingle")


func _intro_tick(delta: float) -> Vector3:
	if not "--intro-freeze" in OS.get_cmdline_user_args():  # dev: hold a frame for screenshots
		_intro_t += delta
	player.input_enabled = false
	_intro_ui.t = _intro_t
	var keys := _intro_keys
	if _intro_t >= keys[-1].t:
		_end_intro()
		return player.global_position + Vector3(0, 0.8, 0)
	var i := 0
	while i < keys.size() - 2 and _intro_t >= keys[i + 1].t:
		i += 1
	var a: Dictionary = keys[i]
	var b: Dictionary = keys[i + 1]
	var k := smoothstep(0.0, 1.0, (_intro_t - a.t) / (b.t - a.t))
	_zoom = lerpf(a.zoom, b.zoom, k)
	_yaw = lerpf(a.yaw, b.yaw, k)
	_cam.size = _zoom
	_pivot.rotation_degrees.y = _yaw
	return (a.focus as Vector3).lerp(b.focus, k)


func _end_intro() -> void:
	if _intro_t < 0.0:
		return
	_intro_t = -1.0
	_yaw = _yaw_target
	_zoom = _zoom_target
	_intro_layer.visible = false
	hud.visible = true
	_kubi.mood = "talking"
	_kubi.say(tr("Hi! I'm Kubi. Tap anything; tap me if you need me.") if hud.touch else tr("Hi! I'm Kubi. Click anything; press Y if you need me."), 7.0, Vox.GREEN)
	get_tree().create_timer(7.0).timeout.connect(func(): _kubi.mood = "alert" if _kubi_count > 0 else "ok")


func _input(event: InputEvent) -> void:
	if _intro_t < 0.0:
		return
	var skip: bool = (event is InputEventKey and event.pressed and not event.echo) or (event is InputEventMouseButton and event.pressed) \
		or (event is InputEventScreenTouch and event.pressed)
	if skip and _intro_t > 0.3:
		_end_intro()
	if skip or event is InputEventMouseButton or event is InputEventScreenTouch or event is InputEventKey:
		get_viewport().set_input_as_handled()
