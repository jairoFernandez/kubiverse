class_name KubiPanel
extends PanelContainer
## Kubi's panel (Y): the list of problems, a diagnosis with steps and
## commands for the selected one, and a chat with the bridge's local
## language model. Commands that only read run straight away in the
## terminal; commands that change things are only typed in (you press Enter).

signal act(id: String, diag: Dictionary)
signal thinking(on: bool)
signal answered(text: String)

var hud  # Hud: styles, terminal
var _list: VBoxContainer
var _diag: RichTextLabel
var _acts: HFlowContainer
var _chat: RichTextLabel
var _input: LineEdit
var _ask_btn: Button
var _status: Label
var _scroll: ScrollContainer
var _problems: Array = []
var _sel: Dictionary = {}
var _llm := false
var _busy := false
var _history := []   # [{q, a}] for this session


func build(h) -> void:
	hud = h
	add_theme_stylebox_override("panel", hud._flat(Color(0.04, 0.03, 0.07, 1.0), Vox.RED, 3, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	var title: Label = hud._label("KUBI", 30, Vox.RED)
	title.add_theme_font_override("font", hud._title_font)
	title.add_theme_font_size_override("font_size", 18)
	head.add_child(title)
	_status = hud._label("", 20, Vox.LAVENDER)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_status)
	head.add_child(hud._button("CLOSE [Y]", func(): visible = false))
	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(_scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	_scroll.add_child(body)
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
	body.add_child(hud._section("ASK KUBI"))
	_chat = hud._rich(22)
	_chat.meta_clicked.connect(_on_cmd)
	body.add_child(_chat)
	var quick := HFlowContainer.new()
	quick.add_theme_constant_override("h_separation", 8)
	quick.add_theme_constant_override("v_separation", 6)
	for q in ["What is wrong?", "How do I fix it?", "Explain it simply"]:
		quick.add_child(hud._button(q, func(): ask(tr(q))))
	v.add_child(quick)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	v.add_child(row)
	_input = LineEdit.new()
	_input.placeholder_text = tr("Ask anything about the cluster...")
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.add_theme_font_size_override("font_size", 24)
	_input.text_submitted.connect(func(t): ask(t))
	row.add_child(_input)
	_ask_btn = hud._button("ASK", func(): ask(_input.text))
	row.add_child(_ask_btn)


func open() -> void:
	visible = true
	refresh_status()
	refresh(K8s.state)


func refresh_status() -> void:
	_status.text = tr("checking the language model...")
	K8s.assistant_status(func(st: Dictionary):
		_llm = bool(st.get("llm", false))
		if _llm:
			_status.text = tr("local AI: %s (Ollama)") % st.get("model", "?")
		elif st.get("demo", false):
			_status.text = tr("demo: built-in guide only (connect a bridge with Ollama to chat)")
		else:
			_status.text = tr("built-in guide only") + ("  ·  " + str(st.error) if st.has("error") else ""))


## Rebuilds the problem list (keeps the selection if it still exists).
func refresh(state: Dictionary) -> void:
	_problems = Diagnose.problems(state)
	for c in _list.get_children():
		c.queue_free()
	if _problems.is_empty():
		_list.add_child(hud._label(tr("Nothing broken right now. Ask me anything below!"), 22, Vox.GREEN))
	for i in mini(_problems.size(), 6):
		var d: Dictionary = _problems[i]
		var col: Color = [Vox.SILVER, Vox.YELLOW, Vox.ORANGE, Vox.RED][clampi(d.sev, 0, 3)]
		var label := "%s  %s%s" % [d.title, (d.ns + "/") if d.ns != "" else "", d.name]
		var b: Button = hud._button(label, func(): select(d))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.add_theme_color_override("font_color", col)
		b.clip_text = true
		_list.add_child(b)
	if _problems.size() > 6:
		_list.add_child(hud._label(tr("... and %d more") % (_problems.size() - 6), 20, Vox.LAVENDER))
	if not _sel.is_empty():
		for d in _problems:
			if d.kind == _sel.kind and d.ns == _sel.ns and d.name == _sel.name:
				_show(d)
				return
		_sel = {}
		_diag.text = ""
		_clear_acts()
	elif not _problems.is_empty():
		_show(_problems[0])


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
	_sel = d
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


func _on_cmd(meta) -> void:
	var cmd := str(meta)
	if Diagnose.is_read_only(cmd) and not cmd.contains("|") and not cmd.contains("<"):
		hud._term_cmd(cmd.trim_prefix("kubectl "))
		if not Settings.terminal:
			hud.toggle_terminal()
	else:
		hud._term_fill(cmd)


## Asks a question: to the local LLM when the bridge has one, otherwise the
## built-in guide answers with the selected diagnosis.
func ask(q: String) -> void:
	q = q.strip_edges()
	if q == "" or _busy:
		return
	_input.text = ""
	_chat.append_text("\n[color=#29adff]%s:[/color] %s\n" % [tr("You"), hud._esc(q)])
	if not _llm:
		var a := _offline_answer(q)
		_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % a)
		answered.emit(a)
		_scroll_down()
		return
	_busy = true
	_ask_btn.disabled = true
	thinking.emit(true)
	_chat.append_text("[color=#83769c]%s[/color]\n" % tr("Kubi is thinking... (a local model can take a few seconds)"))
	var req := {"question": q, "lang": TranslationServer.get_locale(), "kind": _sel.get("kind", ""),
		"ns": _sel.get("ns", ""), "name": _sel.get("name", ""),
		"diagnosis": Diagnose.as_text(_sel) if not _sel.is_empty() else ""}
	K8s.ask_assistant(req, func(ok: bool, text: String):
		_busy = false
		_ask_btn.disabled = false
		thinking.emit(false)
		if ok:
			_history.append({"q": q, "a": text})
			_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % _format(text))
			answered.emit(text)
		else:
			_chat.append_text("[color=#ff4d6d]%s[/color] %s\n" % [tr("Kubi can't reach its brain:"), hud._esc(text)])
			_chat.append_text("[color=#ff004d]Kubi:[/color] %s\n" % _offline_answer(q))
		_scroll_down())
	_scroll_down()


## Markdown-ish answer -> BBCode; `commands` become clickable.
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


func _offline_answer(q: String) -> String:
	if _sel.is_empty():
		return tr("I only have my built-in guide here. Everything looks healthy; select something broken (TAB jumps to the next problem) and I'll explain it.")
	var t: String = "%s — %s" % [_sel.title, hud._esc(_sel.why)]
	if not _sel.steps.is_empty():
		t += "\n" + tr("Start with: %s") % hud._esc(_sel.steps[0])
	return t


func _scroll_down() -> void:
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func has_input_focus() -> bool:
	return _input.has_focus()
