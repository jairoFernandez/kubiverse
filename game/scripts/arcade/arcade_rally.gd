class_name ArcadeRally
extends ArcadeGame
## KUBE RALLY: a packet racing down the service mesh highway. Weave through
## the traffic, grab the coins, and don't slide on the OOM puddles.

const ROAD_L := 104.0
const ROAD_R := 216.0
const LANES := [122.0, 141.0, 160.0, 179.0, 198.0]
const CAR := Vector2(10, 18)
const CAR_Y := 146.0
const COLORS := [Color(0.95, 0.3, 0.3), Color(0.3, 0.6, 1.0), Color(1.0, 0.8, 0.25), Color(0.35, 0.9, 0.45), Color(0.95, 0.5, 0.85), Color(0.9, 0.9, 0.95)]
const DRIVERS := ["nginx-7f9c", "redis-0", "api-6d8b", "ledger-86d1", "grafana-f09", "coredns-5dd", "kafka-2", "fraud-ai-e63"]

var _x := 160.0
var _speed := 110.0        # px/s the road scrolls
var _road := 0.0           # scroll offset
var _dist := 0.0
var _spin := 0.0           # sliding on an OOM puddle
var _spin_dir := 1.0
var _things: Array = []    # {kind: car|coin|oil, x, y, v, color, name}
var _spawn := 0.8
var _boost := false
var _rng := RandomNumberGenerator.new()


func start() -> void:
	_rng.randomize()


func tick(delta: float) -> void:
	var steer := 0.0
	if _spin > 0.0:
		_spin -= delta
		steer = _spin_dir * 1.4
	else:
		if held([KEY_LEFT, KEY_A]): steer -= 1.0
		if held([KEY_RIGHT, KEY_D]): steer += 1.0
	_x = clampf(_x + steer * 120.0 * delta, ROAD_L - 14, ROAD_R + 14)
	var target := 110.0 + minf(t * 3.0, 150.0)
	_boost = held([KEY_UP, KEY_W]) and _spin <= 0.0
	if _boost: target += 90.0
	if held([KEY_DOWN, KEY_S]): target *= 0.55
	var off_road := _x < ROAD_L + 4 or _x > ROAD_R - 4
	if off_road: target *= 0.5
	_speed = lerpf(_speed, target, delta * 2.5)
	_road = fmod(_road + _speed * delta, 24.0)
	_dist += _speed * delta
	score = int(_dist / 10.0)

	_spawn -= delta * _speed / 110.0
	if _spawn <= 0.0:
		_spawn = _rng.randf_range(0.35, 0.8)
		var roll := _rng.randf()
		var lane: float = LANES[_rng.randi() % LANES.size()]
		if _things.any(func(th): return th.x == lane and th.y < 30.0):
			pass   # that lane's entrance is taken: next time
		elif roll < 0.72:
			_things.append({"kind": "car", "x": lane, "y": -24.0, "v": _rng.randf_range(40, 90),
				"color": COLORS[_rng.randi() % COLORS.size()], "name": DRIVERS[_rng.randi() % DRIVERS.size()]})
		elif roll < 0.9:
			_things.append({"kind": "coin", "x": lane, "y": -10.0, "v": 0.0})
		else:
			_things.append({"kind": "oil", "x": lane, "y": -10.0, "v": 0.0})
	var me := Rect2(_x - CAR.x / 2 + 1, CAR_Y + 2, CAR.x - 2, CAR.y - 4)
	for th in _things:
		th.y += (_speed - th.v) * delta
		match th.kind:
			"car":
				if me.intersects(Rect2(th.x - CAR.x / 2 + 1, th.y + 2, CAR.x - 2, CAR.y - 4)):
					Sfx.play("explosion")
					ug.game_over(ug.tr("CRASH!"), ug.tr("you rear-ended %s") % th.name)
					return
			"coin":
				if me.grow(2).has_point(Vector2(th.x, th.y)):
					th.y = 999.0
					_dist += 250.0
					ug.pop("+25", Vector2(_x, CAR_Y - 6), Underground.GOLD)
					Sfx.play("coin")
			"oil":
				if _spin <= 0.0 and me.has_point(Vector2(th.x, th.y)):
					_spin = 0.6
					_spin_dir = -1.0 if _rng.randf() < 0.5 else 1.0
					ug.pop("OOM!", Vector2(_x, CAR_Y - 6), Color(0.7, 0.35, 1.0))
					Sfx.play("fall")
	_things = _things.filter(func(th): return th.y < 200.0 and th.y > -60.0)


func paint(v: Control) -> void:
	# Cave city on both sides, scrolling.
	v.draw_rect(Rect2(0, 14, ROAD_L - 8, 166), Color(0.07, 0.06, 0.1))
	v.draw_rect(Rect2(ROAD_R + 8, 14, 320 - ROAD_R - 8, 166), Color(0.07, 0.06, 0.1))
	for i in 9:
		var y := fmod(i * 24.0 + _road * 2.0, 216.0) - 24.0
		for side in [0, 1]:
			var x: float = 30.0 + (i % 3) * 18.0 if side == 0 else 244.0 + ((i + 1) % 3) * 18.0
			var hgt := 10.0 + (i * 7 % 5) * 3.0
			v.draw_rect(Rect2(x, y, 14, hgt), Underground.ROCK_HI)
			if (i + side) % 2 == 0:
				v.draw_rect(Rect2(x + 3, y + 3, 3, 2), Color(1, 0.85, 0.4, 0.8))
	# Shoulders and road.
	v.draw_rect(Rect2(ROAD_L - 8, 14, 8, 166), Color(0.2, 0.18, 0.24))
	v.draw_rect(Rect2(ROAD_R, 14, 8, 166), Color(0.2, 0.18, 0.24))
	for i in 9:
		var y := fmod(i * 24.0 + _road, 216.0) - 24.0
		v.draw_rect(Rect2(ROAD_L - 8, y, 8, 12), Color(0.9, 0.25, 0.25))
		v.draw_rect(Rect2(ROAD_R, y + 12, 8, 12), Color(0.9, 0.25, 0.25))
	v.draw_rect(Rect2(ROAD_L, 14, ROAD_R - ROAD_L, 166), Color(0.13, 0.12, 0.16))
	for k in range(1, LANES.size()):
		var lx: float = (LANES[k - 1] + LANES[k]) / 2.0
		for i in 9:
			var y := fmod(i * 24.0 + _road, 216.0) - 24.0
			v.draw_rect(Rect2(lx - 0.5, y, 1, 10), Color(1, 1, 1, 0.25))
	for th in _things:
		match th.kind:
			"car": _car(v, th.x, th.y, th.color, true)
			"coin":
				var w := 2.0 + absf(sin(t * 8.0 + th.x)) * 3.0
				v.draw_rect(Rect2(th.x - w / 2, th.y - 3, w, 6), Underground.GOLD)
			"oil":
				v.draw_circle(Vector2(th.x, th.y), 6, Color(0.45, 0.2, 0.7, 0.85))
				v.draw_circle(Vector2(th.x - 2, th.y - 1), 2, Color(0.8, 0.6, 1.0, 0.6))
	if _boost:
		for i in 3:
			v.draw_rect(Rect2(_x - 3 + i * 2, CAR_Y + CAR.y + _rng.randf() * 4, 2, 3), Color(1, 0.6 + i * 0.1, 0.2))
	var wob := sin(t * 40.0) * 2.0 if _spin > 0.0 else 0.0
	_car(v, _x + wob, CAR_Y, Color(0.3, 0.95, 1.0), false)
	ug.paint_bar("KUBE RALLY", "%d km/h" % int(_speed * 0.9))


func _car(v: Control, x: float, y: float, color: Color, other: bool) -> void:
	var r := Rect2(x - CAR.x / 2, y, CAR.x, CAR.y)
	for wy in [3.0, CAR.y - 6.0]:
		v.draw_rect(Rect2(r.position.x - 1, y + wy, 2, 4), Color.BLACK)
		v.draw_rect(Rect2(r.end.x - 1, y + wy, 2, 4), Color.BLACK)
	v.draw_rect(r, color)
	# Windshield at the front: other cars drive the same way, so theirs is at
	# the bottom from the chaser's point of view (we see their back window).
	var wy2 := y + 4.0 if not other else y + CAR.y - 8.0
	v.draw_rect(Rect2(x - 3, wy2, 6, 4), Color(0.1, 0.12, 0.2))
	v.draw_rect(Rect2(x - 4, y + (CAR.y - 2 if other else 0), 2, 1), Color(1, 0.2, 0.2) if other else Color(1, 1, 0.7))
	v.draw_rect(Rect2(x + 2, y + (CAR.y - 2 if other else 0), 2, 1), Color(1, 0.2, 0.2) if other else Color(1, 1, 0.7))


func help() -> String:
	return ug.tr("left/right steer  ·  up turbo  ·  down brake  ·  coins +25, purple = OOM puddle")
