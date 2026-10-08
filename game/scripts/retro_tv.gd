class_name RetroTV
extends Control
## The radio's TV: an 80s wood-cabinet set with rabbit-ear antennas, a curved
## screen (scanlines, vignette, a touch of color fringing, snow while it
## tunes in), a green channel display and knobs on the side. Everything is
## drawn here or by one small shader on the screen: no images.
## The top strip (with the antennas) is `handle`, to drag it around.

signal prev
signal next
signal closed

const TOP := 34.0       # antennas + the strip that drags it
const SIDE := 78.0      # control column on the right
const PAD := 14.0       # wood around the screen

const WOOD := Color("6b3f1f")
const WOOD_DARK := Color("4a2a12")
const WOOD_LIGHT := Color("8a5a30")
const BEZEL := Color("1d1d1f")
const METAL := Color("b8b8b0")

const SHADER := """
shader_type canvas_item;
uniform float curve = 0.06;
uniform float snow = 0.0;
uniform float lines = 240.0;
float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	uv += uv * dot(uv, uv) * curve;          // the tube bulges
	uv = uv * 0.5 + 0.5;
	if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
		COLOR = vec4(0.02, 0.02, 0.02, 1.0);
	} else {
		float f = 0.0015;                    // colors bleed a little sideways
		vec3 c = vec3(texture(TEXTURE, uv + vec2(f, 0.0)).r, texture(TEXTURE, uv).g, texture(TEXTURE, uv - vec2(f, 0.0)).b);
		float n = rnd(floor(uv * vec2(320.0, 180.0)) + fract(TIME) * 91.0);
		c = mix(c, vec3(n), snow);
		c *= 0.82 + 0.18 * sin(uv.y * lines * 3.14159);   // scanlines
		vec2 d = UV - 0.5;
		c *= 1.0 - 1.6 * dot(d, d);                       // darker corners
		c *= 1.04 + 0.02 * sin(TIME * 60.0);              // a faint flicker
		COLOR = vec4(c, 1.0);
	}
}
"""

var handle: Control
var screen: TextureRect
var _osd: Label
var _osd_t := 0.0
var _mat: ShaderMaterial
var _blank: ImageTexture


func _init() -> void:
	clip_contents = false
	mouse_filter = Control.MOUSE_FILTER_STOP
	handle = Control.new()
	handle.mouse_default_cursor_shape = Control.CURSOR_MOVE
	add_child(handle)
	screen = TextureRect.new()
	screen.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	screen.stretch_mode = TextureRect.STRETCH_SCALE
	screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mat = ShaderMaterial.new()
	var sh := Shader.new()
	sh.code = SHADER
	_mat.shader = sh
	screen.material = _mat
	# A black picture until the first frame: the shader needs something to draw.
	var img := Image.create(16, 9, false, Image.FORMAT_RGB8)
	_blank = ImageTexture.create_from_image(img)
	screen.texture = _blank
	add_child(screen)
	_osd = Label.new()
	_osd.add_theme_color_override("font_color", Color("6dff6d"))
	_osd.add_theme_color_override("font_shadow_color", Color(0, 0.25, 0, 0.8))
	_osd.add_theme_constant_override("shadow_offset_x", 2)
	_osd.add_theme_constant_override("shadow_offset_y", 2)
	_osd.add_theme_font_size_override("font_size", 26)
	_osd.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_osd.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	add_child(_osd)
	for k in [["CH+", next, "Next YouTube channel"], ["CH-", prev, "Previous YouTube channel"], ["OFF", closed, "Turn the TV off (the sound keeps playing)"]]:
		var b := Button.new()
		b.text = k[0]
		b.tooltip_text = TranslationServer.translate(k[2])
		b.focus_mode = Control.FOCUS_NONE
		b.add_theme_font_size_override("font_size", 16)
		var sig: Signal = k[1]
		b.pressed.connect(func(): sig.emit())
		b.set_meta("knob", true)
		for st in ["normal", "hover", "pressed"]:
			var sb := StyleBoxFlat.new()
			sb.bg_color = {"normal": Color("2a2a2a"), "hover": Color("444444"), "pressed": Color("111111")}[st]
			sb.border_color = METAL
			sb.set_border_width_all(2)
			sb.set_corner_radius_all(20)
			b.add_theme_stylebox_override(st, sb)
		b.add_theme_color_override("font_color", Color("e8e0c8"))
		b.add_theme_color_override("font_hover_color", Color("ffd54a"))
		add_child(b)
	resized.connect(_layout)


## Smallest size that still reads as a TV.
func _get_minimum_size() -> Vector2:
	return Vector2(300, 190)


func set_frame(tex: Texture2D) -> void:
	screen.texture = tex if tex else _blank


## Static on the screen (0 = clear picture, 1 = only snow).
func set_snow(amount: float) -> void:
	_mat.set_shader_parameter("snow", amount)


## The green channel display, shown for a few seconds.
func show_channel(text: String) -> void:
	_osd.text = text
	_osd_t = 3.0
	_osd.visible = true


func _process(delta: float) -> void:
	if _osd_t > 0.0:
		_osd_t -= delta
		_osd.visible = _osd_t > 0.0


func _layout() -> void:
	handle.position = Vector2.ZERO
	handle.size = Vector2(size.x, TOP)
	var sr := _screen_rect()
	screen.position = sr.position
	screen.size = sr.size
	_mat.set_shader_parameter("lines", clampf(sr.size.y * 0.75, 120.0, 360.0))
	_osd.position = sr.position + Vector2(16, 10)
	var knobs := get_children().filter(func(c): return c.has_meta("knob"))
	var x := size.x - SIDE + 12.0
	var y := TOP + PAD + 6.0
	for b in knobs:
		b.position = Vector2(x, y)
		b.size = Vector2(SIDE - 24.0, 40)
		y += 48.0
	queue_redraw()


func _screen_rect() -> Rect2:
	var area := Rect2(PAD + 10.0, TOP + PAD + 10.0, size.x - SIDE - PAD - 20.0, size.y - TOP - PAD * 2.0 - 20.0)
	# Keep 16:9 inside the area, centered.
	var w := minf(area.size.x, area.size.y * 16.0 / 9.0)
	var h := w * 9.0 / 16.0
	return Rect2(area.position + (area.size - Vector2(w, h)) / 2.0, Vector2(w, h))


func _draw() -> void:
	var body := Rect2(0, TOP, size.x, size.y - TOP)
	# Rabbit ears: two chrome rods on a little dome.
	var base := Vector2(size.x * 0.42, TOP + 2.0)
	draw_line(base, base + Vector2(-size.x * 0.16, -TOP + 4.0), METAL, 3.0, true)
	draw_line(base, base + Vector2(size.x * 0.14, -TOP + 2.0), METAL, 3.0, true)
	draw_circle(base + Vector2(-size.x * 0.16, -TOP + 4.0), 3.5, Color("dcdcd4"))
	draw_circle(base + Vector2(size.x * 0.14, -TOP + 2.0), 3.5, Color("dcdcd4"))
	draw_circle(base + Vector2(0, 4), 10.0, Color("2b2b2b"))
	# Wood cabinet: a dark edge, the grain, and a lighter top lip.
	draw_style_box(_box(WOOD, WOOD_DARK, 4, 10), body)
	var grain := Color(WOOD_DARK, 0.35)
	var gy := body.position.y + 8.0
	var i := 0
	while gy < body.end.y - 6.0:
		var wob := sin(i * 1.7) * 3.0
		draw_line(Vector2(8, gy + wob), Vector2(size.x - 8, gy - wob), grain, 1.0)
		gy += 7.0 + (i % 3)
		i += 1
	draw_line(Vector2(10, body.position.y + 3), Vector2(size.x - 10, body.position.y + 3), WOOD_LIGHT, 2.0)
	# The tube's bezel: rounded black frame around the screen.
	var sr := _screen_rect()
	draw_style_box(_box(BEZEL, Color("333336"), 3, 18), sr.grow(10.0))
	# Control column: a metal plate, the brand and a speaker grille.
	var plate := Rect2(size.x - SIDE, TOP + PAD, SIDE - PAD * 0.5, body.size.y - PAD * 2.0)
	draw_style_box(_box(Color("2c2622"), Color("1a1512"), 2, 6), plate)
	var font := get_theme_default_font()
	draw_string(font, Vector2(plate.position.x, plate.end.y - 8.0), "KUBITRON", HORIZONTAL_ALIGNMENT_CENTER, plate.size.x, 13, Color("d8c79a"))
	var gtop := TOP + PAD + 6.0 + 48.0 * 3.0 + 6.0
	var gl := plate.end.y - 26.0
	var yy := gtop
	while yy < gl:
		draw_line(Vector2(plate.position.x + 10, yy), Vector2(plate.end.x - 10, yy), Color("0d0b0a"), 2.0)
		yy += 6.0
	# Little feet.
	draw_rect(Rect2(18, size.y - 4, 26, 4), WOOD_DARK)
	draw_rect(Rect2(size.x - 44, size.y - 4, 26, 4), WOOD_DARK)


func _box(bg: Color, border: Color, bw: int, radius: int) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	return sb
