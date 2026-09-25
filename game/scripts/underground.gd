class_name Underground
extends CanvasLayer
## KUBIVERSE: UNDERGROUND, the hidden arcade under the cluster (↑ ↑ ↓ ↓ ← →
## and type START). A pixel screen of 320×180 scaled to the window, with a
## cabinet per minigame. Nothing here touches the cluster.

signal closed

const W := 320
const H := 180
const SAVE := "user://underground.cfg"
const GAMES := [
	{"id": "whack", "title": "WHACK-A-POD", "color": Color(0.95, 0.32, 0.3),
		"blurb": "Restart the crashing pods.\nDon't hit the healthy ones."},
	{"id": "snake", "title": "OOM SNAKE", "color": Color(0.6, 0.42, 1.0),
		"blurb": "Eat requests, grow your memory.\nDon't bite yourself."},
	{"id": "soon", "title": "???", "color": Color(0.38, 0.38, 0.44),
		"blurb": "Out of order.\nMore games are coming."},
]
const BG := Color(0.04, 0.035, 0.07)
const ROCK := Color(0.12, 0.1, 0.16)
const ROCK_HI := Color(0.2, 0.16, 0.26)
const TEXT := Color(0.92, 0.9, 1.0)
const DIM := Color(0.55, 0.52, 0.66)
const GOLD := Color(1.0, 0.8, 0.25)
const GREEN := Color(0.35, 0.9, 0.45)

var font: Font
var player: Node          # frozen while we are down here
var code := SecretCode.new()

var _view: Control
var _prompt: Label        # on the surface: "> STA_" while START is typed
var _state := ""          # descend, hub, whack, snake, over
var _t := 0.0
var _sel := 0
var _best := {}
var _score := 0
var _new_best := false
var _over_title := ""
var _over_why := ""
var _rng := RandomNumberGenerator.new()
var _rocks: Array = []    # stalactites / stalagmites [x, width, height, top]
var _shrooms: Array = []  # glowing mushrooms [x, y, hue]
var _pops: Array = []     # floating texts {text, pos, t, color}

# Whack-a-Pod
var _holes: Array = []    # Vector2 centers
var _pods: Array = []     # {hole, kind, t, life, hit}
var _left := 0.0
var _spawn := 0.0
var _cursor := 4

# OOM Snake
const CELL := 8
const GW := 36
const GH := 17
const GRID0 := Vector2(16, 32)
var _snake: Array = []    # Vector2i, head first
var _dir := Vector2i.RIGHT
var _next_dir := Vector2i.RIGHT
var _food := Vector2i.ZERO
var _step := 0.0
var _speed := 0.13


func _ready() -> void:
	layer = 120
	process_mode = Node.PROCESS_MODE_ALWAYS
	_prompt = Label.new()
	_prompt.anchor_left = 0.0
	_prompt.anchor_right = 1.0
	_prompt.anchor_top = 0.3
	_prompt.anchor_bottom = 0.3
	_prompt.offset_top = -30
	_prompt.offset_bottom = 30
	_prompt.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_prompt.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_prompt.add_theme_font_size_override("font_size", 48)
	_prompt.add_theme_color_override("font_color", GOLD)
	_prompt.add_theme_color_override("font_outline_color", Color.BLACK)
	_prompt.add_theme_constant_override("outline_size", 8)
	_prompt.visible = false
	add_child(_prompt)
	_view = Control.new()
	_view.visible = false
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_STOP
	_view.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_view.draw.connect(_paint)
	add_child(_view)
	_rng.seed = 2600
	for i in 22:
		var top := i % 2 == 0
		_rocks.append([_rng.randf_range(0, W), _rng.randf_range(6, 16), _rng.randf_range(8, 26), top])
	for i in 9:
		_shrooms.append([_rng.randf_range(8, W - 8), _rng.randf_range(160, 172), _rng.randf()])
	for r in 3:
		for c in 3:
			_holes.append(Vector2(100 + c * 60, 62 + r * 38))
	var cfg := ConfigFile.new()
	if cfg.load(SAVE) == OK:
		for g in GAMES:
			_best[g.id] = int(cfg.get_value("best", g.id, 0))


func is_open() -> bool:
	return _view.visible


func open(skip_descent := false) -> void:
	if font:
		_prompt.add_theme_font_override("font", font)
	_prompt.visible = false
	_view.visible = true
	_state = "hub" if skip_descent else "descend"
	_t = 0.0
	_pops.clear()
	if player:
		player.set("frozen", true)
	Sfx.play("jingle" if skip_descent else "fall")


func close() -> void:
	_view.visible = false
	_state = ""
	if player:
		player.set("frozen", false)
	Sfx.play("door")
	closed.emit()


func start_game(id: String) -> void:
	_score = 0
	_new_best = false
	_pops.clear()
	_t = 0.0
	match id:
		"whack":
			_state = "whack"
			_pods.clear()
			_left = 30.0
			_spawn = 0.6
			_cursor = 4
		"snake":
			_state = "snake"
			_snake = [Vector2i(8, 8), Vector2i(7, 8), Vector2i(6, 8)]
			_dir = Vector2i.RIGHT
			_next_dir = _dir
			_speed = 0.13
			_step = 0.0
			_place_food()
		_:
			Sfx.play("error")
			_pop(tr("OUT OF ORDER"), Vector2(80 + _sel * 80, 60), DIM)
			return
	Sfx.play("coin")


func _process(delta: float) -> void:
	if not _view.visible:
		code.tick(delta)
		if _prompt.visible and not code.armed():
			_prompt.visible = false
			if player:
				player.set("frozen", false)
		elif _prompt.visible:
			_prompt.text = "> " + code.typed() + ("_" if fmod(Time.get_ticks_msec() / 1000.0, 0.8) < 0.5 else " ")
		return
	_t += delta
	match _state:
		"descend":
			if _t > 2.2:
				_state = "hub"
				_t = 0.0
				Sfx.play("jingle")
		"whack":
			_whack_tick(delta)
		"snake":
			_snake_tick(delta)
	for p in _pops:
		p.t += delta
		p.pos.y -= delta * 18.0
	_pops = _pops.filter(func(p): return p.t < 1.0)
	_view.queue_redraw()


# --- input -------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _view.visible:
		_listen(event)
		return
	get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click(_to_virtual(_view.get_local_mouse_position()))
		return
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var k: int = event.keycode
	match _state:
		"descend":
			if k in [KEY_ENTER, KEY_SPACE, KEY_ESCAPE]:
				_t = 99.0
		"hub":
			if k in [KEY_LEFT, KEY_A]:
				_sel = (_sel + GAMES.size() - 1) % GAMES.size()
				Sfx.play("click")
			elif k in [KEY_RIGHT, KEY_D]:
				_sel = (_sel + 1) % GAMES.size()
				Sfx.play("click")
			elif k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]:
				start_game(GAMES[_sel].id)
			elif k == KEY_ESCAPE:
				close()
		"whack":
			if k == KEY_ESCAPE:
				_state = "hub"
			var n := _numpad(k)
			if n >= 0:
				_whack(n)
			elif k in [KEY_LEFT, KEY_A] and _cursor % 3 > 0: _cursor -= 1
			elif k in [KEY_RIGHT, KEY_D] and _cursor % 3 < 2: _cursor += 1
			elif k in [KEY_UP, KEY_W] and _cursor >= 3: _cursor -= 3
			elif k in [KEY_DOWN, KEY_S] and _cursor < 6: _cursor += 3
			elif k in [KEY_SPACE, KEY_ENTER]: _whack(_cursor)
		"snake":
			var d := Vector2i.ZERO
			match k:
				KEY_UP, KEY_W: d = Vector2i.UP
				KEY_DOWN, KEY_S: d = Vector2i.DOWN
				KEY_LEFT, KEY_A: d = Vector2i.LEFT
				KEY_RIGHT, KEY_D: d = Vector2i.RIGHT
				KEY_ESCAPE: _state = "hub"
			if d != Vector2i.ZERO and d != -_dir:
				_next_dir = d
		"over":
			if k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE] and _t > 0.5:
				start_game(GAMES[_sel].id)
			elif k == KEY_ESCAPE:
				_state = "hub"


## On the surface: watch for the code (not while typing in a text field).
func _listen(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	var focus := get_viewport().gui_get_focus_owner()
	if focus is LineEdit or focus is TextEdit:
		return
	var was_armed := code.armed()
	var done := code.feed(SecretCode.token(event.keycode))
	if done or (was_armed and code.armed()):
		# START is being typed: don't let S/T/A/R reach the game's hotkeys.
		get_viewport().set_input_as_handled()
	if player and not done:
		player.set("frozen", code.armed())
	if font and not _prompt.has_theme_font_override("font"):
		_prompt.add_theme_font_override("font", font)
	_prompt.visible = code.armed()
	_prompt.text = "> " + code.typed() + "_"
	if done:
		open()
	elif was_armed and not code.armed():
		Sfx.play("miss")
	elif code.armed():
		Sfx.play("key")


func _click(p: Vector2) -> void:
	match _state:
		"hub":
			for i in GAMES.size():
				if Rect2(52 + i * 80, 58, 56, 92).has_point(p):
					if i == _sel:
						start_game(GAMES[i].id)
					else:
						_sel = i
						Sfx.play("click")
			if Rect2(4, 164, 90, 14).has_point(p):
				close()
		"whack":
			for i in _holes.size():
				if p.distance_to(_holes[i]) < 22:
					_cursor = i
					_whack(i)
		"over":
			if _t > 0.5:
				start_game(GAMES[_sel].id)


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


# --- Whack-a-Pod -------------------------------------------------------------

func _whack_tick(delta: float) -> void:
	_left -= delta
	if _left <= 0.0:
		_game_over(tr("TIME'S UP"), tr("%d points of uptime saved") % _score)
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
			var life := base / sqrt(pace)
			_pods.append({"hole": free[_rng.randi() % free.size()], "kind": kind, "t": 0.0, "life": life, "hit": -1.0})
	for p in _pods:
		p.t += delta
		if p.hit >= 0.0:
			p.hit += delta
	_pods = _pods.filter(func(p): return p.t < p.life and p.hit < 0.35)


func _whack(hole: int) -> void:
	for p in _pods:
		if p.hole != hole or p.hit >= 0.0:
			continue
		p.hit = 0.0
		var at: Vector2 = _holes[hole] + Vector2(0, -20)
		match p.kind:
			"crash":
				_score += 10
				_pop("+10", at, GREEN)
				Sfx.play("hit")
			"oom":
				_score += 20
				_pop("+20 OOM!", at, GOLD)
				Sfx.play("coin")
			"ok":
				_score = maxi(0, _score - 15)
				_pop(tr("-15 it was fine!"), at, Color(1, 0.4, 0.4))
				Sfx.play("error")
		return
	Sfx.play("miss")


# --- OOM Snake ---------------------------------------------------------------

func _snake_tick(delta: float) -> void:
	_step += delta
	if _step < _speed:
		return
	_step = 0.0
	_dir = _next_dir
	var head: Vector2i = _snake[0] + _dir
	if head.x < 0 or head.y < 0 or head.x >= GW or head.y >= GH:
		_game_over("CrashLoopBackOff", tr("you ran into the node's wall"))
		return
	if head in _snake.slice(0, _snake.size() - 1):
		_game_over("OOMKilled", tr("you ate your own memory"))
		return
	_snake.push_front(head)
	if head == _food:
		_score += 10
		_speed = maxf(0.055, _speed - 0.004)
		_pop("+%dMi" % 64, GRID0 + Vector2(head) * CELL, GOLD)
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


func _game_over(title: String, why: String) -> void:
	_state = "over"
	_t = 0.0
	_over_title = title
	_over_why = why
	var id: String = GAMES[_sel].id
	if _score > int(_best.get(id, 0)):
		_best[id] = _score
		_new_best = true
		var cfg := ConfigFile.new()
		cfg.load(SAVE)
		cfg.set_value("best", id, _score)
		cfg.save(SAVE)
		Sfx.play("jingle")
	else:
		Sfx.play("pod_death")


func _pop(text: String, at: Vector2, color: Color) -> void:
	_pops.append({"text": text, "pos": at, "t": 0.0, "color": color})


# --- drawing -----------------------------------------------------------------

func _scale() -> float:
	var s := _view.size
	return maxf(1.0, floorf(minf(s.x / W, s.y / H) * 2.0) / 2.0)


func _origin() -> Vector2:
	return ((_view.size - Vector2(W, H) * _scale()) / 2.0).floor()


func _to_virtual(p: Vector2) -> Vector2:
	return (p - _origin()) / _scale()


func _paint() -> void:
	var v := _view
	v.draw_rect(Rect2(Vector2.ZERO, v.size), Color.BLACK)
	v.draw_set_transform(_origin(), 0.0, Vector2.ONE * _scale())
	v.draw_rect(Rect2(0, 0, W, H), BG)
	match _state:
		"descend": _paint_descend()
		"hub": _paint_hub()
		"whack": _paint_whack()
		"snake": _paint_snake()
		"over":
			if GAMES[_sel].id == "snake": _paint_snake()
			else: _paint_whack()
			_paint_over()
	for p in _pops:
		_text(p.text, p.pos, 8, Color(p.color, 1.0 - p.t), true)
	# CRT scanlines
	for y in range(0, H, 2):
		v.draw_rect(Rect2(0, y, W, 1), Color(0, 0, 0, 0.18))
	v.draw_set_transform(Vector2.ZERO)


func _text(s: String, at: Vector2, size: int, color: Color, center := false) -> void:
	if font == null:
		font = ThemeDB.fallback_font
	# Drawn at the screen's resolution: a pixel font scaled below its size
	# turns to mush.
	var k := _scale()
	var px := int(size * k)
	var pos := _origin() + at * k
	if center:
		pos.x -= font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x / 2.0
	pos = pos.floor()
	_view.draw_set_transform(Vector2.ZERO)
	_view.draw_string(font, pos + Vector2(k, k), s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, Color(0, 0, 0, color.a * 0.8))
	_view.draw_string(font, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)
	_view.draw_set_transform(_origin(), 0.0, Vector2.ONE * k)


func _paint_descend() -> void:
	var v := _view
	var k := minf(_t / 2.2, 1.0)
	# Elevator shaft walls rushing up.
	for i in 14:
		var y := fmod(i * 16.0 - _t * 260.0, H + 16.0)
		if y < 0: y += H + 16.0
		v.draw_rect(Rect2(40, y, 6, 3), ROCK_HI)
		v.draw_rect(Rect2(W - 46, fmod(y + 8.0, H + 16.0), 6, 3), ROCK_HI)
	v.draw_rect(Rect2(36, 0, 2, H), ROCK)
	v.draw_rect(Rect2(W - 38, 0, 2, H), ROCK)
	# The cabin.
	var cy := 70.0 + sin(_t * 30.0) * 1.0
	v.draw_rect(Rect2(130, cy, 60, 50), Color(0.25, 0.22, 0.32))
	v.draw_rect(Rect2(134, cy + 4, 52, 42), Color(0.08, 0.07, 0.12))
	v.draw_rect(Rect2(159, 0, 2, cy), Color(0.4, 0.4, 0.45))
	_text("-%d m" % int(k * 1337), Vector2(160, cy + 30), 8, GOLD, true)
	_text(tr("going down..."), Vector2(160, 150), 8, DIM, true)


func _paint_cave() -> void:
	var v := _view
	for r in _rocks:
		var x: float = r[0]
		var w: float = r[1]
		var h: float = r[2]
		if r[3]:
			v.draw_colored_polygon(PackedVector2Array([Vector2(x - w / 2, 0), Vector2(x + w / 2, 0), Vector2(x, h)]), ROCK)
		else:
			v.draw_colored_polygon(PackedVector2Array([Vector2(x - w / 2, H), Vector2(x + w / 2, H), Vector2(x, H - h * 0.6)]), ROCK)
	v.draw_rect(Rect2(0, 156, W, 24), ROCK)
	v.draw_rect(Rect2(0, 156, W, 1), ROCK_HI)
	for m in _shrooms:
		var c := Color.from_hsv(0.5 + m[2] * 0.35, 0.7, 1.0)
		var glow := 0.25 + 0.15 * sin(_t * 2.0 + m[2] * 9.0)
		v.draw_circle(Vector2(m[0], m[1] - 3), 6, Color(c, glow * 0.4))
		v.draw_rect(Rect2(m[0] - 0.5, m[1] - 3, 1, 4), Color(0.8, 0.8, 0.7))
		v.draw_rect(Rect2(m[0] - 2.5, m[1] - 5, 5, 2), c)


func _paint_hub() -> void:
	var v := _view
	_paint_cave()
	# Title with a colour-cycling shadow.
	_text("KUBIVERSE:", Vector2(160, 20), 8, DIM, true)
	var hue := fmod(_t * 0.15, 1.0)
	_text("UNDERGROUND", Vector2(161, 39), 16, Color.from_hsv(hue, 0.8, 0.9), true)
	_text("UNDERGROUND", Vector2(160, 38), 16, TEXT, true)
	for i in GAMES.size():
		var g: Dictionary = GAMES[i]
		var sel := i == _sel
		var x := 52.0 + i * 80.0
		var y := 58.0 - (2.0 + sin(_t * 6.0) * 1.5 if sel else 0.0)
		if sel:
			v.draw_rect(Rect2(x - 3, y - 3, 62, 98), Color(g.color, 0.25 + 0.15 * sin(_t * 5.0)))
		# Cabinet: marquee, screen, panel, base.
		v.draw_rect(Rect2(x, y, 56, 92), Color(0.16, 0.14, 0.22))
		v.draw_rect(Rect2(x + 2, y + 2, 52, 12), g.color.darkened(0.2))
		_text(g.title, Vector2(x + 28, y + 11), 8 if g.title.length() < 10 else 6, TEXT, true)
		v.draw_rect(Rect2(x + 5, y + 18, 46, 34), Color(0.02, 0.02, 0.04))
		_paint_attract(g.id, Rect2(x + 6, y + 19, 44, 32))
		v.draw_rect(Rect2(x + 3, y + 56, 50, 12), Color(0.24, 0.22, 0.3))
		v.draw_circle(Vector2(x + 14, y + 62), 3, Color(0.9, 0.2, 0.2))
		v.draw_circle(Vector2(x + 30, y + 62), 2.5, GOLD)
		v.draw_circle(Vector2(x + 40, y + 62), 2.5, Color(0.3, 0.6, 1.0))
		v.draw_rect(Rect2(x + 6, y + 70, 44, 22), Color(0.12, 0.1, 0.17))
		var best := int(_best.get(g.id, 0))
		if g.id != "soon":
			_text("HI %d" % best, Vector2(x + 28, y + 84), 6, GOLD if best > 0 else DIM, true)
	var g2: Dictionary = GAMES[_sel]
	var lines: PackedStringArray = tr(g2.blurb).split("\n")
	for j in lines.size():
		_text(lines[j], Vector2(160, 162 + j * 8), 6, TEXT, true)
	_text(tr("ESC: surface"), Vector2(6, 176), 6, DIM)
	_text("< >  ENTER", Vector2(W - 6 - 40, 176), 6, DIM)


## What each cabinet's screen shows while nobody plays it.
func _paint_attract(id: String, r: Rect2) -> void:
	var v := _view
	match id:
		"whack":
			for i in 3:
				var up := sin(_t * 3.0 + i * 2.1) > 0.3
				var c := Vector2(r.position.x + 8 + i * 14, r.position.y + 24)
				v.draw_rect(Rect2(c.x - 5, c.y, 10, 3), Color(0.1, 0.08, 0.1))
				if up:
					v.draw_rect(Rect2(c.x - 4, c.y - 8, 8, 8), Color(0.95, 0.3, 0.3) if i != 1 else GREEN)
		"snake":
			var n := 8
			for i in n:
				var a := _t * 2.0 - i * 0.35
				var p := r.get_center() + Vector2(cos(a) * 14, sin(a * 2.0) * 8)
				v.draw_rect(Rect2(p.floor(), Vector2(3, 3)), Color(0.6, 0.42, 1.0).lightened(0.3 if i == 0 else 0.0))
		_:
			if fmod(_t, 1.2) < 0.9:
				_text("???", r.get_center() + Vector2(0, 3), 8, DIM, true)
			for i in 10:
				v.draw_rect(Rect2(r.position.x + _rng.randf() * r.size.x, r.position.y + _rng.randf() * r.size.y, 1, 1), Color(1, 1, 1, 0.3))


func _paint_hud_bar(title: String, right: String) -> void:
	_view.draw_rect(Rect2(0, 0, W, 14), Color(0, 0, 0, 0.5))
	_text(title, Vector2(6, 10), 8, TEXT)
	_text("%s  %d" % [tr("SCORE"), _score], Vector2(160, 10), 8, GOLD, true)
	_text(right, Vector2(W - 6 - font.get_string_size(right, HORIZONTAL_ALIGNMENT_LEFT, -1, 8 * int(_scale())).x / _scale(), 10), 8, DIM)


func _paint_whack() -> void:
	var v := _view
	_paint_cave()
	_paint_hud_bar("WHACK-A-POD", "%ds" % ceili(maxf(_left, 0.0)))
	for i in _holes.size():
		var c: Vector2 = _holes[i]
		v.draw_rect(Rect2(c.x - 18, c.y, 36, 7), Color(0.02, 0.02, 0.03))
		v.draw_rect(Rect2(c.x - 20, c.y + 5, 40, 3), ROCK_HI)
		if i == _cursor and _state == "whack":
			v.draw_rect(Rect2(c.x - 21, c.y + 9, 42, 1), GOLD)
		var n: int = [7, 8, 9, 4, 5, 6, 1, 2, 3][i]
		_text(str(n), Vector2(c.x + 24, c.y + 8), 6, DIM)
	for p in _pods:
		var c: Vector2 = _holes[p.hole]
		var rise := clampf(minf(p.t, p.life - p.t) / 0.15, 0.0, 1.0)
		var col: Color = {"crash": Color(0.95, 0.3, 0.3), "oom": Color(0.7, 0.35, 1.0), "ok": GREEN}[p.kind]
		if p.hit >= 0.0:
			col = GREEN if p.kind != "ok" else Color(1, 0.5, 0.2)
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
				_text("OOM", Vector2(c.x, c.y - hgt - 3), 6, GOLD, true)
	_text(tr("1-9, click or arrows + SPACE  ·  red/purple = broken, green = fine"), Vector2(160, 176), 6, DIM, true)


func _paint_snake() -> void:
	var v := _view
	_paint_hud_bar("OOM SNAKE", "%d Mi" % (_snake.size() * 64))
	v.draw_rect(Rect2(GRID0 - Vector2(2, 2), Vector2(GW, GH) * CELL + Vector2(4, 4)), ROCK_HI)
	v.draw_rect(Rect2(GRID0, Vector2(GW, GH) * CELL), Color(0.02, 0.02, 0.05))
	for x in range(0, GW, 4):
		for y in range(0, GH, 4):
			v.draw_rect(Rect2(GRID0 + Vector2(x, y) * CELL + Vector2(3, 3), Vector2(1, 1)), Color(1, 1, 1, 0.08))
	# The request to eat: a blinking packet.
	var fp := GRID0 + Vector2(_food) * CELL
	v.draw_rect(Rect2(fp + Vector2(1, 1), Vector2(6, 6)), GOLD if fmod(_t, 0.4) < 0.3 else GOLD.darkened(0.3))
	for i in _snake.size():
		var sp := GRID0 + Vector2(_snake[i]) * CELL
		var c := Color(0.6, 0.42, 1.0).lerp(Color(0.95, 0.3, 0.3), minf(float(_snake.size()) / 60.0, 1.0))
		v.draw_rect(Rect2(sp + Vector2(0.5, 0.5), Vector2(7, 7)), c.lightened(0.35) if i == 0 else c)
	var head := GRID0 + Vector2(_snake[0]) * CELL
	v.draw_rect(Rect2(head + Vector2(2, 2), Vector2(1, 1)), Color.BLACK)
	v.draw_rect(Rect2(head + Vector2(5, 2), Vector2(1, 1)), Color.BLACK)
	_text(tr("arrows / WASD  ·  eat requests, don't hit the walls or yourself"), Vector2(160, 176), 6, DIM, true)


func _paint_over() -> void:
	var v := _view
	v.draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.6))
	v.draw_rect(Rect2(60, 50, 200, 80), Color(0.08, 0.06, 0.12))
	v.draw_rect(Rect2(60, 50, 200, 2), Color(0.95, 0.3, 0.3))
	_text(_over_title, Vector2(160, 70), 16, Color(0.95, 0.35, 0.35), true)
	_text(_over_why, Vector2(160, 84), 6, DIM, true)
	_text("%s %d" % [tr("SCORE"), _score], Vector2(160, 100), 8, TEXT, true)
	if _new_best and fmod(_t, 0.5) < 0.35:
		_text(tr("NEW HIGH SCORE!"), Vector2(160, 112), 8, GOLD, true)
	elif not _new_best:
		_text("HI %d" % int(_best.get(GAMES[_sel].id, 0)), Vector2(160, 112), 8, GOLD, true)
	_text(tr("ENTER: again   ESC: arcade"), Vector2(160, 125), 6, DIM, true)
