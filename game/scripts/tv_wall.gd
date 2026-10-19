class_name TVWall
extends PanelContainer
## The CONTROL ROOM: a wall of small CRT monitors, one per saved cluster,
## each showing how that cluster is doing. Green is calm, amber needs a look,
## red flashes when it is in alarm, snow when it doesn't answer. Click a
## screen to go to that cluster.

signal picked(feed: Dictionary)
signal closed
signal watch_changed

var room: ControlRoom
var _grid: GridContainer
var _empty: Label
var _ack: Button
var _bg: CheckBox
var _tiles := {}   # feed key -> Monitor


## One TV on the wall. Everything is drawn: bezel, screen, scanlines, snow.
class Monitor extends Control:
	signal clicked

	const BG := {"ok": Color("0b2a12"), "warn": Color("33260a"), "alarm": Color("3a0808"), "wait": Color("0a1630"), "off": Color("101010")}
	const FG := {"ok": Color("6dff6d"), "warn": Color("ffd54a"), "alarm": Color("ff5a5a"), "wait": Color("7fb2ff"), "off": Color("c8c8c8")}

	var feed: Dictionary = {}
	var live := false
	var _flash := 0.0
	var _redraw_t := 0.0

	func _init() -> void:
		custom_minimum_size = Vector2(300, 196)
		mouse_filter = Control.MOUSE_FILTER_STOP
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _gui_input(e: InputEvent) -> void:
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			clicked.emit()
			accept_event()

	func _process(delta: float) -> void:
		_flash += delta
		_redraw_t -= delta
		# Only on screen, and at ~20 fps: hidden TVs asking to be redrawn
		# every frame kept the frame from ever being drawn (frame_post_draw
		# never came, the --shot captures hung).
		if _redraw_t > 0.0 or not is_visible_in_tree():
			return
		_redraw_t = 0.05
		var lv: String = feed.get("level", "wait")
		if lv in ["alarm", "off", "wait"]:
			queue_redraw()   # flashing, snow, tuning

	## What the screen says under the name.
	static func status_text(f: Dictionary) -> String:
		match str(f.get("level", "wait")):
			"ok": return "OK"
			"warn": return "WARN"
			"alarm": return "ALARM" + ("  (ack)" if f.get("acked", false) else "")
			"off": return TranslationServer.translate("NO SIGNAL")
		return TranslationServer.translate("TUNING...")

	static func lines(f: Dictionary) -> Array:
		var s: Dictionary = f.get("sum", {})
		if s.is_empty():
			return [str(f.get("err", ""))] if str(f.get("err", "")) != "" else []
		var out := [TranslationServer.translate("nodes %d/%d   pods %d") % [int(s.nodes) - int(s.nodes_down), int(s.nodes), int(s.pods)],
			TranslationServer.translate("bad %d   waiting %d   alerts %d") % [int(s.pods_bad), int(s.pods_waiting), int(s.alerts_critical) + int(s.alerts_warning)]]
		for w in s.get("worst", []).slice(0, 3):
			out.append("> " + str(w))
		return out

	func _draw() -> void:
		var lv: String = feed.get("level", "wait")
		var ring: bool = ControlRoom.rings(lv) and not feed.get("acked", false)
		var on: bool = ring and fmod(_flash, 0.8) < 0.4
		var font := get_theme_default_font()
		# Cabinet and bezel: the bezel glows red while it rings.
		draw_rect(Rect2(Vector2.ZERO, size), Color("2a2a2e"))
		draw_rect(Rect2(Vector2(3, 3), size - Vector2(6, 6)), Color("ff3030") if on else Color("161618"), false, 3.0)
		var sr := Rect2(Vector2(12, 12), size - Vector2(24, 34))
		var bg: Color = BG.get(lv, BG.wait)
		draw_rect(sr, bg.lightened(0.25) if on else bg)
		if lv in ["off", "wait"]:
			# Snow: a different handful of grey specks every frame.
			var n := 260 if lv == "off" else 60
			for i in n:
				var p := sr.position + Vector2(randf() * sr.size.x, randf() * sr.size.y)
				var g := randf()
				draw_rect(Rect2(p, Vector2(3, 2)), Color(g, g, g, 0.55))
		var fg: Color = FG.get(lv, FG.wait)
		var x := sr.position.x + 10
		draw_string(font, Vector2(x, sr.position.y + 26), str(feed.get("name", "?")), HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 20, 20, Color.WHITE)
		draw_string(font, Vector2(x, sr.position.y + 50), status_text(feed), HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 20, 22, fg)
		var y := sr.position.y + 72
		for l in lines(feed):
			draw_string(font, Vector2(x, y), l, HORIZONTAL_ALIGNMENT_LEFT, sr.size.x - 20, 14, fg.lerp(Color.WHITE, 0.3))
			y += 17
		# Scanlines over the picture.
		var sy := sr.position.y
		while sy < sr.end.y:
			draw_line(Vector2(sr.position.x, sy), Vector2(sr.end.x, sy), Color(0, 0, 0, 0.22))
			sy += 3.0
		# Under the screen: the power LED and ON AIR for the cluster being played.
		draw_circle(Vector2(size.x - 20, size.y - 11), 4.0, fg)
		if live:
			draw_string(font, Vector2(14, size.y - 6), TranslationServer.translate("ON AIR"), HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color("ff6a6a"))


func _init() -> void:
	visible = false
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 8)
	v.add_child(top)
	var title := Label.new()
	title.text = "CONTROL ROOM"
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", Vox.LAVENDER)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(title)
	_ack = Button.new()
	_ack.text = "SILENCE"
	_ack.tooltip_text = tr("Acknowledge the alarms: no siren until a cluster goes bad again")
	_ack.focus_mode = Control.FOCUS_NONE
	_ack.theme_type_variation = "DangerButton"
	top.add_child(_ack)
	_bg = CheckBox.new()
	_bg.text = tr("Keep watching when closed")
	_bg.tooltip_text = tr("Check every saved cluster in the background and sound the alarm")
	_bg.focus_mode = Control.FOCUS_NONE
	top.add_child(_bg)
	var x := Button.new()
	x.text = "X"
	x.focus_mode = Control.FOCUS_NONE
	x.pressed.connect(func(): closed.emit())
	top.add_child(x)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 430)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(scroll)
	_grid = GridContainer.new()
	_grid.columns = 3
	_grid.add_theme_constant_override("h_separation", 10)
	_grid.add_theme_constant_override("v_separation", 10)
	_grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_grid)
	_empty = Label.new()
	_empty.text = tr("No saved clusters yet. Save them in the connect screen (CONNECT + SAVE) and they show up here, one TV each.")
	_empty.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_empty.custom_minimum_size = Vector2(600, 0)
	v.add_child(_empty)
	var hint := Label.new()
	hint.text = tr("Click a screen to go to that cluster. [I] opens and closes this room.")
	hint.add_theme_color_override("font_color", Vox.SILVER)
	v.add_child(hint)


func setup(r: ControlRoom) -> void:
	room = r
	room.changed.connect(refresh)
	_ack.pressed.connect(room.acknowledge)
	_bg.button_pressed = Settings.watch_clusters
	_bg.toggled.connect(func(on: bool):
		Settings.watch_clusters = on
		Settings.save()
		watch_changed.emit())
	resized.connect(_fit_columns)


func _fit_columns() -> void:
	_grid.columns = maxi(1, int((size.x - 20) / 310.0))


func refresh() -> void:
	if room == null:
		return
	var seen := {}
	for f in room.feeds:
		seen[f.key] = true
		var m: Monitor = _tiles.get(f.key)
		if m == null:
			m = Monitor.new()
			m.clicked.connect(func(): picked.emit(m.feed))
			_grid.add_child(m)
			_tiles[f.key] = m
		m.feed = f
		m.live = room.is_live(f)
		m.queue_redraw()
	for k in _tiles.keys():
		if not seen.has(k):
			_tiles[k].queue_free()
			_tiles.erase(k)
	# Same order as the saved list.
	var i := 0
	for f in room.feeds:
		_grid.move_child(_tiles[f.key], i)
		i += 1
	_empty.visible = room.feeds.is_empty()
	_ack.disabled = room.ringing().is_empty()


func tile_count() -> int:
	return _tiles.size()
