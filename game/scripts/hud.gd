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
signal add_cp_requested
signal jetpack_requested
signal touch_mode_changed
signal watch_toggled(on: bool)
signal intro_requested

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
var kubi: KubiPanel
var _term_drag: DragResize   # the terminal can float: moved and resized
var _connect_v: VBoxContainer
var _connect_title: Label
var _connect_grid: GridContainer
# Phones / tablets: compact layout (menu instead of button rows) and touch controls.
var compact := false
var touch := false
var touch_ctl: TouchControls
var _bar_btns: Array[Control] = []
var _strip_extra: Array[Control] = []
var _menu_btn: Button
var _menu_panel: PanelContainer
var _compact_term := false
var _was_compact := false
var _close_fab: Button
var editor: ManifestEditor
var term_log := []     # last terminal outputs [{id, cmd, out, ok}]
var _term_seq := 0
var watch: WatchPanel
var flying := false
var _view_jet: CheckBox
var _view_click: CheckBox
var _view_finished: CheckBox
var _view_intro: CheckBox
var _view_touch: Button
var _vol_panel: PanelContainer
var _vol_mute: CheckBox
var _vol_btn: Button
var map_mini: MapView
var stats: StatsPanel
var _perf_label: Label
var _perf_t := 0.0
var _view_stats: CheckBox
var _view_challenge: CheckBox
var _view_fastday: CheckBox
var clock_text := ""
var _fade: ColorRect
var _banner: PanelContainer
var _banner_title: Label
var _banner_body: Label
var _banner_t := 0.0
var _weapon_bar: HBoxContainer
var _last_bad := -1
var _guide_panel: PanelContainer
var _guide_text: RichTextLabel
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
var _saved_list: VBoxContainer
var _ctx_pick: OptionButton
var _save_name: LineEdit
var _kc_box: VBoxContainer
var _kc_name: LineEdit
var _kc_text: TextEdit

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
	var text_scale := 1.0     # smaller plates on phones
	var hits := []   # [[Rect2, Entity]] label plates you can click, last drawn on top
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
		hits.clear()
		var sorted := items.duplicate()
		sorted.sort_custom(func(a, b): return a.big and not b.big)
		for it in sorted:
			var size: int = roundi((23 if it.big else (18 if it.get("small", false) else 21)) * text_scale)
			var sub_size := roundi(18 * text_scale)
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
			if it.get("entity") != null:
				hits.append([r, it.entity])
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
	b.pressed.connect(func(): Sfx.play("click", null, 0.0))
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
	panel.add_theme_stylebox_override("panel", _flat(PANEL, Vox.BLUE, 4, 22))
	_connect_root.add_child(panel)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.name = "Scroll"
	panel.add_child(scroll)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.custom_minimum_size = Vector2(720, 0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(v)
	_connect_v = v
	var title := Label.new()
	_connect_title = title
	title.text = "KUBIVERSE"
	title.add_theme_font_override("font", _title_font)
	title.add_theme_font_size_override("font_size", 38)
	title.add_theme_color_override("font_color", Vox.YELLOW)
	title.add_theme_color_override("font_shadow_color", Vox.PLUM)
	title.add_theme_constant_override("shadow_offset_x", 4)
	title.add_theme_constant_override("shadow_offset_y", 4)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(title)
	var sub := _label("Your Kubernetes cluster, as a voxel world.", 26, Vox.PEACH)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(sub)

	# ---- saved clusters
	v.add_child(_section("SAVED CLUSTERS"))
	_saved_list = VBoxContainer.new()
	_saved_list.add_theme_constant_override("separation", 6)
	v.add_child(_saved_list)

	# ---- run a bridge here (not needed when this page is served by one)
	if not K8s.served_by_bridge():
		v.add_child(_section("RUN THE BRIDGE ON THIS COMPUTER"))
		var bn := _label("The game reaches your cluster through k8s-bridge, a small program that uses your kubeconfig like kubectl. Paste one of these in a terminal: it downloads the latest release, checks its SHA256 and starts it. Then press CONNECT TO CLUSTER.", 21, Vox.SILVER)
		bn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		v.add_child(bn)
		for pair in K8s.bridge_install_commands():
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var os_l := _label(pair[0], 21, Vox.PEACH)
			os_l.custom_minimum_size.x = 150
			row.add_child(os_l)
			var cmd := LineEdit.new()
			cmd.text = pair[1]
			cmd.editable = false
			cmd.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(cmd)
			row.add_child(_button("COPY", _copy.bind(pair[1])))
			v.add_child(row)

	# ---- native builds (web only, collapsible)
	if OS.has_feature("web"):
		var nbox := VBoxContainer.new()
		nbox.add_theme_constant_override("separation", 6)
		nbox.visible = false
		var nh := HBoxContainer.new()
		nh.add_child(_button("+ NATIVE APP (MACOS, WINDOWS, LINUX)", func(): nbox.visible = not nbox.visible))
		v.add_child(nh)
		v.add_child(nbox)
		var ntext := "Smoother than the browser. It connects to the same bridge: start it with the command above (without --allow-origin), then CONNECT TO CLUSTER."
		if K8s.served_by_bridge():
			ntext = "Smoother than the browser. It connects to the bridge serving this page: keep it running and press CONNECT TO CLUSTER in the app."
		var nn := _label(ntext, 21, Vox.SILVER)
		nn.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nbox.add_child(nn)
		for d in K8s.native_downloads():
			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 8)
			var os_l := _label(d[0], 21, Vox.PEACH)
			os_l.custom_minimum_size.x = 110
			row.add_child(os_l)
			row.add_child(_button("DOWNLOAD", OS.shell_open.bind(d[1]), "GoButton"))
			var how := _label(d[2], 19, Vox.SILVER)
			how.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			how.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row.add_child(how)
			nbox.add_child(row)

	# ---- new connection
	v.add_child(_section("NEW CONNECTION"))
	var g := GridContainer.new()
	_connect_grid = g
	g.columns = 2
	g.add_theme_constant_override("h_separation", 10)
	g.add_theme_constant_override("v_separation", 8)
	v.add_child(g)
	g.add_child(_label("k8s-bridge URL", 24, Vox.SILVER))
	_url_edit = LineEdit.new()
	_url_edit.text = K8s.default_bridge_url()
	_url_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_url_edit.text_submitted.connect(func(_t): _load_contexts())
	g.add_child(_url_edit)
	g.add_child(_label("Token", 24, Vox.SILVER))
	_token_edit = LineEdit.new()
	_token_edit.secret = true
	_token_edit.placeholder_text = tr("optional (--token on the bridge)")
	_token_edit.text = K8s.web_query_param("token")
	g.add_child(_token_edit)
	g.add_child(_label("Context", 24, Vox.SILVER))
	var ch := HBoxContainer.new()
	ch.add_theme_constant_override("separation", 8)
	_ctx_pick = OptionButton.new()
	_ctx_pick.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_ctx_pick.fit_to_longest_item = false
	_ctx_pick.clip_text = true
	_ctx_pick.custom_minimum_size.x = 120
	_ctx_pick.focus_mode = Control.FOCUS_NONE
	_ctx_pick.add_item(tr("(bridge default)"))
	_ctx_pick.item_selected.connect(func(_i): _save_name.placeholder_text = _picked_context())
	ch.add_child(_ctx_pick)
	ch.add_child(_button("LOAD CONTEXTS", _load_contexts))
	g.add_child(ch)
	g.add_child(_label("Name", 24, Vox.SILVER))
	_save_name = LineEdit.new()
	_save_name.placeholder_text = tr("name to save it as (optional)")
	g.add_child(_save_name)
	var h := HFlowContainer.new()
	h.add_theme_constant_override("h_separation", 10)
	h.add_theme_constant_override("v_separation", 8)
	var c := _button("CONNECT TO CLUSTER", func(): _do_connect(false), "GoButton")
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(c)
	var sv := _button("SAVE & CONNECT", func(): _do_connect(true), "GoButton")
	sv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sv)
	v.add_child(h)

	# ---- add kubeconfig (collapsible)
	var kh := HBoxContainer.new()
	v.add_child(kh)
	var ktoggle := _button("+ ADD A KUBECONFIG", func(): _kc_box.visible = not _kc_box.visible)
	kh.add_child(ktoggle)
	_kc_box = VBoxContainer.new()
	_kc_box.add_theme_constant_override("separation", 8)
	_kc_box.visible = false
	v.add_child(_kc_box)
	var note := _label("The kubeconfig is sent only to the bridge above and stored there (~/.kubecraft/kubeconfigs, permissions 0600). Its contexts then appear in the list.", 21, Vox.SILVER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_kc_box.add_child(note)
	_kc_name = LineEdit.new()
	_kc_name.placeholder_text = tr("file name, e.g. prod-eu")
	_kc_box.add_child(_kc_name)
	_kc_text = TextEdit.new()
	_kc_text.placeholder_text = tr("paste the kubeconfig YAML here")
	_kc_text.custom_minimum_size = Vector2(0, 150)
	_kc_box.add_child(_kc_text)
	var kb := HBoxContainer.new()
	kb.add_theme_constant_override("separation", 10)
	kb.add_child(_button("LOAD FILE...", _pick_kubeconfig_web if OS.has_feature("web") else _pick_kubeconfig_file))
	kb.add_child(_button("ADD CLUSTER", _upload_kubeconfig, "GoButton"))
	_kc_box.add_child(kb)

	# ---- misc
	var h2 := HFlowContainer.new()
	h2.add_theme_constant_override("h_separation", 10)
	h2.add_theme_constant_override("v_separation", 8)
	var d := _button("DEMO MODE", func():
		K8s.start_demo()
		show_connect(false))
	h2.add_child(d)
	h2.add_child(_label("Text size", 24, Vox.SILVER))
	h2.add_child(_button(" - ", func(): Settings.step_scale(-1)))
	_connect_scale = _label("", 26, Vox.YELLOW)
	h2.add_child(_connect_scale)
	h2.add_child(_button(" + ", func(): Settings.step_scale(1)))
	v.add_child(h2)
	v.add_child(_lang_row())
	_connect_status = _label("Start the bridge first, then CONNECT TO CLUSTER.", 24, Vox.SILVER)
	_connect_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(_connect_status)
	_refresh_saved()


func _volume_row(label: String, key: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	var l := _label(label, 24, Vox.SILVER)
	l.custom_minimum_size = Vector2(110, 0)
	h.add_child(l)
	var sl := HSlider.new()
	sl.min_value = 0.0
	sl.max_value = 1.0
	sl.step = 0.05
	sl.value = Settings.get(key)
	sl.custom_minimum_size = Vector2(200, 24)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	sl.focus_mode = Control.FOCUS_NONE
	sl.value_changed.connect(func(v):
		Settings.set(key, v)
		Settings.save()
		if key == "sfx_volume":
			Sfx.play("coin", null, 0.0))
	h.add_child(sl)
	return h


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


func _status(msg: String, col: Color) -> void:
	_connect_status.text = msg
	_connect_status.add_theme_color_override("font_color", col)


func _picked_context() -> String:
	var i := _ctx_pick.selected
	return "" if i <= 0 else _ctx_pick.get_item_text(i).split("  ")[0]


func _load_contexts() -> void:
	_status(tr("Asking %s for its contexts...") % K8s.normalize_url(_url_edit.text), Vox.YELLOW)
	K8s.list_contexts(_url_edit.text, _token_edit.text, func(ok: bool, data):
		if not ok or not data.get("ok", false):
			_status(tr("Cannot reach the bridge: %s") % str(data if not ok else data.get("error", "")), Vox.RED)
			return
		var keep := _picked_context()
		_ctx_pick.clear()
		_ctx_pick.add_item(tr("(bridge default)"))
		for cx in data.contexts:
			var label: String = cx.name + "  " + cx.server + ("  *" if cx.default else "")
			_ctx_pick.add_item(label)
			if cx.name == keep:
				_ctx_pick.select(_ctx_pick.item_count - 1)
		_status(tr("%d contexts available. Pick one and connect.") % data.contexts.size(), Vox.GREEN))


func _refresh_saved() -> void:
	for c in _saved_list.get_children():
		c.queue_free()
	if Settings.servers.is_empty():
		var none := _label("Nothing saved yet: fill in a new connection and use SAVE & CONNECT.", 22, Vox.SLATE)
		none.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_saved_list.add_child(none)
		return
	for i in Settings.servers.size():
		var sv: Dictionary = Settings.servers[i]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 6)
		var go := _button("> %s   %s @ %s" % [sv.name, sv.context if sv.context != "" else "default", sv.url], func():
			_url_edit.text = sv.url
			_token_edit.text = sv.get("token", "")
			K8s.connect_bridge(sv.url, sv.get("token", ""), sv.context)
			_status(tr("Connecting to %s ...") % sv.name, Vox.YELLOW), "GoButton")
		go.alignment = HORIZONTAL_ALIGNMENT_LEFT
		go.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		go.clip_text = true  # long names shrink instead of widening the screen
		go.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		go.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		row.add_child(go)
		row.add_child(_button("X", func():
			Settings.servers.remove_at(i)
			Settings.save()
			_refresh_saved(), "DangerButton"))
		_saved_list.add_child(row)


func _do_connect(save: bool) -> void:
	var ctx := _picked_context()
	if save:
		var name := _save_name.text.strip_edges()
		if name == "":
			name = ctx if ctx != "" else K8s.normalize_url(_url_edit.text).trim_prefix("http://")
		Settings.servers = Settings.servers.filter(func(x): return x.name != name)
		Settings.servers.append({"name": name, "url": K8s.normalize_url(_url_edit.text), "token": _token_edit.text, "context": ctx})
		Settings.save()
		_refresh_saved()
	K8s.connect_bridge(_url_edit.text, _token_edit.text, ctx)
	_status(tr("Connecting to %s ...") % K8s.base_url, Vox.YELLOW)


## Adds a kubeconfig as a new cluster: the bridge stores it, we check that
## the cluster answers, save it in the list and connect.
func _upload_kubeconfig() -> void:
	var name := _kc_name.text.strip_edges().replace(" ", "-")
	if _kc_text.text.strip_edges() == "":
		_status(tr("Paste the kubeconfig or load its file first."), Vox.RED)
		return
	if name == "":
		name = "cluster-%d" % (Settings.servers.size() + 1)
		_kc_name.text = name
	_status(tr("Sending the kubeconfig to the bridge..."), Vox.YELLOW)
	K8s.add_kubeconfig(_url_edit.text, _token_edit.text, name, _kc_text.text, func(ok: bool, data):
		if not ok or not data.get("ok", false):
			_status(tr("The bridge rejected it: %s") % str(data if not ok else data.get("error", "")), Vox.RED)
			return
		var ctxs: Array = data.get("contexts", [])
		if ctxs.is_empty():
			_status(tr("The kubeconfig has no usable context."), Vox.RED)
			return
		_kc_text.text = ""
		_kc_box.visible = false
		_load_contexts()
		var ctx: String = ctxs[0]
		var more := "" if ctxs.size() == 1 else "  " + tr("(%d more contexts in the list)") % (ctxs.size() - 1)
		_status(tr("Checking the cluster %s (can take up to 25 s)...") % ctx + more, Vox.YELLOW)
		K8s.check_context(_url_edit.text, _token_edit.text, ctx, func(ok2: bool, err: String):
			if not ok2:
				_status(tr("Saved on the bridge, but the cluster doesn't answer: %s") % err + "\n" +
					tr("Check that the server is reachable from the bridge machine and that its credentials (or exec plugins like aws / gke-gcloud-auth-plugin) work there."), Vox.RED)
				return
			var label := name if ctxs.size() == 1 else "%s (%s)" % [name, ctx]
			Settings.servers = Settings.servers.filter(func(x): return x.name != label)
			Settings.servers.append({"name": label, "url": K8s.normalize_url(_url_edit.text), "token": _token_edit.text, "context": ctx})
			Settings.save()
			_refresh_saved()
			_status(tr("Cluster %s added. Connecting...") % label, Vox.GREEN)
			K8s.connect_bridge(_url_edit.text, _token_edit.text, ctx)))


## Web: the browser's own file picker (there is no native dialog there).
var _js_file_cb: JavaScriptObject


func _pick_kubeconfig_web() -> void:
	_js_file_cb = JavaScriptBridge.create_callback(func(args: Array):
		_kc_text.text = str(args[0])
		if _kc_name.text.strip_edges() == "":
			_kc_name.text = str(args[1]).get_basename().replace(" ", "-")
		_status(tr("File loaded: %s. Now press ADD CLUSTER.") % str(args[1]), Vox.GREEN))
	JavaScriptBridge.get_interface("window").kubecraftFile = _js_file_cb
	JavaScriptBridge.eval("""(function(){
		const i = document.createElement('input');
		i.type = 'file';
		i.onchange = async () => { const f = i.files[0]; if (f) window.kubecraftFile(await f.text(), f.name); };
		i.click();
	})()""", true)


func _pick_kubeconfig_file() -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = true
	fd.current_dir = OS.get_environment("HOME") + "/.kube"
	fd.file_selected.connect(func(path: String):
		_kc_text.text = FileAccess.get_file_as_string(path)
		if _kc_name.text == "":
			_kc_name.text = path.get_file().get_basename().replace(" ", "-")
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered(Vector2i(900, 600))


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
	logo.name = "Logo"
	logo.text = "KUBIVERSE"
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
	_vol_btn = _button("VOL", toggle_volume)
	_chaos_btn = _button("C CHAOS", toggle_chaos)
	for b in [_vol_btn, _button("Y KUBI", toggle_kubi), _button("O WATCH", toggle_watch), _button("G LEGEND", toggle_legend),
			_button("B BUILD", open_build, "GoButton"), _chaos_btn, _button("V VIEW", toggle_view), _button("EXIT", func(): disconnect_requested.emit())]:
		h.add_child(b)
		_bar_btns.append(b)
	_menu_btn = _button("MENU", toggle_menu, "GoButton")
	_menu_btn.custom_minimum_size = Vector2(96, 44)
	_menu_btn.visible = false
	h.add_child(_menu_btn)
	_build_menu()


	# ---- Volume panel (drops down under the bar)
	_vol_panel = PanelContainer.new()
	_vol_panel.anchor_left = 1.0
	_vol_panel.anchor_right = 1.0
	_vol_panel.offset_left = -470
	_vol_panel.offset_right = -10
	_vol_panel.offset_top = TOP
	_vol_panel.visible = false
	_vol_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_game_root.add_child(_vol_panel)
	var volv := VBoxContainer.new()
	volv.add_theme_constant_override("separation", 10)
	_vol_panel.add_child(volv)
	volv.add_child(_section("SOUND"))
	volv.add_child(_volume_row("General", "master_volume"))
	volv.add_child(_volume_row("Music", "music_volume"))
	volv.add_child(_volume_row("Effects", "sfx_volume"))
	_vol_mute = _check("Mute everything", func():
		Settings.muted = not Settings.muted
		Settings.save()
		_sync_view())
	volv.add_child(_vol_mute)

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
	_view_click = _check("Click to move (click the ground)", func():
		Settings.click_to_move = not Settings.click_to_move
		Settings.save())
	vv.add_child(_view_click)
	_view_finished = _check("Show every finished pod (Completed)", func():
		Settings.show_finished = not Settings.show_finished
		Settings.save()
		if world:
			world.apply_state(K8s.state))  # redraw with / without them
	vv.add_child(_view_finished)
	var ir := HBoxContainer.new()
	_view_intro = _check("Intro when connecting", func():
		Settings.intro = not Settings.intro
		Settings.save())
	ir.add_child(_view_intro)
	ir.add_child(_button("PLAY INTRO", func():
		close_top()
		intro_requested.emit()))
	vv.add_child(ir)
	_view_touch = _button("", func():
		Settings.touch = {"auto": "on", "on": "off", "off": "auto"}[Settings.touch]
		Settings.save()
		touch_mode_changed.emit()
		_sync_view())
	vv.add_child(_view_touch)
	_view_run = _check("Always run  [X]", func():
		Settings.always_run = not Settings.always_run
		Settings.save())
	vv.add_child(_view_run)
	_view_minimap = _check("Minimap  [N]", toggle_minimap)
	vv.add_child(_view_minimap)
	_view_fpv = _check("First person view  [P]", func(): fpv_requested.emit())
	vv.add_child(_view_fpv)
	_view_jet = _check("Jetpack flight  [Z / SPACE x2]", func(): jetpack_requested.emit())
	vv.add_child(_view_jet)
	_view_stats = _check("Performance & cluster stats  [F3]", toggle_stats)
	vv.add_child(_view_stats)
	_view_challenge = _check("Jump challenge (Mario platforms)", func():
		Settings.challenge = not Settings.challenge
		Settings.save())
	vv.add_child(_view_challenge)
	_view_fastday = _check("Accelerated day/night cycle", func():
		Settings.fast_day = not Settings.fast_day
		Settings.save())
	vv.add_child(_view_fastday)
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
	_inspector.add_theme_stylebox_override("panel", _flat(Color(0.114, 0.169, 0.325, 1.0), INK, 3, 16))
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
	_term_drag = DragResize.new().attach(_terminal, th)
	_term_text = _rich(20)
	_term_text.fit_content = false
	_term_text.scroll_active = true
	_term_text.scroll_following = true
	_term_text.custom_minimum_size = Vector2(0, 120)
	_term_text.selection_enabled = true
	_term_text.meta_underlined = false
	_term_text.meta_clicked.connect(func(m): _term_meta(str(m)))
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
	_term_input.text_changed.connect(_term_clean)
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
	_strip_extra.append(_perf_label)
	for b in [_button("F3 STATS", toggle_stats), _button("M MAP", toggle_map), _button("J MISSIONS", toggle_missions, "GoButton")]:
		h.add_child(b)
		_strip_extra.append(b)
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
	var keys := [["WASD", "walk"], ["SHIFT/X", "run"], ["SPACE", "jump"], ["Z", "jetpack"], ["P", "first person"], ["E", "enter/use"], ["DRAG", "camera"],
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
		[Vox.BLUE, "North: THE INTERNET city. Billboard = a domain\n  (Ingress); cars = requests to the halls"],
		[Vox.GREEN, "INGRESS gate: routes domains to Services;\n  a car stopping with 503 = broken route"],
		[Vox.PINK, "Pink road + toll booth = LoadBalancer\n  Service (its external IP)"],
		[Vox.BLUE, "HALL: inside a namespace"],
		["h", "INSIDE A HALL"],
		[Vox.GREEN, "Assembly line = Deployment/StatefulSet/DaemonSet\n  console lamps = replicas (green = ready)"],
		[Vox.PINK, "Robot at a station = a Pod\n  one body block per container"],
		[Vox.BLUE, "Loading dock = Service. Color = type: blue\n  ClusterIP, orange NodePort, pink LoadBalancer"],
		[Vox.WHITE, "Line dock -> robot = Service sends traffic\n  there; white dashes = direction"],
		[Vox.BROWN, "Boxes on the belt = the line is working\n  (decoration, not a Kubernetes object)"],
		[Vox.LAVENDER, "WORKSHOP row = pods with no assembly line:\n  Jobs, Workflows, bare pods"],
		["h", "ROBOT GEM = POD STATUS"],
		[Vox.GREEN, "Running and ready"],
		[Vox.YELLOW, "Running but NOT ready"],
		[Vox.BLUE, "Pending / creating container"],
		[Vox.RED, "Crashing (CrashLoopBackOff, Error), smokes"],
		[Vox.PINK, "Image cannot be pulled"],
		[Vox.SLATE, "Terminating / completed (grey robot,\n  eyes closed: it finished its work)"],
		["h", "ENERGY ROOM"],
		[Vox.GREEN, "Island = Node, castle = control-plane"],
		[Vox.YELLOW, "Fence = cordoned, red light = NotReady"],
		[Vox.WHITE, "Cloud = pods waiting for the scheduler"],
		["h", "KEYS"],
		[Vox.LAVENDER, "WASD walk, SHIFT (hold) or X (toggle) run, SPACE jump\nZ or SPACE twice: jetpack (hold SPACE up, CTRL down)\nE enter/use/inspect, P first person, DRAG pan, RIGHT-DRAG rotate\nQ/R rotate 90, WHEEL zoom, M map, N minimap, J missions\nTAB next problem, L logs, B build, H system ns\nK all lines, T terminal, V view menu, C chaos + F blaster\nBACKSPACE plant, HOME recenter"],
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
	# First person is immersive: terminal and minimap step aside (/ brings
	# the terminal back to type a command).
	_terminal.visible = Settings.terminal and (not fpv or _term_input.has_focus())
	if compact:
		_terminal.visible = _compact_term or _term_input.has_focus()
	_view_run.set_pressed_no_signal(Settings.always_run)
	if _view_jet:
		_view_jet.set_pressed_no_signal(flying)
	if _view_click:
		_view_click.set_pressed_no_signal(Settings.click_to_move)
	if _view_finished:
		_view_finished.set_pressed_no_signal(Settings.show_finished)
	if _view_intro:
		_view_intro.set_pressed_no_signal(Settings.intro)
	if _view_touch:
		_view_touch.text = tr("Touch controls: %s") % tr({"auto": "automatic", "on": "on", "off": "off"}[Settings.touch])
	if _vol_mute:
		_vol_mute.set_pressed_no_signal(Settings.muted)
		_vol_btn.text = tr("MUTED") if Settings.muted else "VOL"
	_view_minimap.set_pressed_no_signal(Settings.minimap)
	_view_fpv.set_pressed_no_signal(fpv)
	_view_stats.set_pressed_no_signal(stats.visible)
	_view_challenge.set_pressed_no_signal(Settings.challenge)
	_view_fastday.set_pressed_no_signal(Settings.fast_day)
	if map_mini:
		map_mini.get_parent().visible = Settings.minimap and not stats.visible and not fpv
	for b in _lang_btns:
		b.theme_type_variation = "GoButton" if b.get_meta("lang") == Settings.lang else ""


## Opens the Matrix-style YAML editor on an object (focus = a key to jump to).
func open_editor(kind: String, ns: String, name: String, focus := "") -> void:
	editor.open(kind, ns, name, focus)


func toggle_kubi() -> void:
	if kubi.visible:
		kubi.visible = false
	else:
		kubi.open()


func toggle_watch() -> void:
	if watch.visible:
		watch.visible = false
	else:
		watch.open()
	watch_toggled.emit(watch.visible)


## Compact layout: one big-button menu with everything the top rows hold.
func _build_menu() -> void:
	_menu_panel = PanelContainer.new()
	_menu_panel.set_anchors_preset(Control.PRESET_TOP_WIDE)
	_menu_panel.offset_left = 8
	_menu_panel.offset_right = -8
	_menu_panel.offset_top = TOP
	_menu_panel.visible = false
	_menu_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_menu_panel.add_theme_stylebox_override("panel", _flat(Color(0.05, 0.06, 0.12, 0.98), Vox.GREEN, 3, 12))
	_game_root.add_child(_menu_panel)
	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = 3
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 8)
	_menu_panel.add_child(grid)
	var items := [["KUBI", toggle_kubi], ["WATCH", toggle_watch], ["MAP", toggle_map], ["MISSIONS", toggle_missions],
		["ALARMS", toggle_alarms], ["BUILD", open_build], ["CHAOS", toggle_chaos], ["TERMINAL", toggle_terminal],
		["LEGEND", toggle_legend], ["STATS", toggle_stats], ["FIRST PERSON", func(): fpv_requested.emit()],
		["JETPACK", func(): jetpack_requested.emit()], ["SOUND", toggle_volume], ["VIEW", toggle_view],
		["EXIT", func(): disconnect_requested.emit()]]
	for it in items:
		var cb: Callable = it[1]
		var b := _button(it[0], func():
			_menu_panel.visible = false
			cb.call(), "DangerButton" if it[0] == "EXIT" else "")
		b.custom_minimum_size = Vector2(0, 54)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(b)


func toggle_menu() -> void:
	_menu_panel.visible = not _menu_panel.visible
	_menu_panel.move_to_front()
	for p in [_view_panel, _vol_panel, _alarm_panel]:
		p.visible = false
	if touch_ctl:
		touch_ctl.reset()


## Desktop: if the top bar doesn't fit, the least used buttons move into
## the MENU (kept in this order of importance: EXIT, BUILD, CHAOS, VIEW...).
func _fit_top_bar(width: float) -> void:
	var sep := 12.0
	var used := 0.0
	var h: HBoxContainer = _menu_btn.get_parent()
	for c in h.get_children():
		if not c in _bar_btns and c != _menu_btn and c.visible:
			used += c.get_combined_minimum_size().x + sep
	used += 20.0
	# _bar_btns order: VOL, KUBI, WATCH, LEGEND, BUILD, CHAOS, VIEW, EXIT
	var priority := [7, 4, 5, 6, 1, 2, 0, 3]
	var hidden := false
	var menu_w := _menu_btn.get_combined_minimum_size().x + sep
	for i in priority:
		var w: float = _bar_btns[i].get_combined_minimum_size().x + sep
		var fits := used + w + menu_w <= width
		_bar_btns[i].visible = fits and not hidden
		if _bar_btns[i].visible:
			used += w
		else:
			hidden = true
	_menu_btn.visible = hidden


## Switches between the desktop layout and the compact (phone) one.
func _apply_compact(on: bool) -> void:
	compact = on
	for b in _bar_btns:
		b.visible = not on
	for b in _strip_extra:
		b.visible = not on
	_menu_btn.visible = on
	if not on:
		_menu_panel.visible = false
	var mm: Control = _game_root.get_node("Minimap")
	if on:
		_mission_panel.visible = false  # opened from the menu
		mm.anchor_left = 0.0
		mm.anchor_right = 0.0
		mm.anchor_top = 0.0
		mm.anchor_bottom = 0.0
	else:
		mm.anchor_left = 0.0
		mm.anchor_right = 0.0
		mm.anchor_top = 1.0
		mm.anchor_bottom = 1.0
		_ctx_label.visible = true
		map_mini.custom_minimum_size = MINIMAP_SIZES[Settings.minimap_size]
		var logo: Label = _game_root.find_child("Logo", true, false)
		logo.add_theme_font_size_override("font_size", 16)
	_sync_view()


## Closes the panel on top (phones have no ESC key). True if one closed.
func close_top() -> bool:
	if close_modals():
		return true
	for p in [_menu_panel, stats, _mission_panel]:
		if p.visible:
			p.visible = false
			_sync_view()
			return true
	if _compact_term and _terminal.visible:
		_compact_term = false
		_term_input.release_focus()
		_sync_view()
		return true
	if _inspector.visible:
		inspect(null)
		return true
	return false


func _anything_to_close() -> bool:
	for p in [_confirm_panel, _build_panel, _guide_panel, _map_panel, _logs_panel, _view_panel, _vol_panel, _alarm_panel,
			_legend, kubi, watch, _menu_panel, stats, _mission_panel, _inspector]:
		if p.visible:
			return true
	return _compact_term and _terminal.visible


## Rects of the visible UI, where touches belong to the interface.
func ui_rects() -> Array:
	var out := []
	for c in [_inspector, kubi, watch, _terminal, _menu_panel, _mission_panel, _legend, _vol_panel, _view_panel,
			_alarm_panel, stats, _game_root.get_node("Minimap")]:
		if c and c.is_visible_in_tree():
			out.append(c.get_global_rect())
	if _close_fab and _close_fab.visible:
		out.append(_close_fab.get_global_rect().grow(8))
	out.append(Rect2(0, 0, _game_root.size.x, TOP))
	return out


func toggle_volume() -> void:
	_vol_panel.visible = not _vol_panel.visible
	_view_panel.visible = false
	_sync_view()


func toggle_view() -> void:
	_vol_panel.visible = false
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
	if compact:
		_compact_term = not _compact_term
		_sync_view()
		return
	_toggle_terminal_setting()


func _toggle_terminal_setting() -> void:
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
	if _weapon_bar:
		_weapon_bar.visible = chaos


## Weapon slots (visible in chaos mode): 1-6, locked ones greyed out.
func set_weapon(current: int) -> void:
	if _weapon_bar == null:
		_weapon_bar = HBoxContainer.new()
		_weapon_bar.add_theme_constant_override("separation", 6)
		_weapon_bar.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_weapon_bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_weapon_bar.offset_top = TOP + 2
		_weapon_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_game_root.add_child(_weapon_bar)
	for c in _weapon_bar.get_children():
		c.queue_free()
	for i in Weapons.LIST.size():
		var w: Dictionary = Weapons.LIST[i]
		var ok := Weapons.unlocked(i)
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", _flat(Color(0.043, 0.051, 0.102, 0.92), w.color if i == current else (Vox.SLATE if ok else INK), 3 if i == current else 2, 6))
		var txt := "%d %s" % [i + 1, tr(w.name)] if i == current else ("%d" % (i + 1) if ok else "%d x" % (i + 1))
		var l := _label(txt, 20, w.color if ok else Vox.SLATE)
		l.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
		p.add_child(l)
		_weapon_bar.add_child(p)
	_weapon_bar.visible = chaos


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
	var failing := _alarms.filter(func(a): return a.sev >= 3).size()
	if failing > _last_bad and _last_bad >= 0:
		Sfx.play("alarm", null, 0.0)
	_last_bad = failing
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
	if not ok:
		Sfx.play("error", null, 0.0)
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


## Terminal kiosk on a node island: open the console already showing that
## node, with the next useful command typed in and ready to run.
func node_terminal(node_name: String, is_cp: bool) -> void:
	if not Settings.terminal:
		toggle_terminal()
	_term_text.append_text("[color=#83769c]# --- %s %s ---[/color]\n" % [tr("console of node"), node_name])
	if is_cp:
		_term_submit("get nodes -o wide")
		_term_input.text = "cluster-info"
	else:
		_term_submit("get pods -A -o wide --field-selector spec.nodeName=" + node_name)
		_term_input.text = "describe node " + node_name
	_term_input.grab_focus()
	_term_input.caret_column = _term_input.text.length()


## Why and how to add a control-plane to a REAL cluster: it is an
## infrastructure operation (a new machine), not something the Kubernetes
## API can do, so the game explains the steps for this kind of cluster.
func show_cp_guide() -> void:
	var ctx: String = K8s.state.get("context", "")
	var server: String = K8s.state.get("server", "")
	var n: int = K8s.state.get("nodes", []).filter(func(x): return "control-plane" in x.get("roles", []) or "master" in x.get("roles", [])).size()
	var lines := []
	lines.append("[color=#ffec27]%s[/color]" % tr("Adding a control-plane means adding a MACHINE: it is done on the infrastructure, not through the Kubernetes API, so the game cannot do it for you. This is how:"))
	lines.append("")
	lines.append(tr("This cluster has %d control-plane node(s). Use an odd number (3 or 5): etcd needs a majority, so 3 tolerate 1 failure and 5 tolerate 2.") % n)
	lines.append("")
	var cmds := []
	if ctx.begins_with("kind-"):
		lines.append("[color=#83769c]kind[/color]  " + tr("kind cannot add nodes to a running cluster: create one with several control-plane nodes."))
		cmds = ["kind create cluster --config deploy/kind-ha.yaml", "make cluster-ha"]
	elif server.contains("eks.amazonaws.com") or server.contains("azmk8s.io") or server.contains("gke") or ctx.begins_with("gke_") or ctx.contains(":cluster/"):
		lines.append("[color=#83769c]" + tr("managed") + "[/color]  " + tr("Your provider runs the control-plane (it is not shown as nodes) and makes it highly available: choose a regional / HA tier."))
	else:
		lines.append("[color=#83769c]kubeadm[/color]  " + tr("1) on an existing control-plane, upload the certificates and get the key; 2) print the join command; 3) run it on the NEW machine with --control-plane; 4) check."))
		cmds = ["sudo kubeadm init phase upload-certs --upload-certs",
			"kubeadm token create --print-join-command",
			"sudo kubeadm join <api-endpoint>:6443 --token <token> --discovery-token-ca-cert-hash sha256:<hash> --control-plane --certificate-key <key>",
			"kubectl get nodes -l node-role.kubernetes.io/control-plane"]
		lines.append(tr("Requires controlPlaneEndpoint (a load balancer in front of the API servers) set when the cluster was created."))
	for c in cmds:
		lines.append("[color=#ffec27]$[/color] [url=%s]%s[/url]" % [c, c])
	_guide_text.text = "\n".join(lines)
	_guide_panel.visible = true


## Short explanation of the area you just walked into (fades after a while).
func banner(title: String, body: String) -> void:
	if _banner == null:
		_banner = PanelContainer.new()
		_banner.add_theme_stylebox_override("panel", _flat(Color(0.043, 0.051, 0.102, 0.95), Vox.YELLOW, 3, 14))
		_banner.set_anchors_preset(Control.PRESET_CENTER_TOP)
		_banner.grow_horizontal = Control.GROW_DIRECTION_BOTH
		_banner.offset_top = TOP + 6
		_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var v := VBoxContainer.new()
		v.add_theme_constant_override("separation", 4)
		_banner.add_child(v)
		_banner_title = _label("", 28, Vox.YELLOW)
		v.add_child(_banner_title)
		_banner_body = _label("", 22, Vox.WHITE)
		_banner_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		_banner_body.custom_minimum_size = Vector2(620, 0)
		v.add_child(_banner_body)
		_game_root.add_child(_banner)
	_banner_title.text = title
	_banner_body.text = body
	_banner_body.custom_minimum_size.x = minf(620.0, _game_root.size.x - 50.0)
	_banner.size = Vector2.ZERO
	_banner.visible = true
	_banner.modulate.a = 1.0
	_banner_t = 9.0


## Full-screen fade used by the warp pipes (0 = clear, 1 = dark).
func fade(to: float, secs: float) -> void:
	if _fade == null:
		_fade = ColorRect.new()
		_fade.color = Color("0b0d1a")
		_fade.set_anchors_preset(Control.PRESET_FULL_RECT)
		_fade.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_fade.modulate.a = 0.0
		add_child(_fade)
	create_tween().tween_property(_fade, "modulate:a", to, secs)


func focus_terminal() -> void:
	if not Settings.terminal:
		toggle_terminal()
	_terminal.visible = true
	_term_input.grab_focus()


func _term_keys(ev: InputEvent) -> void:
	if not (ev is InputEventKey and ev.pressed):
		return
	Sfx.play("key", null, 0.15)
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


## The terminal already is kubectl: a pasted "kubectl get pods" (or
## "$ kubectl ...", or several lines) becomes "get pods".
func _term_clean(t: String) -> void:
	var clean := clean_kubectl(t)
	if clean != t:
		var col := _term_input.caret_column - (t.length() - clean.length())
		_term_input.text = clean
		_term_input.caret_column = clampi(col, 0, clean.length())


static func clean_kubectl(t: String) -> String:
	var line := t.split("\n")[0] if t.contains("\n") else t
	var s := line.strip_edges(true, false)
	for p in ["$ ", "% ", "> "]:
		if s.begins_with(p):
			s = s.substr(p.length())
	for p in ["kubectl ", "k "]:
		if s.begins_with(p):
			s = s.substr(p.length())
	return s if s != line.strip_edges(true, false) or t.contains("\n") else t


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
	if line.begins_with("edit ") or line.contains(" edit "):
		_term_edit(line)
		return
	term_run(line)


## `kubectl edit` would need a text editor on the bridge host: open the
## in-game one instead. Accepts "edit deploy/web -n shop" or "edit deploy web".
func _term_edit(line: String) -> void:
	var parts := line.split(" ", false)
	var ns := ""
	var rest := []
	var i := 0
	while i < parts.size():
		if parts[i] in ["-n", "--namespace"] and i + 1 < parts.size():
			ns = parts[i + 1]
			i += 2
			continue
		if not parts[i].begins_with("-") and parts[i] != "edit":
			rest.append(parts[i])
		i += 1
	var kind := ""
	var name := ""
	if rest.size() >= 1 and str(rest[0]).contains("/"):
		kind = str(rest[0]).get_slice("/", 0)
		name = str(rest[0]).get_slice("/", 1)
	elif rest.size() >= 2:
		kind = rest[0]
		name = rest[1]
	var kinds := {"deploy": "Deployment", "deployment": "Deployment", "deployments": "Deployment", "sts": "StatefulSet",
		"statefulset": "StatefulSet", "ds": "DaemonSet", "daemonset": "DaemonSet", "svc": "Service", "service": "Service",
		"po": "Pod", "pod": "Pod", "pods": "Pod", "no": "Node", "node": "Node", "cm": "ConfigMap", "configmap": "ConfigMap",
		"job": "Job", "cj": "CronJob", "cronjob": "CronJob", "ns": "Namespace", "namespace": "Namespace"}
	var k: String = kinds.get(kind.to_lower(), "")
	if k == "" or name == "":
		_term_text.append_text("[color=#ff4d6d]%s[/color]\n" % tr("usage: edit <kind>/<name> [-n namespace]  (opens the in-game editor)"))
		return
	if ns == "" and not k in ["Node", "Namespace"]:
		ns = "default"
	_term_text.append_text("[color=#00e436]%s[/color]\n" % (tr("opening the in-game editor for %s %s...") % [k, name]))
	open_editor(k, ns, name)


## Runs a kubectl line in the terminal. Every output gets a "-> Kubi" link
## that attaches it to Kubi's chat. cb(entry: {id, cmd, out, ok}) optional.
func term_run(line: String, cb := Callable()) -> void:
	line = line.strip_edges().trim_prefix("kubectl ").strip_edges()
	_term_text.append_text("[color=#ffec27]$[/color] [color=#fff1e8]kubectl %s[/color]\n" % _esc(line))
	K8s.run_kubectl(line, func(ok: bool, out: String):
		_term_seq += 1
		var entry := {"id": _term_seq, "cmd": "kubectl " + line, "out": out.strip_edges(), "ok": ok}
		term_log.append(entry)
		if term_log.size() > 30:
			term_log.pop_front()
		_term_text.append_text("[color=%s]%s[/color]\n" % ["#c2c3c7" if ok else "#ff4d6d", _esc(out.strip_edges())])
		_term_text.append_text("[url=kubi:%d][color=#ff77a8]%s[/color][/url]\n" % [_term_seq, tr("-> send this output to Kubi")])
		if ok and missions:
			var req := Kubectl.to_action(line)
			if not req.is_empty():
				missions.notify("action", req, true)
		if cb.is_valid():
			cb.call(entry))


## "-> Kubi" link in the terminal: attach that output to Kubi's chat.
func _term_meta(m: String) -> void:
	if not m.begins_with("kubi:"):
		_term_fill(m)
		return
	var id := int(m.substr(5))
	for e in term_log:
		if e.id == id:
			if not kubi.visible:
				kubi.open()
			kubi.attach(e)
			return
	toast(tr("That output is too old, run the command again"), false)


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
	_inspector.move_to_front()
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
			var why: String = d.get("message", "")
			if why != "" and cat != "ok":
				lines.append(_kv("why", "[color=#ffec27]%s[/color]" % why.replace("[", "(")))
			if cat == "done":
				# Not a problem: finished work. Explain it and offer a cleanup.
				var ok_kind: String = d.get("owner_kind", "")
				var who: String = {"Workflow": tr("an Argo Workflow step"), "Job": tr("a Job run")}.get(ok_kind, tr("a one-off task"))
				lines.append("[color=#00e436]%s[/color]" % (tr("It finished its work successfully: it is %s. It uses no CPU or memory; 0/N ready is normal.") % who))
				lines.append("[color=#83769c]%s[/color]" % tr("It stays so you can read its logs. Its owner (or a TTL / podGC setting) decides when it is deleted."))
				var clean := "kubectl -n %s delete pods --field-selector=status.phase==Succeeded" % d.ns
				buttons.append(["CLEAN FINISHED PODS", func(): _clean_finished(d.ns), "DangerButton", ro, clean])
			if float(d.get("cpu_req_m", 0)) > 0 or float(d.get("mem_req", 0)) > 0:
				lines.append(_kv("requests", "cpu %s, mem %s" % [StatsPanel.cores(float(d.get("cpu_req_m", 0))), StatsPanel.mib(float(d.get("mem_req", 0)))]))
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
			var usage := _usage_lines([d], true)
			for i in usage.size():
				lines.insert(3 + i, usage[i])
			buttons.append(["LOGS [L]", func(): open_logs(d), "", false, Kubectl.logs(d.ns, d.name, "", false, true)])
			buttons.append(["EDIT YAML", func(): open_editor("Pod", d.ns, d.name), "", false, "kubectl -n %s edit pod %s" % [d.ns, d.name]])
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
			buttons.append(["EDIT YAML", func(): open_editor(d.kind, d.ns, d.name), "", false, "kubectl -n %s edit %s %s" % [d.ns, str(d.kind).to_lower(), d.name]])
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
			buttons.append(["EDIT YAML", func(): open_editor("Service", d.ns, d.name), "", false, "kubectl -n %s edit service %s" % [d.ns, d.name]])
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
		"gate":
			_insp_title.text = tr("INGRESS - THE DOOR TO THE INTERNET")
			lines.append("[color=#83769c]%s[/color]" % tr("Requests from the Internet arrive by domain (host) and path; the Ingress controller sends each one to a Service inside a namespace. Cars = requests; they stop at the gate (503) when the Service is missing or has no ready pods."))
			var cls: Array = d.get("classes", [])
			lines.append(_kv("controller", ", ".join(cls) if not cls.is_empty() else tr("(default class)")))
			var addr: Array = d.get("address", [])
			lines.append(_kv("address", ", ".join(addr) if not addr.is_empty() else "[color=#ffec27]%s[/color]" % tr("pending (no external address yet)")))
			var rs: Array = d.get("routes", [])
			if rs.is_empty():
				lines.append("[color=#ffec27]%s[/color]" % tr("No Ingress: nothing is published by domain. Services are only reachable inside the cluster (or through a LoadBalancer / NodePort)."))
			for r in rs:
				var st: String = {"ok": "[color=#00e436]%s[/color]" % tr("OK"), "empty": "[color=#ff004d]%s[/color]" % tr("503: no ready pods"),
					"missing": "[color=#ff004d]%s[/color]" % tr("503: Service not found")}.get(r.status, r.status)
				lines.append("[color=#%s]%s%s[/color]%s  ->  %s/%s:%s  %s" % [InternetCity.host_color(r.host).to_html(false),
					r.host if r.host != "" else "*", r.path, "  [HTTPS]" if r.tls else "", r.ns, r.service, r.port, st])
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
			buttons.append(["EDIT YAML", func(): open_editor("Node", "", d.name), "", false, "kubectl edit node %s" % d.name])
			if _insp_target.is_control_plane():
				var add := {"action": "add_control_plane"}
				buttons.append(["+ CONTROL-PLANE", func(): add_cp_requested.emit(), "GoButton", false, Kubectl.for_action(add)])
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
func _usage_lines(pod_list: Array, pod_view := false) -> Array:
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
	elif (rcpu > 0 or rmem > 0) and not pod_view:
		out.append(_kv("requests", "cpu %s, mem %s" % [StatsPanel.cores(rcpu), StatsPanel.mib(rmem)]))
	if not live:
		out.append("[color=#5f574f]%s[/color]" % tr("no live usage: metrics-server not installed"))
	elif seen == 0 and not pod_list.is_empty() and not (pod_view and pod_list[0].get("node", "") == ""):
		out.append("[color=#5f574f]%s[/color]" % tr("no metrics yet (they refresh every 15 s)"))
	return out


## Node capacity: what pods REQUEST (the scheduler only looks at this) and,
## if metrics-server is installed, what they really use.
func _node_usage_lines(n: Dictionary) -> Array:
	var m = K8s.state.get("metrics", {})
	var out := []
	var cap_cpu := float(n.get("cpu_m", 0))
	var cap_mem := float(n.get("mem_bytes", 0))
	var rcpu := 0.0
	var rmem := 0.0
	for p in K8s.state.get("pods", []):
		if p.get("node", "") == n.name and not p.get("deleting", false) and PodBot.categorize(p) != "done":
			rcpu += float(p.get("cpu_req_m", 0))
			rmem += float(p.get("mem_req", 0))
	out.append("[color=#83769c]%s[/color]" % tr("RESERVED (requests) - what the scheduler checks"))
	out.append(_kv("cpu", "%s %s / %s" % [StatsPanel.bar(rcpu / maxf(cap_cpu, 1.0), 10), StatsPanel.cores(rcpu), StatsPanel.cores(cap_cpu)]))
	out.append(_kv("memory", "%s %s / %s" % [StatsPanel.bar(rmem / maxf(cap_mem, 1.0), 10), StatsPanel.mib(rmem), StatsPanel.mib(cap_mem)]))
	out.append(_kv("free", "cpu %s, mem %s" % [StatsPanel.cores(maxf(0.0, cap_cpu - rcpu)), StatsPanel.mib(maxf(0.0, cap_mem - rmem))]))
	if m != null and m.get("available", false) and m.nodes.has(n.name):
		var cpu := float(m.nodes[n.name].cpu_m)
		var mem := float(m.nodes[n.name].mem_bytes)
		out.append("[color=#83769c]%s[/color]" % tr("REAL USE (metrics-server)"))
		out.append(_kv("cpu", "%s %s" % [StatsPanel.bar(cpu / maxf(cap_cpu, 1.0), 10), StatsPanel.cores(cpu)]))
		out.append(_kv("memory", "%s %s" % [StatsPanel.bar(mem / maxf(cap_mem, 1.0), 10), StatsPanel.mib(mem)]))
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


## Deletes the finished (Succeeded) pods of a namespace, after confirming.
func _clean_finished(ns: String) -> void:
	var line := "-n %s delete pods --field-selector=status.phase==Succeeded" % ns
	var n: int = K8s.state.get("pods", []).filter(func(p): return p.ns == ns and PodBot.categorize(p) == "done").size()
	confirm(tr("Delete the %d finished pods of %s? Their logs go away with them; running pods are not touched.") % [n, ns], func():
		if not Settings.terminal and not compact:
			toggle_terminal()
		term_run(line), "kubectl " + line)


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
	kubi = KubiPanel.new()
	kubi.visible = false
	kubi.build(self)
	_modal_layer.add_child(kubi)
	watch = WatchPanel.new()
	watch.visible = false
	watch.build(self)
	_modal_layer.add_child(watch)
	editor = ManifestEditor.new()
	_modal_layer.add_child(editor)
	editor.build(self)
	# Phones have no ESC: one big button closes whatever panel is on top.
	_close_fab = _button("CLOSE X", close_top, "DangerButton")
	_close_fab.custom_minimum_size = Vector2(120, 48)
	_close_fab.visible = false
	_modal_layer.add_child(_close_fab)

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

	# Control-plane guide
	_guide_panel = _modal(60)
	_guide_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	var gv := VBoxContainer.new()
	gv.add_theme_constant_override("separation", 10)
	_guide_panel.add_child(gv)
	var gh := HBoxContainer.new()
	gv.add_child(gh)
	var gt := _label("ADD A CONTROL-PLANE", 30, Vox.YELLOW)
	gt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	gh.add_child(gt)
	gh.add_child(_button("CLOSE [ESC]", func(): _guide_panel.visible = false))
	_guide_text = _rich(24)
	_guide_text.fit_content = false
	_guide_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_guide_text.meta_underlined = false
	_guide_text.selection_enabled = true
	_guide_text.meta_clicked.connect(func(m): _copy(str(m)))
	gv.add_child(_guide_text)

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
	return editor.visible or _guide_panel.visible or _map_panel.visible or _logs_panel.visible or _confirm_panel.visible or _build_panel.visible or _connect_root.visible


func close_modals() -> bool:
	if _confirm_panel.visible:
		_confirm_panel.visible = false
		return true
	if editor.visible:
		editor.request_close()
		return true
	for p in [_confirm_panel, _build_panel, _guide_panel, _map_panel, _logs_panel, _view_panel, _vol_panel, _alarm_panel, _legend, kubi, watch]:
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
	_confirm_panel.move_to_front()  # above the editor / Kubi


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
	var want_compact := touch or sz.x < 760.0
	if want_compact != _was_compact:
		_was_compact = want_compact
		_apply_compact(want_compact)
	if not compact:
		_fit_top_bar(sz.x)
	var top := TOP
	_help_bar.visible = not touch
	overlay.text_scale = 0.82 if compact else 1.0
	# Toasts wrap on narrow screens instead of running off the edges.
	_toast.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART if compact else TextServer.AUTOWRAP_OFF
	_toast.custom_minimum_size.x = (sz.x - 30.0) if compact else 0.0
	_close_fab.visible = compact and _anything_to_close() and not editor.visible
	if _close_fab.visible:
		_close_fab.move_to_front()
		_close_fab.size = Vector2.ZERO
		var fs := _close_fab.get_combined_minimum_size()
		# Right under the open panel(s), on the right: away from the thumbs.
		var lowest := top
		for p in [_inspector, kubi, watch, _legend, _mission_panel, stats, _alarm_panel, _vol_panel, _view_panel, _menu_panel]:
			if p.visible:
				lowest = maxf(lowest, p.get_global_rect().end.y)
		_close_fab.position = Vector2(sz.x - fs.x - 8.0, clampf(lowest + 8.0, top, sz.y * 0.62))
	var bottom := (_help_bar.size.y + 6.0) if _help_bar.visible else 6.0
	# Terminal and feed sit above the help bar.
	var term_floating := _term_drag.place(sz)
	if term_floating:
		# Floating: its size is the player's; the text fills it.
		_term_text.custom_minimum_size.y = 40
		_term_text.size_flags_vertical = Control.SIZE_EXPAND_FILL
	else:
		_term_text.size_flags_vertical = Control.SIZE_FILL
		_term_text.custom_minimum_size.y = 300 if _term_input.has_focus() else 120
		_terminal.offset_bottom = -bottom
		_terminal.offset_top = -bottom - _terminal.get_combined_minimum_size().y
	_feed.offset_bottom = -bottom
	var low := bottom + (_terminal.size.y + 6.0 if _terminal.visible and not term_floating else 0.0)
	# Inspector on the right, legend on the left: scroll when too tall.
	var w := clampf(sz.x * 0.42, 340.0, 560.0)
	_inspector.offset_left = -w - 10
	# The inspector may cover the terminal, never the other way round.
	var max_h := sz.y - top - bottom - 10
	var want := _insp_box.get_combined_minimum_size().y + 36
	_insp_scroll.custom_minimum_size = Vector2(w - 36, clampf(want - 36, 60, max_h - 36))
	_inspector.size.y = 0
	_mission_panel.size = Vector2.ZERO
	stats.size = Vector2.ZERO
	stats.offset_top = TOP + ((_mission_panel.size.y + 8) if _mission_panel.visible else 0.0)
	# The terminal grows wider while you type in it.
	if not term_floating:
		_terminal.anchor_left = (0.34 if stats.visible else 0.25) if _term_input.has_focus() else 0.5
	var lw := clampf(sz.x * 0.4, 320.0, 560.0)
	var scroll: ScrollContainer = _legend.get_node("Scroll")
	var lwant: float = scroll.get_child(0).get_combined_minimum_size().y
	scroll.custom_minimum_size = Vector2(lw, clampf(lwant, 60, sz.y - top - bottom - 50))
	_legend.size = Vector2.ZERO
	var mm: Control = _game_root.get_node("Minimap")
	var msz: Vector2 = mm.get_combined_minimum_size()
	mm.offset_left = 10
	mm.offset_bottom = -bottom
	mm.offset_top = -bottom - msz.y
	mm.offset_right = 10 + msz.x
	# Kubi on the left, the watchtower on the right (over the inspector).
	var pw := clampf(sz.x * 0.4, 360.0, 640.0)
	# Kubi starts compact (drag/resize it to taste).
	var krect := Rect2(10.0, top, minf(pw, 470.0), minf(sz.y - top - bottom, 430.0))
	var wh: float = watch.get_combined_minimum_size().y if watch.collapsed else sz.y - top - bottom
	if compact:
		# Phones: panels use the full width; the lower part stays for the
		# thumbs (joystick and buttons).
		pw = sz.x - 16.0
		krect = Rect2(8.0, top, pw, maxf(260.0, sz.y * 0.58 - top))
		if not watch.collapsed:
			wh = maxf(260.0, sz.y * 0.58 - top)
		_inspector.offset_left = -pw - 8
		_inspector.offset_right = -8
		_insp_scroll.custom_minimum_size = Vector2(pw - 36, clampf(want - 36, 60, maxf(120.0, sz.y * 0.5 - top)))
		_inspector.size.y = 0
		if not term_floating:
			_terminal.anchor_left = 0.0
			_terminal.offset_left = 8
		_mission_panel.get_child(0).custom_minimum_size.x = minf(380.0, sz.x - 40.0)
		mm.offset_left = 8
		mm.offset_right = 8 + msz.x
		mm.offset_top = top
		mm.offset_bottom = top + msz.y
		# Small minimap on phones (it sits under the top bars).
		map_mini.custom_minimum_size = (MINIMAP_SIZES[Settings.minimap_size] as Vector2).min(Vector2(sz.x * 0.42, sz.y * 0.24))
		# Narrow screens: shorter title bar so the MENU button always fits.
		var narrow := sz.x < 560
		_ctx_label.visible = not narrow
		var logo: Label = _game_root.find_child("Logo", true, false)
		logo.add_theme_font_size_override("font_size", 11 if narrow else 16)
		var grid: GridContainer = _menu_panel.get_node("Grid")
		grid.columns = 3 if sz.x > 420 else 2
	kubi.place(krect, sz)
	watch.size = Vector2(pw, wh)
	watch.position = Vector2(sz.x - pw - (8.0 if compact else 10.0), top)
	# Centered dialogs: size to content, center, keep on screen.
	var full := _modal_layer.size
	for p in [_confirm_panel, _build_panel]:
		if p.visible:
			var ps: Vector2 = p.get_combined_minimum_size().min(full - Vector2(20, 20))
			p.size = ps
			p.position = ((full - ps) * 0.5).floor()
	for p in [_logs_panel, _map_panel, _guide_panel]:
		var m: float = p.get_meta("margin")
		p.offset_left = m
		p.offset_top = m
		p.offset_right = -m
		p.offset_bottom = -m


# ------------------------------------------------------------------ tick

func _process(delta: float) -> void:
	StatsPanel.probe(delta)
	if _banner_t > 0.0:
		_banner_t -= delta
		_banner.modulate.a = clampf(_banner_t, 0.0, 1.0)
		if _banner_t <= 0.0:
			_banner.visible = false
	_perf_t += delta
	if _perf_t > 0.5 and _perf_label:
		_perf_t = 0.0
		_perf_label.text = clock_text + "  " + StatsPanel.summary()
	_insp_t += delta
	if _insp_t > 0.3:
		_insp_t = 0.0
		_refresh_inspector()
	if _game_root.visible:
		_layout()
	else:
		_layout_modals()
	if _connect_root.visible:
		var sc: ScrollContainer = _connect_root.get_child(0).get_node("Scroll")
		var want: float = sc.get_child(0).get_combined_minimum_size().y
		var screen: Vector2 = get_viewport().get_visible_rect().size  # the root grows with its content: use the screen
		sc.custom_minimum_size = Vector2(minf(740.0, screen.x - 40.0), minf(want, screen.y - 70))
		# Phones: one column, smaller title.
		var narrow := screen.x < 700.0
		_connect_v.custom_minimum_size.x = minf(720.0, screen.x - 90.0)
		_connect_grid.columns = 1 if narrow else 2
		_connect_title.add_theme_font_size_override("font_size", 22 if narrow else 38)
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
