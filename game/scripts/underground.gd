class_name Underground
extends CanvasLayer
## KUBIVERSE: UNDERGROUND, the hidden arcade under the cluster (↑ ↑ ↓ ↓ ← →
## and type START). A pixel screen of 320×180 scaled to the window, with a
## cabinet per minigame (scripts/arcade). Nothing here touches the cluster,
## but the cluster's alarms stay in sight on the bar at the top, next to the
## way back up.

signal closed
signal alarm_clicked(alarm: Dictionary)   # go up and look at it

const W := 320
const H := 180
const BAR := 12            # the system bar above the screen (virtual px)
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
const CAB_W := 52.0
const CAB_STEP := 62.0
const CAB_X0 := 10.0
const CAB_Y := 54.0
const BG := Color(0.04, 0.035, 0.07)
const ROCK := Color(0.12, 0.1, 0.16)
const ROCK_HI := Color(0.2, 0.16, 0.26)
const TEXT := Color(0.92, 0.9, 1.0)
const DIM := Color(0.55, 0.52, 0.66)
const GOLD := Color(1.0, 0.8, 0.25)
const GREEN := Color(0.35, 0.9, 0.45)
const RED := Color(1.0, 0.3, 0.3)

var font: Font
var player: Node          # frozen while we are down here
var alarms: Callable      # () -> Array of {sev, text, kind, key, ns}: the HUD's alarms
var code := SecretCode.new()

var _view: Control
var _prompt: Label        # on the surface: "> STA_" while START is typed
var _state := ""          # descend, hub, play, over
var _t := 0.0
var _sel := 0
var _best := {}
var _game: ArcadeGame
var _new_best := false
var _over_title := ""
var _over_why := ""
var _rng := RandomNumberGenerator.new()
var _rocks: Array = []    # stalactites / stalagmites [x, width, height, top]
var _shrooms: Array = []  # glowing mushrooms [x, y, hue]
var _pops: Array = []     # floating texts {text, pos, t, color}
var _alarm_i := 0         # which alarm the bar shows (they take turns)


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
	_game = null
	if player:
		player.set("frozen", false)
	Sfx.play("door")
	closed.emit()


func start_game(id: String) -> void:
	var g: ArcadeGame
	match id:
		"whack": g = ArcadeWhack.new()
		"snake": g = ArcadeSnake.new()
		"rally": g = ArcadeRally.new()
		"laser": g = ArcadeLaser.new()
		_:
			Sfx.play("error")
			pop(tr("OUT OF ORDER"), Vector2(CAB_X0 + _sel * CAB_STEP + CAB_W / 2, 50), DIM)
			return
	g.ug = self
	g.start()
	_game = g
	_new_best = false
	_pops.clear()
	_state = "play"
	_t = 0.0
	Sfx.play("coin")


## For the minigames: the round is over.
func game_over(title: String, why: String) -> void:
	_state = "over"
	_t = 0.0
	_over_title = title
	_over_why = why
	var id: String = GAMES[_sel].id
	var score := _game.score
	if score > int(_best.get(id, 0)):
		_best[id] = score
		_new_best = true
		var cfg := ConfigFile.new()
		cfg.load(SAVE)
		cfg.set_value("best", id, score)
		cfg.save(SAVE)
		Sfx.play("jingle")
	else:
		Sfx.play("pod_death")


func pop(text: String, at: Vector2, color: Color) -> void:
	_pops.append({"text": text, "pos": at, "t": 0.0, "color": color})


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
		"play":
			_game.t += delta
			_game.tick(delta)
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
		"play":
			if k == KEY_ESCAPE:
				_state = "hub"
				_game = null
			else:
				_game.key(k)
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
	# The system bar: the way up, and the alarm on show.
	if p.y < 0:
		if _surface_rect().has_point(p):
			close()
		elif _alarm_rect().has_point(p):
			var list := _alarms()
			if not list.is_empty():
				var a: Dictionary = list[_alarm_i % list.size()]
				close()
				alarm_clicked.emit(a)
		return
	match _state:
		"hub":
			for i in GAMES.size():
				if Rect2(CAB_X0 + i * CAB_STEP, CAB_Y, CAB_W, 92).has_point(p):
					if i == _sel:
						start_game(GAMES[i].id)
					else:
						_sel = i
						Sfx.play("click")
		"play":
			_game.click(p)
		"over":
			if _t > 0.5:
				start_game(GAMES[_sel].id)


func _alarms() -> Array:
	return alarms.call() if alarms.is_valid() else []


# --- drawing -----------------------------------------------------------------

## Pixels per virtual pixel: the screen plus the bar fit the window.
func _scale() -> float:
	var s := _view.size
	return maxf(1.0, floorf(minf(s.x / W, s.y / (H + BAR)) * 2.0) / 2.0)


## Screen position of the virtual (0, 0): the top-left of the game screen.
func _origin() -> Vector2:
	var k := _scale()
	return ((_view.size - Vector2(W, H + BAR) * k) / 2.0 + Vector2(0, BAR * k)).floor()


func _to_virtual(p: Vector2) -> Vector2:
	return (p - _origin()) / _scale()


func _surface_rect() -> Rect2:
	return Rect2(0, -BAR, 74, BAR)


func _alarm_rect() -> Rect2:
	return Rect2(78, -BAR, W - 78, BAR)


func _paint() -> void:
	var v := _view
	v.draw_rect(Rect2(Vector2.ZERO, v.size), Color.BLACK)
	v.draw_set_transform(_origin(), 0.0, Vector2.ONE * _scale())
	v.draw_rect(Rect2(0, 0, W, H), BG)
	match _state:
		"descend": _paint_descend()
		"hub": _paint_hub()
		"play": _game.paint(v)
		"over":
			_game.paint(v)
			_paint_over()
	if _state == "play" and _game.help() != "":
		text(_game.help(), Vector2(160, 177), 6, DIM, true)
	for p in _pops:
		text(p.text, p.pos, 8, Color(p.color, 1.0 - p.t), true)
	# CRT scanlines
	for y in range(0, H, 2):
		v.draw_rect(Rect2(0, y, W, 1), Color(0, 0, 0, 0.18))
	# Whatever a game drew off the screen goes under the black.
	v.draw_rect(Rect2(-W, -H, W * 3, H - BAR), Color.BLACK)
	v.draw_rect(Rect2(-W, H, W * 3, H), Color.BLACK)
	v.draw_rect(Rect2(-W, -BAR, W, H + BAR), Color.BLACK)
	v.draw_rect(Rect2(W, -BAR, W, H + BAR), Color.BLACK)
	_paint_system_bar()
	v.draw_set_transform(Vector2.ZERO)


## Always on top: the way back up and the cluster's alarms.
func _paint_system_bar() -> void:
	var v := _view
	v.draw_rect(Rect2(0, -BAR, W, BAR), Color(0.02, 0.02, 0.04))
	var sr := _surface_rect()
	var hover := sr.has_point(_to_virtual(v.get_local_mouse_position()))
	v.draw_rect(sr.grow(-1), Color(0.3, 0.28, 0.42) if hover else Color(0.18, 0.16, 0.26))
	text("^ " + tr("SURFACE") + " (ESC)", Vector2(sr.get_center().x, -3), 6, TEXT, true)
	var list := _alarms()
	var ar := _alarm_rect()
	if list.is_empty():
		v.draw_rect(Rect2(ar.position.x + 2, -8, 4, 4), GREEN)
		text(tr("cluster OK: no alarms"), Vector2(ar.position.x + 10, -3), 6, GREEN)
		return
	var bad := list.filter(func(a): return int(a.sev) >= 3).size()
	_alarm_i = int(Time.get_ticks_msec() / 3000.0)
	var a: Dictionary = list[_alarm_i % list.size()]
	var c := RED if int(a.sev) >= 3 else GOLD
	var blink := bad > 0 and fmod(Time.get_ticks_msec() / 1000.0, 1.0) < 0.5
	v.draw_rect(Rect2(ar.position.x + 1, -BAR + 1, 50, BAR - 2), Color(c, 0.35 if blink else 0.2))
	text(tr("ALARMS %d") % list.size(), Vector2(ar.position.x + 26, -3), 6, c, true)
	var msg := str(a.text)
	if msg.length() > 46:
		msg = msg.substr(0, 43) + "..."
	text(msg, Vector2(ar.position.x + 56, -3), 6, TEXT)


## Text at the screen's resolution (a pixel font scaled below its size turns
## to mush), at a virtual position.
func text(s: String, at: Vector2, size: int, color: Color, center := false) -> void:
	if font == null:
		font = ThemeDB.fallback_font
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


func text_width(s: String, size: int) -> float:
	if font == null:
		font = ThemeDB.fallback_font
	return font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, int(size * _scale())).x / _scale()


## A game's top bar: its name, the score and something on the right.
func paint_bar(title: String, right: String) -> void:
	_view.draw_rect(Rect2(0, 0, W, 14), Color(0, 0, 0, 0.55))
	text(title, Vector2(6, 10), 8, TEXT)
	text("%s  %d" % [tr("SCORE"), _game.score if _game else 0], Vector2(160, 10), 8, GOLD, true)
	text(right, Vector2(W - 6 - text_width(right, 8), 10), 8, DIM)


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
	text("-%d m" % int(k * 1337), Vector2(160, cy + 30), 8, GOLD, true)
	text(tr("going down..."), Vector2(160, 150), 8, DIM, true)


func paint_cave() -> void:
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
	paint_cave()
	# Title with a colour-cycling shadow.
	text("KUBIVERSE:", Vector2(160, 16), 8, DIM, true)
	var hue := fmod(_t * 0.15, 1.0)
	text("UNDERGROUND", Vector2(161, 35), 16, Color.from_hsv(hue, 0.8, 0.9), true)
	text("UNDERGROUND", Vector2(160, 34), 16, TEXT, true)
	for i in GAMES.size():
		var g: Dictionary = GAMES[i]
		var sel := i == _sel
		var x := CAB_X0 + i * CAB_STEP
		var y := CAB_Y - (2.0 + sin(_t * 6.0) * 1.5 if sel else 0.0)
		var gc: Color = g.color
		if sel:
			v.draw_rect(Rect2(x - 3, y - 3, CAB_W + 6, 98), Color(gc, 0.25 + 0.15 * sin(_t * 5.0)))
		# Cabinet: marquee, screen, panel, base.
		v.draw_rect(Rect2(x, y, CAB_W, 92), Color(0.16, 0.14, 0.22))
		v.draw_rect(Rect2(x + 2, y + 2, CAB_W - 4, 12), gc.darkened(0.2))
		var title: String = g.title
		text(title, Vector2(x + CAB_W / 2, y + 11), 6 if title.length() > 4 else 8, TEXT, true)
		v.draw_rect(Rect2(x + 4, y + 18, CAB_W - 8, 34), Color(0.02, 0.02, 0.04))
		_paint_attract(g.id, Rect2(x + 5, y + 19, CAB_W - 10, 32))
		v.draw_rect(Rect2(x + 3, y + 56, CAB_W - 6, 12), Color(0.24, 0.22, 0.3))
		v.draw_circle(Vector2(x + 12, y + 62), 3, Color(0.9, 0.2, 0.2))
		v.draw_circle(Vector2(x + 28, y + 62), 2.5, GOLD)
		v.draw_circle(Vector2(x + 38, y + 62), 2.5, Color(0.3, 0.6, 1.0))
		v.draw_rect(Rect2(x + 6, y + 70, CAB_W - 12, 22), Color(0.12, 0.1, 0.17))
		var best := int(_best.get(g.id, 0))
		if g.id != "soon":
			text("HI %d" % best, Vector2(x + CAB_W / 2, y + 84), 6, GOLD if best > 0 else DIM, true)
	var g2: Dictionary = GAMES[_sel]
	var lines: PackedStringArray = tr(g2.blurb).split("\n")
	for j in lines.size():
		text(lines[j], Vector2(160, 162 + j * 8), 6, TEXT, true)
	text("< >  ENTER", Vector2(W - 6 - 40, 176), 6, DIM)


## What each cabinet's screen shows while nobody plays it.
func _paint_attract(id: String, r: Rect2) -> void:
	var v := _view
	match id:
		"whack":
			for i in 3:
				var up := sin(_t * 3.0 + i * 2.1) > 0.3
				var c := Vector2(r.position.x + 7 + i * 14, r.position.y + 24)
				v.draw_rect(Rect2(c.x - 5, c.y, 10, 3), Color(0.1, 0.08, 0.1))
				if up:
					v.draw_rect(Rect2(c.x - 4, c.y - 8, 8, 8), RED if i != 1 else GREEN)
		"snake":
			for i in 8:
				var a := _t * 2.0 - i * 0.35
				var p := r.get_center() + Vector2(cos(a) * 13, sin(a * 2.0) * 8)
				v.draw_rect(Rect2(p.floor(), Vector2(3, 3)), Color(0.6, 0.42, 1.0).lightened(0.3 if i == 0 else 0.0))
		"rally":
			v.draw_rect(Rect2(r.position.x + 10, r.position.y, r.size.x - 20, r.size.y), Color(0.13, 0.12, 0.16))
			for i in 4:
				var y := r.position.y + fmod(i * 10.0 + _t * 40.0, r.size.y)
				v.draw_rect(Rect2(r.get_center().x, y, 1, 5), Color(1, 1, 1, 0.3))
			var cx := r.get_center().x + sin(_t * 2.0) * 7.0
			v.draw_rect(Rect2(cx - 3, r.end.y - 11, 6, 9), Color(0.3, 0.95, 1.0))
			var oy := r.position.y + fmod(_t * 25.0, r.size.y)
			v.draw_rect(Rect2(r.get_center().x + 5, oy, 6, 9), RED)
		"laser":
			var a := r.position + Vector2(6, r.size.y / 2)
			var b := r.end - Vector2(8, r.size.y / 2 + sin(_t * 3.0) * 8.0)
			v.draw_rect(Rect2(a - Vector2(2, 2), Vector2(4, 4)), Color(0.3, 0.95, 1.0))
			v.draw_rect(Rect2(b - Vector2(2, 2), Vector2(4, 4)), RED)
			if fmod(_t, 1.0) < 0.15:
				v.draw_line(a, b, Color(0.3, 0.95, 1.0), 1.0)
		_:
			if fmod(_t, 1.2) < 0.9:
				text("???", r.get_center() + Vector2(0, 3), 8, DIM, true)
			for i in 10:
				v.draw_rect(Rect2(r.position.x + _rng.randf() * r.size.x, r.position.y + _rng.randf() * r.size.y, 1, 1), Color(1, 1, 1, 0.3))


func _paint_over() -> void:
	var v := _view
	v.draw_rect(Rect2(0, 0, W, H), Color(0, 0, 0, 0.6))
	v.draw_rect(Rect2(60, 50, 200, 80), Color(0.08, 0.06, 0.12))
	v.draw_rect(Rect2(60, 50, 200, 2), RED)
	text(_over_title, Vector2(160, 70), 16, Color(0.95, 0.35, 0.35), true)
	text(_over_why, Vector2(160, 84), 6, DIM, true)
	text("%s %d" % [tr("SCORE"), _game.score], Vector2(160, 100), 8, TEXT, true)
	if _new_best and fmod(_t, 0.5) < 0.35:
		text(tr("NEW HIGH SCORE!"), Vector2(160, 112), 8, GOLD, true)
	elif not _new_best:
		text("HI %d" % int(_best.get(GAMES[_sel].id, 0)), Vector2(160, 112), 8, GOLD, true)
	text(tr("ENTER: again   ESC: arcade"), Vector2(160, 125), 6, DIM, true)
