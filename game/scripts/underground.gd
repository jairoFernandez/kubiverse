class_name Underground
extends CanvasLayer
## KUBIVERSE: UNDERGROUND, the hidden arcade under the cluster (↑ ↑ ↓ ↓ ← →
## and type START). The way down is a short elevator ride drawn here; down
## there is a 3D room (the World level "arcade", see ArcadeHall) with a
## cabinet per minigame (scripts/arcade). Walking up to one and pressing E
## brings its screen to the front: a pixel screen of 320×180 in the
## cabinet's frame, scaled to the window; ESC goes back to the room. Nothing
## here touches the cluster, but its alarms stay in sight on the bar at the
## top.

signal entered             # the ride down started: build the room under it
signal left_machine        # back from a cabinet's screen to the room
signal alarm_clicked(alarm: Dictionary)   # go up and look at it

const W := 320
const H := 180
const BAR := 12            # the system bar above the cabinet (virtual px)
const SIDE := 10           # the cabinet's sides around the screen
const MARQUEE := 18        # its lit title above the screen
const PANEL := 16          # its control panel below
const ZOOM_T := 0.35       # seconds the screen takes to come to the front
const DESCEND_T := 2.2
const GAMES := ArcadeHall.GAMES
const PLAYABLE := ArcadeHall.PLAYABLE
const BG := Color(0.04, 0.035, 0.07)
const ROCK := Color(0.12, 0.1, 0.16)
const ROCK_HI := Color(0.2, 0.16, 0.26)
const TEXT := Color(0.92, 0.9, 1.0)
const DIM := Color(0.55, 0.52, 0.66)
const GOLD := Color(1.0, 0.8, 0.25)
const GREEN := Color(0.35, 0.9, 0.45)
const RED := Color(1.0, 0.3, 0.3)

var font: Font
var player: Node          # frozen while a screen is in front
var alarms: Callable      # () -> Array of {sev, text, kind, key, ns}: the HUD's alarms
var in_room := false      # set by main: down here the code does nothing
var code := SecretCode.new()

var _view: Control
var _prompt: Label        # on the surface: "> STA_" while START is typed
var _state := ""          # "", descend, zoom, play, over
var _t := 0.0
var _id := ""             # the cabinet being played
var _from := Rect2()      # its screen on the window, where the zoom starts
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
	ArcadeHall.load_best()


## A screen is in front (or the ride down is playing): it takes the input.
func is_open() -> bool:
	return _view.visible


func state() -> String:
	return _state


func playing_id() -> String:
	return _id


## The code was typed: the ride down (or straight to the room). `entered`
## tells main to build the room under it.
func go_down(animate := true) -> void:
	if font:
		_prompt.add_theme_font_override("font", font)
	_prompt.visible = false
	_pops.clear()
	if animate:
		_view.visible = true
		_state = "descend"
		_t = 0.0
		if player:
			player.set("frozen", true)
		Sfx.play("fall")
	elif player:
		player.set("frozen", false)
	entered.emit()


## Walked up to cabinet `id` and pressed E: its screen comes to the front,
## growing from `from` (where it is on the window; empty: no zoom). False if
## that cabinet can't be played.
func play(id: String, from := Rect2()) -> bool:
	if not id in PLAYABLE:
		Sfx.play("error")
		return false
	if font:
		_prompt.add_theme_font_override("font", font)
	_id = id
	_from = from
	_view.visible = true
	if player:
		player.set("frozen", true)
	start_game(id)
	if from.has_area():
		_state = "zoom"
	return true


## Back from the screen to the room.
func leave() -> void:
	if not _view.visible:
		return
	_view.visible = false
	_state = ""
	_game = null
	_id = ""
	if player:
		player.set("frozen", false)
	Sfx.play("door")
	left_machine.emit()


func start_game(id: String) -> void:
	var g: ArcadeGame
	match id:
		"whack": g = ArcadeWhack.new()
		"snake": g = ArcadeSnake.new()
		"rally": g = ArcadeRally.new()
		"laser": g = ArcadeLaser.new()
		_:
			Sfx.play("error")
			return
	_id = id
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
	if ArcadeHall.record(_id, _game.score):
		_new_best = true
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
	tick(delta)
	_view.queue_redraw()


## One step of time (the tests call it without a window).
func tick(delta: float) -> void:
	_t += delta
	match _state:
		"descend":
			if _t > DESCEND_T:
				_view.visible = false
				_state = ""
				if player:
					player.set("frozen", false)
				Sfx.play("jingle")
		"zoom":
			if _t > ZOOM_T:
				_state = "play"
				_t = 0.0
		"play":
			_game.t += delta
			_game.tick(delta)
	for p in _pops:
		p.t += delta
		p.pos.y -= delta * 18.0
	_pops = _pops.filter(func(p): return p.t < 1.0)


# --- input -------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if not _view.visible:
		_listen(event)
		return
	get_viewport().set_input_as_handled()
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_click(_to_virtual(_view.get_local_mouse_position()))
		return
	if event is InputEventKey and event.pressed and not event.echo:
		key(event.keycode)


## A key while a screen is in front.
func key(k: int) -> void:
	match _state:
		"descend":
			if k in [KEY_ENTER, KEY_SPACE, KEY_ESCAPE]:
				_t = 99.0
		"zoom":
			if k == KEY_ESCAPE:
				leave()
		"play":
			if k == KEY_ESCAPE:
				leave()
			else:
				_game.key(k)
		"over":
			if k in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE] and _t > 0.5:
				start_game(_id)
			elif k == KEY_ESCAPE:
				leave()


## On the surface: watch for the code (not while typing in a text field,
## and not down in the room).
func _listen(event: InputEvent) -> void:
	if in_room or not (event is InputEventKey and event.pressed and not event.echo):
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
		go_down()
	elif was_armed and not code.armed():
		Sfx.play("miss")
	elif code.armed():
		Sfx.play("key")


func _click(p: Vector2) -> void:
	if _state == "descend":
		_t = 99.0
		return
	# The system bar: the way back to the room, and the alarm on show.
	if p.y < -MARQUEE:
		if _back_rect().has_point(p):
			leave()
		elif _alarm_rect().has_point(p):
			var list := _alarms()
			if not list.is_empty():
				var a: Dictionary = list[_alarm_i % list.size()]
				leave()
				alarm_clicked.emit(a)
		return
	match _state:
		"play":
			_game.click(p)
		"over":
			if _t > 0.5:
				start_game(_id)


func _alarms() -> Array:
	# The first ones (the worst): the HUD only writes the text of those.
	return (alarms.call() as Array).slice(0, 20) if alarms.is_valid() else []


# --- drawing -----------------------------------------------------------------

## Virtual size of what is drawn: the bare screen while going down, the
## cabinet (and the bar above it) when playing.
func _extent() -> Vector2:
	if _state == "descend":
		return Vector2(W, H)
	return Vector2(W + SIDE * 2, BAR + MARQUEE + H + PANEL)


## Pixels per virtual pixel: everything fits the window.
func _scale() -> float:
	var s := _view.size
	var e := _extent()
	return maxf(1.0, floorf(minf(s.x / e.x, s.y / e.y) * 2.0) / 2.0)


## Screen position of the virtual (0, 0): the top-left of the game screen.
func _origin() -> Vector2:
	var k := _scale()
	var off := Vector2.ZERO if _state == "descend" else Vector2(SIDE, BAR + MARQUEE)
	return ((_view.size - _extent() * k) / 2.0 + off * k).floor()


func _to_virtual(p: Vector2) -> Vector2:
	return (p - _origin()) / _scale()


## The whole cabinet, in virtual pixels.
func _cabinet_rect() -> Rect2:
	return Rect2(-SIDE, -MARQUEE, W + SIDE * 2, MARQUEE + H + PANEL)


func _back_rect() -> Rect2:
	return Rect2(0, -MARQUEE - BAR, 74, BAR)


func _alarm_rect() -> Rect2:
	return Rect2(78, -MARQUEE - BAR, W - 78, BAR)


func _color() -> Color:
	var g := ArcadeHall.game(_id)
	return g.color if not g.is_empty() else DIM


func _paint() -> void:
	var v := _view
	if _state == "zoom":
		_paint_zoom()
		return
	v.draw_rect(Rect2(Vector2.ZERO, v.size), Color.BLACK)
	v.draw_set_transform(_origin(), 0.0, Vector2.ONE * _scale())
	v.draw_rect(Rect2(0, 0, W, H), BG)
	match _state:
		"descend": _paint_descend()
		"play": _game.paint(v)
		"over":
			_game.paint(v)
			_paint_over()
	for p in _pops:
		text(p.text, p.pos, 8, Color(p.color, 1.0 - p.t), true)
	# CRT scanlines
	for y in range(0, H, 2):
		v.draw_rect(Rect2(0, y, W, 1), Color(0, 0, 0, 0.18))
	if _state == "descend":
		_mask(Rect2(0, 0, W, H))
	else:
		_paint_cabinet()
		_paint_system_bar()
	v.draw_set_transform(Vector2.ZERO)


## Whatever a game drew outside `keep` goes under the black.
func _mask(keep: Rect2) -> void:
	var v := _view
	var big := 2000.0
	v.draw_rect(Rect2(keep.position.x - big, keep.position.y - big, big * 2 + keep.size.x, big), Color.BLACK)
	v.draw_rect(Rect2(keep.position.x - big, keep.end.y, big * 2 + keep.size.x, big), Color.BLACK)
	v.draw_rect(Rect2(keep.position.x - big, keep.position.y, big, keep.size.y), Color.BLACK)
	v.draw_rect(Rect2(keep.end.x, keep.position.y, big, keep.size.y), Color.BLACK)


## The frame around the screen: the cabinet you walked up to.
func _paint_cabinet() -> void:
	var v := _view
	var c := _color()
	var cab := _cabinet_rect()
	_mask(cab)
	var body := Color("221a30")
	var side := c.darkened(0.45)
	v.draw_rect(Rect2(cab.position, Vector2(SIDE, cab.size.y)), side)
	v.draw_rect(Rect2(W, cab.position.y, SIDE, cab.size.y), side)
	for x in [-SIDE + 3, W + SIDE - 4]:
		v.draw_rect(Rect2(x, cab.position.y + 4, 1, cab.size.y - 8), Color(c.lightened(0.3), 0.8))
	# Marquee: the game's name, lit.
	var glow := 0.85 + 0.15 * sin(Time.get_ticks_msec() / 300.0)
	v.draw_rect(Rect2(0, -MARQUEE, W, MARQUEE), c.darkened(0.15) * glow)
	v.draw_rect(Rect2(0, -MARQUEE, W, 1), c.lightened(0.4))
	var g := ArcadeHall.game(_id)
	text(str(g.get("title", "")), Vector2(W / 2.0, -5), 12, TEXT, true)
	# Bezel and control panel.
	v.draw_rect(Rect2(-1, -1, W + 2, 1), body)
	v.draw_rect(Rect2(-1, H, W + 2, 1), body)
	v.draw_rect(Rect2(0, H, W, PANEL), Color("2e2840"))
	v.draw_rect(Rect2(0, H, W, 1), Color("3d3555"))
	v.draw_circle(Vector2(14, H + 8), 4, Color(0.9, 0.2, 0.2))
	v.draw_circle(Vector2(W - 34, H + 8), 3, GOLD)
	v.draw_circle(Vector2(W - 24, H + 8), 3, Color(0.3, 0.6, 1.0))
	v.draw_circle(Vector2(W - 14, H + 8), 3, GREEN)
	var help := _game.help() if _game and _state == "play" else ""
	if help != "":
		text(help, Vector2(W / 2.0, H + 11), 6, DIM, true)


## The screen comes to the front: from where it stood in the room to the
## middle of the window.
func _paint_zoom() -> void:
	var v := _view
	var k := ease(clampf(_t / ZOOM_T, 0.0, 1.0), 0.4)
	var s := _scale()
	var to := Rect2(_origin() + _cabinet_rect().position * s, _cabinet_rect().size * s)
	var r := Rect2(_from.position.lerp(to.position, k), _from.size.lerp(to.size, k))
	v.draw_rect(Rect2(Vector2.ZERO, v.size), Color(0, 0, 0, k))
	var c := _color()
	v.draw_rect(r, c.darkened(0.45))
	var inner := Rect2(r.position + Vector2(SIDE, MARQUEE) / _cabinet_rect().size * r.size, Vector2(W, H) / _cabinet_rect().size * r.size)
	v.draw_rect(inner, BG.lerp(c, 0.25 * (1.0 - k)))
	v.draw_rect(Rect2(r.position, Vector2(r.size.x, inner.position.y - r.position.y)), c.darkened(0.15))


## Always on top: the way back to the room and the cluster's alarms.
func _paint_system_bar() -> void:
	var v := _view
	var y := -MARQUEE - 3
	v.draw_rect(Rect2(0, -MARQUEE - BAR, W, BAR), Color(0.02, 0.02, 0.04))
	var br := _back_rect()
	var hover := br.has_point(_to_virtual(v.get_local_mouse_position()))
	v.draw_rect(br.grow(-1), Color(0.3, 0.28, 0.42) if hover else Color(0.18, 0.16, 0.26))
	text("< " + tr("ARCADE") + " (ESC)", Vector2(br.get_center().x, y), 6, TEXT, true)
	var list := _alarms()
	var ar := _alarm_rect()
	if list.is_empty():
		v.draw_rect(Rect2(ar.position.x + 2, y - 5, 4, 4), GREEN)
		text(tr("cluster OK: no alarms"), Vector2(ar.position.x + 10, y), 6, GREEN)
		return
	var bad := int(list[0].sev) >= 3
	_alarm_i = int(Time.get_ticks_msec() / 3000.0)
	var a: Dictionary = list[_alarm_i % list.size()]
	var c := RED if int(a.sev) >= 3 else GOLD
	var blink := bad and fmod(Time.get_ticks_msec() / 1000.0, 1.0) < 0.5
	v.draw_rect(Rect2(ar.position.x + 1, ar.position.y + 1, 50, BAR - 2), Color(c, 0.35 if blink else 0.2))
	text(tr("ALARMS %d") % (alarms.call() as Array).size(), Vector2(ar.position.x + 26, y), 6, c, true)
	var msg := str(a.text)
	if msg.length() > 46:
		msg = msg.substr(0, 43) + "..."
	text(msg, Vector2(ar.position.x + 56, y), 6, TEXT)


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
	var k := minf(_t / DESCEND_T, 1.0)
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
		text("HI %d" % int(ArcadeHall.best.get(_id, 0)), Vector2(160, 112), 8, GOLD, true)
	text(tr("ENTER: again   ESC: arcade"), Vector2(160, 125), 6, DIM, true)
