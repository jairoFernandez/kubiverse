class_name MapView
extends Control
## Top-down map of the current level, drawn straight from World's layout
## (walkable ground, buildings, lines, docks, islands, pods, doors) with the
## player as an arrow. "mini" follows the player; "full" fits the whole level
## and lets you click anywhere to travel there.

signal travel(pos: Vector3, target: Entity)
signal open_full

const MINI_SCALE := 4.5  # map px (UI units) per world unit

var world: World
var player: Player
var full := false
var zoom := 1.0
var font: Font

var _scale := 1.0
var _origin := Vector2.ZERO  # world XZ at the map's center
var _t := 0.0


func _process(delta: float) -> void:
	_t += delta
	if is_visible_in_tree():
		queue_redraw()


func _bounds() -> Rect2:
	var b := Rect2()
	var first := true
	for r in world.walk_rects:
		b = r if first else b.merge(r)
		first = false
	for sg in world.walk_segments:
		for p in [sg[0], sg[1]]:
			b = Rect2(p, Vector2.ZERO) if first else b.expand(p)
			first = false
	return b.grow(2.0)


func to_map(p: Vector2) -> Vector2:
	return size * 0.5 + (p - _origin) * _scale


func to_world(m: Vector2) -> Vector2:
	return _origin + (m - size * 0.5) / _scale


func _xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


func _rect(r: Rect2, col: Color, filled := true, width := 1.0) -> void:
	var a := to_map(r.position)
	draw_rect(Rect2(a, r.size * _scale), col, filled, -1.0 if filled else width)


func _text(p: Vector2, s: String, col: Color, fs := 18) -> void:
	var w := font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
	var q := p - Vector2(w * 0.5, -fs * 0.35)
	draw_string_outline(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, 5, Color("0b0d1a"))
	draw_string(font, q, s, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)


func _draw() -> void:
	if world == null or player == null:
		return
	var b := _bounds()
	if full:
		_scale = minf(size.x / maxf(b.size.x, 1.0), size.y / maxf(b.size.y, 1.0))
		_origin = b.get_center()
	else:
		_scale = MINI_SCALE * zoom
		_origin = _xz(player.global_position)
	draw_rect(Rect2(Vector2.ZERO, size), Color("0e1224"))
	var ground := Color("3d4a33") if world.level == "plant" else (Color("4a5066") if world.level.begins_with("ns:") else Color("343a58"))
	for r in world.walk_rects:
		_rect(r, ground)
	for sg in world.walk_segments:
		draw_line(to_map(sg[0]), to_map(sg[1]), Color("8f4a2e"), maxf(2.0, sg[2] * 2.0 * _scale))
	for r in world.blockers:
		_rect(r, Color("20243a"))
	# Buildings (plant level)
	for bd in world.buildings.values():
		var r: Rect2 = bd.footprint()
		_rect(r, bd.label_color().darkened(0.45))
		_rect(r, bd.health_color(), false, 2.0)
		if full:
			_text(to_map(r.get_center()), tr("ENERGY") if bd.is_power else bd.key, Vox.WHITE)
	# Islands (energy level)
	for isl in world.islands.values():
		var half: float = isl.size * 0.5
		var r := Rect2(isl.target.x - half, isl.target.z - half, isl.size, isl.size)
		_rect(r, Vox.FOREST if isl.data.get("ready", true) else Vox.SLATE)
		_rect(r, isl.label_color(), false, 2.0)
		if full:
			_text(to_map(r.get_center() - Vector2(0, half + 1.0)), isl.key, isl.label_color())
	# Assembly lines and docks (hall level)
	for ln in world.lines.values():
		var r := Rect2(ln.target.x - 0.4, ln.target.z - 0.8, ln.length + 0.4, 1.6)
		_rect(r, ln.label_color().darkened(0.5))
		_rect(r, ln.label_color(), false, 1.5)
		if full:
			_text(to_map(Vector2(ln.target.x + ln.length * 0.5, ln.target.z - 1.6)), ln.data.get("name", ""), ln.label_color())
	for dk in world.services.values():
		var p := to_map(_xz(dk.target))
		draw_rect(Rect2(p - Vector2(5, 9), Vector2(10, 18)), ServicePortal.type_color(dk.data))
		if full:
			_text(p + Vector2(0, -16), dk.data.get("name", ""), ServicePortal.type_color(dk.data), 16)
	# Doors
	for d in world.doors:
		var p := to_map(_xz(d.pos))
		draw_rect(Rect2(p - Vector2(6, 4), Vector2(12, 8)), Vox.YELLOW)
	# Pods
	var pr := clampf(_scale * 0.35, 2.5, 6.0)
	for bot in world.pods.values():
		if bot.dying:
			continue
		draw_circle(to_map(_xz(bot.global_position)), pr, PodBot.category_color(bot.category))
	# Selection ring
	var sel := world.selected
	if sel != null and is_instance_valid(sel):
		draw_arc(to_map(_xz(sel.global_position)), 8.0 + sin(_t * 6.0) * 2.0, 0, TAU, 20, Vox.YELLOW, 2.0)
	# Player arrow
	var pp := to_map(_xz(player.global_position))
	var f := player.forward()
	var dir := Vector2(f.x, f.z).normalized()
	var side := Vector2(-dir.y, dir.x)
	var s := 9.0 if full else 7.0
	var tri := PackedVector2Array([pp + dir * s * 1.4, pp - dir * s * 0.8 + side * s, pp - dir * s * 0.8 - side * s])
	draw_colored_polygon(tri, Vox.WHITE)
	draw_polyline(PackedVector2Array([tri[0], tri[1], tri[2], tri[0]]), Color("0b0d1a"), 2.0)
	if not full:
		draw_rect(Rect2(Vector2.ZERO, size), Vox.SLATE, false, 2.0)


func _gui_input(event: InputEvent) -> void:
	if not (event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT):
		return
	accept_event()
	if not full:
		open_full.emit()
		return
	var m: Vector2 = event.position
	var wp := to_world(m)
	# Small things first (pods, docks), then lines/buildings/islands.
	var best: Entity = null
	var best_d := 14.0
	for bot in world.pods.values():
		if bot.dying:
			continue
		var d := to_map(_xz(bot.global_position)).distance_to(m)
		if d < best_d:
			best_d = d
			best = bot
	for dk in world.services.values():
		var d := to_map(_xz(dk.target)).distance_to(m)
		if d < best_d:
			best_d = d
			best = dk
	if best == null:
		for ln in world.lines.values():
			if Rect2(ln.target.x - 0.4, ln.target.z - 1.0, ln.length + 0.4, 2.0).has_point(wp):
				best = ln
		for e in world.all_entities():
			if e.is_area() and e.contains_xz(Vector3(wp.x, 0, wp.y)):
				best = e
	travel.emit(Vector3(wp.x, 0, wp.y), best)
