class_name MatrixRain
extends Control
## Retro "digital rain": columns of green glyphs falling, with bright heads
## and fading tails, plus CRT scanlines. `density` 1 = the full loading
## storm, lower = a calm background behind the editor.

var font: Font
var density := 1.0
var cell := Vector2(14, 20)
const GLYPHS := "01アイウエオカキクケコサシスセソタチツテトナニヌネノ<>{}[]$#%&*+=:;/\\|ABCDEFXYZ"
var _cols := []   # [{y, speed, len, chars: PackedStringArray}]
var _scan: Array[float] = []


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_setup)
	_setup()


func _setup() -> void:
	_cols.clear()
	var n := int(size.x / cell.x) + 1
	for i in n:
		_cols.append(_new_col(true))


func _new_col(scatter: bool) -> Dictionary:
	var rows := int(size.y / cell.y) + 1
	var c := {"y": randf_range(-rows, rows if scatter else 0), "speed": randf_range(8.0, 26.0),
		"len": randi_range(6, 24), "chars": PackedStringArray()}
	for i in rows + 30:
		c.chars.append(GLYPHS[randi() % GLYPHS.length()])
	return c


func _process(delta: float) -> void:
	if not is_visible_in_tree():
		return
	var rows := size.y / cell.y
	for c in _cols:
		c.y += c.speed * delta * (0.4 + density)
		if c.y - c.len > rows:
			var n := _new_col(false)
			c.y = n.y
			c.speed = n.speed
			c.len = n.len
		# glyphs flicker
		if randf() < 0.3:
			var k: int = randi() % c.chars.size()
			c.chars[k] = GLYPHS[randi() % GLYPHS.length()]
	queue_redraw()


func _draw() -> void:
	if font == null:
		return
	var fs := int(cell.y * 0.9)
	for i in _cols.size():
		var c: Dictionary = _cols[i]
		if density < 0.99 and (i * 7919) % 100 > int(density * 100.0):
			continue
		var head := int(c.y)
		var ln: int = c.len
		for k in ln:
			var row: int = head - k
			if row < 0 or row >= c.chars.size():
				continue
			var t := 1.0 - float(k) / ln
			var col := Color(0.6, 1.0, 0.7, 1.0) if k == 0 else Color(0.0, 0.9, 0.35, t * 0.8 * (0.35 + density * 0.65))
			draw_string(font, Vector2(i * cell.x, (row + 1) * cell.y), c.chars[row], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
	# CRT scanlines
	var y := 0.0
	while y < size.y:
		draw_rect(Rect2(0, y, size.x, 1), Color(0, 0, 0, 0.25))
		y += 3.0
