class_name ArcadeHall
## KUBIVERSE: UNDERGROUND as a level: the cave room under the cluster with a
## cabinet per minigame (GAMES). The pure bits live here (where
## each cabinet stands, which one is in reach, the high scores, what the
## screens show while nobody plays); World builds the room and Underground
## plays the game on the screen you walked up to. No autoloads here: World
## (and its tests) load this before they exist.

const ROOM := Rect2(-11.0, -7.0, 22.0, 15.0)   # the floor (XZ)
const CAB_Z := -5.2        # the row of cabinets, in front of the back wall
const CAB_STEP := 3.4      # between two cabinets
const CAB_SIZE := Vector2(1.6, 1.3)   # footprint (XZ) of a cabinet
const CAB_HEIGHT := 2.8
const FRONT := 1.3         # where you stand to play: this far in front of it
const REACH := 2.2         # E works this close to that spot
const EXIT := Vector3(0, 0, 6.0)      # the elevator back up
const SPAWN := Vector3(0, 0, 0.5)
const SAVE := "user://underground.cfg"
const GAMES := [
	{"id": "whack", "title": "WHACK-A-POD", "color": Color(0.95, 0.32, 0.3),
		"blurb": "Restart the crashing pods.\nDon't hit the healthy ones."},
	{"id": "snake", "title": "OOM SNAKE", "color": Color(0.6, 0.42, 1.0),
		"blurb": "Eat requests, grow your memory.\nDon't bite yourself."},
	{"id": "rally", "title": "KUBE RALLY", "color": Color(0.3, 0.8, 1.0),
		"blurb": "Race down the service mesh.\nDodge the traffic, grab the coins."},
	{"id": "laser", "title": "LASER TAG", "color": Color(0.35, 0.9, 0.45),
		"blurb": "Tag the rogue pods in the server room.\nHide behind the racks."},
	{"id": "soon", "title": "???", "color": Color(0.38, 0.38, 0.44),
		"blurb": "Out of order.\nMore games are coming."},
]
const PLAYABLE := ["whack", "snake", "rally", "laser"]
const RED := Color(1.0, 0.3, 0.3)
const GREEN := Color(0.35, 0.9, 0.45)
const DIM := Color(0.55, 0.52, 0.66)

## High score per game id (saved in SAVE; the cabinets show them too).
static var best := {}


## Where the n cabinets stand: one row along the back wall, centered,
## all facing the room (+z, towards the camera).
static func layout(n: int) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in n:
		out.append(Vector3((i - (n - 1) * 0.5) * CAB_STEP, 0, CAB_Z))
	return out


## The spot in front of a cabinet at `pos` where you stand to play it.
static func front_of(pos: Vector3) -> Vector3:
	return pos + Vector3(0, 0, FRONT)


## Footprint of a cabinet at `pos`: solid, you walk around it.
static func footprint(pos: Vector3) -> Rect2:
	return Rect2(pos.x - CAB_SIZE.x * 0.5, pos.z - CAB_SIZE.y * 0.5, CAB_SIZE.x, CAB_SIZE.y)


## Index of the cabinet in reach from p (the closest one), or -1.
## `cabs` are the cabinets' positions.
static func machine_near(cabs: Array, p: Vector3, reach := REACH) -> int:
	var found := -1
	var found_d := reach
	for i in cabs.size():
		var f := front_of(cabs[i])
		var d := Vector2(f.x - p.x, f.z - p.z).length()
		if d < found_d:
			found_d = d
			found = i
	return found


## The game's entry in GAMES, or {}.
static func game(id: String) -> Dictionary:
	for g in GAMES:
		if g.id == id:
			return g
	return {}


## Can this cabinet be played (the last one is out of order)?
static func playable(id: String) -> bool:
	return id in PLAYABLE


static func load_best() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE) == OK:
		for g in GAMES:
			best[g.id] = maxi(int(best.get(g.id, 0)), int(cfg.get_value("best", g.id, 0)))


## A round of `id` ended with `score`: true (and saved) if it is a new high score.
static func record(id: String, score: int) -> bool:
	if score <= int(best.get(id, 0)):
		return false
	best[id] = score
	var cfg := ConfigFile.new()
	cfg.load(SAVE)
	cfg.set_value("best", id, score)
	cfg.save(SAVE)
	return true


## What each cabinet's screen shows while nobody plays it (drawn on the
## cabinets in the room, in pixels of their small screen).
static func paint_attract(v: CanvasItem, id: String, r: Rect2, t: float) -> void:
	match id:
		"whack":
			for i in 3:
				var up := sin(t * 3.0 + i * 2.1) > 0.3
				var c := Vector2(r.position.x + 7 + i * 14, r.position.y + 24)
				v.draw_rect(Rect2(c.x - 5, c.y, 10, 3), Color(0.1, 0.08, 0.1))
				if up:
					v.draw_rect(Rect2(c.x - 4, c.y - 8, 8, 8), RED if i != 1 else GREEN)
		"snake":
			for i in 8:
				var a := t * 2.0 - i * 0.35
				var p := r.get_center() + Vector2(cos(a) * 13, sin(a * 2.0) * 8)
				v.draw_rect(Rect2(p.floor(), Vector2(3, 3)), Color(0.6, 0.42, 1.0).lightened(0.3 if i == 0 else 0.0))
		"rally":
			v.draw_rect(Rect2(r.position.x + 10, r.position.y, r.size.x - 20, r.size.y), Color(0.13, 0.12, 0.16))
			for i in 4:
				var y := r.position.y + fmod(i * 10.0 + t * 40.0, r.size.y)
				v.draw_rect(Rect2(r.get_center().x, y, 1, 5), Color(1, 1, 1, 0.3))
			var cx := r.get_center().x + sin(t * 2.0) * 7.0
			v.draw_rect(Rect2(cx - 3, r.end.y - 11, 6, 9), Color(0.3, 0.95, 1.0))
			var oy := r.position.y + fmod(t * 25.0, r.size.y)
			v.draw_rect(Rect2(r.get_center().x + 5, oy, 6, 9), RED)
		"laser":
			var a := r.position + Vector2(6, r.size.y / 2)
			var b := r.end - Vector2(8, r.size.y / 2 + sin(t * 3.0) * 8.0)
			v.draw_rect(Rect2(a - Vector2(2, 2), Vector2(4, 4)), Color(0.3, 0.95, 1.0))
			v.draw_rect(Rect2(b - Vector2(2, 2), Vector2(4, 4)), RED)
			if fmod(t, 1.0) < 0.15:
				v.draw_line(a, b, Color(0.3, 0.95, 1.0), 1.0)
		_:
			# Out of order: static, and "???" blinking.
			for i in 14:
				v.draw_rect(Rect2(r.position.x + randf() * r.size.x, r.position.y + randf() * r.size.y, 1, 1), Color(1, 1, 1, 0.35))
			if fmod(t, 1.2) < 0.9:
				var f := ThemeDB.fallback_font
				var w := f.get_string_size("???", HORIZONTAL_ALIGNMENT_LEFT, -1, 10).x
				v.draw_string(f, r.get_center() + Vector2(-w / 2.0, 4), "???", HORIZONTAL_ALIGNMENT_LEFT, -1, 10, DIM)
