class_name KubiPanel
extends PanelContainer
## Kubi's panel (Y). Two pages:
##  - chat: problems with a built-in diagnosis, and a free conversation with
##    the AI (with memory of the last turns). The "topic" is the selected
##    problem or the whole cluster.
##  - settings: AI engine (Ollama / built-in llama.cpp), model, answer
##    length, and downloads of llama.cpp and models with progress.
## Drag the title bar to move it, any border or corner to resize it, "_" to fold it.
## Commands that only read run straight away in the terminal; commands that
## change things are only typed in (you press Enter).

signal act(id: String, diag: Dictionary)
signal thinking(on: bool)
signal answered(text: String)

var hud  # Hud: styles, terminal, confirm dialog
var custom_rect := Rect2()   # set once the player moves/resizes it (UI units)
var collapsed := false
var _list: VBoxContainer
var _diag: RichTextLabel
var _acts: HFlowContainer
var _chat: RichTextLabel
var _input: LineEdit
var _ask_btn: Button
var _status: Label
var _topic: Label
var _scroll: ScrollContainer
var _chat_page: VBoxContainer
var _settings_page: VBoxContainer
var _bottom: Array[Control] = []   # hidden when folded
var _fold_btn: Button
var _drag := ""                    # "" | move | resize
var _problems: Array = []
var _sel: Dictionary = {}
var _llm := false
var _busy := false
var _history := []   # [{role, content}] of this conversation
var _st: Dictionary = {}   # last status from the bridge
var _poll := 0.0
# settings widgets
var _engine: OptionButton
var _length: OptionButton
var _style: OptionButton
var _ollama_model: OptionButton
var _engine_state: RichTextLabel
var _ollama_box: VBoxContainer
var _llama_box: VBoxContainer
var _dl_box: VBoxContainer
var _sig := ""
var _attachments := []   # terminal outputs for the next question [{id, cmd, out, ok}]
var _att_box: HFlowContainer
var _explain_btn: Button
const ENGINES := ["auto", "ollama", "llamacpp", "off"]
const LENGTHS := ["short", "normal", "long"]
const MIN_SIZE := Vector2(360, 220)


func build(h) -> void:
	hud = h
	# Wheel and drags over the panel are the panel's: never zoom/pan the camera.
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", hud._flat(Color(0.04, 0.03, 0.07, 1.0), Vox.RED, 3, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	head.mouse_filter = Control.MOUSE_FILTER_STOP
	head.mouse_default_cursor_shape = Control.CURSOR_MOVE
	head.gui_input.connect(func(e): _drag_input(e, "move"))
	v.add_child(head)
	var title: Label = hud._label("KUBI", 30, Vox.RED)
	title.add_theme_font_override("font", hud._title_font)
	title.add_theme_font_size_override("font_size", 18)
	title.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_child(title)
	_status = hud._label("", 20, Vox.LAVENDER)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.mouse_filter = Control.MOUSE_FILTER_PASS
	head.add_child(_status)
	head.add_child(hud._button("SETTINGS", toggle_settings))
	_fold_btn = hud._button("_", func(): set_collapsed(not collapsed))
	head.add_child(_fold_btn)
	head.add_child(hud._button("X", func(): visible = false))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	_bottom.append(_scroll)
	var pages := VBoxContainer.new()
	pages.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(pages)
	_chat_page = _build_chat_page()
	pages.add_child(_chat_page)
	_settings_page = _build_settings_page()
	_settings_page.visible = false
	pages.add_child(_settings_page)
	# Topic + input stay at the bottom.
	var trow := HBoxContainer.new()
	trow.add_theme_constant_override("separation", 8)
	v.add_child(trow)
	_bottom.append(trow)
	_topic = hud._label("", 20, Vox.PEACH)
	_topic.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_topic.clip_text = true
	trow.add_child(_topic)
	trow.add_child(hud._button("WHOLE CLUSTER", func(): _set_topic({})))
	trow.add_child(hud._button("NEW CHAT", new_chat))
	var quick := HFlowContainer.new()
	quick.add_theme_constant_override("h_separation", 8)
	quick.add_theme_constant_override("v_separation", 6)
	_explain_btn = hud._button("What does this output mean?", func(): ask(tr("What does this output mean? Anything wrong?")), "GoButton")
	_explain_btn.visible = false
	quick.add_child(_explain_btn)
	for q in ["What is wrong?", "How do I fix it?", "Explain it simply"]:
		quick.add_child(hud._button(q, func(): ask(tr(q))))
	v.add_child(quick)
	_bottom.append(quick)
	_att_box = HFlowContainer.new()
	_att_box.add_theme_constant_override("h_separation", 6)
	_att_box.add_theme_constant_override("v_separation", 4)
	v.add_child(_att_box)
	_bottom.append(_att_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_bottom.append(row)
	_input = LineEdit.new()
	_input.placeholder_text = tr("Talk to Kubi about anything...")
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.add_theme_font_size_override("font_size", 24)
	_input.text_submitted.connect(func(t): ask(t))
	row.add_child(_input)
	_ask_btn = hud._button("ASK", func(): ask(_input.text))
	row.add_child(_ask_btn)
	# Resize grip in the bottom-right corner.
	var grip: Label = hud._label("◢", 26, Vox.RED)
	grip.mouse_filter = Control.MOUSE_FILTER_STOP
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.tooltip_text = tr("Drag to resize")
	grip.gui_input.connect(func(e): _drag_input(e, "resize"))
	row.add_child(grip)
	_set_topic({})


## Title bar drag = move; corner grip drag = resize. Positions are in the
## HUD's UI units (the same space as the panel's position and size).
func _drag_input(e: InputEvent, what: String) -> void:
	if e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		_drag = what if e.pressed else ""
		if e.pressed and custom_rect.size == Vector2.ZERO:
			custom_rect = Rect2(position, size)
		if e.double_click and what == "move":
			set_collapsed(not collapsed)
		accept_event()
	elif e is InputEventMouseMotion and _drag == what:
		var rel: Vector2 = e.relative * get_global_transform().get_scale()
		if what == "move":
			custom_rect.position += rel
		else:
			custom_rect.size = (custom_rect.size + rel).max(MIN_SIZE)
		accept_event()


const EDGE := 12.0
var _edge := ""   # edges being dragged: any of "l", "r", "t", "b"


func _edge_at(p: Vector2) -> String:
	var e := ""
	if p.x < EDGE: e += "l"
	elif p.x > size.x - EDGE: e += "r"
	if p.y < EDGE: e += "t"
	elif p.y > size.y - EDGE and not collapsed: e += "b"
	return e


## Resize from any border or corner (the frame around the content).
func _gui_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and _drag == "":
		var ed := _edge_at(e.position)
		mouse_default_cursor_shape = {"l": CURSOR_HSIZE, "r": CURSOR_HSIZE, "t": CURSOR_VSIZE, "b": CURSOR_VSIZE,
			"lt": CURSOR_FDIAGSIZE, "rb": CURSOR_FDIAGSIZE, "rt": CURSOR_BDIAGSIZE, "lb": CURSOR_BDIAGSIZE}.get(ed, CURSOR_ARROW)
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		if e.pressed:
			_edge = _edge_at(e.position)
			if _edge != "":
				_drag = "edge"
				if custom_rect.size == Vector2.ZERO:
					custom_rect = Rect2(position, size)
				accept_event()
		elif _drag == "edge":
			_drag = ""
			accept_event()
	elif e is InputEventMouseMotion and _drag == "edge":
		var rel: Vector2 = e.relative * get_global_transform().get_scale()
		var r := custom_rect
		if _edge.contains("r"):
			r.size.x += rel.x
		if _edge.contains("b"):
			r.size.y += rel.y
		if _edge.contains("l"):
			var w := maxf(MIN_SIZE.x, r.size.x - rel.x)
			r.position.x += r.size.x - w
			r.size.x = w
		if _edge.contains("t"):
			var h := maxf(MIN_SIZE.y, r.size.y - rel.y)
			r.position.y += r.size.y - h
			r.size.y = h
		custom_rect = Rect2(r.position, r.size.max(MIN_SIZE))
		accept_event()


func set_collapsed(on: bool) -> void:
	collapsed = on
	for c in _bottom:
		c.visible = not on
	_fold_btn.text = "+" if on else "_"


## Where the panel goes: the player's rect if moved (kept on screen), or the
## default column on the left.
func place(default_rect: Rect2, screen: Vector2) -> void:
	var r := default_rect if custom_rect.size == Vector2.ZERO else custom_rect
	r.size = r.size.min(screen - Vector2(20, 20)).max(MIN_SIZE)
	if collapsed:
		r.size.y = get_combined_minimum_size().y
	# Sideways it may hang partly off screen; vertically it always fits.
	r.position.x = clampf(r.position.x, -r.size.x + 120.0, screen.x - 120.0)
	r.position.y = clampf(r.position.y, 0.0, maxf(0.0, screen.y - r.size.y - 6.0))
	if custom_rect.size != Vector2.ZERO:
		custom_rect.position = r.position
	position = r.position
	size = r.size


func _build_chat_page() -> VBoxContainer:
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	body.add_child(hud._section("PROBLEMS"))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 4)
	body.add_child(_list)
	_diag = hud._rich(22)
	_diag.meta_clicked.connect(_on_cmd)
	body.add_child(_diag)
	_acts = HFlowContainer.new()
	_acts.add_theme_constant_override("h_separation", 8)
	_acts.add_theme_constant_override("v_separation", 6)
	body.add_child(_acts)
	body.add_child(hud._section("CHAT"))
	_chat = hud._rich(22)
	_chat.meta_clicked.connect(_on_cmd)
	body.add_child(_chat)
	return body


func _opt(items: Array, cb: Callable) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_NONE
	for it in items:
		o.add_item(tr(it))
	o.item_selected.connect(func(_i): cb.call())
	return o


func _row(label: String, ctl: Control) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 10)
	var l: Label = hud._label(label, 22, Vox.SILVER)
	l.custom_minimum_size.x = 150
	r.add_child(l)
	ctl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_child(ctl)
	return r


func _build_settings_page() -> VBoxContainer:
	var s := VBoxContainer.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_theme_constant_override("separation", 8)
	s.add_child(hud._section("AI ENGINE"))
	_engine = _opt(["Automatic", "Ollama", "Built-in llama.cpp", "Off (built-in guide only)"], _save_config)
	s.add_child(_row(tr("Engine"), _engine))
	_length = _opt(["Short", "Normal", "Long"], _save_config)
	s.add_child(_row(tr("Answers"), _length))
	_style = _opt(["Precise", "Creative"], _save_config)
	s.add_child(_row(tr("Style"), _style))
	_engine_state = hud._rich(20)
	s.add_child(_engine_state)
	var note: Label = hud._label(tr("Everything runs on this machine: cluster data never leaves it. Cloud models are not allowed."), 18, Vox.LAVENDER)
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	s.add_child(note)
	s.add_child(hud._section("OLLAMA"))
	_ollama_model = _opt([], _save_config)
	s.add_child(_row(tr("Model"), _ollama_model))
	_ollama_box = VBoxContainer.new()
	_ollama_box.add_theme_constant_override("separation", 4)
	s.add_child(_ollama_box)
	s.add_child(hud._section("BUILT-IN LLAMA.CPP"))
	_llama_box = VBoxContainer.new()
	_llama_box.add_theme_constant_override("separation", 4)
	s.add_child(_llama_box)
	s.add_child(hud._section("DOWNLOADS"))
	_dl_box = VBoxContainer.new()
	_dl_box.add_theme_constant_override("separation", 4)
	s.add_child(_dl_box)
	return s


func open() -> void:
	visible = true
	refresh_status()
	refresh(K8s.state)


func toggle_settings() -> void:
	if collapsed:
		set_collapsed(false)
	_settings_page.visible = not _settings_page.visible
	_chat_page.visible = not _settings_page.visible
	_sig = ""
	refresh_status()


func new_chat() -> void:
	_history.clear()
	_chat.clear()


func _set_topic(d: Dictionary) -> void:
	_sel = d
	if d.is_empty():
		_topic.text = tr("Topic: the whole cluster")
		_diag.text = ""
		_clear_acts()
	else:
		_topic.text = tr("Topic: %s %s%s") % [d.kind, (d.ns + "/") if d.ns != "" else "", d.name]


func _process(delta: float) -> void:
	if not visible:
		return
	_poll -= delta
	var busy_dl := false
	for d in _st.get("downloads", []):
		busy_dl = busy_dl or d.status == "running"
	if _poll <= 0.0:
		_poll = 1.0 if busy_dl or _settings_page.visible else 6.0
		refresh_status()


func refresh_status() -> void:
	K8s.assistant_status(func(st: Dictionary):
		_st = st
		_llm = bool(st.get("llm", false))
		if _llm:
			_status.text = tr("AI: %s (%s)") % [st.get("model", "?"), {"ollama": "Ollama", "llamacpp": "llama.cpp"}.get(st.get("engine", ""), "")]
		elif st.get("demo", false):
			_status.text = tr("demo: built-in guide only (connect a bridge to use AI)")
		else:
			_status.text = tr("built-in guide only") + " · " + tr("SETTINGS = set up AI")
		if _settings_page.visible:
			_fill_settings(st))


## Updates the settings page (lists are only rebuilt when something changed,
## so the option buttons keep working while downloads progress).
func _fill_settings(st: Dictionary) -> void:
	if st.get("demo", false) or not st.has("config"):
		_engine_state.text = "[color=#ffa300]%s[/color]" % tr("Needs a bridge: in demo mode Kubi only has its built-in guide.")
		return
	var cfg: Dictionary = st.config
	_engine.select(maxi(0, ENGINES.find(cfg.get("provider", "auto"))))
	_length.select(maxi(0, LENGTHS.find(cfg.get("length", "normal"))))
	_style.select(1 if float(cfg.get("temperature", 0.2)) > 0.45 else 0)
	var eng: String = {"ollama": "Ollama", "llamacpp": "llama.cpp"}.get(st.get("engine", ""), "")
	if st.get("llm", false):
		_engine_state.text = "[color=#00e436]%s[/color] %s (%s)" % [tr("Using"), st.model, eng]
	else:
		_engine_state.text = "[color=#ffa300]%s[/color] %s" % [tr("No AI:"), tr(str(st.get("why", "")))]
	var ol: Dictionary = st.get("ollama", {})
	var lc: Dictionary = st.get("llamacpp", {})
	var models: Array = ol.get("models", []).filter(func(m): return not str(m).contains("cloud"))
	var sig := JSON.stringify([models, ol.get("up"), lc, st.get("gguf"), cfg])
	if sig != _sig:
		_sig = sig
		_ollama_model.clear()
		_ollama_model.add_item(tr("Automatic (best installed)"))
		_ollama_model.set_item_metadata(0, "auto")
		for m in models:
			_ollama_model.add_item(m)
			_ollama_model.set_item_metadata(_ollama_model.item_count - 1, m)
			if m == cfg.get("ollama_model", "auto"):
				_ollama_model.select(_ollama_model.item_count - 1)
		_ollama_model.disabled = not ol.get("up", false)
		_fill_ollama(ol, models)
		_fill_llama(lc, st.get("gguf", []), cfg)
	_fill_downloads(st.get("downloads", []))


func _fill_ollama(ol: Dictionary, models: Array) -> void:
	for c in _ollama_box.get_children():
		c.queue_free()
	if not ol.get("up", false):
		var t: RichTextLabel = hud._rich(20)
		t.text = "[color=#83769c]%s[/color] %s\n%s [url=https://ollama.com/download]ollama.com/download[/url]" % [
			tr("Not running at"), ol.get("url", ""), tr("Optional. Install it and run `ollama serve`, or use the built-in llama.cpp below:")]
		t.meta_clicked.connect(func(m): OS.shell_open(str(m)))
		_ollama_box.add_child(t)
		return
	_ollama_box.add_child(hud._label(tr("Download into Ollama:"), 20, Vox.LAVENDER))
	for c in ol.get("catalog", []):
		var have: bool = models.any(func(m): return str(m) == c.name or str(m).trim_suffix(":latest") == c.name)
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 8)
		var l: RichTextLabel = hud._rich(20)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		l.text = "[color=#fff1e8]%s[/color] [color=#83769c]%s · %s[/color]" % [c.name, c.size, tr(c.desc)]
		r.add_child(l)
		if have:
			r.add_child(hud._label(tr("installed"), 20, Vox.GREEN))
		else:
			r.add_child(hud._button("DOWNLOAD", func(): _confirm_download("ollama", c.name,
				tr("Download %s (%s) into your Ollama?") % [c.name, c.size], "ollama pull " + c.name)))
		_ollama_box.add_child(r)


func _fill_llama(lc: Dictionary, gguf: Array, cfg: Dictionary) -> void:
	for c in _llama_box.get_children():
		c.queue_free()
	var t: RichTextLabel = hud._rich(20)
	if lc.get("installed", false):
		t.text = "[color=#00e436]%s[/color] %s%s" % [tr("Installed"), lc.get("version", ""),
			("  [color=#83769c]· %s[/color]" % tr("running")) if lc.get("running", false) else ""]
		if str(lc.get("error", "")) != "":
			t.text += "\n[color=#ff004d]%s[/color]" % hud._esc(str(lc.error))
		_llama_box.add_child(t)
	else:
		t.text = "[color=#ffa300]%s[/color] %s" % [tr("Not installed."), tr("KubeCraft can download the official build from github.com/ggml-org/llama.cpp (about 15 MB, SHA256 verified) into ~/.kubecraft.")]
		_llama_box.add_child(t)
		if str(lc.get("platform", "")) != "":
			_llama_box.add_child(hud._button("DOWNLOAD LLAMA.CPP", func(): _confirm_download("llamacpp", "",
				tr("Download the official llama.cpp build (%s) from GitHub ggml-org? It is checked with SHA256 and only listens on 127.0.0.1.") % lc.platform, "")))
	_llama_box.add_child(hud._label(tr("Models (GGUF, Hugging Face, SHA256 pinned):"), 20, Vox.LAVENDER))
	for m in gguf:
		var r := HBoxContainer.new()
		r.add_theme_constant_override("separation", 8)
		var l: RichTextLabel = hud._rich(20)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var using: bool = m.installed and cfg.get("llama_model", "") == m.id
		l.text = "[color=%s]%s[/color] [color=#83769c]%s · %s[/color]" % ["#00e436" if using else "#fff1e8", m.name, Vox.fmt_mib(float(m.size)), tr(m.desc)]
		r.add_child(l)
		if m.installed:
			if using:
				r.add_child(hud._label(tr("in use"), 20, Vox.GREEN))
			else:
				r.add_child(hud._button("USE", func(): _use_gguf(m.id)))
			r.add_child(hud._button("DELETE", func():
				hud.confirm(tr("Delete the model %s (%s) from this machine?") % [m.name, Vox.fmt_mib(float(m.size))], func():
					K8s.assistant_delete_model(m.id, func(_ok, _e): refresh_status()), ""), "DangerButton"))
		else:
			r.add_child(hud._button("DOWNLOAD", func(): _confirm_download("gguf", m.id,
				tr("Download %s (%s) from %s? It is checked with SHA256 and saved in ~/.kubecraft/models.") % [m.name, Vox.fmt_mib(float(m.size)), m.source], "")))
		_llama_box.add_child(r)


func _fill_downloads(dls: Array) -> void:
	for c in _dl_box.get_children():
		c.queue_free()
	if dls.is_empty():
		_dl_box.add_child(hud._label(tr("None."), 20, Vox.LAVENDER))
	for d in dls:
		var r := VBoxContainer.new()
		var total := float(d.get("total", 0))
		var pct := (float(d.get("done", 0)) / total * 100.0) if total > 0 else 0.0
		var col: Color = {"running": Vox.YELLOW, "done": Vox.GREEN, "error": Vox.RED}.get(d.status, Vox.WHITE)
		var txt: String = "%s  %s" % [d.label, {"running": "%d%%" % pct, "done": tr("done"), "error": tr("failed")}.get(d.status, "")]
		if total > 0 and d.status == "running":
			txt += "  (%s / %s)" % [Vox.fmt_mib(float(d.done)), Vox.fmt_mib(total)]
		r.add_child(hud._label(txt, 20, col))
		if d.status == "running":
			var bar := ProgressBar.new()
			bar.max_value = 100
			bar.value = pct
			bar.show_percentage = false
			bar.custom_minimum_size.y = 10
			r.add_child(bar)
		if str(d.get("error", "")) != "":
			var e: Label = hud._label(str(d.error), 18, Vox.RED)
			e.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			r.add_child(e)
		_dl_box.add_child(r)


func _confirm_download(kind: String, id: String, text: String, cmd: String) -> void:
	hud.confirm(text, func():
		K8s.assistant_download(kind, id, func(ok: bool, err: String):
			if not ok:
				hud.toast(err, false)
			_poll = 0.3
			refresh_status()), cmd)


func _use_gguf(id: String) -> void:
	var cfg: Dictionary = _st.get("config", {}).duplicate()
	cfg.llama_model = id
	if cfg.get("provider", "auto") == "ollama":
		cfg.provider = "llamacpp"
	_send_config(cfg)


func _save_config() -> void:
	if not _st.has("config"):
		return
	var cfg: Dictionary = _st.config.duplicate()
	cfg.provider = ENGINES[_engine.selected]
	cfg.length = LENGTHS[_length.selected]
	cfg.temperature = 0.7 if _style.selected == 1 else 0.2
	if _ollama_model.selected >= 0 and _ollama_model.item_count > 0:
		cfg.ollama_model = str(_ollama_model.get_item_metadata(_ollama_model.selected))
	_send_config(cfg)


func _send_config(cfg: Dictionary) -> void:
	K8s.assistant_config(cfg, func(ok: bool, err: String):
		if not ok:
			hud.toast(err, false)
		_sig = ""
		refresh_status())


## Rebuilds the problem list (keeps the selection if it still exists).
func refresh(state: Dictionary) -> void:
	_problems = Diagnose.problems(state)
	for c in _list.get_children():
		c.queue_free()
	if _problems.is_empty():
		_list.add_child(hud._label(tr("Nothing broken right now. Ask me anything below!"), 22, Vox.GREEN))
	for i in mini(_problems.size(), 4):
		var d: Dictionary = _problems[i]
		var col: Color = [Vox.SILVER, Vox.YELLOW, Vox.ORANGE, Vox.RED][clampi(d.sev, 0, 3)]
		var label := "%s  %s%s" % [d.title, (d.ns + "/") if d.ns != "" else "", d.name]
		var b: Button = hud._button(label, func(): select(d))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", col)
		b.clip_text = true
		_list.add_child(b)
	if _problems.size() > 4:
		_list.add_child(hud._label(tr("... and %d more") % (_problems.size() - 4), 20, Vox.LAVENDER))
	if not _sel.is_empty():
		for d in _problems:
			if d.kind == _sel.kind and d.ns == _sel.ns and d.name == _sel.name:
				_show(d)
				return


func select(d: Dictionary) -> void:
	_show(d)


## Focus the panel on an entity the player is inspecting.
func focus_entity(kind: String, data: Dictionary) -> void:
	var d := {}
	match kind:
		"Pod": d = Diagnose.pod(data, K8s.state)
		"Node": d = Diagnose.node(data, K8s.state)
	if not d.is_empty() and d.title != "":
		_show(d)


func selected() -> Dictionary:
	return _sel


func _show(d: Dictionary) -> void:
	_set_topic(d)
	var t := "[color=#ffec27][font_size=26]%s[/font_size][/color]\n[color=#c2c3c7]%s %s%s[/color]\n\n%s\n" % [
		d.title, d.kind, (d.ns + "/") if d.ns != "" else "", d.name, hud._esc(d.why)]
	if not d.steps.is_empty():
		t += "\n[color=#83769c]%s[/color]\n" % tr("HOW TO FIX IT")
		for i in d.steps.size():
			t += "[color=#ffec27]%d.[/color] %s\n" % [i + 1, hud._esc(d.steps[i])]
	if not d.cmds.is_empty():
		t += "\n[color=#83769c]%s[/color]\n" % tr("COMMANDS (click: reading ones run, the rest are typed in the terminal for you to review)")
		for c in d.cmds:
			t += "[color=#ffec27]$[/color] [url=%s]%s[/url]\n" % [c, hud._esc(c)]
	_diag.text = t
	_clear_acts()
	for a in d.acts:
		var b: Button = hud._button(a.label, func(): act.emit(a.id, d), "DangerButton" if a.id in ["delete_pod", "restart"] else "")
		_acts.add_child(b)


func _clear_acts() -> void:
	for c in _acts.get_children():
		c.queue_free()


## A command clicked in the diagnosis or in an answer: reading ones run now
## and their output is attached to the chat; the rest go to the terminal
## input for you to review (their output can be sent back with "-> Kubi").
func _on_cmd(meta) -> void:
	var cmd := str(meta)
	if Diagnose.is_read_only(cmd) and not cmd.contains("|") and not cmd.contains("<"):
		if not Settings.terminal:
			hud.toggle_terminal()
		_chat.append_text("\n[color=#83769c]%s[/color] [color=#ffec27]%s[/color]\n" % [tr("Running"), hud._esc(cmd)])
		hud.term_run(cmd, func(entry: Dictionary): attach(entry))
	else:
		hud._term_fill(cmd)
		_chat.append_text("\n[color=#83769c]%s[/color]\n" % tr("It changes the cluster, so it is typed in the terminal for you to review: press Enter to run it. Then use '-> send this output to Kubi'."))
		_scroll_down()


## Adds a terminal output to the next question (shown as a chip; click to remove).
func attach(entry: Dictionary) -> void:
	for a in _attachments:
		if a.id == entry.id:
			return
	_attachments.append(entry)
	if _attachments.size() > 3:
		_attachments.pop_front()
	var lines: PackedStringArray = str(entry.out).split("\n")
	var preview := "\n".join(lines.slice(0, 6))
	_chat.append_text("[color=#83769c]%s[/color] [color=#fff1e8]%s[/color] [color=#83769c](%d %s)[/color]\n[color=#c2c3c7][font_size=18]%s%s[/font_size][/color]\n" % [
		tr("Attached for Kubi:"), hud._esc(entry.cmd), lines.size(), tr("lines"), hud._esc(preview), "\n..." if lines.size() > 6 else ""])
	_render_attachments()
	_scroll_down()


func _render_attachments() -> void:
	for c in _att_box.get_children():
		c.queue_free()
	for a in _attachments:
		var b: Button = hud._button("[x] %s" % str(a.cmd).left(48), func():
			_attachments.erase(a)
			_render_attachments())
		b.tooltip_text = tr("Remove this output")
		b.add_theme_color_override("font_color", Vox.PINK)
		_att_box.add_child(b)
	_explain_btn.visible = not _attachments.is_empty()


## Asks a question: to the AI when the bridge has one (with the conversation
## so far), otherwise the built-in guide answers about the selected problem.
func ask(q: String) -> void:
	q = q.strip_edges()
	if q == "" or _busy:
		return
	if _settings_page.visible:
		toggle_settings()
	if collapsed:
		set_collapsed(false)
	_input.text = ""
	_chat.append_text("\n[color=#29adff]%s:[/color] %s\n" % [tr("You"), hud._esc(q)])
	if not _llm:
		_attachments.clear()
		_render_attachments()
		var a := _offline_answer(q)
		_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % a)
		answered.emit(a)
		_scroll_down()
		return
	_busy = true
	_ask_btn.disabled = true
	thinking.emit(true)
	_chat.append_text("[color=#83769c]%s[/color]\n" % tr("Kubi is thinking... (a local model can take a few seconds)"))
	var atts := _attachments.map(func(a): return {"cmd": a.cmd, "output": str(a.out).left(6000)})
	var req := {"question": q, "lang": TranslationServer.get_locale(), "kind": _sel.get("kind", ""),
		"ns": _sel.get("ns", ""), "name": _sel.get("name", ""),
		"diagnosis": Diagnose.as_text(_sel) if not _sel.is_empty() else "",
		"history": _history.slice(maxi(0, _history.size() - 10)), "attachments": atts}
	# The outputs go with this question (and a short copy stays in the memory).
	var remembered := q
	for a in atts:
		remembered += "\n[output of %s]\n%s" % [a.cmd, str(a.output).left(1000)]
	_attachments.clear()
	_render_attachments()
	K8s.ask_assistant(req, func(ok: bool, text: String):
		_busy = false
		_ask_btn.disabled = false
		thinking.emit(false)
		if ok:
			_history.append({"role": "user", "content": remembered})
			_history.append({"role": "assistant", "content": text})
			_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % _format(text))
			answered.emit(text)
		else:
			_chat.append_text("[color=#ff4d6d]%s[/color] %s\n" % [tr("Kubi can't reach its brain:"), hud._esc(text)])
			_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % _offline_answer(q))
		_scroll_down())
	_scroll_down()


## Markdown-ish answer -> BBCode; `kubectl ...` commands become clickable.
func _format(text: String) -> String:
	var out: String = hud._esc(text)
	var re := RegEx.new()
	re.compile("`([^`\\n]+)`")
	for m in re.search_all(out):
		var raw := m.get_string(1).replace("[lb]", "[")
		if raw.begins_with("kubectl "):
			out = out.replace(m.get_string(0), "[url=%s][color=#ffec27]%s[/color][/url]" % [raw, m.get_string(1)])
		else:
			out = out.replace(m.get_string(0), "[color=#ffa300]%s[/color]" % m.get_string(1))
	var bold := RegEx.new()
	bold.compile("\\*\\*([^*]+)\\*\\*")
	out = bold.sub(out, "[b]$1[/b]", true)
	var ital := RegEx.new()
	ital.compile("\\*([^*\\n]+)\\*")
	out = ital.sub(out, "[i]$1[/i]", true)
	return out


func _offline_answer(_q: String) -> String:
	if _sel.is_empty():
		return tr("Without AI I only have my built-in guide: pick a problem above and I'll explain it. To chat about anything, set up an AI engine in SETTINGS.")
	var t: String = "%s — %s" % [_sel.title, hud._esc(_sel.why)]
	if not _sel.steps.is_empty():
		t += "\n" + tr("Start with: %s") % hud._esc(_sel.steps[0])
	return t


func _scroll_down() -> void:
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func has_input_focus() -> bool:
	return _input.has_focus()
