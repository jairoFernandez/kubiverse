class_name ManifestEditor
extends Control
## In-game YAML editor with a retro "Matrix" boot: digital rain, then the
## manifest is decoded line by line. Next to every line the DECODER column
## says what it does (and warns about risky values). VALIDATE asks the API
## server with a dry run; APPLY replaces the object (after confirming).

var hud
var kind := ""
var ns := ""
var obj_name := ""
var _focus := ""
var _rain: MatrixRain
var _frame: PanelContainer
var _title: Label
var _status: RichTextLabel
var _code: CodeEdit
var _notes: TextEdit
var _detail: RichTextLabel
var _result: RichTextLabel
var _apply_btn: Button
var _validate_btn: Button
var _orig := ""
var _fetched := ""
var _readonly := false
var _phase := ""        # rain | decode | edit
var _t := 0.0
var _revealed := 0
var _ann := []
var _dirty_t := -1.0
var _last_error := ""
const SCRAMBLE := "01<>{}[]$#%&*+=:;/\\|アイウエオカキクケコ"


func build(h) -> void:
	hud = h
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	visible = false
	var bg := ColorRect.new()
	bg.color = Color(0, 0.02, 0.01, 0.94)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_rain = MatrixRain.new()
	_rain.font = hud._font
	_rain.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(_rain)
	_frame = PanelContainer.new()
	_frame.add_theme_stylebox_override("panel", hud._flat(Color(0.0, 0.04, 0.02, 0.9), Vox.GREEN, 3, 14))
	_frame.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_frame.offset_left = 30
	_frame.offset_top = 30
	_frame.offset_right = -30
	_frame.offset_bottom = -30
	add_child(_frame)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	_frame.add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	v.add_child(head)
	_title = hud._label("", 26, Vox.GREEN)
	_title.add_theme_font_override("font", hud._title_font)
	_title.add_theme_font_size_override("font_size", 14)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_title)
	_status = hud._rich(20)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_status.custom_minimum_size.x = 200
	head.add_child(_status)
	head.add_child(hud._button("RELOAD", func(): _confirm_discard(func(): open(kind, ns, obj_name, _focus))))
	head.add_child(hud._button("CLOSE [ESC]", request_close))
	# Code | decoder, scrolled together.
	var split := HBoxContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_theme_constant_override("separation", 0)
	v.add_child(split)
	_code = CodeEdit.new()
	_code.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_code.size_flags_stretch_ratio = 1.25
	_code.gutters_draw_line_numbers = true
	_code.highlight_current_line = true
	_code.scroll_smooth = false
	_code.indent_use_spaces = true
	_code.indent_size = 2
	_code.auto_brace_completion_enabled = false
	_code.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_style_text(_code, Color(0.55, 1.0, 0.6))
	_code.syntax_highlighter = _yaml_highlighter()
	_code.text_changed.connect(func(): _dirty_t = 0.35)
	_code.caret_changed.connect(_update_detail)
	split.add_child(_code)
	_notes = TextEdit.new()
	_notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_notes.editable = false
	_notes.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_notes.scroll_smooth = false
	_notes.context_menu_enabled = false
	_notes.focus_mode = Control.FOCUS_NONE
	_notes.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_style_text(_notes, Color(0.2, 0.75, 0.4))
	_notes.add_theme_font_size_override("font_size", 19)
	var nh := CodeHighlighter.new()
	nh.symbol_color = Color(0.2, 0.75, 0.4)
	nh.number_color = Color(0.4, 0.9, 0.5)
	nh.function_color = Color(0.2, 0.75, 0.4)
	nh.member_variable_color = Color(0.2, 0.75, 0.4)
	nh.add_color_region("!!", "", Color("ff4d6d"), true)
	nh.add_color_region("~", "", Color("ffec27"), true)
	_notes.syntax_highlighter = nh
	split.add_child(_notes)
	# Detail of the caret line + result of validate/apply.
	_detail = hud._rich(22)
	_detail.custom_minimum_size.y = 64
	v.add_child(_detail)
	_result = hud._rich(20)
	_result.meta_clicked.connect(func(_m): _ask_kubi_error())
	v.add_child(_result)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	v.add_child(bar)
	_validate_btn = hud._button("VALIDATE (dry run)", func(): _submit(true))
	bar.add_child(_validate_btn)
	_apply_btn = hud._button("APPLY", func(): _submit(false), "GoButton")
	bar.add_child(_apply_btn)
	bar.add_child(hud._button("ASK KUBI ABOUT THIS LINE", _ask_kubi_line))
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	var legend: Label = hud._label(tr("~ changed   !! warning"), 20, Color(0.2, 0.75, 0.4))
	bar.add_child(legend)


func _style_text(t: TextEdit, col: Color) -> void:
	t.add_theme_font_override("font", hud._font)
	t.add_theme_font_size_override("font_size", 24)
	t.add_theme_color_override("font_color", col)
	t.add_theme_color_override("font_readonly_color", col)
	t.add_theme_color_override("caret_color", Color(0.7, 1, 0.75))
	t.add_theme_color_override("current_line_color", Color(0, 1, 0.4, 0.08))
	t.add_theme_color_override("selection_color", Color(0, 1, 0.4, 0.25))
	t.add_theme_color_override("line_number_color", Color(0.1, 0.45, 0.25))
	var sb: StyleBoxFlat = hud._flat(Color(0, 0.03, 0.015, 0.95), Color(0, 0.5, 0.2), 1, 8)
	t.add_theme_stylebox_override("normal", sb)
	t.add_theme_stylebox_override("focus", sb)
	t.add_theme_stylebox_override("read_only", sb)


func _yaml_highlighter() -> CodeHighlighter:
	var h := CodeHighlighter.new()
	h.number_color = Color("ffec27")
	h.symbol_color = Color(0.2, 0.6, 0.35)
	h.function_color = Color(0.55, 1.0, 0.6)
	h.member_variable_color = Color(0.55, 1.0, 0.6)
	h.add_color_region("#", "", Color(0.25, 0.5, 0.3), true)
	h.add_color_region("\"", "\"", Color("fff1e8"))
	h.add_color_region("'", "'", Color("fff1e8"))
	var keys := {}
	for k in ManifestHelp.DOCS:
		keys[str(k).get_slice(".", str(k).get_slice_count(".") - 1).replace("[]", "")] = true
	for k in keys:
		h.add_keyword_color(k, Color("c8ffd4"))
	for w in ["true", "false", "null"]:
		h.add_keyword_color(w, Color("ffa300"))
	return h


# ------------------------------------------------------------------ flow

func open(k: String, n_s: String, n: String, focus := "") -> void:
	kind = k
	ns = n_s
	obj_name = n
	_focus = focus
	visible = true
	move_to_front()
	_phase = "rain"
	_t = 0.0
	_fetched = ""
	_orig = ""
	_rain.density = 1.0
	_frame.modulate.a = 0.0
	_code.text = ""
	_code.editable = false
	_notes.text = ""
	_result.text = ""
	_detail.text = ""
	_title.text = "EDIT // %s %s" % [kind.to_upper(), (ns + "/" if ns != "" else "") + obj_name]
	_status.text = "[color=#00e436]%s[/color]" % tr("establishing link with the API server...")
	Sfx.play("door")
	K8s.get_manifest(kind, ns, obj_name, func(ok: bool, text: String, ro: bool):
		if not visible:
			return
		if not ok:
			_phase = "edit"
			_frame.modulate.a = 1.0
			_rain.density = 0.15
			_status.text = "[color=#ff004d]%s[/color] %s" % [tr("ACCESS DENIED:"), hud._esc(text)]
			return
		_readonly = ro
		_fetched = text.strip_edges() + "\n")


func _process(delta: float) -> void:
	if not visible:
		return
	_t += delta
	match _phase:
		"rain":
			_frame.modulate.a = clampf((_t - 0.5) * 2.0, 0.0, 1.0)
			if _t > 0.9 and _fetched != "":
				_phase = "decode"
				_t = 0.0
				_revealed = 0
				_status.text = "[color=#00e436]%s[/color]" % tr("decrypting manifest...")
		"decode":
			_frame.modulate.a = 1.0
			_rain.density = lerpf(1.0, 0.15, clampf(_t / 1.3, 0.0, 1.0))
			var lines := _fetched.split("\n")
			var per_sec := maxf(30.0, lines.size() / 1.3)
			var want := mini(lines.size(), int(_t * per_sec))
			if want != _revealed:
				_revealed = want
				if _revealed % 3 == 0:
					Sfx.play("key", null, 0.2)
				var shown := lines.slice(0, _revealed)
				for i in 3:  # the next lines are still scrambled
					if _revealed + i < lines.size():
						shown.append(_scramble(lines[_revealed + i]))
				_code.text = "\n".join(shown)
				_code.set_caret_line(_revealed)
			if _revealed >= lines.size():
				_finish_decode()
		"edit":
			if _dirty_t > 0.0:
				_dirty_t -= delta
				if _dirty_t <= 0.0:
					_annotate()
	# The decoder column follows the editor's scroll.
	_notes.scroll_vertical = _code.scroll_vertical


func _scramble(s: String) -> String:
	var out := ""
	for ch in s:
		out += ch if ch == " " else SCRAMBLE[randi() % SCRAMBLE.length()]
	return out


func _finish_decode() -> void:
	_phase = "edit"
	# Smaller font in the decoder, same line height: rows stay aligned.
	var f: Font = hud._font
	var code_h := f.get_height(24) + _code.get_theme_constant("line_spacing")
	_notes.add_theme_constant_override("line_spacing", maxi(0, int(round(code_h - f.get_height(19)))))
	_orig = _fetched
	_code.text = _orig
	_code.editable = not _readonly
	_code.clear_undo_history()
	_annotate()
	var line := ManifestHelp.find_line(_orig, _focus) if _focus != "" else 0
	_code.set_caret_line(maxi(0, line))
	_code.set_caret_column(0)
	_code.center_viewport_to_caret()
	_code.grab_focus()
	_apply_btn.disabled = _readonly
	Sfx.play("coin")
	_status.text = "[color=#00e436]%s[/color]  [color=#1f7a3d]%s[/color]" % [tr("ACCESS GRANTED"),
		tr("read-only bridge: you can read and validate, not apply") if _readonly else tr("edit the YAML; the right column explains each line")]
	_update_detail()


## Rebuild the decoder column (and mark changed lines).
func _annotate() -> void:
	_ann = ManifestHelp.annotate(_code.text)
	var orig_lines := _orig.split("\n")
	var cur := _code.text.split("\n")
	var out := PackedStringArray()
	var changed := 0
	for i in _ann.size():
		var a: Dictionary = _ann[i]
		var mark := ""
		if i >= orig_lines.size() or cur[i] != orig_lines[i]:
			mark = "~ "
			changed += 1
		var note: String = a.text
		if a.warn != "":
			note = "!! " + a.warn + ((" · " + note) if note != "" else "")
		out.append(mark + ("# " + note if note != "" and not note.begins_with("!!") else note))
	_notes.text = "\n".join(out)
	if _phase == "edit" and not _readonly and _orig != "":
		_status.text = ("[color=#ffec27]%s[/color]" % (tr("%d line(s) changed") % changed)) if changed > 0 else "[color=#00e436]%s[/color]" % tr("no changes")
	_update_detail()


func _update_detail() -> void:
	if _phase != "edit" or _ann.is_empty():
		return
	var i := _code.get_caret_line()
	if i >= _ann.size():
		_detail.text = ""
		return
	var a: Dictionary = _ann[i]
	if a.path == "":
		_detail.text = "[color=#1f7a3d]%s %d[/color]" % [tr("LINE"), i + 1]
		return
	var t := "[color=#1f7a3d]%s %d[/color]  [color=#c8ffd4]%s[/color]" % [tr("LINE"), i + 1, a.path]
	if a.value != "":
		t += "  = [color=#ffec27]%s[/color]" % hud._esc(str(a.value))
	t += "\n[color=#55ff88]%s[/color]" % (a.text if a.text != "" else tr("(no built-in note: ask Kubi)"))
	if a.warn != "":
		t += "  [color=#ff4d6d]!! %s[/color]" % a.warn
	_detail.text = t


func _submit(dry: bool) -> void:
	if _phase != "edit" or _orig == "":
		return
	if not dry and _code.text == _orig:
		_result.text = "[color=#83769c]%s[/color]" % tr("Nothing to apply: no changes.")
		return
	var send := func():
		_result.text = "[color=#00e436]%s[/color]" % (tr("validating with the API server...") if dry else tr("applying..."))
		K8s.put_manifest(kind, ns, obj_name, _code.text, dry, func(ok: bool, msg: String):
			if ok:
				Sfx.play("coin" if dry else "jingle")
				_last_error = ""
				_result.text = "[color=#00e436]%s[/color] %s" % [tr("OK: the API server accepts it (dry run, nothing changed).") if dry else tr("APPLIED:"), hud._esc(msg)]
				if not dry:
					_orig = _code.text
					_annotate()
					hud.toast(tr("Applied: %s") % msg, true)
			else:
				Sfx.play("error")
				_last_error = msg
				_result.text = "[color=#ff004d]%s[/color] %s  [url=kubi][color=#ff77a8]%s[/color][/url]" % [
					tr("REJECTED:"), hud._esc(msg), tr("-> ask Kubi about this error")])
	if dry:
		send.call()
	else:
		var n := 0
		var a := _orig.split("\n")
		var b := _code.text.split("\n")
		for i in maxi(a.size(), b.size()):
			if i >= a.size() or i >= b.size() or a[i] != b[i]:
				n += 1
		hud.confirm(tr("Apply %d changed line(s) to %s %s? This replaces the object in the cluster.") % [n, kind, obj_name], send,
			"kubectl %sreplace -f %s.yaml" % [("-n %s " % ns) if ns != "" else "", obj_name])


func _ask_kubi_line() -> void:
	if _ann.is_empty():
		return
	var i := _code.get_caret_line()
	var a: Dictionary = _ann[mini(i, _ann.size() - 1)]
	_open_kubi()
	hud.kubi.attach({"id": Time.get_ticks_msec(), "cmd": "%s %s (YAML)" % [kind, obj_name], "out": _code.text.left(6000), "ok": true})
	hud.kubi.ask(tr("In this %s manifest, explain line %d (`%s`) and what happens if I change it.") % [kind, i + 1, _code.get_line(i).strip_edges()])


func _ask_kubi_error() -> void:
	if _last_error == "":
		return
	_open_kubi()
	hud.kubi.attach({"id": Time.get_ticks_msec(), "cmd": "kubectl replace %s %s" % [kind, obj_name], "out": _last_error + "\n\n--- YAML ---\n" + _code.text.left(5000), "ok": false})
	hud.kubi.ask(tr("The API server rejected my edit. Why, and how do I fix the YAML?"))


func _open_kubi() -> void:
	if not hud.kubi.visible:
		hud.kubi.open()
	hud.kubi.move_to_front()


func is_dirty() -> bool:
	return _phase == "edit" and _orig != "" and _code.text != _orig


func request_close() -> void:
	_confirm_discard(func():
		visible = false
		_phase = "")


func _confirm_discard(then: Callable) -> void:
	if is_dirty():
		hud.confirm(tr("Discard your changes to %s %s?") % [kind, obj_name], then)
	else:
		then.call()
