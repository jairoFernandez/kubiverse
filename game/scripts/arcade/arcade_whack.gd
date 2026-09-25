class_name ArcadeWhack
extends ArcadeGame
## WHACK-A-POD: crashing pods pop out of nine holes; restart them before they
## sink. Healthy pods cost points.

const RED := Color(0.95, 0.3, 0.3)
const PURPLE := Color(0.7, 0.35, 1.0)

var _holes: Array = []    # Vector2 centers
var _pods: Array = []     # {hole, kind, t, life, hit}
var _left := 30.0
var _spawn := 0.6
var _cursor := 4
var _rng := RandomNumberGenerator.new()


func start() -> void:
	_rng.randomize()
	for r in 3:
		for c in 3:
			_holes.append(Vector2(100 + c * 60, 62 + r * 38))


func tick(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		ug.game_over(ug.tr("TIME'S UP"), ug.tr("%d points of uptime saved") % score)
		return
	var pace := 1.0 + (30.0 - _left) / 15.0     # 1x → 3x
	_spawn -= delta * pace
	if _spawn <= 0.0:
		_spawn = _rng.randf_range(0.5, 0.9)
		var free := []
		for i in _holes.size():
			if not _pods.any(func(p): return p.hole == i):
				free.append(i)
		if not free.is_empty():
			var roll := _rng.randf()
			var kind := "ok" if roll < 0.28 else ("oom" if roll < 0.45 else "crash")
			var base: float = {"ok": 1.6, "oom": 0.9, "crash": 1.4}[kind]
			_pods.append({"hole": free[_rng.randi() % free.size()], "kind": kind, "t": 0.0, "life": base / sqrt(pace), "hit": -1.0})
	for p in _pods:
		p.t += delta
		if p.hit >= 0.0:
			p.hit += delta
	_pods = _pods.filter(func(p): return p.t < p.life and p.hit < 0.35)


func key(k: int) -> void:
	var n := _numpad(k)
	if n >= 0:
		_cursor = n
		_whack(n)
	elif k in [KEY_LEFT, KEY_A] and _cursor % 3 > 0: _cursor -= 1
	elif k in [KEY_RIGHT, KEY_D] and _cursor % 3 < 2: _cursor += 1
	elif k in [KEY_UP, KEY_W] and _cursor >= 3: _cursor -= 3
	elif k in [KEY_DOWN, KEY_S] and _cursor < 6: _cursor += 3
	elif k in [KEY_SPACE, KEY_ENTER]: _whack(_cursor)


func click(p: Vector2) -> void:
	for i in _holes.size():
		if p.distance_to(_holes[i]) < 22:
			_cursor = i
			_whack(i)


static func _numpad(k: int) -> int:
	# Laid out like a numeric keypad: 7 8 9 on top.
	var n := -1
	if k >= KEY_1 and k <= KEY_9:
		n = k - KEY_1 + 1
	elif k >= KEY_KP_1 and k <= KEY_KP_9:
		n = k - KEY_KP_1 + 1
	if n < 0:
		return -1
	var row := 2 - floori((n - 1) / 3.0)
	return row * 3 + (n - 1) % 3


func _whack(hole: int) -> void:
	for p in _pods:
		if p.hole != hole or p.hit >= 0.0:
			continue
		p.hit = 0.0
		var at: Vector2 = _holes[hole] + Vector2(0, -20)
		match p.kind:
			"crash":
				score += 10
				ug.pop("+10", at, Underground.GREEN)
				Sfx.play("hit")
			"oom":
				score += 20
				ug.pop("+20 OOM!", at, Underground.GOLD)
				Sfx.play("coin")
			"ok":
				score = maxi(0, score - 15)
				ug.pop(ug.tr("-15 it was fine!"), at, Color(1, 0.4, 0.4))
				Sfx.play("error")
		return
	Sfx.play("miss")


func paint(v: Control) -> void:
	ug.paint_cave()
	ug.paint_bar("WHACK-A-POD", "%ds" % ceili(maxf(_left, 0.0)))
	for i in _holes.size():
		var c: Vector2 = _holes[i]
		v.draw_rect(Rect2(c.x - 18, c.y, 36, 7), Color(0.02, 0.02, 0.03))
		v.draw_rect(Rect2(c.x - 20, c.y + 5, 40, 3), Underground.ROCK_HI)
		if i == _cursor:
			v.draw_rect(Rect2(c.x - 21, c.y + 9, 42, 1), Underground.GOLD)
		var n: int = [7, 8, 9, 4, 5, 6, 1, 2, 3][i]
		ug.text(str(n), Vector2(c.x + 24, c.y + 8), 6, Underground.DIM)
	for p in _pods:
		var c: Vector2 = _holes[p.hole]
		var rise := clampf(minf(p.t, p.life - p.t) / 0.15, 0.0, 1.0)
		var col: Color = {"crash": RED, "oom": PURPLE, "ok": Underground.GREEN}[p.kind]
		if p.hit >= 0.0:
			col = Underground.GREEN if p.kind != "ok" else Color(1, 0.5, 0.2)
			rise = 1.0 - p.hit / 0.35
		var hgt := 16.0 * rise
		v.draw_rect(Rect2(c.x - 9, c.y - hgt, 18, hgt), col)
		if hgt > 10:
			# A little face: X eyes when crashing, dots when fine.
			var ey := c.y - hgt + 5
			if p.kind == "ok" or p.hit >= 0.0:
				v.draw_rect(Rect2(c.x - 5, ey, 2, 2), Color.BLACK)
				v.draw_rect(Rect2(c.x + 3, ey, 2, 2), Color.BLACK)
			else:
				for dx in [-5, 3]:
					v.draw_line(Vector2(c.x + dx - 1, ey - 1), Vector2(c.x + dx + 2, ey + 2), Color.BLACK)
					v.draw_line(Vector2(c.x + dx + 2, ey - 1), Vector2(c.x + dx - 1, ey + 2), Color.BLACK)
			if p.kind == "oom" and p.hit < 0.0:
				ug.text("OOM", Vector2(c.x, c.y - hgt - 3), 6, Underground.GOLD, true)


func help() -> String:
	return ug.tr("1-9, click or arrows + SPACE  ·  red/purple = broken, green = fine")
