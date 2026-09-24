class_name Hud
extends CanvasLayer
## All 2D UI: connect screen, top bar, view menu, legend, inspector with
## cluster actions and their kubectl equivalents, terminal log, logs viewer,
## build menu, confirmations, event feed and floating labels.
##
## Sizes are in UI units; Main scales the whole canvas by Settings.ui_factor().

signal disconnect_requested
signal recenter_requested
signal level_requested(level: String)
signal goto_requested(kind: String, key: String, ns: String)
signal fpv_requested

const BG := Color(0.043, 0.051, 0.102, 0.92)
const PANEL := Color(0.114, 0.169, 0.325, 0.96)
const INK := Color("0b0d1a")

var world: World
var missions: Missions
var chaos := false

const TOP := 88.0  # UI units below the two top strips

var _level_label: Label
var _alarm_btn: Button
var _alarm_panel: PanelContainer
var _alarm_list: VBoxContainer
var _alarms: Array = []
var _mission_panel: PanelContainer
var _mission_title: Label
var _mission_goal: Label
var _mission_learn: Label
var _mission_cmd: RichTextLabel
var _mission_hdr: Label
var _mission_body: VBoxContainer
var _build_svc: CheckBox
var _help: RichTextLabel
var _level_title_raw := ""
var _lang_btns: Array[Button] = []
var _view_run: CheckBox
var _view_minimap: CheckBox
var _view_fpv: CheckBox
var fpv := false
var map_mini: MapView
var stats: StatsPanel
var _perf_label: Label
var _perf_t := 0.0
var _view_stats: CheckBox
var map_full: MapView
var _map_panel: PanelContainer

var _font: FontFile
var _title_font: FontFile
var _theme: Theme

var _connect_root: Control
var _url_edit: LineEdit
var _token_edit: LineEdit
var _connect_status: Label
var _connect_scale: Label

var _game_root: Control
var _ctx_label: Label
var _stats_label: RichTextLabel
var _conn_dot: ColorRect
var _chaos_btn: Button

var _view_panel: PanelContainer
var _view_sys: CheckBox
var _view_lines: CheckBox
var _view_term: CheckBox
var _view_legend: CheckBox
var _view_scale: Label

var _legend: PanelContainer

var _inspector: PanelContainer
var _insp_scroll: ScrollContainer
var _insp_box: VBoxContainer
var _insp_title: Label
var _insp_info: RichTextLabel
var _insp_buttons: HFlowContainer
var _insp_preview: Label
var _insp_cmds: RichTextLabel
var _insp_target: Entity
var _insp_kind := ""
var _insp_key := ""
var _insp_sig := ""
var _insp_t := 0.0

var _feed: VBoxContainer
var _terminal: PanelContainer
var _term_text: RichTextLabel
var _term_input: LineEdit
var _term_history: PackedStringArray = []
var _term_hist_idx := -1
var _help_bar: PanelContainer

var _modal_layer: Control
var _toast: Label
var _toast_t := 0.0

var _logs_panel: PanelContainer
var _logs_text: TextEdit
var _logs_title: Label
var _logs_cmd: Label
var _logs_container: OptionButton
var _logs_prev: CheckBox
var _logs_follow: CheckBox
var _logs_pod: Dictionary = {}
var _logs_t := 0.0

var _confirm_panel: PanelContainer
var _confirm_label: Label
var _confirm_cmd: Label
var _confirm_cb: Callable

var _build_panel: PanelContainer
var _build_ns: LineEdit
var _build_name: LineEdit
var _build_image: LineEdit
var _build_replicas: SpinBox
var _build_cmd: Label

var overlay: LabelOverlay


class LabelOverlay extends Control:
	## items: [{screen: Vector2 (UI units), text, sub, color, big, small?}]
	var items := []
	var font: Font
	var crosshair := false
	const PAD := Vector2(10, 5)

	func _draw() -> void:
		if crosshair:
			var c := (size * 0.5).floor()
			for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
				draw_line(c + d * 5, c + d * 13, Color("0b0d1a"), 5.0)
				draw_line(c + d * 5, c + d * 13, Vox.WHITE, 2.0)
		# Big labels first; each label is nudged upward until it does not
		# overlap one already placed, and sits on a dark plate.
		var placed: Array[Rect2] = []
		var sorted := items.duplicate()
		sorted.sort_custom(func(a, b): return a.big and not b.big)
		for it in sorted:
			var size: int = 23 if it.big else (18 if it.get("small", false) else 21)
			var sub_size := 18
			var sub: String = it.get("sub", "")
			var w := font.get_string_size(it.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
			if sub != "":
				w = maxf(w, font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, sub_size).x)
			var h := font.get_height(size) + (font.get_height(sub_size) if sub != "" else 0.0)
			var r := Rect2(it.screen - Vector2(w * 0.5 + PAD.x, h + PAD.y * 2), Vector2(w + PAD.x * 2, h + PAD.y * 2))
			for _i in 8:
				var hit := false
				for o in placed:
					if o.intersects(r):
						hit = true
						r.position.y = o.position.y - r.size.y - 4
				if not hit:
					break
			placed.append(r)
			draw_rect(r, Color(0.043, 0.051, 0.102, 0.8 if it.big else 0.9))
			draw_rect(Rect2(r.position, Vector2(4, r.size.y)), it.color)
			var y := r.position.y + PAD.y + font.get_ascent(size)
			draw_string(font, Vector2(r.position.x + PAD.x, y), it.text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, it.color)
			if sub != "":
				y += font.get_height(sub_size) + 1
				draw_string(font, Vector2(r.position.x + PAD.x, y), sub, HORIZONTAL_ALIGNMENT_LEFT, -1, sub_size, Vox.SILVER)


func _ready() -> void:
	_font = load("res://assets/fonts/VT323-Regular.ttf")
	_title_font = load("res://assets/fonts/PressStart2P-Regular.ttf")
	for f in [_font, _title_font]:
		f.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		f.hinting = TextServer.HINTING_NONE
		f.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
	_theme = _make_theme()

	overlay = LabelOverlay.new()
	overlay.font = _font
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(overlay)

	_build_game_ui()
	_build_connect_ui()
	_build_modals()
	_sync_view()

	K8s.connection_changed.connect(_on_connection)
	K8s.state_updated.connect(_on_state)
	K8s.cluster_event.connect(add_event)
	K8s.action_started.connect(func(req): _term_cmd(Kubectl.for_action(req)))
	K8s.action_done.connect(func(ok, msg, _req):
		_term_result(ok, msg)
		toast(tr("OK: %s" if ok else "ERROR: %s") % msg, ok))
	Settings.changed.connect(_sync_view)
	I18n.lang_changed.connect(_on_lang_changed)


# ------------------------------------------------------------------ theme

func _flat(bg: Color, border := INK, bw := 3, pad := 10) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_content_margin_all(pad)
	sb.anti_aliasing = false
	return sb


func _btn_box(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := _flat(bg, border, 3, 0)
	sb.content_margin_left = 14
	sb.content_margin_right = 14
	sb.content_margin_top = 2
	sb.content_margin_bottom = 2
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	return sb


func _make_theme() -> Theme:
	var t := Theme.new()
	t.default_font = _font
	t.default_font_size = 22
	t.set_stylebox("panel", "PanelContainer", _flat(PANEL, INK, 3, 16))
	t.set_stylebox("normal", "Button", _btn_box(Color("2d3b73"), INK))
	t.set_stylebox("hover", "Button", _btn_box(Color("3d5ba8"), Vox.BLUE))
	t.set_stylebox("pressed", "Button", _btn_box(Vox.BLUE, Vox.WHITE))
	t.set_stylebox("disabled", "Button", _btn_box(Color("23284a"), INK))
	t.set_stylebox("focus", "Button", StyleBoxEmpty.new())
	t.set_color("font_color", "Button", Vox.WHITE)
	t.set_color("font_hover_color", "Button", Vox.YELLOW)
	t.set_color("font_pressed_color", "Button", Vox.WHITE)
	t.set_color("font_disabled_color", "Button", Vox.SLATE)
	t.set_type_variation("DangerButton", "Button")
	t.set_stylebox("normal", "DangerButton", _btn_box(Color("8a1538"), INK))
	t.set_stylebox("hover", "DangerButton", _btn_box(Vox.RED, Vox.YELLOW))
	t.set_type_variation("GoButton", "Button")
	t.set_stylebox("normal", "GoButton", _btn_box(Color("006b40"), INK))
	t.set_stylebox("hover", "GoButton", _btn_box(Vox.FOREST, Vox.GREEN))
	t.set_stylebox("normal", "OptionButton", _btn_box(Color("2d3b73"), INK))
	t.set_stylebox("hover", "OptionButton", _btn_box(Color("3d5ba8"), Vox.BLUE))
	t.set_stylebox("normal", "LineEdit", _flat(INK, Vox.SLATE, 2, 10))
	t.set_stylebox("focus", "LineEdit", _flat(INK, Vox.BLUE, 2, 10))
	t.set_color("font_color", "LineEdit", Vox.WHITE)
	t.set_color("caret_color", "LineEdit", Vox.YELLOW)
	t.set_stylebox("normal", "TextEdit", _flat(INK, Vox.SLATE, 2, 10))
	t.set_stylebox("read_only", "TextEdit", _flat(INK, Vox.SLATE, 2, 10))
	t.set_color("font_readonly_color", "TextEdit", Vox.WHITE)
	t.set_font_size("font_size", "TextEdit", 21)
	t.set_constant("line_spacing", "TextEdit", 6)
	t.set_color("font_color", "Label", Vox.WHITE)
	t.set_color("font_color", "CheckBox", Vox.WHITE)
	t.set_color("font_hover_color", "CheckBox", Vox.YELLOW)
	t.set_color("font_pressed_color", "CheckBox", Vox.WHITE)
	t.set_constant("line_separation", "RichTextLabel", 4)
	t.set_color("default_color", "RichTextLabel", Vox.WHITE)
	t.set_stylebox("normal", "RichTextLabel", StyleBoxEmpty.new())
	return t


## Sizes in this file were tuned big; FS brings them to a calmer default
## (the player scales everything with the text-size setting anyway).
const FS := 0.85


func _label(text: String, size := 24, color := Vox.WHITE) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", roundi(size * FS))
	l.add_theme_color_override("font_color", color)
	return l


func _rich(size := 24) -> RichTextLabel:
	var r := RichTextLabel.new()
	r.bbcode_enabled = true
	r.fit_content = true
	r.scroll_active = false
	r.add_theme_font_size_override("normal_font_size", roundi(size * FS))
	return r


func _button(text: String, cb: Callable, variation := "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	if variation != "":
		b.theme_type_variation = variation
	b.pressed.connect(cb)
	return b


func _check(text: String, cb: Callable) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.focus_mode = Control.FOCUS_NONE
	c.toggled.connect(func(_on): cb.call())
	return c


func _section(text: String) -> Label:
	return _label(text, 22, Vox.LAVENDER)


func _copy(cmd: String) -> void:
	DisplayServer.clipboard_set(cmd)
	toast(tr("Copied: %s") % cmd.split("\n")[0], true)


# ------------------------------------------------------------ connect UI

func _build_connect_ui() -> void:
	_connect_root = CenterContainer.new()
	_connect_root.theme = _theme
	_connect_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_connect_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_connect_root)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _flat(PANEL, Vox.BLUE, 4, 28))
	_connect_root.add_child(panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	v.custom_minimum_size = Vector2(600, 0)
	panel.add_child(v)
	var title := Label.new()
	title.text = "KUBECRAFT"
	title.add_theme_font_override("font", _title_font)
	title.add_theme_font_size_override("font_size", 40)
	title.add_theme_color_override("font_color", Vox.YELLOW)
	title.add_theme_color_override("font_shadow_color", Vox.PLUM)
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := _label("Your Kubernetes cluster, as a voxel world.", 26, Vox.PEACH)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(sub)
	v.add_child(HSeparator.new())
	v.add_child(_label("k8s-bridge URL", 24, Vox.SILVER))
	_url_edit = LineEdit.new()
	_url_edit.text = K8s.default_bridge_url()
	_url_edit.text_submitted.connect(func(_t): _do_connect())
	v.add_child(_url_edit)
	v.add_child(_label("Token (optional, --token on the bridge)", 24, Vox.SILVER))
	_token_edit = LineEdit.new()
	_token_edit.secret = true
	_token_edit.text = K8s.web_query_param("token")
	_token_edit.text_submitted.connect(func(_t): _do_connect())
	v.add_child(_token_edit)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var c := _button("CONNECT TO CLUSTER", _do_connect, "GoButton")
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(c)
	var d := _button("DEMO MODE", func():
		K8s.start_demo()
		show_connect(false))
	d.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(d)
	v.add_child(h)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 10)
	sh.add_child(_label("Text size", 24, Vox.SILVER))
	sh.add_child(_button(" - ", func(): Settings.step_scale(-1)))
	_connect_scale = _label("", 26, Vox.YELLOW)
	sh.add_child(_connect_scale)
	sh.add_child(_button(" + ", func(): Settings.step_scale(1)))
	v.add_child(sh)
	v.add_child(_lang_row())
	_connect_status = _label("Start the bridge first:  make run-bridge", 24, Vox.SILVER)
	_connect_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_connect_status)


func _lang_row() -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	h.add_child(_label("Language", 24, Vox.SILVER))
	for code in I18n.LANGS:
		var b := _button(I18n.LANGS[code], func(): I18n.set_lang(code))
		b.set_meta("lang", code)
		b.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		_lang_btns.append(b)
		h.add_child(b)
	return h


func _do_connect() -> void:
	K8s.connect_bridge(_url_edit.text, _token_edit.text)
	_connect_status.text = tr("Connecting to %s ...") % K8s.base_url
	_connect_status.add_theme_color_override("font_color", Vox.YELLOW)


func show_connect(v: bool) -> void:
	_connect_root.visible = v
	_game_root.visible = not v
	if v:
		_close_inspector()



func is_connect_visible() -> bool:
	return _connect_root.visible


# --------------------------------------------------------------- game UI

func _build_game_ui() -> void:
	_game_root = Control.new()
	_game_root.theme = _theme
	_game_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_game_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_root.visible = false
	add_child(_game_root)

	# ---- Top bar
	var bar := PanelContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_WIDE)
	bar.add_theme_stylebox_override("panel", _flat(BG, INK, 0, 5))
	_game_root.add_child(bar)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	bar.add_child(h)
	var logo := Label.new()
	logo.text = "KUBECRAFT"
	logo.add_theme_font_override("font", _title_font)
	logo.add_theme_font_size_override("font_size", 16)
	logo.add_theme_color_override("font_color", Vox.YELLOW)
	logo.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(logo)
	_conn_dot = ColorRect.new()
	_conn_dot.custom_minimum_size = Vector2(12, 12)
	_conn_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_conn_dot.color = Vox.SLATE
	h.add_child(_conn_dot)
	_ctx_label = _label("", 26, Vox.PEACH)
	_ctx_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_ctx_label.custom_minimum_size = Vector2(90, 0)
	h.add_child(_ctx_label)
	_stats_label = _rich(26)
	_stats_label.autowrap_mode = TextServer.AUTOWRAP_OFF
	_stats_label.fit_content = false
	_stats_label.clip_contents = true
	_stats_label.custom_minimum_size = Vector2(60, 30)
	_stats_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_stats_label.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_stats_label)
	h.add_child(_button("G LEGEND", toggle_legend))
	h.add_child(_button("B BUILD", open_build, "GoButton"))
	_chaos_btn = _button("C CHAOS", toggle_chaos)
	h.add_child(_chaos_btn)
	h.add_child(_button("V VIEW", toggle_view))
	h.add_child(_button("EXIT", func(): disconnect_requested.emit()))

	# ---- View menu (drops down under the bar)
	_view_panel = PanelContainer.new()
	_view_panel.anchor_left = 1.0
	_view_panel.anchor_right = 1.0
	_view_panel.offset_left = -420
	_view_panel.offset_right = -10
	_view_panel.offset_top = TOP
	_view_panel.visible = false
	_game_root.add_child(_view_panel)
	var vv := VBoxContainer.new()
	vv.add_theme_constant_override("separation", 8)
	_view_panel.add_child(vv)
	vv.add_child(_section("VIEW"))
	_view_sys = _check("System namespaces  [H]", toggle_system)
	vv.add_child(_view_sys)
	_view_lines = _check("All service lines  [K]", toggle_lines)
	vv.add_child(_view_lines)
	_view_term = _check("Terminal panel  [T]", toggle_terminal)
	vv.add_child(_view_term)
	_view_legend = _check("Legend  [G]", toggle_legend)
	vv.add_child(_view_legend)
	var sh := HBoxContainer.new()
	sh.add_theme_constant_override("separation", 10)
	sh.add_child(_label("Text size", 26))
	sh.add_child(_button(" - ", func(): Settings.step_scale(-1)))
	_view_scale = _label("", 26, Vox.YELLOW)
	sh.add_child(_view_scale)
	sh.add_child(_button(" + ", func(): Settings.step_scale(1)))
	vv.add_child(sh)
	vv.add_child(_lang_row())
	_view_run = _check("Always run  [X]", func():
		Settings.always_run = not Settings.always_run
		Settings.save())
	vv.add_child(_view_run)
	_view_minimap = _check("Minimap  [N]", toggle_minimap)
	vv.add_child(_view_minimap)
	_view_fpv = _check("First person view  [P]", func(): fpv_requested.emit())
	vv.add_child(_view_fpv)
	_view_stats = _check("Performance & cluster stats  [F3]", toggle_stats)
	vv.add_child(_view_stats)
	vv.add_child(_button("Recenter camera  [HOME]", func(): recenter_requested.emit()))
	vv.add_child(_button("Restart missions", func():
		missions.restart()
		_mission_panel.visible = true))

	_build_level_strip()
	_build_legend()
	_build_missions_panel()
	stats = StatsPanel.new()
	stats.offset_left = 10
	stats.offset_top = TOP
	stats.visible = false
	stats.add_theme_stylebox_override("panel", _flat(Color(0.02, 0.025, 0.05, 0.9), Vox.LAVENDER.darkened(0.3), 2, 12))
	var st_text := _rich(21)
	st_text.custom_minimum_size = Vector2(390, 0)
	stats.setup(st_text)
	_game_root.add_child(stats)

	# ---- Inspector (scrolls if taller than the space available)
	_inspector = PanelContainer.new()
	_inspector.anchor_left = 1.0
	_inspector.anchor_right = 1.0
	_inspector.offset_top = TOP
	_inspector.offset_right = -10
	_inspector.visible = false
	_game_root.add_child(_inspector)
	_insp_scroll = ScrollContainer.new()
	_insp_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_inspector.add_child(_insp_scroll)
	_insp_box = VBoxContainer.new()
	_insp_box.add_theme_constant_override("separation", 10)
	_insp_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_insp_scroll.add_child(_insp_box)
	var ih := HBoxContainer.new()
	_insp_box.add_child(ih)
	_insp_title = _label("", 28, Vox.YELLOW)
	_insp_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_insp_title.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	ih.add_child(_insp_title)
	ih.add_child(_button("X", _close_inspector))
	_insp_info = _rich(24)
	_insp_info.selection_enabled = true
	_insp_info.add_theme_constant_override("line_separation", 6)
	_insp_box.add_child(_insp_info)
	_insp_box.add_child(_section("ACTIONS"))
	_insp_buttons = HFlowContainer.new()
	_insp_buttons.add_theme_constant_override("h_separation", 8)
	_insp_buttons.add_theme_constant_override("v_separation", 8)
	_insp_box.add_child(_insp_buttons)
	_insp_preview = _label("hover an action to see its kubectl command", 22, Vox.SLATE)
	_insp_preview.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_insp_box.add_child(_insp_preview)
	_insp_box.add_child(_section("SAME THING WITH KUBECTL  (click to copy)"))
	_insp_cmds = _rich(22)
	_insp_cmds.meta_clicked.connect(func(m): _copy(str(m)))
	_insp_cmds.meta_underlined = false
	_insp_box.add_child(_insp_cmds)

	# ---- Help bar
	_help_bar = PanelContainer.new()
	_help_bar.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_help_bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_help_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_bar.add_theme_stylebox_override("panel", _flat(BG, INK, 0, 6))
	_game_root.add_child(_help_bar)
	_help = _rich(22)
	_help.autowrap_mode = TextServer.AUTOWRAP_WORD
	_help.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_help_bar.add_child(_help)
	_fill_help()

	# ---- Event feed (bottom-left) and terminal (bottom-right)
	_feed = VBoxContainer.new()
	_feed.anchor_top = 1.0
	_feed.anchor_bottom = 1.0
	_feed.anchor_right = 0.5
	_feed.offset_left = 10
	_feed.offset_right = -6
	_feed.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 4)
	_feed.visible = false
	_game_root.add_child(_feed)

	_terminal = PanelContainer.new()
	_terminal.anchor_left = 0.5
	_terminal.anchor_right = 1.0
	_terminal.anchor_top = 1.0
	_terminal.anchor_bottom = 1.0
	_terminal.offset_left = 6
	_terminal.offset_right = -10
	_terminal.grow_vertical = Control.GROW_DIRECTION_BEGIN
	_terminal.add_theme_stylebox_override("panel", _flat(Color(0.02, 0.025, 0.05, 0.94), Vox.SLATE, 2, 10))
	_game_root.add_child(_terminal)
	var tv := VBoxContainer.new()
	tv.add_theme_constant_override("separation", 6)
	_terminal.add_child(tv)
	var th := HBoxContainer.new()
	tv.add_child(th)
	var tl := _label("TERMINAL - type kubectl commands, see what the game ran", 22, Vox.LAVENDER)
	tl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	tl.clip_text = true
	th.add_child(tl)
	th.add_child(_button("T HIDE", toggle_terminal))
	_term_text = _rich(20)
	_term_text.fit_content = false
	_term_text.scroll_active = true
	_term_text.scroll_following = true
	_term_text.custom_minimum_size = Vector2(0, 120)
	_term_text.selection_enabled = true
	_term_text.meta_underlined = false
	_term_text.meta_clicked.connect(func(m): _term_fill(str(m)))
	# Minimap (bottom-left)
	var mm := PanelContainer.new()
	mm.anchor_top = 1.0
	mm.anchor_bottom = 1.0
	mm.offset_left = 10
	mm.clip_contents = true
	mm.name = "Minimap"
	mm.add_theme_stylebox_override("panel", _flat(Color("0e1224"), Vox.SLATE, 2, 0))
	_game_root.add_child(mm)
	var mmv := VBoxContainer.new()
	mmv.add_theme_constant_override("separation", 0)
	mm.add_child(mmv)
	var mmh := HBoxContainer.new()
	mmh.add_theme_constant_override("separation", 2)
	mmv.add_child(mmh)
	var mml := _label("N", 18, Vox.SLATE)
	mml.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mmh.add_child(mml)
	for b in [["-", func(): _minimap_size(-1)], ["+", func(): _minimap_size(1)], ["x", toggle_minimap]]:
		var btn := _button(b[0], b[1])
		btn.add_theme_font_size_override("font_size", 16)
		btn.custom_minimum_size = Vector2(22, 0)
		mmh.add_child(btn)
	map_mini = MapView.new()
	map_mini.font = _font
	map_mini.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	map_mini.clip_contents = true
	map_mini.open_full.connect(toggle_map)
	mmv.add_child(map_mini)
	_minimap_size(0)

	_term_text.append_text("[color=#5f574f]%s[/color]\n" % tr("# every action you take in the world is a real kubectl call.\n# click a command to copy it."))
	tv.add_child(_term_text)
	var tin := HBoxContainer.new()
	tin.add_theme_constant_override("separation", 6)
	tv.add_child(tin)
	tin.add_child(_label("$ kubectl", 24, Vox.YELLOW))
	_term_input = LineEdit.new()
	_term_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_term_input.placeholder_text = tr("type a command, e.g. get pods -A   (/ to focus)")
	_term_input.add_theme_stylebox_override("normal", _flat(Color("05060c"), Vox.SLATE, 1, 6))
	_term_input.add_theme_stylebox_override("focus", _flat(Color("05060c"), Vox.YELLOW, 2, 6))
	_term_input.text_submitted.connect(_term_submit)
	_term_input.gui_input.connect(_term_keys)
	tin.add_child(_term_input)


func _build_level_strip() -> void:
	var strip := PanelContainer.new()
	strip.set_anchors_preset(Control.PRESET_TOP_WIDE)
	strip.offset_top = 42
	strip.add_theme_stylebox_override("panel", _flat(Color(0.07, 0.09, 0.18, 0.9), INK, 0, 4))
	_game_root.add_child(strip)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	strip.add_child(h)
	h.add_child(_button("PLANT", func(): level_requested.emit("plant")))
	h.add_child(_button("ENERGY (nodes)", func(): level_requested.emit("power")))
	_level_label = _label("", 26, Vox.YELLOW)
	_level_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_label.clip_text = true
	h.add_child(_level_label)
	_perf_label = _label("", 20, Vox.SILVER)
	_perf_label.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	h.add_child(_perf_label)
	h.add_child(_button("F3 STATS", toggle_stats))
	h.add_child(_button("M MAP", toggle_map))
	h.add_child(_button("J MISSIONS", toggle_missions, "GoButton"))
	_alarm_btn = _button("ALARMS 0", toggle_alarms)
	h.add_child(_alarm_btn)
	# Alarm dropdown
	_alarm_panel = PanelContainer.new()
	_alarm_panel.anchor_left = 1.0
	_alarm_panel.anchor_right = 1.0
	_alarm_panel.offset_left = -560
	_alarm_panel.offset_right = -10
	_alarm_panel.offset_top = TOP
	_alarm_panel.visible = false
	_game_root.add_child(_alarm_panel)
	var av := VBoxContainer.new()
	av.add_theme_constant_override("separation", 6)
	_alarm_panel.add_child(av)
	av.add_child(_section("ALARMS - live problems in the cluster (click to go there)"))
	_alarm_list = VBoxContainer.new()
	_alarm_list.add_theme_constant_override("separation", 4)
	av.add_child(_alarm_list)


func set_level_title(t: String) -> void:
	_level_label.text = "  >  " + t
	_level_title_raw = t


func toggle_alarms() -> void:
	_alarm_panel.visible = not _alarm_panel.visible
	if _alarm_panel.visible:
		_view_panel.visible = false
		_fill_alarms()


func _compute_alarms(s: Dictionary) -> Array:
	var out := []
	for n in s.get("nodes", []):
		if not n.ready:
			out.append({"sev": 3, "text": tr("node %s is NotReady") % n.name, "kind": "node", "key": n.name, "ns": ""})
		elif n.unschedulable:
			out.append({"sev": 1, "text": tr("node %s is cordoned") % n.name, "kind": "node", "key": n.name, "ns": ""})
	for p in s.get("pods", []):
		var cat := PodBot.categorize(p)
		if cat in ["crash", "pull", "failed"]:
			out.append({"sev": 3, "text": tr("%s/%s  %s (restarts %d)") % [p.ns, p.name, p.status, int(p.restarts)], "kind": "pod", "key": p.ns + "/" + p.name, "ns": p.ns})
		elif cat == "pending" and int(p.get("age", 0)) > 60:
			out.append({"sev": 2, "text": tr("%s/%s  stuck in %s") % [p.ns, p.name, p.status], "kind": "pod", "key": p.ns + "/" + p.name, "ns": p.ns})
	for w in s.get("workloads", []):
		if int(w.ready) < int(w.desired):
			out.append({"sev": 1, "text": tr("%s %s/%s  %d/%d ready") % [str(w.kind).to_lower(), w.ns, w.name, int(w.ready), int(w.desired)], "kind": "workload", "key": "%s/%s/%s" % [w.ns, w.kind, w.name], "ns": w.ns})
	out.sort_custom(func(a, b): return a.sev > b.sev)
	return out


func _fill_alarms() -> void:
	for c in _alarm_list.get_children():
		c.queue_free()
	if _alarms.is_empty():
		_alarm_list.add_child(_label("All good: nothing failing.", 24, Vox.GREEN))
		return
	for a in _alarms.slice(0, 10):
		var b := _button(a.text, func(): goto_requested.emit(a.kind, a.key, a.ns), "DangerButton" if a.sev >= 3 else "")
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		b.custom_minimum_size = Vector2(500, 0)
		_alarm_list.add_child(b)
	if _alarms.size() > 10:
		_alarm_list.add_child(_label(tr("... and %d more") % (_alarms.size() - 10), 22, Vox.SILVER))


func _build_missions_panel() -> void:
	_mission_panel = PanelContainer.new()
	_mission_panel.offset_left = 10
	_mission_panel.offset_top = TOP
	_mission_panel.add_theme_stylebox_override("panel", _flat(Color(0.05, 0.12, 0.1, 0.94), Vox.GREEN.darkened(0.3), 3, 14))
	_game_root.add_child(_mission_panel)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.custom_minimum_size = Vector2(380, 0)
	_mission_panel.add_child(v)
	var h := HBoxContainer.new()
	v.add_child(h)
	_mission_hdr = _label("", 22, Vox.GREEN)
	_mission_hdr.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(_mission_hdr)
	h.add_child(_button("WHY?", _toggle_mission_why))
	h.add_child(_button("SKIP", func(): missions.skip()))
	h.add_child(_button("_", toggle_missions))
	_mission_body = VBoxContainer.new()
	_mission_body.add_theme_constant_override("separation", 6)
	v.add_child(_mission_body)
	_mission_title = _label("", 26, Vox.YELLOW)
	_mission_body.add_child(_mission_title)
	_mission_goal = _label("", 24)
	_mission_goal.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mission_body.add_child(_mission_goal)
	_mission_learn = _label("", 22, Vox.PEACH)
	_mission_learn.visible = false
	_mission_learn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mission_body.add_child(_mission_learn)
	_mission_cmd = _rich(22)
	_mission_cmd.visible = false
	_mission_cmd.meta_underlined = false
	_mission_cmd.meta_clicked.connect(func(m): _copy(str(m)))
	_mission_body.add_child(_mission_cmd)


func _toggle_mission_why() -> void:
	_mission_learn.visible = not _mission_learn.visible
	_mission_cmd.visible = _mission_learn.visible


func refresh_missions() -> void:
	if missions == null:
		return
	if missions.all_done():
		_mission_hdr.text = tr("MISSIONS COMPLETE")
		_mission_title.text = tr("Certified plant!")
		_mission_goal.text = tr("You completed every mission. You now know your way around a Kubernetes cluster.")
		_mission_learn.text = tr("To replay them: VIEW > Restart missions.")
		_mission_cmd.text = ""
		return
	var m := missions.current()
	_mission_hdr.text = tr("MISSION %d / %d") % [missions.index() + 1, Missions.LIST.size()]
	_mission_title.text = tr(m.title)
	_mission_goal.text = tr(m.goal)
	_mission_learn.text = tr(m.learn)
	_mission_cmd.text = "[color=#ffec27]$[/color] [url=%s]%s[/url]" % [m.cmd, m.cmd]


func toggle_missions() -> void:
	_mission_panel.visible = not _mission_panel.visible
	if _mission_panel.visible:
		_legend.visible = false
	_sync_view()


func _fill_help() -> void:
	var keys := [["WASD", "walk"], ["SHIFT/X", "run"], ["SPACE", "jump"], ["P", "first person"], ["E", "enter/use"], ["DRAG", "camera"],
		["TAB", "next problem"], ["M", "map"], ["J", "missions"], ["G", "legend + all keys"]]
	_help.text = "   ".join(keys.map(func(k): return "[color=#ffec27]%s[/color] [color=#c2c3c7]%s[/color]" % [tr(k[0]), tr(k[1])]))


## Re-translate everything built from formatted strings.
func _on_lang_changed() -> void:
	_fill_help()
	refresh_missions()
	_update_chaos_btn()
	if not K8s.state.is_empty():
		_on_state(K8s.state)
	if world:
		set_level_title(world.level_title())
	_insp_sig = ""
	_refresh_inspector()
	_sync_view()


func _build_legend() -> void:
	_legend = PanelContainer.new()
	_legend.offset_left = 10
	_legend.offset_top = TOP
	_legend.visible = false
	_game_root.add_child(_legend)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.name = "Scroll"
	_legend.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)
	var hh := HBoxContainer.new()
	var t := _label("WHAT AM I LOOKING AT?", 26, Vox.YELLOW)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hh.add_child(t)
	hh.add_child(_button("X", toggle_legend))
	v.add_child(hh)
	var rows := [
		["h", "LEVELS (E at a door, or double-click)"],
		[Vox.SILVER, "PLANT: each factory hall = a Namespace"],
		[Vox.GREEN, "  lit windows = pods (green ok, red failing)"],
		[Vox.RED, "  roof light = worst status, red smoke = crashes"],
		[Vox.YELLOW, "ENERGY PLANT = the Nodes (real machines)"],
		[Vox.BLUE, "HALL: inside a namespace"],
		["h", "INSIDE A HALL"],
		[Vox.GREEN, "Assembly line = Deployment/StatefulSet/DaemonSet\n  console lamps = replicas (green = ready)"],
		[Vox.PINK, "Robot at a station = a Pod\n  one body block per container"],
		[Vox.BLUE, "Loading dock = Service. Color = type: blue\n  ClusterIP, orange NodePort, pink LoadBalancer"],
		[Vox.WHITE, "Line dock -> robot = Service sends traffic\n  there; white dashes = direction"],
		["h", "ROBOT GEM = POD STATUS"],
		[Vox.GREEN, "Running and ready"],
		[Vox.YELLOW, "Running but NOT ready"],
		[Vox.BLUE, "Pending / creating container"],
		[Vox.RED, "Crashing (CrashLoopBackOff, Error), smokes"],
		[Vox.PINK, "Image cannot be pulled"],
		[Vox.SLATE, "Terminating / completed"],
		["h", "ENERGY ROOM"],
		[Vox.GREEN, "Island = Node, castle = control-plane"],
		[Vox.YELLOW, "Fence = cordoned, red light = NotReady"],
		[Vox.WHITE, "Cloud = pods waiting for the scheduler"],
		["h", "KEYS"],
		[Vox.LAVENDER, "WASD walk, SHIFT (hold) or X (toggle) run, SPACE jump\nE enter/use/inspect, P first person, DRAG pan, RIGHT-DRAG rotate\nQ/R rotate 90, WHEEL zoom, M map, N minimap, J missions\nTAB next problem, L logs, B build, H system ns\nK all lines, T terminal, V view menu, C chaos + F blaster\nBACKSPACE plant, HOME recenter"],
	]
	for r in rows:
		if typeof(r[0]) == TYPE_STRING:
			var s := _section(r[1])
			s.add_theme_color_override("font_color", Vox.LAVENDER)
			v.add_child(s)
			continue
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 10)
		var sw := ColorRect.new()
		sw.color = r[0]
		sw.custom_minimum_size = Vector2(16, 16)
		sw.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var swm := MarginContainer.new()
		swm.add_theme_constant_override("margin_top", 5)
		swm.add_child(sw)
		row.add_child(swm)
		row.add_child(_label(r[1], 23))
		v.add_child(row)


func _sync_view() -> void:
	var pct := "%d%%" % roundi(Settings.ui_scale * 100)
	if _view_scale:
		_view_scale.text = pct
	if _connect_scale:
		_connect_scale.text = pct
	if world:
		world.lines_all = Settings.lines_all
		_view_sys.set_pressed_no_signal(not world.hide_system)
	_view_lines.set_pressed_no_signal(Settings.lines_all)
	_view_term.set_pressed_no_signal(Settings.terminal)
	_view_legend.set_pressed_no_signal(_legend.visible)
	_terminal.visible = Settings.terminal
	_view_run.set_pressed_no_signal(Settings.always_run)
	_view_minimap.set_pressed_no_signal(Settings.minimap)
	_view_fpv.set_pressed_no_signal(fpv)
	_view_stats.set_pressed_no_signal(stats.visible)
	if map_mini:
		map_mini.get_parent().visible = Settings.minimap and not stats.visible
	for b in _lang_btns:
		b.theme_type_variation = "GoButton" if b.get_meta("lang") == Settings.lang else ""


func toggle_view() -> void:
	_view_panel.visible = not _view_panel.visible
	_alarm_panel.visible = false
	_sync_view()


func toggle_legend() -> void:
	_legend.visible = not _legend.visible
	if _legend.visible:
		_mission_panel.visible = false
	_sync_view()


func toggle_lines() -> void:
	Settings.lines_all = not Settings.lines_all
	Settings.save()
	toast(tr("Service lines: ALL" if Settings.lines_all else "Service lines: only for what you hover/select"), true)


func toggle_terminal() -> void:
	Settings.terminal = not Settings.terminal
	Settings.save()


func toggle_system() -> void:
	world.hide_system = not world.hide_system
	if not K8s.state.is_empty():
		world.apply_state(K8s.state)
	_sync_view()


func toggle_chaos() -> void:
	if chaos:
		chaos = false
		_update_chaos_btn()
		return
	confirm(tr("CHAOS MODE: the blaster (F) will delete REAL pods in context \"%s\" without asking. Enable?") % K8s.state.get("context", "?"),
		_enable_chaos, tr("kubectl delete pod <the pod you shoot>"))


func _enable_chaos() -> void:
	chaos = true
	_update_chaos_btn()


func _update_chaos_btn() -> void:
	_chaos_btn.text = tr("C CHAOS ON") if chaos else tr("C CHAOS")
	_chaos_btn.theme_type_variation = "DangerButton" if chaos else ""


func _on_connection(status: String, detail: String) -> void:
	match status:
		"online":
			_conn_dot.color = Vox.GREEN
			if _connect_root.visible:
				show_connect(false)
			toast(tr("Connected: %s") % detail, true)
		"connecting":
			_conn_dot.color = Vox.YELLOW
		_:
			_conn_dot.color = Vox.RED
			if _connect_root.visible:
				_connect_status.text = detail
				_connect_status.add_theme_color_override("font_color", Vox.RED)
			else:
				toast(detail, false)


func _on_state(s: Dictionary) -> void:
	_ctx_label.text = "%s%s" % [s.get("context", "?"), tr(" (read-only)") if s.get("readonly", false) else ""]
	var running := 0
	var pending := 0
	var bad := 0
	for p in s.pods:
		match PodBot.categorize(p):
			"ok": running += 1
			"pending", "warn": pending += 1
			"crash", "pull", "failed": bad += 1
	_alarms = _compute_alarms(s)
	_alarm_btn.text = tr("ALARMS %d") % _alarms.size()
	_alarm_btn.theme_type_variation = "DangerButton" if _alarms.any(func(a): return a.sev >= 3) else ""
	if _alarm_panel.visible:
		_fill_alarms()
	var ready_nodes: int = s.nodes.filter(func(n): return n.ready).size()
	_stats_label.text = "[color=#c2c3c7]%s[/color] %d/%d  [color=#c2c3c7]%s[/color] [color=#00e436]%d %s[/color] [color=#ffec27]%d %s[/color] [color=#ff004d]%d %s[/color]" % [
		tr("nodes"), ready_nodes, s.nodes.size(), tr("pods"), running, tr("ok"), pending, tr("wait"), bad, tr("bad")]


func add_event(ev: Dictionary) -> void:
	var warn: bool = ev.get("etype", "") == "Warning"
	_term_text.append_text("[color=%s]  %s %s %s/%s: %s[/color]\n" % ["#ff4d6d" if warn else "#6f7690", tr("event"), ev.get("reason", ""),
		str(ev.get("kind", "")).to_lower(), ev.get("name", ""), str(ev.get("message", "")).replace("[", "(")])
	if not _feed.visible:
		return
	var l := _label("%s %s/%s: %s" % [ev.get("reason", ""), str(ev.get("kind", "")).to_lower(), ev.get("name", ""), ev.get("message", "")], 22, Vox.RED if warn else Vox.SILVER)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.custom_minimum_size = Vector2(40, 0)
	var plate := _flat(Color(0.043, 0.051, 0.102, 0.85), Vox.RED if warn else Vox.SLATE, 0, 0)
	plate.border_width_left = 4
	plate.content_margin_left = 10
	plate.content_margin_right = 10
	plate.content_margin_top = 2
	plate.content_margin_bottom = 2
	l.add_theme_stylebox_override("normal", plate)
	l.set_meta("t", 9.0)
	_feed.add_child(l)
	while _feed.get_child_count() > 5:
		var old := _feed.get_child(0)
		_feed.remove_child(old)
		old.queue_free()


func toast(msg: String, ok := true) -> void:
	_toast.text = msg
	_toast.add_theme_color_override("font_color", Vox.GREEN if ok else Vox.RED)
	_toast.visible = true
	_toast_t = 4.0


# -------------------------------------------------------------- terminal

## Clicking a command anywhere puts it in the terminal input, ready to run.
func _term_fill(cmd: String) -> void:
	DisplayServer.clipboard_set(cmd)
	if not Settings.terminal:
		toggle_terminal()
	_term_input.text = cmd.trim_prefix("kubectl ").split("\n")[0]
	_term_input.grab_focus()
	_term_input.caret_column = _term_input.text.length()


func focus_terminal() -> void:
	if not Settings.terminal:
		toggle_terminal()
	_term_input.grab_focus()


func _term_keys(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed):
		return
	match ev.keycode:
		KEY_UP:
			if _term_history.is_empty():
				return
			_term_hist_idx = clampi(_term_hist_idx - 1 if _term_hist_idx >= 0 else _term_history.size() - 1, 0, _term_history.size() - 1)
			_term_input.text = _term_history[_term_hist_idx]
			_term_input.caret_column = _term_input.text.length()
			_term_input.accept_event()
		KEY_DOWN:
			if _term_hist_idx < 0:
				return
			_term_hist_idx += 1
			if _term_hist_idx >= _term_history.size():
				_term_hist_idx = -1
				_term_input.text = ""
			else:
				_term_input.text = _term_history[_term_hist_idx]
			_term_input.accept_event()
		KEY_ESCAPE:
			_term_input.release_focus()
			_term_input.accept_event()


func _term_submit(line: String) -> void:
	line = line.strip_edges().trim_prefix("kubectl ").strip_edges()
	_term_input.text = ""
	_term_hist_idx = -1
	if line == "":
		return
	if line == "clear":
		_term_text.clear()
		return
	if _term_history.is_empty() or _term_history[-1] != line:
		_term_history.append(line)
	_term_text.append_text("[color=#ffec27]$[/color] [color=#fff1e8]kubectl %s[/color]\n" % _esc(line))
	K8s.run_kubectl(line, func(ok: bool, out: String):
		_term_text.append_text("[color=%s]%s[/color]\n" % ["#c2c3c7" if ok else "#ff4d6d", _esc(out.strip_edges())])
		if ok and missions:
			var req := Kubectl.to_action(line)
			if not req.is_empty():
				missions.notify("action", req, true))


func _esc(t: String) -> String:
	return t.replace("[", "[lb]")


func _term_cmd(cmd: String) -> void:
	for line in cmd.split("\n"):
		_term_text.append_text("[color=#ffec27]$[/color] [url=%s]%s[/url]\n" % [line.split("  #")[0], line])


func _term_result(ok: bool, msg: String) -> void:
	_term_text.append_text("[color=%s]  %s[/color]\n" % ["#00e436" if ok else "#ff004d", msg])


# ------------------------------------------------------------- inspector

func inspect(e: Entity) -> void:
	if e == null:
		_close_inspector()
		return
	_insp_target = e
	_insp_kind = e.kind
	_insp_key = e.key
	_insp_sig = ""
	_inspector.visible = true
	world.selected = e
	if missions:
		missions.notify("inspect", e.kind, e.data)
	_insp_preview.text = tr("hover an action to see its kubectl command")
	_insp_preview.add_theme_color_override("font_color", Vox.SLATE)
	_refresh_inspector()


func inspected() -> Entity:
	return _insp_target if _inspector.visible and is_instance_valid(_insp_target) else null


func _close_inspector() -> void:
	_inspector.visible = false
	_insp_target = null
	if world:
		world.selected = null


func _find_workload(ns: String, kind: String, name: String) -> Dictionary:
	for w in K8s.state.get("workloads", []):
		if w.ns == ns and w.kind == kind and w.name == name:
			return w
	return {}


func _kv(k: String, v: String) -> String:
	return "[color=#c2c3c7]%s[/color] %s" % [tr(k).rpad(11), v]


func _refresh_inspector() -> void:
	if not _inspector.visible:
		return
	if not is_instance_valid(_insp_target) or (_insp_target is PodBot and _insp_target.dying):
		var again := world.find_entity(_insp_kind, _insp_key)
		if again:
			_insp_target = again
			world.selected = again
		else:
			_insp_title.text = tr("(gone) %s") % _insp_key
			_insp_info.text = "[color=#83769c]%s[/color]" % tr("This object no longer exists in the cluster.")
			_insp_cmds.text = ""
			_set_buttons([])
			_insp_sig = ""
			return
	var d := _insp_target.data
	var ro := K8s.is_readonly()
	var lines := []
	var buttons := []   # [text, callable, variation, disabled, kubectl]
	match _insp_kind:
		"pod":
			var cat := PodBot.categorize(d)
			_insp_title.text = tr("POD %s") % d.name
			lines.append(_kv("namespace", d.ns))
			lines.append(_kv("status", "[color=#%s]%s[/color]" % [PodBot.category_color(cat).to_html(false), d.status]))
			lines.append(_kv("ready", tr("%d/%d containers   restarts %d") % [int(d.ready), int(d.total), int(d.restarts)]))
			lines.append(_kv("node", d.node if d.node != "" else "[color=#ffec27]%s[/color]" % tr("(not scheduled yet)")))
			lines.append(_kv("ip", d.get("ip", "")))
			lines.append(_kv("age", _age(d.get("age", 0))))
			if d.get("owner_kind", "") != "":
				lines.append(_kv("owner", "%s %s" % [str(d.owner_kind).to_lower(), d.owner_name]))
			var imgs = d.get("images", [])
			for i in (imgs if imgs != null else []).size():
				lines.append(_kv("container", "%s [color=#83769c]%s[/color]" % [d.containers[i], imgs[i]]))
			var svcs := []
			for sv in K8s.state.get("services", []):
				if sv.ns == d.ns and sv.get("pods") != null and d.name in sv.pods:
					svcs.append(sv.name)
			lines.append(_kv("services", ", ".join(svcs) if svcs else "[color=#5f574f]%s[/color]" % tr("none route traffic here")))
			var usage := _usage_lines([d])
			for i in usage.size():
				lines.insert(3 + i, usage[i])
			buttons.append(["LOGS [L]", func(): open_logs(d), "", false, Kubectl.logs(d.ns, d.name, "", false, true)])
			var del := {"action": "delete_pod", "ns": d.ns, "name": d.name}
			buttons.append(["DELETE POD", func(): _delete_pod(d), "DangerButton", ro, Kubectl.for_action(del)])
			var ok: String = d.get("owner_kind", "")
			if ok in ["Deployment", "StatefulSet", "DaemonSet"]:
				var w := _find_workload(d.ns, ok, d.owner_name)
				if not w.is_empty():
					buttons.append_array(_workload_buttons(w, ro))
					buttons.append(["GO TO OWNER", func(): inspect(world.find_entity("workload", "%s/%s/%s" % [w.ns, w.kind, w.name])), "", false, ""])
		"workload":
			_insp_title.text = str(d.kind).to_upper() + " " + d.name
			lines.append(_kv("namespace", d.ns))
			lines.append(_kv("replicas", tr("%d wanted, [color=#00e436]%d ready[/color]") % [int(d.desired), int(d.ready)]))
			lines.append(_kv("", tr("%d up-to-date, %d available") % [int(d.updated), int(d.available)]))
			lines.append(_kv("image", "[color=#83769c]%s[/color]" % d.get("image", "")))
			lines.append_array(_usage_lines(K8s.state.get("pods", []).filter(func(p): return p.ns == d.ns and p.get("owner_kind") == d.kind and p.get("owner_name") == d.name)))
			buttons.append_array(_workload_buttons(d, ro))
			var req := {"action": "delete_workload", "kind": d.kind, "ns": d.ns, "name": d.name}
			buttons.append(["DELETE", func(): _delete_workload(d), "DangerButton", ro, Kubectl.for_action(req)])
		"service":
			_insp_title.text = tr("SERVICE %s") % d.name
			lines.append(_kv("namespace", d.ns))
			lines.append(_kv("type", "[color=#%s]%s[/color]" % [ServicePortal.type_color(d).to_html(false), d.type]))
			lines.append(_kv("clusterIP", d.get("cluster_ip", "")))
			lines.append(_kv("ports", ", ".join(d.get("ports", []) if d.get("ports") != null else [])))
			var sel = d.get("selector", {})
			var parts := []
			if sel != null:
				for k in sel:
					parts.append("%s=%s" % [k, sel[k]])
			lines.append(_kv("selector", ", ".join(parts) if parts else tr("(none)")))
			var backs: Array = _insp_target.backends()
			lines.append(_kv("endpoints", tr("%d pods get its traffic (the lines)") % backs.size()))
			for pn in backs.slice(0, 8):
				lines.append("             - " + pn)
		"namespace":
			var st: Dictionary = _insp_target.stats
			if _insp_target.is_power:
				_insp_title.text = tr("ENERGY PLANT")
				lines.append(tr("Here live the [color=#ffec27]nodes[/color]: the real machines"))
				lines.append(tr("that run the pods."))
				lines.append(_kv("nodes", tr("%d (%d ready)") % [st.get("nodes", 0), st.get("ready", 0)]))
				buttons.append(["ENTER [E]", func(): level_requested.emit("power"), "GoButton", false, "kubectl get nodes -o wide"])
			else:
				_insp_title.text = tr("NAMESPACE %s") % d.name
				lines.append(_kv("pods", tr("%d  ([color=#00e436]%d ok[/color], [color=#ffec27]%d waiting[/color], [color=#ff004d]%d failing[/color])") % [st.pods, st.ok, st.wait, st.bad]))
				lines.append(_kv("workloads", tr("%d assembly lines") % st.workloads))
				lines.append(_kv("services", tr("%d loading docks") % st.services))
				lines.append_array(_usage_lines(K8s.state.get("pods", []).filter(func(p): return p.ns == d.name)))
				lines.append("[color=#83769c]%s[/color]" % tr("windows = pods (green ok, red failing)"))
				lines.append("[color=#83769c]%s[/color]" % tr("roof light = worst status inside"))
				buttons.append(["ENTER HALL [E]", func(): level_requested.emit("ns:" + d.name), "GoButton", false, "kubectl -n %s get all" % d.name])
		"node":
			_insp_title.text = tr("NODE %s") % d.name
			lines.append(_kv("status", ("[color=#00e436]Ready[/color]" if d.ready else "[color=#ff004d]NotReady[/color]") + ("  [color=#ffec27]%s[/color]" % tr("cordoned") if d.unschedulable else "")))
			lines.append(_kv("roles", ", ".join(d.roles) if d.roles else "worker"))
			lines.append(_kv("capacity", "%s cpu, %s mem" % [d.cpu, d.memory]))
			lines.append(_kv("max pods", str(int(d.pod_capacity))))
			lines.append_array(_node_usage_lines(d))
			lines.append(_kv("kubelet", "%s %s/%s" % [d.kubelet, d.os, d.arch]))
			lines.append(_kv("pods here", str(_insp_target.slots.size())))
			lines.append(_kv("age", _age(d.get("age", 0))))
			if d.unschedulable:
				var req := {"action": "uncordon", "name": d.name}
				buttons.append(["UNCORDON", func(): K8s.action(req), "GoButton", ro, Kubectl.for_action(req)])
			else:
				var req := {"action": "cordon", "name": d.name}
				buttons.append(["CORDON", func(): _cordon(d), "DangerButton", ro, Kubectl.for_action(req)])
	_insp_info.text = "\n".join(lines)
	var sig := str(buttons.map(func(b): return [b[0], b[3], b[4]])) + _insp_key
	if sig != _insp_sig:
		_insp_sig = sig
		_set_buttons(buttons)
		var cmds := []
		for c in Kubectl.for_view(_insp_kind, d):
			cmds.append("[color=#83769c]# %s[/color]\n[color=#ffec27]$[/color] [url=%s]%s[/url]" % [tr(c[0]), c[1], c[1]])
		_insp_cmds.text = "\n".join(cmds)


## CPU/memory of a set of pods: live usage from metrics-server (if any)
## next to what they requested.
func _usage_lines(pod_list: Array) -> Array:
	var m = K8s.state.get("metrics", {})
	var live: bool = m != null and m.get("available", false)
	var cpu := 0.0
	var mem := 0.0
	var rcpu := 0.0
	var rmem := 0.0
	var seen := 0
	for p in pod_list:
		rcpu += float(p.get("cpu_req_m", 0))
		rmem += float(p.get("mem_req", 0))
		if live and m.pods.has(p.ns + "/" + p.name):
			seen += 1
			cpu += float(m.pods[p.ns + "/" + p.name].cpu_m)
			mem += float(m.pods[p.ns + "/" + p.name].mem_bytes)
	var out := []
	if live and seen > 0:
		out.append(_kv("cpu", "%s  %s" % [StatsPanel.cores(cpu), ("[color=#5f574f](req %s)[/color]" % StatsPanel.cores(rcpu)) if rcpu > 0 else ""]))
		if rcpu > 0:
			out.append(_kv("", StatsPanel.bar(cpu / rcpu, 12) + " [color=#5f574f]%s[/color]" % tr("of request")))
		out.append(_kv("memory", "%s  %s" % [StatsPanel.mib(mem), ("[color=#5f574f](req %s)[/color]" % StatsPanel.mib(rmem)) if rmem > 0 else ""]))
		if rmem > 0:
			out.append(_kv("", StatsPanel.bar(mem / rmem, 12) + " [color=#5f574f]%s[/color]" % tr("of request")))
	elif rcpu > 0 or rmem > 0:
		out.append(_kv("requests", "cpu %s, mem %s" % [StatsPanel.cores(rcpu), StatsPanel.mib(rmem)]))
	if not live:
		out.append("[color=#5f574f]%s[/color]" % tr("no live usage: metrics-server not installed"))
	elif seen == 0 and not pod_list.is_empty():
		out.append("[color=#5f574f]%s[/color]" % tr("no metrics yet (they refresh every 15 s)"))
	return out


func _node_usage_lines(n: Dictionary) -> Array:
	var m = K8s.state.get("metrics", {})
	var out := []
	var cap_cpu := float(n.get("cpu_m", 0))
	var cap_mem := float(n.get("mem_bytes", 0))
	var cpu := 0.0
	var mem := 0.0
	var label := "live"
	if m != null and m.get("available", false) and m.nodes.has(n.name):
		cpu = float(m.nodes[n.name].cpu_m)
		mem = float(m.nodes[n.name].mem_bytes)
	else:
		label = "requested"
		for p in K8s.state.get("pods", []):
			if p.get("node", "") == n.name:
				cpu += float(p.get("cpu_req_m", 0))
				mem += float(p.get("mem_req", 0))
	out.append(_kv("cpu", "%s %s / %s [color=#5f574f](%s)[/color]" % [StatsPanel.bar(cpu / maxf(cap_cpu, 1.0), 10), StatsPanel.cores(cpu), StatsPanel.cores(cap_cpu), tr(label)]))
	out.append(_kv("memory", "%s %s / %s" % [StatsPanel.bar(mem / maxf(cap_mem, 1.0), 10), StatsPanel.mib(mem), StatsPanel.mib(cap_mem)]))
	return out


func _workload_buttons(w: Dictionary, ro: bool) -> Array:
	var out := []
	var cur := int(w.desired)
	if w.kind != "DaemonSet":
		out.append(["SCALE -", func(): _scale(w, -1), "", ro,
			Kubectl.for_action({"action": "scale", "kind": w.kind, "ns": w.ns, "name": w.name, "replicas": maxi(0, cur - 1)})])
		out.append(["SCALE +", func(): _scale(w, 1), "GoButton", ro,
			Kubectl.for_action({"action": "scale", "kind": w.kind, "ns": w.ns, "name": w.name, "replicas": cur + 1})])
	var rr := {"action": "restart", "kind": w.kind, "ns": w.ns, "name": w.name}
	out.append(["RESTART", func(): K8s.action(rr), "", ro, Kubectl.for_action(rr)])
	return out


func _scale(w: Dictionary, delta: int) -> void:
	var cur := int(_find_workload(w.ns, w.kind, w.name).get("desired", w.desired))
	var want := maxi(0, cur + delta)
	if want == cur:
		return
	var req := {"action": "scale", "kind": w.kind, "ns": w.ns, "name": w.name, "replicas": want}
	if want == 0:
		confirm(tr("Scale %s/%s to 0 replicas? It will stop serving.") % [w.ns, w.name], func(): K8s.action(req), Kubectl.for_action(req))
	else:
		K8s.action(req)


func _delete_workload(d: Dictionary) -> void:
	var req := {"action": "delete_workload", "kind": d.kind, "ns": d.ns, "name": d.name}
	confirm(tr("Delete %s %s/%s and all its pods?") % [d.kind, d.ns, d.name], func(): K8s.action(req), Kubectl.for_action(req))


func _cordon(d: Dictionary) -> void:
	var req := {"action": "cordon", "name": d.name}
	confirm(tr("Cordon node %s? New pods will not be scheduled on it.") % d.name, func(): K8s.action(req), Kubectl.for_action(req))


func _delete_pod(d: Dictionary) -> void:
	var req := {"action": "delete_pod", "ns": d.ns, "name": d.name}
	confirm(tr("Delete pod %s/%s? (its controller will usually recreate it)") % [d.ns, d.name], func(): K8s.action(req), Kubectl.for_action(req))


func _set_buttons(defs: Array) -> void:
	for c in _insp_buttons.get_children():
		c.queue_free()
	for b in defs:
		var btn := _button(b[0], b[1], b[2])
		btn.disabled = b[3]
		var cmd: String = b[4]
		if cmd != "":
			btn.mouse_entered.connect(func():
				_insp_preview.text = "$ " + cmd.replace("\n", "\n$ ")
				_insp_preview.add_theme_color_override("font_color", Vox.YELLOW))
		_insp_buttons.add_child(btn)


func _age(secs) -> String:
	var s := int(secs)
	if s < 120:
		return "%ds" % s
	if s < 7200:
		return "%dm" % (s / 60)
	if s < 172800:
		return "%dh" % (s / 3600)
	return "%dd" % (s / 86400)


# ---------------------------------------------------------------- modals

func _modal(margin: float) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", _flat(PANEL.lightened(0.02), Vox.YELLOW, 4, 22))
	p.visible = false
	p.set_meta("margin", margin)
	_modal_layer.add_child(p)
	return p


func _build_modals() -> void:
	_modal_layer = Control.new()
	_modal_layer.theme = _theme
	_modal_layer.set_anchors_preset(Control.PRESET_FULL_RECT)
	_modal_layer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_modal_layer)

	# Toast
	_toast = _label("", 28, Vox.GREEN)
	_toast.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toast.offset_top = 64
	_toast.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toast.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var tp := _flat(BG, INK, 0, 0)
	tp.content_margin_left = 16
	tp.content_margin_right = 16
	tp.content_margin_top = 4
	tp.content_margin_bottom = 4
	_toast.add_theme_stylebox_override("normal", tp)
	_toast.visible = false
	_modal_layer.add_child(_toast)

	# Logs viewer (fills most of the screen)
	_logs_panel = _modal(30)
	_logs_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var lv := VBoxContainer.new()
	lv.add_theme_constant_override("separation", 10)
	_logs_panel.add_child(lv)
	var lh := HBoxContainer.new()
	lh.add_theme_constant_override("separation", 10)
	lv.add_child(lh)
	_logs_title = _label("LOGS", 28, Vox.YELLOW)
	_logs_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_logs_title.clip_text = true
	lh.add_child(_logs_title)
	lh.add_child(_button("CLOSE [ESC]", func(): _logs_panel.visible = false))
	var lh2 := HFlowContainer.new()
	lh2.add_theme_constant_override("h_separation", 12)
	lv.add_child(lh2)
	lh2.add_child(_label("container", 24, Vox.SILVER))
	_logs_container = OptionButton.new()
	_logs_container.focus_mode = Control.FOCUS_NONE
	_logs_container.item_selected.connect(func(_i): _load_logs())
	lh2.add_child(_logs_container)
	_logs_prev = _check("previous run (after a crash)", _load_logs)
	lh2.add_child(_logs_prev)
	_logs_follow = _check("follow", _update_logs_cmd)
	_logs_follow.set_pressed_no_signal(true)
	lh2.add_child(_logs_follow)
	lh2.add_child(_button("REFRESH", _load_logs))
	_logs_cmd = _label("", 22, Vox.YELLOW)
	_logs_cmd.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	lv.add_child(_logs_cmd)
	_logs_text = TextEdit.new()
	_logs_text.editable = false
	_logs_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_logs_text.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	lv.add_child(_logs_text)

	# Full map
	_map_panel = _modal(24)
	_map_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var mv := VBoxContainer.new()
	mv.add_theme_constant_override("separation", 8)
	_map_panel.add_child(mv)
	var mh := HBoxContainer.new()
	mh.add_theme_constant_override("separation", 14)
	mv.add_child(mh)
	var mt := _label("MAP", 30, Vox.YELLOW)
	mh.add_child(mt)
	var mhint := _label("click a place to travel there", 22, Vox.SILVER)
	mhint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mh.add_child(mhint)
	mh.add_child(_button("CLOSE [M]", toggle_map))
	map_full = MapView.new()
	map_full.font = _font
	map_full.full = true
	map_full.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map_full.clip_contents = true
	map_full.mouse_default_cursor_shape = Control.CURSOR_CROSS
	mv.add_child(map_full)

	# Confirm
	_confirm_panel = _modal(-1)
	var cv := VBoxContainer.new()
	cv.add_theme_constant_override("separation", 14)
	_confirm_panel.add_child(cv)
	cv.add_child(_label("ARE YOU SURE?", 30, Vox.YELLOW))
	_confirm_label = _label("", 26)
	_confirm_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_confirm_label.custom_minimum_size = Vector2(520, 0)
	cv.add_child(_confirm_label)
	_confirm_cmd = _label("", 22, Vox.YELLOW)
	_confirm_cmd.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	_confirm_cmd.custom_minimum_size = Vector2(520, 0)
	cv.add_child(_confirm_cmd)
	var ch := HBoxContainer.new()
	ch.add_theme_constant_override("separation", 12)
	ch.alignment = BoxContainer.ALIGNMENT_END
	ch.add_child(_button("CANCEL [ESC]", func(): _confirm_panel.visible = false))
	ch.add_child(_button("YES, DO IT [ENTER]", _confirm_yes, "DangerButton"))
	cv.add_child(ch)

	# Build menu
	_build_panel = _modal(-1)
	var bv := VBoxContainer.new()
	bv.add_theme_constant_override("separation", 8)
	bv.custom_minimum_size = Vector2(540, 0)
	_build_panel.add_child(bv)
	bv.add_child(_label("BUILD A DEPLOYMENT", 30, Vox.GREEN))
	bv.add_child(_label("namespace (created if missing)", 24, Vox.SILVER))
	_build_ns = LineEdit.new()
	_build_ns.text = "academia"
	_build_ns.text_changed.connect(func(_t): _update_build_cmd())
	bv.add_child(_build_ns)
	bv.add_child(_label("name", 24, Vox.SILVER))
	_build_name = LineEdit.new()
	_build_name.text_changed.connect(func(_t): _update_build_cmd())
	bv.add_child(_build_name)
	bv.add_child(_label("image", 24, Vox.SILVER))
	_build_image = LineEdit.new()
	_build_image.text = "nginx:alpine"
	_build_image.text_changed.connect(func(_t): _update_build_cmd())
	bv.add_child(_build_image)
	var presets := HFlowContainer.new()
	presets.add_theme_constant_override("h_separation", 8)
	presets.add_theme_constant_override("v_separation", 8)
	for img in ["nginx:alpine", "httpd:alpine", "redis:7-alpine", "traefik/whoami"]:
		presets.add_child(_button(img, func():
			_build_image.text = img
			_update_build_cmd()))
	bv.add_child(presets)
	bv.add_child(_label("replicas", 24, Vox.SILVER))
	_build_replicas = SpinBox.new()
	_build_replicas.min_value = 1
	_build_replicas.max_value = 20
	_build_replicas.value = 2
	_build_replicas.value_changed.connect(func(_v): _update_build_cmd())
	bv.add_child(_build_replicas)
	_build_svc = _check("also create a Service (loading dock) on port 80", _update_build_cmd)
	_build_svc.set_pressed_no_signal(true)
	bv.add_child(_build_svc)
	_build_cmd = _label("", 22, Vox.YELLOW)
	_build_cmd.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	bv.add_child(_build_cmd)
	var bh := HBoxContainer.new()
	bh.alignment = BoxContainer.ALIGNMENT_END
	bh.add_theme_constant_override("separation", 12)
	bh.add_child(_button("CANCEL [ESC]", func(): _build_panel.visible = false))
	bh.add_child(_button("DEPLOY!", _do_build, "GoButton"))
	bv.add_child(bh)


func toggle_map() -> void:
	_map_panel.visible = not _map_panel.visible


func toggle_stats() -> void:
	stats.visible = not stats.visible
	if stats.visible:
		_mission_panel.visible = false
		_legend.visible = false
		stats.move_to_front()
	_sync_view()


const MINIMAP_SIZES := [Vector2(110, 75), Vector2(160, 110), Vector2(220, 150), Vector2(300, 210)]


func _minimap_size(step: int) -> void:
	Settings.minimap_size = clampi(Settings.minimap_size + step, 0, MINIMAP_SIZES.size() - 1)
	map_mini.custom_minimum_size = MINIMAP_SIZES[Settings.minimap_size]
	# Smaller map = zoomed out a bit so it still shows the surroundings.
	map_mini.zoom = [0.6, 0.8, 1.0, 1.0][Settings.minimap_size]
	if step != 0:
		Settings.save()


func toggle_minimap() -> void:
	Settings.minimap = not Settings.minimap
	Settings.save()


func is_modal_open() -> bool:
	return _map_panel.visible or _logs_panel.visible or _confirm_panel.visible or _build_panel.visible or _connect_root.visible


func close_modals() -> bool:
	for p in [_confirm_panel, _build_panel, _map_panel, _logs_panel, _view_panel, _alarm_panel, _legend]:
		if p.visible:
			p.visible = false
			_sync_view()
			return true
	return false


func confirm(text: String, cb: Callable, cmd := "") -> void:
	_confirm_label.text = text
	_confirm_cmd.text = ("$ " + cmd.replace("\n", "\n$ ")) if cmd != "" else ""
	_confirm_cmd.visible = cmd != ""
	_confirm_cb = cb
	_confirm_panel.visible = true


func _confirm_yes() -> void:
	_confirm_panel.visible = false
	if _confirm_cb.is_valid():
		_confirm_cb.call()


func _input(event: InputEvent) -> void:
	# Handled before the GUI so focused controls can't swallow ESC/ENTER.
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if event.keycode == KEY_ESCAPE and close_modals():
		get_viewport().set_input_as_handled()
	elif event.keycode in [KEY_ENTER, KEY_KP_ENTER] and _confirm_panel.visible:
		_confirm_yes()
		get_viewport().set_input_as_handled()


func open_build() -> void:
	if K8s.is_readonly():
		toast(tr("Bridge is read-only"), false)
		return
	_build_name.text = "app-%d" % (randi() % 900 + 100)
	_update_build_cmd()
	_build_panel.visible = true
	_build_name.grab_focus()


func _build_req() -> Dictionary:
	return {"action": "create_deployment", "ns": _build_ns.text.strip_edges().to_lower(),
		"name": _build_name.text.strip_edges().to_lower(), "image": _build_image.text.strip_edges(),
		"replicas": int(_build_replicas.value), "service": _build_svc.button_pressed}


func _update_build_cmd() -> void:
	_build_cmd.text = "$ " + Kubectl.for_action(_build_req()).replace("\n", "\n$ ")


func _do_build() -> void:
	_build_panel.visible = false
	K8s.action(_build_req())


func open_logs(d: Dictionary) -> void:
	_logs_pod = d
	_logs_title.text = "LOGS  %s/%s" % [d.ns, d.name]
	_logs_container.clear()
	for c in (d.get("containers", []) if d.get("containers") != null else []):
		_logs_container.add_item(c)
	_logs_prev.set_pressed_no_signal(PodBot.categorize(d) == "crash")
	_logs_text.text = tr("loading...")
	_logs_panel.visible = true
	_load_logs()
	if missions:
		missions.notify("logs", d, _logs_prev.button_pressed)


func _logs_container_name() -> String:
	return _logs_container.get_item_text(_logs_container.selected) if _logs_container.item_count > 0 else ""


func _update_logs_cmd() -> void:
	if _logs_pod.is_empty():
		return
	var c := _logs_container_name() if _logs_container.item_count > 1 else ""
	_logs_cmd.text = "$ " + Kubectl.logs(_logs_pod.ns, _logs_pod.name, c, _logs_prev.button_pressed, _logs_follow.button_pressed)


func _load_logs() -> void:
	if _logs_pod.is_empty():
		return
	_update_logs_cmd()
	_logs_t = 0.0
	var pod := _logs_pod
	K8s.fetch_logs(pod.ns, pod.name, _logs_container_name(), _logs_prev.button_pressed, func(ok: bool, text: String):
		if _logs_pod != pod:
			return
		var sb := _logs_text.get_v_scroll_bar()
		var at_bottom := sb.value >= sb.max_value - sb.page - 4
		_logs_text.text = text if ok else tr("ERROR: %s") % text
		if text.strip_edges() == "" and ok:
			_logs_text.text = tr("(no output)")
		if at_bottom or _logs_text.text.length() < 50:
			_logs_text.scroll_vertical = _logs_text.get_line_count()
		_logs_text.add_theme_color_override("font_readonly_color", Vox.WHITE if ok else Vox.RED))


# ---------------------------------------------------------------- layout

## Keeps side panels within the (UI-unit) screen size.
func _layout_modals() -> void:
	var full := _modal_layer.size
	for p in [_confirm_panel, _build_panel]:
		if p.visible:
			var ps: Vector2 = p.get_combined_minimum_size().min(full - Vector2(20, 20))
			p.size = ps
			p.position = ((full - ps) * 0.5).floor()


func _layout() -> void:
	var sz := _game_root.size
	var top := TOP
	var bottom := _help_bar.size.y + 6.0
	# Terminal and feed sit above the help bar.
	_term_text.custom_minimum_size.y = 300 if _term_input.has_focus() else 120
	_terminal.offset_bottom = -bottom
	_terminal.offset_top = -bottom - _terminal.get_combined_minimum_size().y
	_feed.offset_bottom = -bottom
	var low := bottom + (_terminal.size.y + 6.0 if _terminal.visible else 0.0)
	# Inspector on the right, legend on the left: scroll when too tall.
	var w := clampf(sz.x * 0.42, 340.0, 560.0)
	_inspector.offset_left = -w - 10
	var max_h := sz.y - top - low - 10
	var want := _insp_box.get_combined_minimum_size().y + 36
	_insp_scroll.custom_minimum_size = Vector2(w - 36, clampf(want - 36, 60, max_h - 36))
	_inspector.size.y = 0
	_mission_panel.size = Vector2.ZERO
	stats.size = Vector2.ZERO
	stats.offset_top = TOP + ((_mission_panel.size.y + 8) if _mission_panel.visible else 0.0)
	# The terminal grows wider while you type in it.
	_terminal.anchor_left = (0.34 if stats.visible else 0.25) if _term_input.has_focus() else 0.5
	var lw := clampf(sz.x * 0.4, 320.0, 560.0)
	var scroll: ScrollContainer = _legend.get_node("Scroll")
	var lwant: float = scroll.get_child(0).get_combined_minimum_size().y
	scroll.custom_minimum_size = Vector2(lw, clampf(lwant, 60, sz.y - top - bottom - 50))
	_legend.size = Vector2.ZERO
	var mm: Control = _game_root.get_node("Minimap")
	var msz: Vector2 = mm.get_combined_minimum_size()
	mm.offset_bottom = -bottom
	mm.offset_top = -bottom - msz.y
	mm.offset_right = 10 + msz.x
	# Centered dialogs: size to content, center, keep on screen.
	var full := _modal_layer.size
	for p in [_confirm_panel, _build_panel]:
		if p.visible:
			var ps: Vector2 = p.get_combined_minimum_size().min(full - Vector2(20, 20))
			p.size = ps
			p.position = ((full - ps) * 0.5).floor()
	for p in [_logs_panel, _map_panel]:
		var m: float = p.get_meta("margin")
		p.offset_left = m
		p.offset_top = m
		p.offset_right = -m
		p.offset_bottom = -m


# ------------------------------------------------------------------ tick

func _process(delta: float) -> void:
	StatsPanel.probe(delta)
	_perf_t += delta
	if _perf_t > 0.5 and _perf_label:
		_perf_t = 0.0
		_perf_label.text = StatsPanel.summary()
	_insp_t += delta
	if _insp_t > 0.3:
		_insp_t = 0.0
		_refresh_inspector()
	if _game_root.visible:
		_layout()
	else:
		_layout_modals()
	if _toast_t > 0.0:
		_toast_t -= delta
		_toast.modulate.a = clampf(_toast_t, 0.0, 1.0)
		if _toast_t <= 0.0:
			_toast.visible = false
	for l in _feed.get_children():
		var t: float = l.get_meta("t") - delta
		l.set_meta("t", t)
		l.modulate.a = clampf(t / 2.0, 0.0, 1.0)
		if t <= 0.0:
			l.queue_free()
	if _logs_panel.visible and _logs_follow.button_pressed:
		_logs_t += delta
		if _logs_t > 3.0:
			_load_logs()
