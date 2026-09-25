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
var challenge := false
var fast_day := false
var servers: Array = []   # [{name, url, token, context}]
var music_volume := 0.5
var sfx_volume := 0.8
var master_volume := 1.0
var muted := false
var click_to_move := true
var touch := "auto"
var intro := true           # opening fly-through when a cluster connects
var show_finished := false   # draw every Completed pod (they can be thousands)   # on-screen touch controls: auto | on | off


func _ready() -> void:
	_migrate_old_name()
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
		challenge = cf.get_value("ui", "challenge", challenge)
		fast_day = cf.get_value("ui", "fast_day", fast_day)
		servers = cf.get_value("servers", "list", servers)
		music_volume = cf.get_value("audio", "music", music_volume)
		sfx_volume = cf.get_value("audio", "sfx", sfx_volume)
		master_volume = cf.get_value("audio", "master", master_volume)
		muted = cf.get_value("audio", "muted", muted)
		click_to_move = cf.get_value("controls", "click_to_move", click_to_move)
		touch = cf.get_value("controls", "touch", touch)
		show_finished = cf.get_value("ui", "show_finished", show_finished)
		intro = cf.get_value("ui", "intro", intro)
	apply_audio()


## Master volume / mute are applied by Sfx to every sound and the music
## (the web build plays audio as browser samples, where the bus volume is
## not reliable). The bus stays at 0 dB.
func apply_audio() -> void:
	AudioServer.set_bus_volume_db(0, 0.0)
	AudioServer.set_bus_mute(0, false)


## Overall gain: master volume, or 0 when muted.
func master_gain() -> float:
	return 0.0 if muted else clampf(master_volume, 0.0, 1.0)


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
	cf.set_value("ui", "challenge", challenge)
	cf.set_value("ui", "fast_day", fast_day)
	cf.set_value("servers", "list", servers)
	cf.set_value("audio", "music", music_volume)
	cf.set_value("audio", "sfx", sfx_volume)
	cf.set_value("audio", "master", master_volume)
	cf.set_value("audio", "muted", muted)
	cf.set_value("controls", "click_to_move", click_to_move)
	cf.set_value("controls", "touch", touch)
	cf.set_value("ui", "show_finished", show_finished)
	cf.set_value("ui", "intro", intro)
	cf.save(PATH)
	apply_audio()
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
func ui_factor(win: Vector2, touch_mode := false) -> float:
	if touch_mode:
		# Phones: about 460 UI units on the short side, so text and buttons
		# are finger-sized whatever the pixel density.
		return clampf(minf(win.x, win.y) / 460.0, 0.8, 5.0) * ui_scale
	var fit := maxf(0.8, minf(win.x / 1280.0, win.y / 800.0))
	return minf(dpi(), fit) * ui_scale


## The project used to be called KubeCraft: native builds kept their settings
## (saved clusters, missions...) in that user folder. Bring them over once.
func _migrate_old_name() -> void:
	if OS.has_feature("web") or FileAccess.file_exists(PATH):
		return
	var old := OS.get_user_data_dir().get_base_dir().path_join("KubeCraft").path_join("settings.cfg")
	if FileAccess.file_exists(old):
		DirAccess.copy_absolute(old, ProjectSettings.globalize_path(PATH))
