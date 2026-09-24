extends Node
## Autoload "Settings": user preferences persisted in user://settings.cfg
## (IndexedDB on the web build).

signal changed

const PATH := "user://settings.cfg"
const UI_SCALES := [1.0, 1.25, 1.5, 1.75, 2.0, 2.5]

var ui_scale := 1.25
var lines_all := false
var terminal := true
var legend_seen := false
var missions_done: Array = []
var mission_idx := 0
var lang := ""
var always_run := false
var minimap := true
var minimap_size := 2


func _ready() -> void:
	var cf := ConfigFile.new()
	if cf.load(PATH) == OK:
		ui_scale = cf.get_value("ui", "scale", ui_scale)
		lines_all = cf.get_value("ui", "lines_all", lines_all)
		terminal = cf.get_value("ui", "terminal", terminal)
		legend_seen = cf.get_value("ui", "legend_seen", legend_seen)
		missions_done = cf.get_value("missions", "done", missions_done)
		mission_idx = cf.get_value("missions", "idx", mission_idx)
		lang = cf.get_value("ui", "lang", lang)
		always_run = cf.get_value("ui", "always_run", always_run)
		minimap = cf.get_value("ui", "minimap", minimap)
		minimap_size = cf.get_value("ui", "minimap_size", minimap_size)


func save() -> void:
	var cf := ConfigFile.new()
	cf.set_value("ui", "scale", ui_scale)
	cf.set_value("ui", "lines_all", lines_all)
	cf.set_value("ui", "terminal", terminal)
	cf.set_value("ui", "legend_seen", legend_seen)
	cf.set_value("missions", "done", missions_done)
	cf.set_value("missions", "idx", mission_idx)
	cf.set_value("ui", "lang", lang)
	cf.set_value("ui", "always_run", always_run)
	cf.set_value("ui", "minimap", minimap)
	cf.set_value("ui", "minimap_size", minimap_size)
	cf.save(PATH)
	changed.emit()


func step_scale(dir: int) -> void:
	var i := UI_SCALES.find(ui_scale)
	if i < 0:
		i = 1
	ui_scale = UI_SCALES[clampi(i + dir, 0, UI_SCALES.size() - 1)]
	save()


## Physical pixels per logical pixel (2 on Retina / HiDPI browsers).
func dpi() -> float:
	return maxf(1.0, DisplayServer.screen_get_scale())


## Final UI zoom: DPI times the user's preference, but never so big that the
## canvas gets smaller than ~1280x800 logical units at 100%.
func ui_factor(win: Vector2) -> float:
	var fit := maxf(0.8, minf(win.x / 1280.0, win.y / 800.0))
	return minf(dpi(), fit) * ui_scale
