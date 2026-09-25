class_name ArcadeLaser
extends ArcadeGame
## LASER TAG: you against three rogue pods in the server room. Tag them with
## your laser, hide behind the racks; a hit stuns you for a second.

const ARENA := Rect2(8, 18, 304, 150)
const ROUND := 60.0
const ME := Color(0.3, 0.95, 1.0)
const BOT := Color(0.95, 0.3, 0.3)
const RACKS := [Rect2(60, 44, 14, 34), Rect2(60, 110, 14, 34), Rect2(246, 44, 14, 34), Rect2(246, 110, 14, 34),
	Rect2(126, 40, 68, 10), Rect2(126, 136, 68, 10), Rect2(150, 80, 20, 26), Rect2(100, 84, 10, 18), Rect2(210, 84, 10, 18)]

var _pos := Vector2(24, 93)
var _face := Vector2.RIGHT
var _stun := 0.0
var _cool := 0.0
var _bots: Array = []     # {pos, goal, cool, out, name}
var _beams: Array = []    # {a, b, t, color}
var _left := ROUND
var _tags := 0
var _rng := RandomNumberGenerator.new()


func start() -> void:
	_rng.randomize()
	for n in ["rogue-a1", "rogue-b7", "rogue-c3"]:
		_bots.append({"pos": _free_spot(160.0), "goal": _free_spot(0.0), "cool": _rng.randf_range(1.0, 2.0), "out": 0.0, "name": n})


func tick(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		ug.game_over(ug.tr("ROUND OVER"), ug.tr("you tagged %d rogue pods") % _tags)
		return
	_cool -= delta
	if _stun > 0.0:
		_stun -= delta
	else:
		var d := Vector2.ZERO
		if held([KEY_LEFT, KEY_A]): d.x -= 1
		if held([KEY_RIGHT, KEY_D]): d.x += 1
		if held([KEY_UP, KEY_W]): d.y -= 1
		if held([KEY_DOWN, KEY_S]): d.y += 1
		if d != Vector2.ZERO:
			_face = d.normalized()
			_pos = _move(_pos, _face * 75.0 * delta, 4.0)
	for b in _bots:
		if b.out > 0.0:
			b.out -= delta
			if b.out <= 0.0:
				b.pos = _free_spot(90.0)
			continue
		var to: Vector2 = b.goal - b.pos
		if to.length() < 4.0:
			b.goal = _free_spot(0.0)
		else:
			var np := _move(b.pos, to.normalized() * (38.0 + minf(ROUND - _left, 40.0) * 0.5) * delta, 4.0)
			if np == b.pos:
				b.goal = _free_spot(0.0)
			b.pos = np
		b.cool -= delta
		if b.cool <= 0.0 and _stun <= 0.0 and _sees(b.pos, _pos):
			b.cool = _rng.randf_range(1.4, 2.4)
			var aim: Vector2 = (_pos - b.pos).normalized().rotated(_rng.randf_range(-0.12, 0.12))
			var hit := _ray(b.pos, aim, b)
			_beams.append({"a": b.pos, "b": hit.end, "t": 0.0, "color": BOT})
			Sfx.play("ray")
			if hit.me:
				_stun = 1.0
				score = maxi(0, score - 50)
				ug.pop("-50", _pos + Vector2(0, -8), BOT)
				Sfx.play("hit")
	for bm in _beams:
		bm.t += delta
	_beams = _beams.filter(func(bm): return bm.t < 0.15)


func key(k: int) -> void:
	if k in [KEY_SPACE, KEY_ENTER, KEY_KP_ENTER, KEY_J, KEY_K]:
		_fire(_face)


func click(p: Vector2) -> void:
	if p.distance_to(_pos) > 1.0:
		_face = (p - _pos).normalized()
	_fire(_face)


func _fire(dir: Vector2) -> void:
	if _stun > 0.0 or _cool > 0.0:
		return
	_cool = 0.3
	var hit := _ray(_pos, dir, null)
	_beams.append({"a": _pos, "b": hit.end, "t": 0.0, "color": ME})
	Sfx.play("blaster")
	if hit.bot != null:
		hit.bot.out = 2.0
		_tags += 1
		score += 100
		ug.pop("+100 %s" % hit.bot.name, hit.bot.pos + Vector2(0, -8), Underground.GOLD)


## Where a laser stops: a rack, the wall, a pod or you.
func _ray(from: Vector2, dir: Vector2, shooter) -> Dictionary:
	var p := from
	for i in 200:
		p += dir * 2.0
		if not ARENA.has_point(p) or _in_rack(p, 0.0):
			return {"end": p, "bot": null, "me": false}
		if shooter != null and p.distance_to(_pos) < 5.0:
			return {"end": p, "bot": null, "me": true}
		if shooter == null:
			for b in _bots:
				if b.out <= 0.0 and p.distance_to(b.pos) < 5.0:
					return {"end": p, "bot": b, "me": false}
	return {"end": p, "bot": null, "me": false}


func _sees(a: Vector2, b: Vector2) -> bool:
	var n := int(a.distance_to(b) / 3.0)
	for i in n:
		if _in_rack(a.lerp(b, float(i) / n), 0.0):
			return false
	return true


func _in_rack(p: Vector2, r: float) -> bool:
	for rk in RACKS:
		if (rk as Rect2).grow(r).has_point(p):
			return true
	return false


func _move(p: Vector2, by: Vector2, r: float) -> Vector2:
	var box := ARENA.grow(-r)
	var nx := Vector2(p.x + by.x, p.y)
	if box.has_point(nx) and not _in_rack(nx, r):
		p = nx
	var ny := Vector2(p.x, p.y + by.y)
	if box.has_point(ny) and not _in_rack(ny, r):
		p = ny
	return p


func _free_spot(away: float) -> Vector2:
	for i in 60:
		var p := Vector2(_rng.randf_range(ARENA.position.x + 8, ARENA.end.x - 8), _rng.randf_range(ARENA.position.y + 8, ARENA.end.y - 8))
		if not _in_rack(p, 6.0) and p.distance_to(_pos) >= away:
			return p
	return ARENA.get_center() + Vector2(100, 0)


func paint(v: Control) -> void:
	v.draw_rect(ARENA.grow(2), Underground.ROCK_HI)
	v.draw_rect(ARENA, Color(0.03, 0.03, 0.06))
	for x in range(int(ARENA.position.x), int(ARENA.end.x), 16):
		v.draw_rect(Rect2(x, ARENA.position.y, 1, ARENA.size.y), Color(0.3, 0.5, 1.0, 0.06))
	for y in range(int(ARENA.position.y), int(ARENA.end.y), 16):
		v.draw_rect(Rect2(ARENA.position.x, y, ARENA.size.x, 1), Color(0.3, 0.5, 1.0, 0.06))
	for rk in RACKS:
		var r: Rect2 = rk
		v.draw_rect(r, Color(0.18, 0.17, 0.24))
		v.draw_rect(Rect2(r.position, Vector2(r.size.x, 1)), Color(0.35, 0.33, 0.45))
		# Blinking server lights.
		for k in int(r.size.y / 6.0):
			var on := sin(t * 5.0 + k * 1.7 + r.position.x) > 0.0
			v.draw_rect(Rect2(r.position.x + 2, r.position.y + 3 + k * 6, 2, 1), Underground.GREEN if on else Color(0.2, 0.3, 0.2))
	for bm in _beams:
		var a: Vector2 = bm.a
		var b: Vector2 = bm.b
		var c: Color = bm.color
		v.draw_line(a, b, Color(c, 0.35), 3.0)
		v.draw_line(a, b, Color(1, 1, 1, 0.9), 1.0)
		v.draw_circle(b, 2.5, Color(c, 0.8))
	for bt in _bots:
		var p: Vector2 = bt.pos
		if bt.out > 0.0:
			if fmod(t, 0.2) < 0.1:
				v.draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), Color(BOT, 0.3))
			continue
		v.draw_rect(Rect2(p - Vector2(4, 4), Vector2(8, 8)), BOT)
		v.draw_rect(Rect2(p + Vector2(-2, -2), Vector2(1, 1)), Color.BLACK)
		v.draw_rect(Rect2(p + Vector2(1, -2), Vector2(1, 1)), Color.BLACK)
		if bt.cool < 0.35:
			v.draw_circle(p, 6, Color(BOT, 0.25))   # about to fire
	if _stun <= 0.0 or fmod(t, 0.16) < 0.08:
		v.draw_rect(Rect2(_pos - Vector2(4, 4), Vector2(8, 8)), ME)
		v.draw_rect(Rect2(_pos + _face * 5 - Vector2(1, 1), Vector2(2, 2)), Color.WHITE)
	ug.paint_bar("LASER TAG", "%ds" % ceili(maxf(_left, 0.0)))


func help() -> String:
	return ug.tr("move WASD/arrows  ·  SPACE or click fires  ·  hide behind the racks")
