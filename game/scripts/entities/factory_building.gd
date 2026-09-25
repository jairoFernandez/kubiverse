class_name FactoryBuilding
extends Entity
## PLANT level: one factory hall per Namespace (or the power plant for the
## Nodes). Its look is a health monitor: lit windows = healthy pods, roof
## beacon = worst status inside, red smoke = something is crashing.

var w := 8.0
var d := 6.0
var h := 4.0
var stats := {}      # {pods, ok, bad, wait, workloads, services}
var is_power := false
var _geo: Node3D
var _beacon: MeshInstance3D
var _sig := ""
var _t := 0.0
var _smoke_cd := 0.0
# "On fire" effects for halls with failing pods
var _fire_light: OmniLight3D
var _slices: Array[MeshInstance3D] = []
var _fire_cd := 0.0
var _glitch_next := 1.0
var _glitch_left := 0.0
var info := {}       # NsCatalog.info(): district, style, logo, tag


func _init() -> void:
	kind = "namespace"


func setup(ns_name: String, st: Dictionary, power := false) -> void:
	is_power = power
	key = ns_name
	data = {"name": ns_name}
	stats = st
	info = {} if power else NsCatalog.info(ns_name)
	var n: int = st.get("pods", 0)
	w = clampf(7.0 + sqrt(float(n + st.get("workloads", 0) * 2)) * 1.6, 7.0, 16.0)
	d = clampf(w * 0.7, 6.0, 11.0)
	h = 3.4 + minf(float(n) * 0.06, 2.0)
	if power:
		w = 12.0
		d = 8.0
		h = 4.0
	var sig := "%s|%.1f|%s|%s" % [str(st), w, power, Look.current]
	if sig != _sig:
		_sig = sig
		_rebuild()


func health() -> String:
	if stats.get("bad", 0) > 0:
		return "bad"
	if stats.get("wait", 0) > 0:
		return "wait"
	return "ok"


func health_color() -> Color:
	match health():
		"bad": return Vox.RED
		"wait": return Vox.YELLOW
	return Vox.GREEN


func label_text() -> String:
	var t: String = tr("ENERGY PLANT (nodes)") if is_power else "namespace " + key
	return _corrupt(t) if glitching() else t


func glitching() -> bool:
	return _glitch_left > 0.0


## Glitch look for text: a few characters replaced by noise.
func _corrupt(t: String) -> String:
	var noise := "#%&@$*!?/<>"
	var out := t
	for i in maxi(1, t.length() / 4):
		var k := randi() % out.length()
		out = out.substr(0, k) + noise[randi() % noise.length()] + out.substr(k + 1)
	return out


func label_sub() -> String:
	if is_power:
		return tr("%d nodes, %d ready") % [stats.get("nodes", 0), stats.get("ready", 0)] + ((tr(", %d cordoned") % stats.cordoned) if stats.get("cordoned", 0) else "")
	var tag: String = tr(info.get("tag", "")) + " · " if info.get("tag", "") != "" else ""
	if stats.get("pods", 0) == 0 and stats.get("workloads", 0) == 0:
		return tag + tr("empty")
	var t := tag + tr("%d pods: %d ok") % [stats.get("pods", 0), stats.get("ok", 0)]
	if stats.get("wait", 0):
		t += tr(", %d waiting") % stats.wait
	if stats.get("bad", 0):
		t += tr(", %d FAILING") % stats.bad
	return t


func label_color() -> Color:
	return Vox.YELLOW if is_power else Vox.ns_color(key)


func anchor() -> Vector3:
	return global_position + Vector3(0, h + 1.6, d * 0.5)


func door_position() -> Vector3:
	return target + Vector3(0, 0, d * 0.5 + 0.9)


func is_area() -> bool:
	return true


func contains_xz(p: Vector3) -> bool:
	var l := p - global_position
	return absf(l.x) <= w * 0.5 and absf(l.z) <= d * 0.5


func footprint() -> Rect2:
	return Rect2(target.x - w * 0.5, target.z - d * 0.5, w, d)


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var nsc := Vox.YELLOW if is_power else Vox.ns_color(key)
	var wall: Color = (Look.v("building") as Color).lerp(nsc, 0.25)
	var wall_dark := wall.darkened(0.25)
	# Foundation, walls, colored band
	Vox.box(_geo, Vector3(w + 0.6, 0.2, d + 0.6), Vector3(0, 0.1, 0), Vox.SLATE)
	Vox.box(_geo, Vector3(w, h, d), Vector3(0, h * 0.5 + 0.2, 0), wall)
	Vox.box(_geo, Vector3(w + 0.04, 0.35, d + 0.04), Vector3(0, h - 0.3, 0), nsc.darkened(0.1))
	var style: String = info.get("style", "factory")
	var roof_top := h + 1.0
	if (style == "factory" and Look.current == "factory") or is_power:
		# Saw-tooth factory roof
		var teeth := maxi(2, int(w / 2.2))
		var tw := w / teeth
		for i in teeth:
			var x := -w * 0.5 + tw * (i + 0.5)
			var tooth := Vox.box(_geo, Vector3(tw * 0.95, 0.9, d), Vector3(x, h + 0.55, 0), wall_dark)
			tooth.rotation.z = deg_to_rad(-18)
			Vox.box(_geo, Vector3(0.1, 0.7, d - 0.2), Vector3(x + tw * 0.42, h + 0.55, 0), Vox.BLUE.darkened(0.3), 0.4, false)
	else:
		Vox.box(_geo, Vector3(w + 0.3, 0.3, d + 0.3), Vector3(0, h + 0.35, 0), wall_dark)
		roof_top = h + 0.5
		if style != "factory":
			_style_extras(style, nsc, wall, wall_dark)
		# Every namespace wears the chosen look (barn, dome, module, castle).
		Look.decorate_building(_geo, w, d, h, roof_top, nsc)
	# Door (front, +z) with frame and light
	Vox.box(_geo, Vector3(2.4, 2.6, 0.12), Vector3(0, 1.5, d * 0.5 + 0.02), Color("1b1b2a"), 0.0, false)
	Vox.box(_geo, Vector3(2.8, 0.3, 0.3), Vector3(0, 2.95, d * 0.5 + 0.1), nsc)
	for x in [-1.3, 1.3]:
		Vox.box(_geo, Vector3(0.25, 2.8, 0.3), Vector3(x, 1.6, d * 0.5 + 0.1), nsc.darkened(0.2))
	Vox.box(_geo, Vector3(2.2, 0.05, 1.4), Vector3(0, 0.03, d * 0.5 + 0.8), Vox.YELLOW.darkened(0.2), 0.0, false)
	# Windows = pods: lit green when ok, red when failing, dark when waiting
	var total: int = stats.get("pods", 0)
	var slots := int((w - 3.6) / 0.9)
	var shown := mini(total, slots * 2)
	var ok: int = stats.get("ok", 0)
	var bad: int = stats.get("bad", 0)
	for i in slots * 2:
		var row := i / slots
		var col := i % slots
		var side := -1.0 if col < slots / 2 else 1.0
		var x := -w * 0.5 + 0.9 + col * 0.9 + (1.8 if side > 0 else 0.0)
		if absf(x) < 1.6:
			x += 1.8 * side
		if absf(x) > w * 0.5 - 0.4:
			continue
		var c := Color("20243a")
		var glow := 0.0
		if i < shown:
			if i < ok:
				c = Vox.GREEN.lerp(Vox.YELLOW, 0.3)
				glow = 1.5
			elif i < ok + bad:
				c = Vox.RED
				glow = 2.0
			else:
				c = Vox.BLUE.darkened(0.2)
				glow = 0.8
		Vox.box(_geo, Vector3(0.6, 0.55, 0.06), Vector3(x, 1.2 + row * 0.9, d * 0.5 + 0.03), c, glow, false)
	if info.get("logo", "") != "":
		_logo(info.logo, roof_top)
	# Roof beacon = health
	_beacon = Vox.box(_geo, Vector3(0.5, 0.5, 0.5), Vector3(w * 0.5 - 0.8, h + 1.4, -d * 0.5 + 0.8), health_color(), 3.0)
	Vox.box(_geo, Vector3(0.2, 0.6, 0.2), Vector3(w * 0.5 - 0.8, h + 0.9, -d * 0.5 + 0.8), Vox.SLATE)
	# Chimney
	Vox.box(_geo, Vector3(0.8, 2.2, 0.8), Vector3(-w * 0.5 + 1.0, h + 1.1, -d * 0.5 + 1.0), Vox.BROWN)
	# Fire light and glitch slices (hidden until the hall has failing pods)
	_fire_light = OmniLight3D.new()
	_fire_light.light_color = Vox.ORANGE
	_fire_light.omni_range = w * 0.9
	_fire_light.position = Vector3(0, h + 1.5, 0)
	_fire_light.visible = false
	_geo.add_child(_fire_light)
	_slices.clear()
	for i in 5:
		var sl := Vox.box(_geo, Vector3(w * randf_range(0.3, 0.9), randf_range(0.08, 0.25), 0.05), Vector3.ZERO, [Vox.PINK, Vox.BLUE, Vox.WHITE][i % 3], 3.0, false)
		sl.visible = false
		_slices.append(sl)
	if is_power:
		# Cooling towers + generators = nodes
		for i in mini(int(stats.get("nodes", 1)), 6):
			var gx := -w * 0.5 + 1.5 + i * 1.8
			Vox.box(_geo, Vector3(1.2, 1.0, 1.0), Vector3(gx, 0.7, -d * 0.5 - 0.9), Vox.NAVY)
			Vox.box(_geo, Vector3(0.3, 0.3, 0.05), Vector3(gx, 0.9, -d * 0.5 - 0.38), Vox.GREEN, 2.0, false)
		Vox.box(_geo, Vector3(2.0, 3.0, 2.0), Vector3(w * 0.5 + 1.6, 1.5, -1.0), Vox.SILVER)
		Vox.box(_geo, Vector3(1.6, 0.4, 1.6), Vector3(w * 0.5 + 1.6, 3.2, -1.0), Vox.SILVER.darkened(0.1))


func _process(delta: float) -> void:
	_t += delta
	position = position.lerp(target, clampf(delta * 3.0, 0.0, 1.0))
	_burn(delta)
	if _beacon:
		_beacon.visible = health() == "ok" or fmod(_t, 0.8) < 0.5
		_beacon.rotation.y += delta * 2.0
	_smoke_cd -= delta
	if _smoke_cd <= 0.0 and world:
		var bad: int = stats.get("bad", 0)
		_smoke_cd = 0.25 if bad > 0 else 0.9
		var base := global_position + Vector3(-w * 0.5 + 1.0, h + 2.3, -d * 0.5 + 1.0)
		world.smoke(base, Color("9b2a3a") if bad > 0 else Color("b8bcc8"))


## Failing namespace: flames on the roof and windows, flickering fire light
## and short digital "glitch" bursts. Intensity grows with failing pods.
func _burn(delta: float) -> void:
	var bad: int = stats.get("bad", 0)
	var on_fire := bad > 0 and world != null
	if _fire_light:
		_fire_light.visible = on_fire
	if not on_fire:
		if _glitch_left > 0.0 or (_geo and _geo.position != Vector3.ZERO):
			_glitch_left = 0.0
			_end_glitch()
		return
	var heat := clampf(float(bad) / 3.0, 0.4, 1.5)
	if _fire_light:
		_fire_light.light_energy = (1.6 + sin(_t * 23.0) * 0.5 + randf() * 0.6) * heat
	# Flames
	_fire_cd -= delta
	while _fire_cd <= 0.0:
		_fire_cd += 0.09 / heat
		var p: Vector3
		if randf() < 0.7:
			p = Vector3(randf_range(-w * 0.45, w * 0.45), h + 0.9, randf_range(-d * 0.45, d * 0.45))
		else:
			p = Vector3(randf_range(-w * 0.45, w * 0.45), randf_range(1.0, 2.2), d * 0.5 + 0.1)
		world.flame(global_position + p, randf_range(0.8, 1.3) * heat)
	# Glitch bursts
	_glitch_next -= delta
	if _glitch_left > 0.0:
		_glitch_left -= delta
		_geo.position = Vector3(randf_range(-0.25, 0.25), 0, randf_range(-0.1, 0.1)) * heat
		_geo.scale = Vector3(1.0 + randf_range(-0.03, 0.03), 1.0 + randf_range(-0.06, 0.06), 1.0)
		for sl in _slices:
			sl.visible = randf() < 0.7
			sl.position = Vector3(randf_range(-w * 0.2, w * 0.2), randf_range(0.4, h), d * 0.5 + 0.08)
		if _glitch_left <= 0.0:
			_end_glitch()
	elif _glitch_next <= 0.0:
		_glitch_left = randf_range(0.08, 0.3)
		_glitch_next = randf_range(0.5, 2.2) / heat


func _end_glitch() -> void:
	if _geo:
		_geo.position = Vector3.ZERO
		_geo.scale = Vector3.ONE
	for sl in _slices:
		sl.visible = false


## Extra geometry that makes each kind of namespace recognisable.
func _style_extras(style: String, nsc: Color, wall: Color, dark: Color) -> void:
	var top := h + 0.5
	match style:
		"castle":  # the cluster's own namespaces: a small fortress
			var n := int(w / 1.2)
			for i in n:
				var x := -w * 0.5 + 0.3 + i * (w - 0.6) / maxf(1.0, n - 1)
				if i % 2 == 0:
					Vox.box(_geo, Vector3(0.5, 0.6, 0.5), Vector3(x, top + 0.3, d * 0.5 - 0.1), dark)
					Vox.box(_geo, Vector3(0.5, 0.6, 0.5), Vector3(x, top + 0.3, -d * 0.5 + 0.1), dark)
			for cx in [-1.0, 1.0]:
				for cz in [-1.0, 1.0]:
					var p := Vector3(cx * (w * 0.5 - 0.3), 0, cz * (d * 0.5 - 0.3))
					Vox.box(_geo, Vector3(1.3, h + 1.8, 1.3), p + Vector3(0, (h + 1.8) * 0.5 + 0.2, 0), wall.lightened(0.05))
					Vox.box(_geo, Vector3(1.5, 0.35, 1.5), p + Vector3(0, h + 2.15, 0), nsc)
					Vox.box(_geo, Vector3(0.2, 0.9, 0.05), p + Vector3(0, h + 3.0, 0), Vox.SILVER)
					Vox.box(_geo, Vector3(0.6, 0.35, 0.05), p + Vector3(0.4, h + 3.25, 0), nsc, 1.0, false)
		"tower":  # GitOps: a lighthouse that keeps everything in sync
			var p := Vector3(-w * 0.5 + 1.3, 0, -d * 0.5 + 1.3)
			Vox.box(_geo, Vector3(2.0, h + 5.0, 2.0), p + Vector3(0, (h + 5.0) * 0.5 + 0.2, 0), wall.lightened(0.1))
			for i in 3:
				Vox.box(_geo, Vector3(2.08, 0.3, 2.08), p + Vector3(0, h * 0.5 + i * 2.0, 0), nsc.darkened(0.15))
			Vox.box(_geo, Vector3(1.4, 1.0, 1.4), p + Vector3(0, h + 5.7, 0), Vox.YELLOW, 2.5, false)
			Vox.box(_geo, Vector3(2.2, 0.3, 2.2), p + Vector3(0, h + 6.35, 0), nsc)
		"crane":  # platform builders: construction crane on the roof
			var p := Vector3(w * 0.5 - 1.2, top, -d * 0.5 + 1.2)
			Vox.box(_geo, Vector3(0.5, 6.0, 0.5), p + Vector3(0, 3.0, 0), Vox.YELLOW)
			Vox.box(_geo, Vector3(7.0, 0.35, 0.35), p + Vector3(-2.6, 6.0, 0), Vox.YELLOW)
			Vox.box(_geo, Vector3(1.0, 0.8, 0.8), p + Vector3(0.9, 5.7, 0), Vox.SLATE)
			Vox.box(_geo, Vector3(0.06, 2.4, 0.06), p + Vector3(-5.2, 4.8, 0), Vox.SILVER, 0.0, false)
			Vox.box(_geo, Vector3(0.9, 0.6, 0.9), p + Vector3(-5.2, 3.4, 0), nsc)
		"vault":  # secrets: a bank vault door
			var c := Vector3(0, 1.6, d * 0.5 + 0.2)
			for i in 12:
				var a := TAU * i / 12.0
				Vox.box(_geo, Vector3(0.45, 0.45, 0.3), c + Vector3(cos(a) * 1.35, sin(a) * 1.35, 0), Vox.SILVER)
			Vox.box(_geo, Vector3(1.9, 1.9, 0.2), c + Vector3(0, 0, -0.05), Vox.SILVER.darkened(0.35))
			for a in [0.0, PI / 3.0, 2.0 * PI / 3.0]:
				var spoke := Vox.box(_geo, Vector3(1.3, 0.14, 0.1), c + Vector3(0, 0, 0.12), Vox.YELLOW, 0.8, false)
				spoke.rotation.z = a
			Vox.box(_geo, Vector3(w + 0.08, 0.3, d + 0.08), Vector3(0, h - 0.8, 0), Vox.YELLOW.darkened(0.2))
		"gatehouse":  # ingress: a big arch over the door
			for x in [-1.9, 1.9]:
				Vox.box(_geo, Vector3(0.7, 4.2, 0.7), Vector3(x, 2.1, d * 0.5 + 1.0), nsc.darkened(0.2))
			Vox.box(_geo, Vector3(4.6, 0.6, 0.9), Vector3(0, 4.3, d * 0.5 + 1.0), nsc)
			for i in 5:
				Vox.box(_geo, Vector3(0.35, 0.18, 0.06), Vector3(-1.4 + i * 0.7, 4.3, d * 0.5 + 1.47), Vox.YELLOW, 2.0, false)
		"dome":  # metrics / tracing: an observatory
			var c := Vector3(0, top, -d * 0.15)
			var r := minf(w, d) * 0.36
			for i in 5:
				var k := cos(float(i) / 5.0 * PI * 0.5)
				Vox.box(_geo, Vector3(r * 2.0 * k, 0.45, r * 2.0 * k), c + Vector3(0, 0.22 + i * 0.45, 0), Vox.SILVER.lightened(0.1 * i))
			Vox.box(_geo, Vector3(0.5, 1.6, 0.35), c + Vector3(0, 1.4, r * 0.55), Color("1b1b2a"), 0.0, false)
			var scope := Vox.box(_geo, Vector3(0.4, 0.4, 2.0), c + Vector3(0, 2.2, r * 0.7), Vox.SLATE)
			scope.rotation.x = deg_to_rad(-35)
		"screens":  # dashboards: big screens with charts
			for j in 2:
				var sx := -w * 0.25 + j * w * 0.5
				Vox.box(_geo, Vector3(w * 0.42, 2.2, 0.2), Vector3(sx, top + 1.3, -d * 0.2), Color("10131f"))
				for b in 5:
					var bh := 0.3 + fmod(float(b * 7 + j * 3), 5.0) * 0.28
					Vox.box(_geo, Vector3(w * 0.06, bh, 0.06), Vector3(sx - w * 0.15 + b * w * 0.075, top + 0.35 + bh * 0.5, -d * 0.2 + 0.13), [Vox.GREEN, Vox.YELLOW, Vox.ORANGE, Vox.BLUE][(b + j) % 4], 1.5, false)
				Vox.box(_geo, Vector3(0.25, 0.4, 0.25), Vector3(sx, top + 0.1, -d * 0.2), Vox.SLATE)
		"library":  # logs and search: shelves full of records
			var n := int(w / 0.7)
			for row in 2:
				for i in n:
					var x := -w * 0.5 + 0.45 + i * 0.7
					var bh := 0.5 + fmod(float(i * 13 + row * 5), 4.0) * 0.12
					Vox.box(_geo, Vector3(0.5, bh, 0.8), Vector3(x, top + bh * 0.5, -d * 0.25 + row * 1.2), [Vox.RED, Vox.BLUE, Vox.YELLOW, Vox.GREEN, Vox.LAVENDER][(i + row) % 5])
		"shop":  # a store with a striped awning
			var n := int((w - 1.0) / 0.8)
			for i in n:
				var awn := Vox.box(_geo, Vector3(0.8, 0.12, 1.6), Vector3(-w * 0.5 + 0.9 + i * 0.8, 3.45, d * 0.5 + 0.7), Vox.RED if i % 2 == 0 else Vox.WHITE)
				awn.rotation.x = deg_to_rad(18)
		"bank":  # payments: columns and a pediment
			for x in [-w * 0.5 + 0.8, -2.2, 2.2, w * 0.5 - 0.8]:
				Vox.box(_geo, Vector3(0.55, h, 0.55), Vector3(x, h * 0.5 + 0.2, d * 0.5 + 0.55), Vox.WHITE)
			Vox.box(_geo, Vector3(w + 0.4, 0.4, 1.4), Vector3(0, h + 0.4, d * 0.5 + 0.2), Vox.WHITE)
			for i in 3:
				Vox.box(_geo, Vector3(w * (0.8 - i * 0.25), 0.4, 0.6), Vector3(0, h + 0.8 + i * 0.4, d * 0.5 + 0.3), Vox.WHITE.darkened(0.05 * i))
		"silo":  # data: storage tanks
			for j in 2:
				var p := Vector3(-w * 0.5 + 1.4 + j * 2.2, top, -d * 0.5 + 1.5)
				for a in [0.0, PI / 4.0]:
					var t := Vox.box(_geo, Vector3(1.7, 3.0, 1.7), p + Vector3(0, 1.5, 0), Vox.SILVER.darkened(0.1))
					t.rotation.y = a
				Vox.box(_geo, Vector3(1.2, 0.3, 1.2), p + Vector3(0, 3.15, 0), nsc)
				Vox.box(_geo, Vector3(1.75, 0.15, 1.75), p + Vector3(0, 1.0, 0), nsc.darkened(0.2))


## Pixel logo on a roof sign, facing the street (+z).
func _logo(id: String, roof_top: float) -> void:
	var m: Array = NsCatalog.LOGOS.get(id, [])
	if m.is_empty():
		return
	var px := 0.3
	var size := px * 7 + 0.5
	var c := Vector3(0, roof_top + size * 0.5 + 0.35, d * 0.5 - 0.5)
	Vox.box(_geo, Vector3(0.2, 0.5, 0.2), c + Vector3(-size * 0.3, -size * 0.5 - 0.15, -0.1), Vox.SLATE)
	Vox.box(_geo, Vector3(0.2, 0.5, 0.2), c + Vector3(size * 0.3, -size * 0.5 - 0.15, -0.1), Vox.SLATE)
	Vox.box(_geo, Vector3(size, size, 0.15), c, Color("10131f"))
	for y in 7:
		var row: String = m[y]
		for x in 7:
			var ch := row[x]
			if ch == ".":
				continue
			Vox.box(_geo, Vector3(px, px, 0.08), c + Vector3((x - 3) * px, (3 - y) * px, 0.11), NsCatalog.LOGO_PAL[ch], 1.2, false)
