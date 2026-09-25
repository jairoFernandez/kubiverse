class_name InternetCity
extends Node3D
## The world outside the cluster, north of the plant: a little city under
## the Internet globe. Every domain of an Ingress is a neon billboard; cars
## (requests) leave it, pass through the Ingress gate and drive along the
## streets to the hall (namespace) of the Service that answers. LoadBalancer
## Services have their own pink road with a toll booth showing the external
## IP. Routes with no working backend: the car stops at the gate, "503".

var world
var signs := []          # labels for the HUD: [{pos, text, sub, color, big}]
var _routes := []        # [{pts: [Vector3], color, broken, tls, every, t}]
var _cars := []          # [{node, pts, i, speed, broken}]
var _pops := []          # transient "503" labels [{pos, t}]
var _globe: Node3D
var _boards: Array[Vector3] = []   # billboard tops (packets from the globe land there)
var _packets := []                 # [{node, from, to, t}]
var _static: Node3D
var _sig := ""
var _t := 0.0
const MAX_CARS := 60


static func host_color(host: String) -> Color:
	var pal := [Vox.PINK, Vox.BLUE, Vox.ORANGE, Color("7ad6c0"), Color("c98bff"), Vox.YELLOW, Color("a8e6ff"), Vox.PEACH]
	return pal[abs(host.hash()) % pal.size()]


## layout: {z0 (north edge of the plant), gate: Vector3, doors: {ns: Vector3}, street: {ns: x}, gw}
func setup(routes: Array, lbs: Array, layout: Dictionary) -> void:
	# Geometry only changes with the structure (domains, routes, LBs, halls);
	# route health changes often and only updates labels and cars.
	var shape := JSON.stringify([routes.map(func(r): return [r.host, r.path, r.ns, r.service, r.tls]),
		lbs.map(func(l): return [l.ns, l.name, l.external]), layout.z0, layout.gw, layout.doors])
	var build := shape != _sig
	_sig = shape
	if build:
		if _static:
			_static.queue_free()
		_static = Node3D.new()
		add_child(_static)
	var old_t := {}
	for i in _routes.size():
		old_t[i] = _routes[i].t
	signs.clear()
	_routes.clear()
	if build:
		_boards.clear()
	var z0: float = layout.z0
	var gw: float = layout.gw
	var gate: Vector3 = layout.gate
	if build:
		_build_city(z0, gw)
	else:
		signs.append({"pos": _globe.position + Vector3(0, 4.2, 0), "text": tr("THE INTERNET"), "sub": tr("requests come from here"), "color": Vox.BLUE, "big": true})
	# One billboard per domain, spread along the city front.
	var hosts := []
	for r in routes:
		if not r.host in hosts:
			hosts.append(r.host)
	var bx := {}
	for i in hosts.size():
		var x := -gw * 0.5 + 4.0 + (gw - 8.0) * (float(i) + 0.5) / maxf(1.0, hosts.size())
		bx[hosts[i]] = x
		var h: String = hosts[i]
		var col := host_color(h)
		var base := Vector3(x, 0, z0 - 9.0)
		if build or not _boards.has(base + Vector3(0, 4.4, 0)):
			_boards.append(base + Vector3(0, 4.4, 0))
		if build:
			Vox.box(_static, Vector3(0.3, 3.2, 0.3), base + Vector3(-1.2, 1.6, 0), Vox.SLATE)
		if build:
			Vox.box(_static, Vector3(0.3, 3.2, 0.3), base + Vector3(1.2, 1.6, 0), Vox.SLATE)
		if build:
			Vox.box(_static, Vector3(3.6, 1.4, 0.3), base + Vector3(0, 3.6, 0), Color("0b0d1a"))
		if build:
			Vox.box(_static, Vector3(3.3, 1.1, 0.08), base + Vector3(0, 3.6, 0.18), col, 2.2, false)
		var tls: bool = routes.any(func(r): return r.host == h and r.tls)
		if tls:  # golden padlock = HTTPS
			if build:
				Vox.box(_static, Vector3(0.5, 0.45, 0.2), base + Vector3(1.9, 4.3, 0.2), Vox.YELLOW, 2.0, false)
			if build:
				Vox.box(_static, Vector3(0.3, 0.3, 0.12), base + Vector3(1.9, 4.65, 0.2), Vox.YELLOW.darkened(0.3), 1.0, false)
		var dests := routes.filter(func(r): return r.host == h).map(func(r): return "%s -> %s/%s%s" % [r.path, r.ns, r.service, "" if r.status == "ok" else " (!)"])
		signs.append({"pos": base + Vector3(0, 5.0, 0), "text": (h if h != "" else "*") + ("  [HTTPS]" if tls else ""),
			"sub": "\n".join(dests.slice(0, 3)) + ("\n..." if dests.size() > 3 else ""), "color": col, "big": false})
		# City road from the billboard to the gate road
		if build:
			_road([base + Vector3(0, 0, 0.8), Vector3(x, 0, z0 - 4.5), Vector3(0, 0, z0 - 4.5)], Color("2a2d3c"))
	if not hosts.is_empty():
		if build:
			_road([Vector3(0, 0, z0 - 4.5), gate + Vector3(0, 0, -1.5), gate + Vector3(0, 0, 2.5)], Color("2a2d3c"))
	# Routes: billboard -> gate -> street -> hall door
	for r in routes:
		var col := host_color(r.host)
		var x: float = bx[r.host]
		var pts := [Vector3(x, 0, z0 - 8.2), Vector3(x, 0, z0 - 4.5), Vector3(0, 0, z0 - 4.5), gate + Vector3(0, 0, -1.0)]
		var broken: bool = r.status != "ok" or not layout.doors.has(r.ns)
		if not broken:
			var door: Vector3 = layout.doors[r.ns]
			var sx: float = layout.street[r.ns]
			pts.append_array([gate + Vector3(0, 0, 2.5), Vector3(sx, 0, gate.z + 2.5), Vector3(sx, 0, door.z + 0.6), Vector3(door.x, 0, door.z + 0.6)])
		_routes.append({"pts": pts, "color": col, "broken": broken, "tls": r.tls, "every": 1.6 if not broken else 3.2, "t": old_t.get(_routes.size(), randf() * 2.0)})
	# Plant streets used by the routes (drawn once per street)
	var drawn := {}
	for r in routes:
		if r.status == "ok" and layout.doors.has(r.ns) and not drawn.has(r.ns):
			drawn[r.ns] = true
			var door: Vector3 = layout.doors[r.ns]
			var sx: float = layout.street[r.ns]
			if build:
				_road([gate + Vector3(0, 0, 2.5), Vector3(sx, 0, gate.z + 2.5), Vector3(sx, 0, door.z + 0.6), Vector3(door.x, 0, door.z + 0.6)], host_color(r.host).darkened(0.55), 0.8)
	# LoadBalancer services: their own pink road straight from the city.
	for i in lbs.size():
		var lb: Dictionary = lbs[i]
		if not layout.doors.has(lb.ns):
			continue
		var door: Vector3 = layout.doors[lb.ns]
		var sx: float = layout.street[lb.ns] + 1.2
		var start := Vector3(sx, 0, z0 - 7.0)
		var booth := Vector3(sx, 0, z0 + 1.2)
		var pts := [start, booth, Vector3(sx, 0, door.z + 1.6), Vector3(door.x + 0.8, 0, door.z + 1.6)]
		if build:
			_road(pts, Vox.PINK.darkened(0.55), 0.9)
		if build:
			Vox.box(_static, Vector3(1.0, 1.6, 1.0), booth + Vector3(1.2, 0.8, 0), Vox.PINK.darkened(0.2))
		if build:
			Vox.box(_static, Vector3(1.2, 0.2, 1.2), booth + Vector3(1.2, 1.7, 0), Vox.WHITE)
		var ext: String = ", ".join(lb.external) if not lb.external.is_empty() else tr("external IP pending")
		signs.append({"pos": booth + Vector3(1.2, 2.4, 0), "text": tr("LoadBalancer %s/%s") % [lb.ns, lb.name], "sub": ext + ("  " + tr("(no ready pods)") if lb.ready == 0 else ""), "color": Vox.PINK, "big": false})
		_routes.append({"pts": pts, "color": Vox.PINK, "broken": lb.ready == 0, "tls": false, "every": 2.4, "t": old_t.get(_routes.size(), randf() * 2.0)})
	if hosts.is_empty() and lbs.is_empty():
		signs.append({"pos": Vector3(0, 6.0, z0 - 12.0), "text": tr("THE INTERNET"),
			"sub": tr("No Ingress or LoadBalancer: nothing in this cluster is reachable from outside"), "color": Vox.SILVER, "big": true})


func _build_city(z0: float, gw: float) -> void:
	var w := gw + 34.0
	Vox.box(_static, Vector3(w, 0.4, 26.0), Vector3(0, -0.25, z0 - 15.0), Color("1a1d2e"))
	Vox.box(_static, Vector3(w, 0.06, 1.0), Vector3(0, 0.0, z0 - 2.0), Vox.YELLOW.darkened(0.4), 0.0, false)  # city limit line
	var rng := Vox.rng_for("city")
	var x := -w * 0.5 + 2.0
	while x < w * 0.5 - 2.0:
		for row in 2:
			var h := rng.randf_range(3.0, 12.0) * (1.0 if row == 1 else 0.6)
			var z := z0 - 16.0 - row * 6.0 + rng.randf_range(-1.0, 1.0)
			var bw := rng.randf_range(2.2, 3.6)
			var col: Color = [Color("283050"), Color("3a2a50"), Color("2a3a48"), Color("3c3450")][rng.randi() % 4]
			Vox.box(_static, Vector3(bw, h, bw), Vector3(x, h * 0.5, z), col)
			# lit windows on the facade facing the plant
			var rows := int(h / 1.1)
			for wy in rows:
				for wx in 2:
					if rng.randf() < 0.55:
						var wc: Color = [Vox.YELLOW, Color("a8e6ff"), Vox.PEACH][rng.randi() % 3]
						Vox.box(_static, Vector3(0.35, 0.4, 0.05), Vector3(x - bw * 0.22 + wx * bw * 0.44, 0.8 + wy * 1.1, z + bw * 0.5 + 0.03), wc, 1.6, false)
					if rng.randf() < 0.45:  # side facade too (seen from the other camera angles)
						Vox.box(_static, Vector3(0.05, 0.4, 0.35), Vector3(x + bw * 0.5 + 0.03, 0.8 + wy * 1.1, z - bw * 0.22 + wx * bw * 0.44), Color("a8e6ff"), 1.4, false)
			if rng.randf() < 0.3:  # antenna with a red light
				Vox.box(_static, Vector3(0.1, 1.2, 0.1), Vector3(x, h + 0.6, z), Vox.SILVER)
				Vox.box(_static, Vector3(0.2, 0.2, 0.2), Vector3(x, h + 1.25, z), Vox.RED, 3.0, false)
		x += rng.randf_range(3.2, 4.6)
	# The Internet: a glowing voxel globe floating over the city.
	_globe = Node3D.new()
	_globe.position = Vector3(0, 13.0, z0 - 22.0)
	_static.add_child(_globe)
	for lat in range(-60, 90, 30):
		var r := 3.2 * cos(deg_to_rad(lat))
		var y := 3.2 * sin(deg_to_rad(lat))
		var n := maxi(6, int(r * 5))
		for i in n:
			var a := TAU * i / n
			Vox.box(_globe, Vector3(0.35, 0.35, 0.35), Vector3(cos(a) * r, y, sin(a) * r), Vox.BLUE, 2.5, false)
	for i in 12:  # meridian
		var a := TAU * i / 12.0
		Vox.box(_globe, Vector3(0.3, 0.3, 0.3), Vector3(0, sin(a) * 3.2, cos(a) * 3.2), Color("a8e6ff"), 2.0, false)
	signs.append({"pos": _globe.position + Vector3(0, 4.2, 0), "text": tr("THE INTERNET"), "sub": tr("requests come from here"), "color": Vox.BLUE, "big": true})
	for m in _static.find_children("*", "MeshInstance3D", true, false):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## A flat road along a polyline, with a dashed centre line.
func _road(pts: Array, col: Color, width := 1.3) -> void:
	for i in pts.size() - 1:
		var a: Vector3 = pts[i]
		var b: Vector3 = pts[i + 1]
		var d := b - a
		var len := d.length()
		if len < 0.05:
			continue
		var mid := (a + b) * 0.5 + Vector3(0, 0.03, 0)
		var seg := Vox.box(_static, Vector3(width, 0.04, len + width), mid, col, 0.0, false)
		seg.look_at_from_position(mid, mid + d, Vector3.UP)
		var n := int(len / 1.6)
		for k in n:
			var p := a.lerp(b, (k + 0.5) / n) + Vector3(0, 0.06, 0)
			var dash := Vox.box(_static, Vector3(0.12, 0.02, 0.5), p, Vox.YELLOW.darkened(0.2), 0.8, false)
			dash.look_at_from_position(p, p + d, Vector3.UP)


func _process(delta: float) -> void:
	_t += delta
	if _globe:
		_globe.rotation.y += delta * 0.3
	# Data packets rain from the globe onto the domain billboards.
	if _globe and not _boards.is_empty() and randf() < delta * 6.0 and _packets.size() < 30:
		var pk := Vox.box(self, Vector3(0.25, 0.25, 0.25), _globe.position, Color("a8e6ff"), 3.5, false)
		pk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_packets.append({"node": pk, "from": _globe.position + Vector3(randf_range(-2, 2), randf_range(-2, 2), randf_range(-2, 2)), "to": _boards.pick_random(), "t": 0.0})
	for i in range(_packets.size() - 1, -1, -1):
		var pk: Dictionary = _packets[i]
		pk.t += delta * 0.8
		var a: Vector3 = pk.from
		var b: Vector3 = pk.to
		# a little arc
		pk.node.position = a.lerp(b, pk.t) + Vector3(0, sin(pk.t * PI) * 3.0, 0)
		if pk.t >= 1.0:
			if world:
				world.poof(b, Color("a8e6ff"))
			pk.node.queue_free()
			_packets.remove_at(i)
	# Spawn cars
	for r in _routes:
		r.t -= delta
		if r.t <= 0.0 and _cars.size() < MAX_CARS:
			r.t = r.every * randf_range(0.7, 1.4)
			_spawn_car(r)
	# Drive
	for i in range(_cars.size() - 1, -1, -1):
		var c: Dictionary = _cars[i]
		var node: Node3D = c.node
		if not is_instance_valid(node):
			_cars.remove_at(i)
			continue
		var to: Vector3 = c.pts[c.i]
		var d: Vector3 = to - node.position
		var step: float = c.speed * delta
		if d.length() <= step:
			node.position = to
			c.i += 1
			if c.i >= c.pts.size():
				_arrive(c)
				node.queue_free()
				_cars.remove_at(i)
			continue
		node.position += d.normalized() * step
		node.look_at(node.position + d, Vector3.UP)
	for i in range(_pops.size() - 1, -1, -1):
		_pops[i].t -= delta
		if _pops[i].t <= 0.0:
			_pops.remove_at(i)


func _spawn_car(r: Dictionary) -> void:
	var car := Node3D.new()
	add_child(car)
	var col: Color = r.color
	Vox.box(car, Vector3(0.55, 0.28, 0.9), Vector3(0, 0.26, 0), col)
	Vox.box(car, Vector3(0.45, 0.22, 0.45), Vector3(0, 0.5, 0.05), col.lightened(0.3))
	Vox.box(car, Vector3(0.14, 0.1, 0.05), Vector3(-0.16, 0.28, -0.46), Vox.WHITE, 3.0, false)  # headlights
	Vox.box(car, Vector3(0.14, 0.1, 0.05), Vector3(0.16, 0.28, -0.46), Vox.WHITE, 3.0, false)
	if r.tls:
		Vox.box(car, Vector3(0.18, 0.12, 0.18), Vector3(0, 0.68, 0.05), Vox.YELLOW, 3.0, false)  # HTTPS beacon
	for w in [Vector3(-0.3, 0.1, 0.3), Vector3(0.3, 0.1, 0.3), Vector3(-0.3, 0.1, -0.3), Vector3(0.3, 0.1, -0.3)]:
		Vox.box(car, Vector3(0.12, 0.2, 0.2), w, Color("111111"), 0.0, false)
	for m in car.find_children("*", "MeshInstance3D", true, false):
		m.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	car.scale = Vector3.ONE * 1.35
	car.position = r.pts[0]
	_cars.append({"node": car, "pts": r.pts, "i": 1, "speed": randf_range(5.5, 8.0), "broken": r.broken})


func _arrive(c: Dictionary) -> void:
	var p: Vector3 = c.node.position
	if c.broken:
		# No backend: the request dies at the gate.
		if world:
			world.flash(p + Vector3(0, 0.6, 0), Vox.RED, 0.6)
			world.smoke(p + Vector3(0, 0.5, 0), Vox.RED.darkened(0.3))
		_pops.append({"pos": p + Vector3(0, 1.6, 0), "t": 1.2})
	elif world:
		world.poof(p + Vector3(0, 0.4, 0), c.node.get_child(0).material_override.albedo_color)


## Labels for the HUD overlay (signs + transient "503"s).
func labels() -> Array:
	var out := signs.duplicate()
	for p in _pops:
		out.append({"pos": p.pos, "text": "503", "sub": "", "color": Vox.RED, "big": false, "small": true})
	return out
