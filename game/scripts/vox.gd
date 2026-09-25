class_name Vox
## Voxel/pixel-art helpers: PICO-8 palette, cached toon materials with
## inverted-hull outlines, and box builders.

const BLACK := Color("000000")
const NAVY := Color("1d2b53")
const PLUM := Color("7e2553")
const FOREST := Color("008751")
const BROWN := Color("ab5236")
const SLATE := Color("5f574f")
const SILVER := Color("c2c3c7")
const WHITE := Color("fff1e8")
const RED := Color("ff004d")
const ORANGE := Color("ffa300")
const YELLOW := Color("ffec27")
const GREEN := Color("00e436")
const BLUE := Color("29adff")
const LAVENDER := Color("83769c")
const PINK := Color("ff77a8")
const PEACH := Color("ffccaa")

## Colors used to tell namespaces apart (status colors are kept out of it).
const NS_COLORS := [BLUE, PINK, ORANGE, LAVENDER, PEACH, Color("a8e6ff"), Color("c98bff"), Color("ffd27a"), Color("7ad6c0"), Color("e08060")]

const OUTLINE_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_opaque, shadows_disabled;
uniform vec4 color : source_color = vec4(0.0, 0.0, 0.0, 1.0);
uniform float width = 0.05;
void vertex() {
	// Boxes are centered on their origin, so pushing along sign(VERTEX)
	// grows the hull uniformly without cracking at the corners.
	VERTEX += sign(VERTEX) * width;
}
void fragment() {
	ALBEDO = color.rgb;
}
"""

static var _mats := {}
static var _meshes := {}
static var _outline: ShaderMaterial


static func ns_color(ns: String) -> Color:
	if ns == "kube-system":
		return SILVER
	if ns == "default":
		return BLUE
	return NS_COLORS[abs(ns.hash()) % NS_COLORS.size()]


static func outline_mat() -> ShaderMaterial:
	if _outline == null:
		var sh := Shader.new()
		sh.code = OUTLINE_SHADER
		_outline = ShaderMaterial.new()
		_outline.shader = sh
		_outline.set_shader_parameter("color", Color("0b0d1a"))
	return _outline


static func mat(c: Color, glow := 0.0, outlined := true) -> StandardMaterial3D:
	var key := "%s|%.2f|%s" % [c.to_html(), glow, outlined]
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.roughness = 1.0
	m.metallic_specular = 0.0
	m.diffuse_mode = BaseMaterial3D.DIFFUSE_TOON
	m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
	if glow > 0.0:
		m.emission_enabled = true
		m.emission = c
		m.emission_energy_multiplier = glow
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA  # ghosts (things that should exist and don't)
	if outlined:
		m.next_pass = outline_mat()
	_mats[key] = m
	return m


static func unlit(c: Color) -> StandardMaterial3D:
	var key := "unlit|" + c.to_html()
	if _mats.has(key):
		return _mats[key]
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = c
	m.vertex_color_use_as_albedo = true
	if c.a < 1.0:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	_mats[key] = m
	return m


static func box_mesh(size: Vector3) -> BoxMesh:
	var key := str(size)
	if _meshes.has(key):
		return _meshes[key]
	var bm := BoxMesh.new()
	bm.size = size
	_meshes[key] = bm
	return bm


static func box(parent: Node3D, size: Vector3, pos: Vector3, c: Color, glow := 0.0, outlined := true) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = box_mesh(size)
	mi.position = pos
	mi.material_override = mat(c, glow, outlined)
	parent.add_child(mi)
	return mi


## Deterministic pseudo-random generator seeded by a string (so a node's
## island always looks the same between runs).
static func rng_for(s: String) -> RandomNumberGenerator:
	var r := RandomNumberGenerator.new()
	r.seed = s.hash()
	return r


## "250m" / "1.5" cores from millicores.
static func fmt_cores(m: float) -> String:
	return "%dm" % roundi(m) if m < 1000 else "%.1f" % (m / 1000.0)


## "512 MiB" / "1.2 GiB" from bytes.
static func fmt_mib(b: float) -> String:
	if b >= 1024.0 * 1024 * 1024:
		return "%.1f GiB" % (b / (1024.0 * 1024 * 1024))
	return "%d MiB" % roundi(b / (1024.0 * 1024))
