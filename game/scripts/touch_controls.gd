class_name TouchControls
extends Control
## On-screen controls for phones and tablets (multi-touch):
##  - floating joystick: touch anywhere in the lower-left area and drag
##    (push to the edge to run)
##  - buttons on the right: JUMP (hold it to climb with the jetpack), USE,
##    JET, DOWN (while flying) and FIRE (in chaos mode)
## Taps and drags elsewhere go to the game: tap = inspect / walk there,
## drag = pan, pinch = zoom, two-finger twist = rotate (see main.gd).

signal action(id: String)

var font: Font
var stick := Vector2.ZERO         # -1..1, screen space (y down)
var jump_held := false
var down_held := false
var show_fire := false
var flying := false
var blockers: Callable            # -> Array[Rect2] of visible panels (touches there are the UI's)

var _stick_index := -1
var _stick_center := Vector2.ZERO
var _stick_pos := Vector2.ZERO
var _held := {}                   # touch index -> button id
const STICK_R := 70.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _k() -> float:
	return clampf(minf(size.x, size.y) / 430.0, 0.85, 1.5)


## [id, label, center, radius]
func _buttons() -> Array:
	var k := _k()
	var br := size - Vector2(20, 20) * k
	var out := [
		["jump", tr("JUMP") if not flying else tr("UP"), br + Vector2(-62, -62) * k, 56.0 * k],
		["use", tr("USE"), br + Vector2(-178, -40) * k, 42.0 * k],
		["jet", "JET", br + Vector2(-44, -178) * k, 34.0 * k],
	]
	if flying:
		out.append(["down", tr("DOWN"), br + Vector2(-150, -150) * k, 38.0 * k])
	elif show_fire:
		out.append(["fire", tr("FIRE"), br + Vector2(-150, -150) * k, 40.0 * k])
	return out


func _button_at(p: Vector2) -> String:
	for b in _buttons():
		if p.distance_to(b[2]) <= b[3] * 1.15:
			return b[0]
	return ""


func _in_stick_zone(p: Vector2) -> bool:
	return p.x < size.x * 0.45 and p.y > size.y * 0.45


func _on_ui(p: Vector2) -> bool:
	if blockers.is_valid():
		for r in blockers.call():
			if r.has_point(p):
				return true
	return false


## True if a mouse event at p (emulated from a touch) belongs to the controls.
func owns(p: Vector2) -> bool:
	if not visible:
		return false
	if _stick_index != -1 or not _held.is_empty():
		return true
	return _button_at(p) != "" or (_in_stick_zone(p) and not _on_ui(p))


func _input(e: InputEvent) -> void:
	if not visible:
		return
	if e is InputEventScreenTouch:
		var p: Vector2 = e.position
		if e.pressed:
			if _on_ui(p):
				return
			var b := _button_at(p)
			if b != "":
				_held[e.index] = b
				match b:
					"jump": jump_held = true
					"down": down_held = true
				action.emit(b)
				Input.vibrate_handheld(15)
				get_viewport().set_input_as_handled()
				queue_redraw()
			elif _in_stick_zone(p) and _stick_index == -1:
				_stick_index = e.index
				_stick_center = p
				_stick_pos = p
				get_viewport().set_input_as_handled()
				queue_redraw()
		else:
			if _held.has(e.index):
				match _held[e.index]:
					"jump": jump_held = false
					"down": down_held = false
				_held.erase(e.index)
				get_viewport().set_input_as_handled()
				queue_redraw()
			if e.index == _stick_index:
				_stick_index = -1
				stick = Vector2.ZERO
				get_viewport().set_input_as_handled()
				queue_redraw()
	elif e is InputEventScreenDrag and e.index == _stick_index:
		_stick_pos = e.position
		var v: Vector2 = _stick_pos - _stick_center
		var r := STICK_R * _k()
		if v.length() > r:
			# The base follows the thumb, so you never "fall off" the stick.
			_stick_center = _stick_pos - v.normalized() * r
			v = v.normalized() * r
		stick = v / r
		get_viewport().set_input_as_handled()
		queue_redraw()


## Releases everything (e.g. when a menu opens).
func reset() -> void:
	_stick_index = -1
	_held.clear()
	stick = Vector2.ZERO
	jump_held = false
	down_held = false
	queue_redraw()


func _draw() -> void:
	var k := _k()
	var fs := int(22 * k)
	# Joystick: faint hint where to put the thumb, or the live stick.
	if _stick_index == -1:
		var hint := Vector2(size.x * 0.18, size.y * 0.8)
		draw_arc(hint, STICK_R * k, 0, TAU, 40, Color(1, 1, 1, 0.18), 3.0)
		draw_circle(hint, 26 * k, Color(1, 1, 1, 0.12))
	else:
		draw_circle(_stick_center, STICK_R * k, Color(0.05, 0.07, 0.15, 0.45))
		draw_arc(_stick_center, STICK_R * k, 0, TAU, 40, Color(Vox.BLUE, 0.7), 3.0)
		draw_circle(_stick_center + stick * STICK_R * k, 30 * k, Color(Vox.BLUE, 0.85 if stick.length() < 0.9 else 1.0))
	for b in _buttons():
		var held: bool = _held.values().has(b[0])
		var col: Color = {"jump": Vox.GREEN, "use": Vox.YELLOW, "jet": Vox.ORANGE, "fire": Vox.RED, "down": Vox.LAVENDER}.get(b[0], Vox.WHITE)
		draw_circle(b[2], b[3], Color(0.04, 0.05, 0.1, 0.6 if not held else 0.85))
		draw_arc(b[2], b[3], 0, TAU, 40, Color(col, 0.95 if held else 0.7), 4.0 if held else 3.0)
		if font:
			var tw := font.get_string_size(b[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, b[2] + Vector2(-tw * 0.5, fs * 0.35), b[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
