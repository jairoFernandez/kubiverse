class_name Look
## Visual themes, chosen per cluster (VIEW > Theme): the same Kubernetes
## objects, dressed as a factory, a farm, a futuristic megacity, a space
## station or a medieval kingdom. Colours, ground props, building and robot
## decorations, and the names of the places. Kubernetes words (pod, service,
## deployment) stay: they are what you are learning.

const LIST := ["factory", "farm", "future", "space", "medieval"]

const DATA := {
	"factory": {"title": "Factory", "ground": Color("4a5a3a"), "road": Color("3b3f4f"), "floor": Color("565c6e"), "tile": Color("5e6477"),
		"wall": Color("7a8094"), "building": Color("8a8f9e"), "island": Color("00e436"), "island_dark": Color("008751"),
		"sky_day": Color("2b4a8a"), "sky_night": Color("0d1230"), "sky_dusk": Color("5a2450"),
		"plant": "PLANT", "hall": "HALL %s", "energy": "ENERGY ROOM (nodes)", "building_word": "namespace"},
	"farm": {"title": "Farm", "ground": Color("5f8a3a"), "road": Color("8a6a44"), "floor": Color("a07850"), "tile": Color("b08a5a"),
		"wall": Color("9b3b2e"), "building": Color("b0463a"), "island": Color("7cc242"), "island_dark": Color("4f8a2a"),
		"sky_day": Color("4d86c8"), "sky_night": Color("121a38"), "sky_dusk": Color("b0583a"),
		"plant": "FARM", "hall": "BARN %s", "energy": "THE FIELDS (nodes)", "building_word": "barn"},
	"future": {"title": "Futuristic factory", "ground": Color("181c34"), "road": Color("0c0e20"), "floor": Color("20264a"), "tile": Color("2a3264"),
		"wall": Color("35407a"), "building": Color("4a5890"), "island": Color("29adff"), "island_dark": Color("1a3a6a"),
		"sky_day": Color("3a2a7a"), "sky_night": Color("07051a"), "sky_dusk": Color("7a1a6a"),
		"plant": "MEGACITY", "hall": "DOME %s", "energy": "REACTOR CORE (nodes)", "building_word": "dome"},
	"space": {"title": "Space station", "ground": Color("5c5c68"), "road": Color("3a3a46"), "floor": Color("48506a"), "tile": Color("56607c"),
		"wall": Color("8a90a8"), "building": Color("c2c6d4"), "island": Color("8a8a9a"), "island_dark": Color("5a5a6a"),
		"sky_day": Color("0a0c1e"), "sky_night": Color("04050e"), "sky_dusk": Color("1a0e30"),
		"plant": "STATION", "hall": "MODULE %s", "energy": "SOLAR ARRAY (nodes)", "building_word": "module"},
	"medieval": {"title": "Medieval kingdom", "ground": Color("55773a"), "road": Color("8a8272"), "floor": Color("6a5a48"), "tile": Color("7a6a55"),
		"wall": Color("8a8a80"), "building": Color("a0a096"), "island": Color("6aa03a"), "island_dark": Color("3f6a2a"),
		"sky_day": Color("4a7ab0"), "sky_night": Color("10142e"), "sky_dusk": Color("8a4a5a"),
		"plant": "KINGDOM", "hall": "CASTLE %s", "energy": "THE MILLS (nodes)", "building_word": "castle"},
}

static var current := "factory"


static func v(key: String):
	return DATA.get(current, DATA.factory).get(key, DATA.factory[key])


static func next(t: String) -> String:
	return LIST[(LIST.find(t) + 1) % LIST.size()]


## Space has no daylight: always the starry sky.
static func always_night() -> bool:
	return current == "space"


# ------------------------------------------------------------ decorations

## On top of a namespace building (its root node, size and roof height).
static func decorate_building(g: Node3D, w: float, d: float, h: float, roof: float, nsc: Color) -> void:
	match current:
		"farm":
			_barn(g, w, d, h, nsc)
		"future":
			# Neon edges, a hologram ring over the roof, a spire.
			for x in [-w * 0.5, w * 0.5]:
				for z in [-d * 0.5, d * 0.5]:
					Vox.box(g, Vector3(0.14, h, 0.14), Vector3(x, h * 0.5 + 0.2, z), nsc, 3.0, false)
			for z in [-d * 0.5, d * 0.5]:
				Vox.box(g, Vector3(w, 0.12, 0.14), Vector3(0, h + 0.25, z), Color("29adff"), 3.0, false)
			Vox.box(g, Vector3(0.3, 2.4, 0.3), Vector3(0, roof + 1.2, 0), Vox.SILVER)
			for a in 8:
				Vox.box(g, Vector3(0.5, 0.12, 0.2), Vector3(1.6, 0, 0).rotated(Vector3.UP, a * TAU / 8.0) + Vector3(0, roof + 1.8, 0), Color("a8e6ff"), 3.0, false)
		"space":
			_module(g, w, d, h, nsc)
		"medieval":
			# Battlements, corner towers with pointed roofs and banners.
			var n := int(w / 1.0)
			for i in n:
				if i % 2 == 0:
					for z in [-d * 0.5, d * 0.5]:
						Vox.box(g, Vector3(0.6, 0.6, 0.6), Vector3(-w * 0.5 + 0.5 + i * 1.0, h + 0.5, z), Color("7a7a70"))
			for x in [-w * 0.5, w * 0.5]:
				Vox.box(g, Vector3(1.6, h + 1.6, 1.6), Vector3(x, (h + 1.6) * 0.5, d * 0.5), Color("8a8a80"))
				for k in 3:
					Vox.box(g, Vector3(1.8 - k * 0.55, 0.5, 1.8 - k * 0.55), Vector3(x, h + 1.85 + k * 0.5, d * 0.5), Color("5a3a8a") if k < 2 else nsc)
				Vox.box(g, Vector3(0.1, 1.4, 0.1), Vector3(x, h + 3.2, d * 0.5), Vox.BROWN)
				Vox.box(g, Vector3(0.7, 0.5, 0.05), Vector3(x + 0.4, h + 3.6, d * 0.5), nsc, 1.0, false)


## On top of a pod robot (its body node and the height of its head).
static func decorate_pod(b: Node3D, top_y: float) -> void:
	match current:
		"farm":  # straw hat
			Vox.box(b, Vector3(1.1, 0.06, 1.0), Vector3(0, top_y + 0.02, 0), Color("d8b848"))
			Vox.box(b, Vector3(0.55, 0.25, 0.5), Vector3(0, top_y + 0.16, 0), Color("c8a038"))
			Vox.box(b, Vector3(0.57, 0.06, 0.52), Vector3(0, top_y + 0.1, 0), Vox.RED)
		"future":  # floating halo
			for a in 6:
				Vox.box(b, Vector3(0.18, 0.05, 0.08), Vector3(0.42, 0, 0).rotated(Vector3.UP, a * TAU / 6.0) + Vector3(0, top_y + 0.7, 0), Color("a8e6ff"), 3.0, false)
		"space":  # glass bubble helmet
			var m := Vox.box(b, Vector3(0.95, 0.6, 0.85), Vector3(0, top_y - 0.15, 0), Color.WHITE, 0.0, false)
			var glass := StandardMaterial3D.new()
			glass.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			glass.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			glass.albedo_color = Color(0.7, 0.9, 1.0, 0.3)
			m.material_override = glass
		"medieval":  # helmet with a plume
			Vox.box(b, Vector3(0.86, 0.14, 0.76), Vector3(0, top_y + 0.05, 0), Vox.SILVER)
			Vox.box(b, Vector3(0.12, 0.35, 0.4), Vector3(0, top_y + 0.3, -0.05), Vox.RED)


## A prop scattered on the plant's ground (instead of a tree).
static func ground_prop(parent: Node3D, q: Vector3, i: int) -> void:
	match current:
		"farm":
			if i % 3 == 0:
				Vox.box(parent, Vector3(1.0, 0.8, 0.8), q + Vector3(0, 0.4, 0), Color("d8b848"))  # hay bale
			else:
				Vox.box(parent, Vector3(0.3, 1.2, 0.3), q + Vector3(0, 0.6, 0), Vox.BROWN)
				Vox.box(parent, Vector3(1.4, 1.3, 1.4), q + Vector3(0, 1.75, 0), Color("4f8a2a"))
				Vox.box(parent, Vector3(0.25, 0.25, 0.25), q + Vector3(0.4, 1.9, 0.72), Vox.RED)  # apple
		"future":
			Vox.box(parent, Vector3(0.3, 2.6, 0.3), q + Vector3(0, 1.3, 0), Color("2a3264"))
			Vox.box(parent, Vector3(0.5, 0.5, 0.5), q + Vector3(0, 2.8, 0), [Color("29adff"), Color("ff77a8"), Color("00e436")][i % 3], 3.0, false)
		"space":
			if i % 3 == 0:
				Vox.box(parent, Vector3(1.4, 0.7, 1.2), q + Vector3(0, 0.35, 0), Color("4a4a56"))  # rock
				Vox.box(parent, Vector3(0.8, 0.5, 0.7), q + Vector3(0.7, 0.25, 0.4), Color("5a5a66"))
			elif i % 3 == 1:
				for k in 4:
					var c := Vox.box(parent, Vector3(0.3, 1.2 - k * 0.2, 0.3), q + Vector3(k * 0.3 - 0.45, 0.5, (k % 2) * 0.2), [Color("c98bff"), Color("29adff")][k % 2], 2.0, false)
					c.rotation.z = (k - 1.5) * 0.35
			else:  # a runway light post
				Vox.box(parent, Vector3(0.2, 0.9, 0.2), q + Vector3(0, 0.45, 0), HULL_DARK)
				Vox.box(parent, Vector3(0.35, 0.35, 0.35), q + Vector3(0, 1.0, 0), Vox.YELLOW, 3.0, false)
		"medieval":
			if i % 4 == 0:  # a cottage
				Vox.box(parent, Vector3(1.6, 1.0, 1.4), q + Vector3(0, 0.5, 0), Color("c8b89a"))
				Vox.box(parent, Vector3(1.8, 0.5, 1.6), q + Vector3(0, 1.25, 0), Color("7a4a2a"))
			else:
				Vox.box(parent, Vector3(0.3, 1.2, 0.3), q + Vector3(0, 0.6, 0), Vox.BROWN)
				Vox.box(parent, Vector3(1.3, 1.3, 1.3), q + Vector3(0, 1.75, 0), Vox.FOREST)
		_:
			Vox.box(parent, Vector3(0.3, 1.2, 0.3), q + Vector3(0, 0.6, 0), Vox.BROWN)
			Vox.box(parent, Vector3(1.3, 1.3, 1.3), q + Vector3(0, 1.75, 0), Vox.FOREST)


# ------------------------------------------------------------ farm

const BARN_RED := Color("a8382c")
const BARN_DARK := Color("6a2420")
const TRIM := Color("f1ece0")
const HAY := Color("e0c050")


## A proper barn: white trim, big X doors, a gambrel roof, a hayloft full of
## hay, a weathervane; a tall silo with a dome and ladder; a white fence.
static func _barn(g: Node3D, w: float, d: float, h: float, nsc: Color) -> void:
	# White corner posts and a white band at the eaves.
	for x in [-w * 0.5, w * 0.5]:
		for z in [-d * 0.5, d * 0.5]:
			Vox.box(g, Vector3(0.28, h, 0.28), Vector3(x, h * 0.5 + 0.2, z), TRIM)
	Vox.box(g, Vector3(w + 0.1, 0.2, d + 0.1), Vector3(0, h + 0.1, 0), TRIM)
	# Gambrel roof: steep lower slopes, gentle upper ones, a ridge.
	for s in [-1.0, 1.0]:
		var low := Vox.box(g, Vector3(w + 0.5, 0.28, d * 0.3), Vector3(0, h + 0.75, s * d * 0.38), BARN_DARK)
		low.rotation.x = s * 1.0
		var up := Vox.box(g, Vector3(w + 0.5, 0.28, d * 0.34), Vector3(0, h + 1.55, s * d * 0.16), BARN_DARK.darkened(0.15))
		up.rotation.x = s * 0.35
	Vox.box(g, Vector3(w + 0.6, 0.18, 0.3), Vector3(0, h + 1.72, 0), TRIM)
	# Gable end (front): barn red triangle-ish steps with a hayloft door.
	for k in 3:
		Vox.box(g, Vector3(w * (0.9 - k * 0.28), 0.5, 0.2), Vector3(0, h + 0.45 + k * 0.5, d * 0.5 + 0.02), BARN_RED.darkened(0.05 * k))
	Vox.box(g, Vector3(1.2, 0.9, 0.12), Vector3(0, h + 0.8, d * 0.5 + 0.14), BARN_DARK)
	Vox.box(g, Vector3(0.9, 0.5, 0.14), Vector3(0, h + 0.6, d * 0.5 + 0.18), HAY)
	# Big sliding doors: white frame with the X, on both sides of the door.
	for sx in [-1.0, 1.0]:
		var cx: float = sx * minf(w * 0.3, 2.2)
		Vox.box(g, Vector3(1.6, 2.2, 0.08), Vector3(cx, 1.3, d * 0.5 + 0.05), BARN_RED.darkened(0.1))
		Vox.box(g, Vector3(1.7, 0.14, 0.1), Vector3(cx, 2.4, d * 0.5 + 0.09), TRIM)
		Vox.box(g, Vector3(1.7, 0.14, 0.1), Vector3(cx, 0.25, d * 0.5 + 0.09), TRIM)
		for r in [-0.8, 0.8]:
			var bar := Vox.box(g, Vector3(0.12, 2.6, 0.08), Vector3(cx, 1.3, d * 0.5 + 0.1), TRIM)
			bar.rotation.z = r * 0.6
	# Weathervane: a little rooster on a pole.
	Vox.box(g, Vector3(0.08, 1.0, 0.08), Vector3(w * 0.25, h + 2.2, 0), Vox.SLATE)
	Vox.box(g, Vector3(0.5, 0.3, 0.12), Vector3(w * 0.25, h + 2.8, 0), Vox.BLACK)
	Vox.box(g, Vector3(0.14, 0.18, 0.12), Vector3(w * 0.25 + 0.3, h + 3.0, 0), Vox.RED)
	# Silo: tall, banded, a dome and a ladder.
	var sx0 := w * 0.5 + 1.4
	for y in 6:
		Vox.box(g, Vector3(2.0, 1.1, 2.0), Vector3(sx0, 0.55 + y * 1.1, -d * 0.15), Vox.SILVER if y % 2 == 0 else Vox.SILVER.darkened(0.12))
	for k in 3:
		Vox.box(g, Vector3(1.8 - k * 0.55, 0.4, 1.8 - k * 0.55), Vector3(sx0, 6.8 + k * 0.4, -d * 0.15), Color("9aa0b0").darkened(k * 0.08))
	for y in 12:
		Vox.box(g, Vector3(0.5, 0.06, 0.06), Vector3(sx0, 0.4 + y * 0.55, -d * 0.15 + 1.05), Vox.SLATE)
	# White fence around the yard, with a gap at the door.
	var fx := w * 0.5 + 0.9
	var fz := d * 0.5 + 1.6
	for i in int(fx * 2.0 / 1.2) + 1:
		var x := -fx + i * 1.2
		if absf(x) < 1.6:
			continue
		Vox.box(g, Vector3(0.14, 0.8, 0.14), Vector3(x, 0.4, fz), TRIM)
	for x0 in [-fx, 1.6]:
		Vox.box(g, Vector3(fx - 1.6, 0.1, 0.08), Vector3(x0 + (fx - 1.6) * 0.5, 0.55, fz), TRIM)
	# Hay bales by the door.
	for i in 2:
		Vox.box(g, Vector3(0.9, 0.7, 0.7), Vector3(-w * 0.5 + 0.7, 0.35 + i * 0.7, d * 0.5 + 0.8), HAY.darkened(0.05 * i))


# ------------------------------------------------------------ space

const HULL := Color("d8dce6")
const HULL_DARK := Color("9aa2b6")
const GLOW := Color("a8e6ff")


## A station module: white hull panels with seams, lit portholes, a docking
## ring, a glass dome, a dish, blinking antennas and big solar wings.
static func _module(g: Node3D, w: float, d: float, h: float, nsc: Color) -> void:
	# Panel seams on the front and sides.
	for i in int(w / 1.6):
		Vox.box(g, Vector3(0.05, h - 0.2, 0.04), Vector3(-w * 0.5 + 0.8 + i * 1.6, h * 0.5 + 0.2, d * 0.5 + 0.03), HULL_DARK, 0.0, false)
	for y in [h * 0.35, h * 0.75]:
		Vox.box(g, Vector3(w, 0.05, 0.04), Vector3(0, y, d * 0.5 + 0.03), HULL_DARK, 0.0, false)
	# Portholes: framed, glowing.
	for i in int(w / 2.0):
		var x := -w * 0.5 + 1.0 + i * 2.0
		if absf(x) < 1.4:
			continue
		Vox.box(g, Vector3(0.7, 0.7, 0.06), Vector3(x, h * 0.62, d * 0.5 + 0.05), HULL_DARK)
		Vox.box(g, Vector3(0.45, 0.45, 0.07), Vector3(x, h * 0.62, d * 0.5 + 0.08), GLOW, 1.6, false)
	# Docking ring around the door.
	Vox.box(g, Vector3(2.4, 0.25, 0.25), Vector3(0, 2.8, d * 0.5 + 0.18), nsc, 1.0)
	for sx in [-1.2, 1.2]:
		Vox.box(g, Vector3(0.25, 2.6, 0.25), Vector3(sx, 1.5, d * 0.5 + 0.18), nsc, 1.0)
	# Glass dome on the roof (stepped), with something green growing inside.
	for i in 4:
		var m := Vox.box(g, Vector3(w * 0.45 - i * 0.7, 0.5, d * 0.5 - i * 0.55), Vector3(-w * 0.12, h + 0.45 + i * 0.5, 0), GLOW, 0.4, false)
		var gm := StandardMaterial3D.new()
		gm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		gm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		gm.albedo_color = Color(GLOW, 0.35)
		m.material_override = gm
	for k in 3:
		Vox.box(g, Vector3(0.4, 0.6 + k * 0.2, 0.4), Vector3(-w * 0.12 - 0.6 + k * 0.6, h + 0.6, 0), Vox.GREEN.darkened(0.2), 0.3)
	# Dish antenna.
	Vox.box(g, Vector3(0.2, 1.2, 0.2), Vector3(w * 0.32, h + 0.8, -d * 0.25), HULL_DARK)
	var dish := Vox.box(g, Vector3(1.6, 0.15, 1.6), Vector3(w * 0.32, h + 1.5, -d * 0.25), HULL)
	dish.rotation = Vector3(0.6, 0.4, 0)
	Vox.box(g, Vector3(0.1, 0.5, 0.1), Vector3(w * 0.32, h + 1.9, -d * 0.1), Vox.SILVER)
	# Blinking-light antennas.
	for x in [-w * 0.42, w * 0.1]:
		Vox.box(g, Vector3(0.1, 2.2, 0.1), Vector3(x, h + 1.3, -d * 0.4), Vox.SILVER)
		Vox.box(g, Vector3(0.25, 0.25, 0.25), Vector3(x, h + 2.45, -d * 0.4), Vox.RED, 4.0, false)
	# Solar wings: a truss and two panels with a cell grid each side.
	for s in [-1.0, 1.0]:
		Vox.box(g, Vector3(1.4, 0.2, 0.2), Vector3(s * (w * 0.5 + 0.7), h * 0.7, 0), HULL_DARK)
		for k in 2:
			var px: float = s * (w * 0.5 + 1.9 + k * 2.3)
			Vox.box(g, Vector3(2.1, 0.08, 2.6), Vector3(px, h * 0.7, 0), Color("1d2b53"), 0.5)
			for c in 3:
				Vox.box(g, Vector3(0.04, 0.1, 2.6), Vector3(px - 0.7 + c * 0.7, h * 0.7 + 0.01, 0), Color("5a7ac8"), 0.3, false)


# ------------------------------------------------------------ the plant's surroundings

## Extra scenery on the plant ground, outside the building grid: crop fields
## and a windmill (farm); craters, landing pads, a rover and a planet in the
## sky (space). avoid: [Vector3] spots to keep clear (buildings, the hut).
static func plant_extras(parent: Node3D, g: Rect2, grid_z: float, avoid: Array) -> void:
	var rng := Vox.rng_for("look:" + current)
	g = Rect2(maxf(g.position.x, -60.0), g.position.y, minf(g.end.x, 60.0) - maxf(g.position.x, -60.0), g.size.y)
	var free := func(p: Vector3, r: float) -> bool:
		if absf(p.x) < 9.0:  # the central avenue to the gate
			return false
		for a in avoid:
			if Vector2(p.x, p.z).distance_to(Vector2(a.x, a.z)) < r + 7.0:
				return false
		return p.x > g.position.x + r and p.x < g.end.x - r and p.z > grid_z + r + 2.0 and p.z < g.end.y - r
	match current:
		"farm":
			var placed := 0
			for i in 60:
				if placed >= 6:
					break
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if not free.call(p, 3.5):
					continue
				placed += 1
				avoid.append(p)
				_field(parent, p, rng)
			for i in 40:
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if free.call(p, 3.0):
					avoid.append(p)
					_windmill(parent, p)
					break
			for i in 12:  # chickens
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if free.call(p, 0.5):
					Vox.box(parent, Vector3(0.35, 0.3, 0.45), p + Vector3(0, 0.15, 0), Vox.WHITE)
					Vox.box(parent, Vector3(0.12, 0.12, 0.12), p + Vector3(0, 0.35, 0.2), Vox.RED)
		"space":
			for i in 50:
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if free.call(p, 2.0):
					_crater(parent, p, rng.randf_range(1.2, 2.4))
			var pads := 0
			for i in 60:
				if pads >= 2:
					break
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if free.call(p, 3.0):
					avoid.append(p)
					pads += 1
					_landing_pad(parent, p)
			for i in 40:
				var p := Vector3(rng.randf_range(g.position.x, g.end.x), 0, rng.randf_range(grid_z, g.end.y))
				if free.call(p, 1.5):
					_rover(parent, p)
					break
			# A big planet low in the sky, behind the station.
			var c := Vector3(g.get_center().x - 30.0, 26.0, g.position.y - 70.0)
			for k in 7:
				var r := 14.0 - absf(k - 3) * 3.2
				Vox.box(parent, Vector3(r * 2.0, 3.4, r * 2.0), c + Vector3(0, (k - 3) * 3.4, 0), Color("2e6fd0").lerp(Color("3fa34d"), float(k % 3 == 1) * 0.6), 1.2, false)
			Vox.box(parent, Vector3(40.0, 0.8, 6.0), c + Vector3(0, 0, 0), Color("c8a8ff"), 0.8, false)  # a ring


static func _field(parent: Node3D, p: Vector3, rng: RandomNumberGenerator) -> void:
	var crop: Color = [Color("4f8a2a"), Color("d8b848"), Color("7cc242")][rng.randi() % 3]
	Vox.box(parent, Vector3(6.0, 0.08, 5.0), p + Vector3(0, 0.04, 0), Color("7a5a3a"), 0.0, false)
	for r in 5:
		Vox.box(parent, Vector3(5.6, 0.12, 0.35), p + Vector3(0, 0.1, -2.0 + r * 1.0), Color("5a3f28"), 0.0, false)
		for c in 7:
			Vox.box(parent, Vector3(0.35, 0.5 if crop != Color("d8b848") else 0.8, 0.35), p + Vector3(-2.4 + c * 0.8, 0.3, -2.0 + r * 1.0), crop, 0.0, false)
	# Scarecrow in one corner.
	Vox.box(parent, Vector3(0.12, 1.6, 0.12), p + Vector3(2.6, 0.8, 2.2), Vox.BROWN)
	Vox.box(parent, Vector3(1.0, 0.12, 0.12), p + Vector3(2.6, 1.2, 2.2), Vox.BROWN)
	Vox.box(parent, Vector3(0.35, 0.35, 0.35), p + Vector3(2.6, 1.75, 2.2), HAY)
	Vox.box(parent, Vector3(0.5, 0.1, 0.5), p + Vector3(2.6, 1.98, 2.2), Color("6a4a2a"))


static func _windmill(parent: Node3D, p: Vector3) -> void:
	for k in 5:
		Vox.box(parent, Vector3(2.2 - k * 0.3, 1.2, 2.2 - k * 0.3), p + Vector3(0, 0.6 + k * 1.2, 0), TRIM.darkened(0.05 * k))
	Vox.box(parent, Vector3(1.4, 0.8, 1.4), p + Vector3(0, 6.4, 0), BARN_RED)
	for a in 4:
		var blade := Vox.box(parent, Vector3(0.4, 3.2, 0.1), p + Vector3(0, 6.2, 0.8) + Vector3(0, 1.6, 0).rotated(Vector3.FORWARD, a * TAU / 4.0 + 0.4), TRIM)
		blade.rotation.z = a * TAU / 4.0 + 0.4


static func _crater(parent: Node3D, p: Vector3, r: float) -> void:
	for a in 10:
		var q := p + Vector3(r, 0, 0).rotated(Vector3.UP, a * TAU / 10.0)
		Vox.box(parent, Vector3(0.8, 0.3, 0.8), q + Vector3(0, 0.15, 0), Color("6c6c78"), 0.0, false)
	Vox.box(parent, Vector3(r * 1.5, 0.05, r * 1.5), p + Vector3(0, 0.02, 0), Color("3e3e48"), 0.0, false)


static func _landing_pad(parent: Node3D, p: Vector3) -> void:
	Vox.box(parent, Vector3(5.0, 0.2, 5.0), p + Vector3(0, 0.1, 0), Color("4a5068"))
	for x in [-0.6, 0.6]:
		Vox.box(parent, Vector3(0.3, 0.05, 2.0), p + Vector3(x, 0.22, 0), Vox.YELLOW, 0.8, false)
	Vox.box(parent, Vector3(1.2, 0.05, 0.3), p + Vector3(0, 0.22, 0), Vox.YELLOW, 0.8, false)
	for x in [-2.3, 2.3]:
		for z in [-2.3, 2.3]:
			Vox.box(parent, Vector3(0.25, 0.25, 0.25), p + Vector3(x, 0.3, z), Vox.GREEN, 3.0, false)


static func _rover(parent: Node3D, p: Vector3) -> void:
	Vox.box(parent, Vector3(1.8, 0.6, 1.2), p + Vector3(0, 0.7, 0), HULL)
	for x in [-0.7, 0.7]:
		for z in [-0.65, 0.65]:
			Vox.box(parent, Vector3(0.5, 0.5, 0.25), p + Vector3(x, 0.25, z), Vox.SLATE)
	Vox.box(parent, Vector3(0.08, 0.8, 0.08), p + Vector3(0.6, 1.4, 0), Vox.SILVER)
	Vox.box(parent, Vector3(0.5, 0.08, 0.5), p + Vector3(0.6, 1.8, 0), HULL)
	# A flag nearby.
	Vox.box(parent, Vector3(0.06, 1.8, 0.06), p + Vector3(-2.0, 0.9, 0.5), Vox.SILVER)
	Vox.box(parent, Vector3(0.8, 0.5, 0.04), p + Vector3(-1.58, 1.5, 0.5), Vox.BLUE, 0.4, false)


## Node islands wear the look too: ploughed fields on the farm, metal
## decks with lights on the station.
static func decorate_island(g: Node3D, s: float) -> void:
	match current:
		"farm":
			for r in int(s / 1.2):
				Vox.box(g, Vector3(s * 0.9, 0.08, 0.3), Vector3(0, 0.05, -s * 0.45 + 0.6 + r * 1.2), Color("5a3f28"), 0.0, false)
		"space":
			for x in [-s * 0.5, s * 0.5]:
				for z in [-s * 0.5, s * 0.5]:
					Vox.box(g, Vector3(0.3, 0.3, 0.3), Vector3(x, 0.15, z), Vox.GREEN, 3.0, false)
			for i in int(s / 1.5):
				Vox.box(g, Vector3(s, 0.03, 0.06), Vector3(0, 0.02, -s * 0.5 + 0.75 + i * 1.5), HULL_DARK, 0.0, false)
