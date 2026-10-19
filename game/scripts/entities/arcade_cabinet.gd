class_name ArcadeCabinet
extends Entity
## A voxel arcade cabinet in the UNDERGROUND: marquee in the game's color, a
## screen running the game's attract mode (a tiny SubViewport), a control
## panel and a coin door. Walk up and press E (or click it) to play.

const SCREEN_PX := Vector2i(48, 36)   # the attract screen, in pixels

var color := Color.WHITE
var screen: MeshInstance3D
var _vp: SubViewport
var _canvas: Control
var _t := 0.0


func setup(g: Dictionary, best: int) -> void:
	kind = "cabinet"
	key = g.id
	color = g.color
	data = {"name": g.title, "best": best}
	_build()


func label_text() -> String:
	return str(data.get("name", key))


func label_sub() -> String:
	if not ArcadeHall.playable(key):
		return tr("OUT OF ORDER")
	return "HI %d" % int(data.get("best", 0))


func label_color() -> Color:
	return color


func anchor() -> Vector3:
	return global_position + Vector3(0, ArcadeHall.CAB_HEIGHT + 0.5, 0)


func pick_radius() -> float:
	return 40.0


func build_box() -> AABB:
	return AABB(Vector3(-0.9, 0, -0.7), Vector3(1.8, ArcadeHall.CAB_HEIGHT, 1.4))


## Center of the screen in the world: where the camera leans in.
func screen_pos() -> Vector3:
	return global_position + Vector3(0, 1.75, 0.5)


func _build() -> void:
	var body := Color("221a30")
	var side := color.darkened(0.45)
	Vox.box(self, Vector3(1.4, 2.4, 1.1), Vector3(0, 1.2, -0.1), body)
	for x in [-0.76, 0.76]:
		Vox.box(self, Vector3(0.12, 2.6, 1.3), Vector3(x, 1.3, 0.0), side)
		Vox.box(self, Vector3(0.14, 0.08, 1.32), Vector3(x, 2.0, 0.0), color, 1.2, false)   # neon stripe
	# The marquee on top, lit from inside.
	Vox.box(self, Vector3(1.6, 0.4, 0.4), Vector3(0, 2.6, 0.3), color, 1.6)
	# Screen: a dark bezel and the attract mode on it.
	Vox.box(self, Vector3(1.26, 0.98, 0.08), Vector3(0, 1.75, 0.46), Color("0a0910"), 0.0, false)
	_vp = SubViewport.new()
	_vp.size = SCREEN_PX
	_vp.disable_3d = true
	_vp.transparent_bg = false
	_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	_vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	add_child(_vp)
	_canvas = Control.new()
	_canvas.size = Vector2(SCREEN_PX)
	_canvas.draw.connect(_paint)
	_vp.add_child(_canvas)
	var q := QuadMesh.new()
	q.size = Vector2(1.12, 0.84)
	screen = MeshInstance3D.new()
	screen.mesh = q
	screen.position = Vector3(0, 1.75, 0.51)
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST
	m.albedo_texture = _vp.get_texture()
	screen.material_override = m
	add_child(screen)
	# Control panel (tilted), joystick and three buttons.
	var panel := Node3D.new()
	panel.position = Vector3(0, 1.08, 0.62)
	panel.rotation.x = 0.3
	add_child(panel)
	Vox.box(panel, Vector3(1.4, 0.16, 0.5), Vector3.ZERO, Color("2e2840"))
	Vox.box(panel, Vector3(0.06, 0.22, 0.06), Vector3(-0.38, 0.18, 0), Color("15121c"), 0.0, false)
	Vox.box(panel, Vector3(0.16, 0.16, 0.16), Vector3(-0.38, 0.32, 0), Vox.RED, 0.6)
	var bc := [Vox.YELLOW, Vox.BLUE, Vox.GREEN]
	for i in 3:
		Vox.box(panel, Vector3(0.12, 0.08, 0.12), Vector3(0.05 + i * 0.2, 0.1, 0.02), bc[i], 1.0, false)
	# Coin door with two glowing slots.
	Vox.box(self, Vector3(0.5, 0.4, 0.04), Vector3(0, 0.5, 0.46), Color("15121c"), 0.0, false)
	for x in [-0.1, 0.1]:
		Vox.box(self, Vector3(0.05, 0.12, 0.02), Vector3(x, 0.55, 0.49), Vox.ORANGE, 2.0, false)
	var light := OmniLight3D.new()
	light.light_color = color
	light.light_energy = 1.4
	light.omni_range = 3.6
	light.position = Vector3(0, 1.9, 1.1)
	add_child(light)


func _process(delta: float) -> void:
	_t += delta
	if _canvas and _canvas.is_visible_in_tree():
		_canvas.queue_redraw()


func _paint() -> void:
	var r := Rect2(Vector2.ZERO, Vector2(SCREEN_PX))
	_canvas.draw_rect(r, Color(0.02, 0.02, 0.04))
	ArcadeHall.paint_attract(_canvas, key, r.grow(-3.0), _t)
	for y in range(0, SCREEN_PX.y, 2):
		_canvas.draw_rect(Rect2(0, y, SCREEN_PX.x, 1), Color(0, 0, 0, 0.2))
