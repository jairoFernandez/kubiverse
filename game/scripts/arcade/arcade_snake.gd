class_name ArcadeSnake
extends ArcadeGame
## OOM SNAKE: a container eating requests, one more 64Mi each; the node's
## wall is a CrashLoopBackOff and biting yourself is an OOMKill.

const CELL := 8
const GW := 36
const GH := 17
const GRID0 := Vector2(16, 32)
const BODY := Color(0.6, 0.42, 1.0)

var _snake: Array = []    # Vector2i, head first
var _dir := Vector2i.RIGHT
var _next_dir := Vector2i.RIGHT
var _food := Vector2i.ZERO
var _step := 0.0
var _speed := 0.13
var _rng := RandomNumberGenerator.new()


func start() -> void:
	_rng.randomize()
	_snake = [Vector2i(8, 8), Vector2i(7, 8), Vector2i(6, 8)]
	_place_food()


func key(k: int) -> void:
	var d := Vector2i.ZERO
	match k:
		KEY_UP, KEY_W: d = Vector2i.UP
		KEY_DOWN, KEY_S: d = Vector2i.DOWN
		KEY_LEFT, KEY_A: d = Vector2i.LEFT
		KEY_RIGHT, KEY_D: d = Vector2i.RIGHT
	if d != Vector2i.ZERO and d != -_dir:
		_next_dir = d


func tick(delta: float) -> void:
	_step += delta
	if _step < _speed:
		return
	_step = 0.0
	_dir = _next_dir
	var head: Vector2i = _snake[0] + _dir
	if head.x < 0 or head.y < 0 or head.x >= GW or head.y >= GH:
		ug.game_over("CrashLoopBackOff", ug.tr("you ran into the node's wall"))
		return
	if head in _snake.slice(0, _snake.size() - 1):
		ug.game_over("OOMKilled", ug.tr("you ate your own memory"))
		return
	_snake.push_front(head)
	if head == _food:
		score += 10
		_speed = maxf(0.055, _speed - 0.004)
		ug.pop("+64Mi", GRID0 + Vector2(head) * CELL, Underground.GOLD)
		Sfx.play("coin")
		_place_food()
	else:
		_snake.pop_back()


func _place_food() -> void:
	while true:
		var f := Vector2i(_rng.randi() % GW, _rng.randi() % GH)
		if not f in _snake:
			_food = f
			return


func paint(v: Control) -> void:
	ug.paint_bar("OOM SNAKE", "%d Mi" % (_snake.size() * 64))
	v.draw_rect(Rect2(GRID0 - Vector2(2, 2), Vector2(GW, GH) * CELL + Vector2(4, 4)), Underground.ROCK_HI)
	v.draw_rect(Rect2(GRID0, Vector2(GW, GH) * CELL), Color(0.02, 0.02, 0.05))
	for x in range(0, GW, 4):
		for y in range(0, GH, 4):
			v.draw_rect(Rect2(GRID0 + Vector2(x, y) * CELL + Vector2(3, 3), Vector2(1, 1)), Color(1, 1, 1, 0.08))
	# The request to eat: a blinking packet.
	var fp := GRID0 + Vector2(_food) * CELL
	v.draw_rect(Rect2(fp + Vector2(1, 1), Vector2(6, 6)), Underground.GOLD if fmod(t, 0.4) < 0.3 else Underground.GOLD.darkened(0.3))
	var c := BODY.lerp(Color(0.95, 0.3, 0.3), minf(float(_snake.size()) / 60.0, 1.0))
	for i in _snake.size():
		var sp := GRID0 + Vector2(_snake[i]) * CELL
		v.draw_rect(Rect2(sp + Vector2(0.5, 0.5), Vector2(7, 7)), c.lightened(0.35) if i == 0 else c)
	var head := GRID0 + Vector2(_snake[0]) * CELL
	v.draw_rect(Rect2(head + Vector2(2, 2), Vector2(1, 1)), Color.BLACK)
	v.draw_rect(Rect2(head + Vector2(5, 2), Vector2(1, 1)), Color.BLACK)


func help() -> String:
	return ug.tr("arrows / WASD  ·  eat requests, don't hit the walls or yourself")
