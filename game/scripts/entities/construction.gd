class_name Construction
extends Node3D
## A building site around something the cluster just created: scaffolding,
## a crane dropping voxel blocks, dust and a blinking beacon, while the thing
## itself rises from the ground. `hold` keeps the site open after it has
## risen (a Deployment whose pods aren't ready yet, a claim not bound...).
## Small things (a Secret, a book) get a lighter site: no crane, blocks just
## fall into place. It lives under the world's fx root, beside its entity
## (the entity is scaled while it rises; the site must not be).

const DUR := 5.0          # seconds to rise
const DROP_EVERY := 0.28  # a block from the crane this often
const MIN_OPEN := 4.0     # a site stays at least this long (fast clusters)

var entity: Entity
var world: World
var box := AABB(Vector3(-0.8, 0, -0.8), Vector3(1.6, 1.8, 1.6))
var t := 0.0
var hold := false
var rise := true          # false: the thing is old, only work is going on in it
var done := false
var _open := 0.0          # seconds since the site was opened
var _small := false
var _jib: Node3D
var _beacon: MeshInstance3D
var _drop_cd := 0.0
var _blocks: Array = []   # [{m, v, floor}]
var _col := Vox.ORANGE


## elapsed: how long ago the thing was created (seconds): entering a hall
## a moment later shows the work already under way.
func setup(e: Entity, w: World, elapsed: float, rises: bool) -> void:
	entity = e
	world = w
	rise = rises
	box = e.build_box()
	t = clampf(elapsed, 0.0, DUR) if rise else DUR
	_small = box.size.x < 2.5 and box.size.z < 2.5
	_col = e.label_color()
	_build()
	_follow()
	_apply_rise()


func _build() -> void:
	var lo := box.position
	var hi := box.end
	var top := hi.y + 0.4
	# Bright and a little glowing: it must read at night and in the rain too.
	var pole := Vox.ORANGE
	var plank := Color("d08a3c")
	# Corner poles and plank rings: the scaffolding.
	var pad := 0.25
	var corners := [Vector2(lo.x - pad, lo.z - pad), Vector2(hi.x + pad, lo.z - pad), Vector2(lo.x - pad, hi.z + pad), Vector2(hi.x + pad, hi.z + pad)]
	var thick := 0.08 if _small else 0.14
	for c in corners:
		Vox.box(self, Vector3(thick, top, thick), Vector3(c.x, top * 0.5, c.y), pole, 0.6, not _small)
	var w := hi.x - lo.x + pad * 2
	var d := hi.z - lo.z + pad * 2
	var cx := (lo.x + hi.x) * 0.5
	var cz := (lo.z + hi.z) * 0.5
	var step := 0.6 if _small else 1.3
	var y := step
	while y < top:
		for zz in [lo.z - pad, hi.z + pad]:
			Vox.box(self, Vector3(w, thick * 0.8, thick * 1.6), Vector3(cx, y, zz), plank, 0.3, false)
		for xx in [lo.x - pad, hi.x + pad]:
			Vox.box(self, Vector3(thick * 1.6, thick * 0.8, d), Vector3(xx, y, cz), plank, 0.3, false)
		y += step
	# Hazard stripes at the foot of the site.
	if not _small:
		var n := maxi(2, int(w / 0.8))
		for i in n:
			var x := lo.x - pad + (i + 0.5) * w / n
			Vox.box(self, Vector3(w / n * 0.9, 0.12, 0.12), Vector3(x, 0.08, lo.z - pad - 0.25), Vox.YELLOW if i % 2 == 0 else Vox.BLACK, 0.0, false)
	# The crane: a mast at a corner and a jib that swings over the site.
	var mast_h := top + (1.6 if _small else 2.8)
	var mx: float = hi.x + pad + (0.4 if _small else 0.9)
	var mz: float = hi.z + pad + (0.4 if _small else 0.9)
	if not _small:
		Vox.box(self, Vector3(0.5, mast_h, 0.5), Vector3(mx, mast_h * 0.5, mz), Vox.YELLOW)
		Vox.box(self, Vector3(1.0, 0.5, 1.0), Vector3(mx, 0.25, mz), Vox.SLATE)
		_jib = Node3D.new()
		_jib.position = Vector3(mx, mast_h, mz)
		add_child(_jib)
		var reach := Vector2(mx - cx, mz - cz).length() + 1.0
		Vox.box(_jib, Vector3(reach, 0.3, 0.3), Vector3(-reach * 0.5, 0, 0), Vox.YELLOW)
		Vox.box(_jib, Vector3(1.4, 0.3, 0.3), Vector3(0.7, 0, 0), Vox.YELLOW)
		Vox.box(_jib, Vector3(0.7, 0.6, 0.6), Vector3(1.3, -0.3, 0), Vox.SLATE)   # counterweight
		Vox.box(_jib, Vector3(0.6, 0.5, 0.5), Vector3(0, 0.4, 0), Vox.ORANGE)     # cab
		var cable := Vox.box(_jib, Vector3(0.05, 1.6, 0.05), Vector3(-reach * 0.7, -0.8, 0), Vox.BLACK, 0.0, false)
		cable.name = "Cable"
		var hook := Vox.box(_jib, Vector3(0.3, 0.2, 0.3), Vector3(-reach * 0.7, -1.7, 0), Vox.SLATE)
		hook.name = "Hook"
		_jib.rotation.y = atan2(cz - mz, mx - cx)   # its arm (local -x) over the site
	_beacon = Vox.box(self, Vector3.ONE * (0.2 if _small else 0.35), Vector3(mx if not _small else hi.x + pad, (mast_h if not _small else top) + 0.3, mz if not _small else hi.z + pad), Vox.ORANGE, 3.0, false)
	_beacon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


func progress() -> float:
	return clampf(t / DUR, 0.0, 1.0)


## Text for the floating label over the site.
func sign_text() -> String:
	if rise and progress() < 1.0:
		return tr("BUILDING %d%%") % roundi(progress() * 100.0)
	return tr("UNDER CONSTRUCTION")


func sign_pos() -> Vector3:
	return global_position + Vector3((box.position.x + box.end.x) * 0.5, box.end.y + 1.4, (box.position.z + box.end.z) * 0.5)


func _follow() -> void:
	global_position = entity.global_position
	rotation.y = entity.rotation.y


func _apply_rise() -> void:
	if not rise:
		return
	var p := progress()
	var s := 0.06 + 0.94 * (1.0 - pow(1.0 - p, 2.0))
	entity.scale = Vector3(1.0, s, 1.0)


func _process(delta: float) -> void:
	if entity == null or not is_instance_valid(entity) or entity.is_queued_for_deletion():
		queue_free()
		return
	t += delta
	_open += delta
	_follow()
	_apply_rise()
	var p := progress()
	var working := p < 1.0 or hold or _open < MIN_OPEN
	if _beacon:
		_beacon.visible = fmod(t, 0.7) < 0.4
	if _jib and working:
		_jib.rotation.y += sin(t * 0.7) * delta * 0.5
	if working:
		_drop_cd -= delta
		if _drop_cd <= 0.0:
			_drop_cd = DROP_EVERY * (1.6 if hold and p >= 1.0 else 1.0)
			_drop_block()
	for i in range(_blocks.size() - 1, -1, -1):
		var b: Dictionary = _blocks[i]
		var m: MeshInstance3D = b.m
		b.v.y -= 18.0 * delta
		m.position += b.v * delta
		if m.position.y <= b.floor:
			if world and not _small and randf() < 0.35:
				world.smoke(to_global(m.position), Color("8a7f74"))
				world.sfx("land", to_global(m.position))
			m.queue_free()
			_blocks.remove_at(i)
	if not working and not done:
		_finish()


## A block in the thing's color falls from the hook (or from the sky for
## small things) onto the current top of the work.
func _drop_block() -> void:
	var lo := box.position
	var hi := box.end
	var top_now: float = lo.y + (hi.y - lo.y) * (progress() if rise else 1.0)
	var from: Vector3
	if _jib:
		var hook: Node3D = _jib.get_node("Hook")
		from = to_local(hook.global_position)
	else:
		from = Vector3(randf_range(lo.x, hi.x), hi.y + 1.6, randf_range(lo.z, hi.z))
	var to := Vector3(randf_range(lo.x + 0.2, hi.x - 0.2), top_now, randf_range(lo.z + 0.2, hi.z - 0.2))
	var sz := 0.18 if _small else 0.42
	var col: Color = _col if randf() < 0.6 else Vox.SILVER
	var m := Vox.box(self, Vector3.ONE * sz, from, col, 0.4, not _small)
	# Aim it: horizontal speed so it lands on `to` when it reaches top_now.
	var h := maxf(0.2, from.y - to.y)
	var fall_t := sqrt(2.0 * h / 18.0)
	var v := Vector3((to.x - from.x) / fall_t, 0.0, (to.z - from.z) / fall_t)
	_blocks.append({"m": m, "v": v, "floor": to.y})


## Done: a puff of dust at every corner and the site is taken down.
func _finish() -> void:
	done = true
	if entity and is_instance_valid(entity):
		entity.scale = Vector3.ONE
	if world:
		var lo := box.position
		var hi := box.end
		for c in [Vector3(lo.x, 0.3, lo.z), Vector3(hi.x, 0.3, lo.z), Vector3(lo.x, 0.3, hi.z), Vector3(hi.x, 0.3, hi.z)]:
			world.poof(to_global(c), Vox.WHITE)
		world.flash(to_global(Vector3((lo.x + hi.x) * 0.5, hi.y, (lo.z + hi.z) * 0.5)), Vox.GREEN, 0.6 if _small else 1.2)
		world.sfx("coin", global_position)
	var tw := create_tween()
	tw.tween_property(self, "scale", Vector3(1.0, 0.01, 1.0), 0.35)
	tw.tween_callback(queue_free)
