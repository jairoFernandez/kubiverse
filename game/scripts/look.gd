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
			# Red gable roof, a silo and hay bales.
			for s in [-1.0, 1.0]:
				var slope := Vox.box(g, Vector3(w + 0.4, 0.3, d * 0.58), Vector3(0, h + 0.9, s * d * 0.24), Color("7a2a22"))
				slope.rotation.x = s * 0.55
			Vox.box(g, Vector3(0.3, 0.3, 0.3), Vector3(0, h + 1.55, 0), Vox.WHITE)
			for y in 4:
				Vox.box(g, Vector3(1.8, 1.4, 1.8), Vector3(w * 0.5 + 1.2, 0.7 + y * 1.4, -d * 0.2), Vox.SILVER.darkened(0.1 * (y % 2)))
			Vox.box(g, Vector3(2.0, 0.6, 2.0), Vector3(w * 0.5 + 1.2, 6.0, -d * 0.2), Color("7a2a22"))
			for i in 3:
				Vox.box(g, Vector3(0.9, 0.7, 0.7), Vector3(-w * 0.5 + 0.8 + i * 1.1, 0.35, d * 0.5 + 1.2), Color("d8b848"))
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
			# A glass dome, antennas and solar wings.
			for i in 4:
				Vox.box(g, Vector3(w * 0.5 - i * 0.8, 0.5, d * 0.6 - i * 0.6), Vector3(0, h + 0.45 + i * 0.5, 0), Color("a8e6ff").darkened(i * 0.08), 0.5)
			Vox.box(g, Vector3(0.12, 2.6, 0.12), Vector3(w * 0.35, roof + 1.3, -d * 0.3), Vox.SILVER)
			Vox.box(g, Vector3(0.6, 0.1, 0.6), Vector3(w * 0.35, roof + 2.6, -d * 0.3), Vox.RED, 3.0, false)
			for s in [-1.0, 1.0]:
				Vox.box(g, Vector3(0.2, 0.2, 1.2), Vector3(s * (w * 0.5 + 0.3), h * 0.6, 0), Vox.SILVER)
				Vox.box(g, Vector3(2.4, 0.1, 2.0), Vector3(s * (w * 0.5 + 1.6), h * 0.6, 0), Color("1d2b53"), 0.6)
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
			if i % 2 == 0:
				Vox.box(parent, Vector3(1.4, 0.7, 1.2), q + Vector3(0, 0.35, 0), Color("4a4a56"))  # rock
			else:
				for k in 3:
					var c := Vox.box(parent, Vector3(0.3, 1.0 - k * 0.2, 0.3), q + Vector3(k * 0.3 - 0.3, 0.5, 0), Color("c98bff"), 2.0, false)
					c.rotation.z = (k - 1) * 0.4
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
