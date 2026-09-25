class_name DragResize
extends RefCounted
## Makes a docked panel movable (drag its title bar) and resizable (drag any
## border or corner). Double-click the title bar to dock it back. While
## `rect` is empty the panel keeps its normal (docked) layout.

var panel: Control
var rect := Rect2()             # UI units; size ZERO = docked
var min_size := Vector2(320, 150)
var _drag := ""                 # "" | move | edge
var _edge := ""
var _anchors := []              # original anchors, restored when docked
const EDGE := 12.0


func attach(p: Control, handle: Control) -> DragResize:
	panel = p
	_anchors = [p.anchor_left, p.anchor_top, p.anchor_right, p.anchor_bottom, p.grow_vertical,
		p.offset_left, p.offset_top, p.offset_right, p.offset_bottom]
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	panel.gui_input.connect(_panel_input)
	handle.mouse_filter = Control.MOUSE_FILTER_STOP
	handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	handle.tooltip_text = TranslationServer.translate("Drag to move, double-click to dock")
	handle.gui_input.connect(_handle_input)
	return self


func is_floating() -> bool:
	return rect.size != Vector2.ZERO


func dock() -> void:
	rect = Rect2()
	panel.anchor_left = _anchors[0]
	panel.anchor_top = _anchors[1]
	panel.anchor_right = _anchors[2]
	panel.anchor_bottom = _anchors[3]
	panel.grow_vertical = _anchors[4]
	panel.offset_left = _anchors[5]
	panel.offset_top = _anchors[6]
	panel.offset_right = _anchors[7]
	panel.offset_bottom = _anchors[8]


func _start() -> void:
	panel.move_to_front()  # a floating panel goes over the others
	if rect.size == Vector2.ZERO:
		rect = Rect2(panel.position, panel.size)
		panel.anchor_left = 0.0
		panel.anchor_top = 0.0
		panel.anchor_right = 0.0
		panel.anchor_bottom = 0.0
		panel.grow_vertical = Control.GROW_DIRECTION_END


func _scale() -> float:
	return panel.get_global_transform().get_scale().x


func _handle_input(e: InputEvent) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and e.double_click:
			dock()
			_drag = ""
		elif e.pressed:
			_start()
			_drag = "move"
		else:
			_drag = ""
		panel.accept_event()
	elif e is InputEventMouseMotion and _drag == "move":
		rect.position += e.relative * _scale()
		panel.accept_event()


func _edge_at(p: Vector2) -> String:
	var e := ""
	if p.x < EDGE: e += "l"
	elif p.x > panel.size.x - EDGE: e += "r"
	if p.y < EDGE: e += "t"
	elif p.y > panel.size.y - EDGE: e += "b"
	return e


func _panel_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and _drag == "":
		panel.mouse_default_cursor_shape = {"l": Control.CURSOR_HSIZE, "r": Control.CURSOR_HSIZE, "t": Control.CURSOR_VSIZE,
			"b": Control.CURSOR_VSIZE, "lt": Control.CURSOR_FDIAGSIZE, "rb": Control.CURSOR_FDIAGSIZE,
			"rt": Control.CURSOR_BDIAGSIZE, "lb": Control.CURSOR_BDIAGSIZE}.get(_edge_at(e.position), Control.CURSOR_ARROW)
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed and is_floating():
			panel.move_to_front()
		if e.pressed:
			_edge = _edge_at(e.position)
			if _edge != "":
				_start()
				_drag = "edge"
				panel.accept_event()
		elif _drag == "edge":
			_drag = ""
			panel.accept_event()
	elif e is InputEventMouseMotion and _drag == "edge":
		var rel: Vector2 = e.relative * _scale()
		var r := rect
		if _edge.contains("r"):
			r.size.x += rel.x
		if _edge.contains("b"):
			r.size.y += rel.y
		if _edge.contains("l"):
			var w := maxf(min_size.x, r.size.x - rel.x)
			r.position.x += r.size.x - w
			r.size.x = w
		if _edge.contains("t"):
			var h := maxf(min_size.y, r.size.y - rel.y)
			r.position.y += r.size.y - h
			r.size.y = h
		rect = Rect2(r.position, r.size.max(min_size))
		panel.accept_event()


## Applies the floating rect (kept on screen). False while docked.
func place(screen: Vector2) -> bool:
	if not is_floating():
		return false
	var r := rect
	r.size = r.size.min(screen - Vector2(20, 20)).max(min_size)
	r.position.x = clampf(r.position.x, -r.size.x + 120.0, screen.x - 120.0)
	r.position.y = clampf(r.position.y, 0.0, maxf(0.0, screen.y - 60.0))
	rect.position = r.position
	panel.position = r.position
	panel.size = r.size
	return true
