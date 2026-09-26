class_name Book
extends Entity
## A PersistentVolume as a book on the shelf of its StorageClass: the thicker
## the book, the bigger the volume; its colour is its state (green Bound,
## blue Available, orange Released, red Failed); a bookmark sticks out as
## high as the real use (red past 90%). A claim with no visible volume is a
## book too (its data comes from the claim).

var used_pct := -1.0
var _geo: Node3D
var _sig := ""


func _init() -> void:
	kind = "pv"


static func status_color(d: Dictionary) -> Color:
	match str(d.get("status", "")):
		"Bound": return Vox.GREEN.darkened(0.15)
		"Available": return Vox.BLUE
		"Released": return Vox.ORANGE
	return Vox.RED


## Thickness from the size: 1Gi thin, 1Ti thick.
static func thickness(cap: String) -> float:
	var n := cap.to_float()
	var gi := n
	if cap.ends_with("Mi"):
		gi = n / 1024.0
	elif cap.ends_with("Ti"):
		gi = n * 1024.0
	return clampf(0.12 + log(maxf(gi, 1.0) + 1.0) * 0.06, 0.14, 0.55)


func update_data(d: Dictionary, use := -1.0) -> void:
	data = d
	key = str(d.name)
	used_pct = use
	var sig := "%s|%s|%d" % [d.get("status", ""), d.get("capacity", ""), int(use / 10.0)]
	if sig != _sig:
		_sig = sig
		_rebuild()


func width() -> float:
	return thickness(str(data.get("capacity", "1Gi")))


func label_text() -> String:
	var claim := str(data.get("claim", ""))
	return ("book " + claim.get_slice("/", 1)) if claim != "" else "pv " + str(data.get("name", ""))


func label_sub() -> String:
	var s := "%s %s" % [data.get("capacity", ""), data.get("status", "")]
	if str(data.get("claim", "")) != "":
		s += " - " + tr("lent to %s") % str(data.claim).get_slice("/", 0)
	if used_pct >= 0.0:
		s += " - " + tr("%d%% used") % int(used_pct)
	return s


func label_color() -> Color:
	return status_color(data)


func anchor() -> Vector3:
	return global_position + Vector3(0, 1.4, 0)


func pick_radius() -> float:
	return 14.0


func _rebuild() -> void:
	if _geo:
		_geo.queue_free()
	_geo = Node3D.new()
	add_child(_geo)
	var w := width()
	var c := status_color(data)
	var h := 0.9 + fmod(float(hash(str(data.get("name", "")))) / 1000.0, 0.25)
	Vox.box(_geo, Vector3(w, h, 0.7), Vector3(0, h * 0.5, 0), c)
	# Two bands on the spine.
	Vox.box(_geo, Vector3(w + 0.02, 0.06, 0.72), Vector3(0, h * 0.2, 0), c.lightened(0.35), 0.0, false)
	Vox.box(_geo, Vector3(w + 0.02, 0.06, 0.72), Vector3(0, h * 0.8, 0), c.lightened(0.35), 0.0, false)
	if used_pct >= 0.0:
		var bm := 0.1 + clampf(used_pct / 100.0, 0.0, 1.0) * 0.5
		Vox.box(_geo, Vector3(0.06, bm, 0.12), Vector3(0, h + bm * 0.5, 0.2), Vox.RED if used_pct >= 90.0 else Vox.YELLOW, 1.0, false)
