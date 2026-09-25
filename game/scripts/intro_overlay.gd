class_name IntroOverlay
extends Control
## The 2D layer of the opening fly-through: cinema bars, the KUBIVERSE logo,
## one caption per shot and the "skip" hint. main.gd moves the camera and
## sets `t`; this only draws.

var title_font: Font
var font: Font
var t := 0.0
var captions: Array = []   # [{from, to, text}]
var total := 1.0
var ui := 1.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _process(_d: float) -> void:
	queue_redraw()


func _fade(a: float, b: float, edge := 0.5) -> float:
	return clampf(minf((t - a) / edge, (b - t) / edge), 0.0, 1.0)


func _centered(f: Font, text: String, y: float, fs: int, col: Color, shadow := true) -> void:
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var p := Vector2((size.x - w) * 0.5, y)
	if shadow:
		draw_string(f, p + Vector2(0, maxf(2.0, fs * 0.08)), text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, col.a * 0.8))
	draw_string(f, p, text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw() -> void:
	if title_font == null or font == null:
		return
	# Cinema bars slide in, and out at the end.
	var bars := clampf(minf(t / 0.6, (total - t) / 0.6), 0.0, 1.0)
	var bh := size.y * 0.11 * bars
	draw_rect(Rect2(0, 0, size.x, bh), Color.BLACK)
	draw_rect(Rect2(0, size.y - bh, size.x, bh), Color.BLACK)
	# Logo: pops in over the Internet globe, then leaves.
	var la := _fade(0.4, 3.6, 0.6)
	if la > 0.0:
		var fs := int(clampf(size.x / 13.0, 26.0, 84.0))
		var bob := sin(t * 3.0) * 3.0
		var text := "KUBIVERSE"
		var w := title_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var x0 := (size.x - w) * 0.5
		var y := size.y * 0.36 + bob
		# One colour per letter, revealed left to right.
		var shown := int(clampf((t - 0.4) / 1.2, 0.0, 1.0) * text.length() + 0.999)
		var cols := [Vox.RED, Vox.ORANGE, Vox.YELLOW, Vox.GREEN, Vox.BLUE, Vox.LAVENDER, Vox.PINK, Vox.YELLOW, Vox.GREEN]
		var x := x0
		for i in text.length():
			var ch := text[i]
			var cw := title_font.get_string_size(ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			if i < shown:
				var c: Color = cols[i]
				c.a = la
				draw_string(title_font, Vector2(x, y + fs * 0.12), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(0, 0, 0, la * 0.85))
				draw_string(title_font, Vector2(x, y), ch, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, c)
			x += cw
		_centered(font, tr("your Kubernetes cluster, as a world you can walk"), y + fs * 0.9, int(fs * 0.5), Color(Vox.WHITE, la))
	# Captions (lower third, inside the bottom bar area).
	for c in captions:
		var a := _fade(c.from, c.to, 0.4)
		if a > 0.0:
			var fs := int(clampf(size.x / 34.0, 20.0, 34.0))
			var y := size.y - bh - fs * 1.2
			draw_rect(Rect2(0, y - fs * 1.05, size.x, fs * 1.5), Color(0, 0, 0, 0.45 * a))
			_centered(font, tr(c.text), y, fs, Color(Vox.WHITE, a))
	# Skip hint.
	if bh > 4.0:
		var fs := int(clampf(size.x / 60.0, 14.0, 22.0))
		var hint := tr("any key or tap: skip")
		var w := font.get_string_size(hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		draw_string(font, Vector2(size.x - w - 16, size.y - bh * 0.35), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, Color(Vox.SILVER, 0.7 * bars))
