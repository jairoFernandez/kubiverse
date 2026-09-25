class_name WatchPanel
extends PanelContainer
## WATCHTOWER (O): who is using the cluster. Lists the identities seen by
## the bridge (API audit log, managedFields, Kubiverse players) and a feed
## of what they did. Raises an alarm when a new identity shows up.

signal intruder(v: Dictionary, why: String)

var hud
var data := {"audit": false, "visitors": [], "actions": []}
var _status: RichTextLabel
var _list: VBoxContainer
var _feed: RichTextLabel
var _known := {}          # visitor key -> true (seen since the mode was on)
var _recent := []        # last actions, newest last
var show_self := false
var collapsed := false       # only the header: the mode stays on (ghosts, alarms)
var _summary: Label
var _collapse_btn: Button
var _scroll: ScrollContainer


func build(h) -> void:
	hud = h
	# Wheel and drags over the panel are the panel's: never zoom/pan the camera.
	mouse_filter = Control.MOUSE_FILTER_STOP
	add_theme_stylebox_override("panel", hud._flat(Color(0.02, 0.04, 0.05, 1.0), Vox.BLUE, 3, 14))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	add_child(v)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	v.add_child(head)
	var title: Label = hud._label("WATCHTOWER", 30, Vox.BLUE)
	title.add_theme_font_override("font", hud._title_font)
	title.add_theme_font_size_override("font_size", 16)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	_summary = hud._label("", 20, Vox.LAVENDER)
	_summary.visible = false
	head.add_child(_summary)
	_collapse_btn = hud._button("_", func(): set_collapsed(not collapsed))
	head.add_child(_collapse_btn)
	head.add_child(hud._button("CLOSE [O]", func(): hud.toggle_watch()))
	_status = hud._rich(20)
	_status.meta_clicked.connect(func(m): hud._copy(str(m)))
	v.add_child(_status)
	var scroll := ScrollContainer.new()
	_scroll = scroll
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	v.add_child(scroll)
	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 8)
	scroll.add_child(body)
	body.add_child(hud._section("WHO IS HERE (last 30 min)"))
	_list = VBoxContainer.new()
	_list.add_theme_constant_override("separation", 6)
	body.add_child(_list)
	body.add_child(hud._section("WHAT THEY DID"))
	_feed = hud._rich(20)
	body.add_child(_feed)


static func color_for(key: String) -> Color:
	var pal := [Vox.PINK, Vox.ORANGE, Vox.LAVENDER, Vox.PEACH, Color("a8e6ff"), Color("c98bff"), Color("7ad6c0"), Color("ffd27a")]
	return pal[abs(key.hash()) % pal.size()]


## Friendly name of a client from its user agent.
static func tool_name(agent: String) -> String:
	var a := agent.to_lower()
	for k in ["kubectl", "helm", "argocd", "flux", "k9s", "lens", "terraform", "curl", "python", "browser", "kubeadm", "kubecraft", "k8sgame"]:
		if a.begins_with(k) or a.contains(k):
			return {"k8sgame": "Kubiverse", "kubecraft": "Kubiverse"}.get(k, k)
	return agent.get_slice("/", 0) if agent != "" else "?"


func visible_visitors() -> Array:
	return data.visitors.filter(func(x): return show_self or not x.get("self", false))


func update(w: Dictionary) -> void:
	data = w
	_recent.append_array(w.actions)
	if _recent.size() > 80:
		_recent = _recent.slice(_recent.size() - 80)
	if not visible:
		return
	# While the tower is open, new faces and suspicious actions raise alarms
	# (whoever was already here when it opened is the baseline).
	for vis in w.visitors:
		var key: String = vis.key
		if vis.get("self", false) or vis.get("source", "") == "player":
			_known[key] = true
			continue
		if not _known.has(key):
			_known[key] = true
			intruder.emit(vis, tr("new identity"))
	for a in w.actions:
		if a.get("self", false):
			continue
		if int(a.get("code", 0)) in [401, 403]:
			intruder.emit(a, tr("access denied"))
		elif str(a.get("resource", "")).begins_with("secrets"):
			intruder.emit(a, tr("touched Secrets"))
	_render()


func open() -> void:
	visible = true
	_known.clear()
	for vis in data.visitors:
		_known[vis.key] = true
	_render()


func set_collapsed(on: bool) -> void:
	collapsed = on
	_status.visible = not on
	_scroll.visible = not on
	_summary.visible = on
	_collapse_btn.text = "+" if on else "_"
	_render()


func _render() -> void:
	var n := visible_visitors().filter(func(x): return x.get("source", "") != "player").size()
	var bad := visible_visitors().filter(func(x): return int(x.get("denied", 0)) > 0 or x.get("secrets", false)).size()
	_summary.text = tr("%d identities") % n + ((" · " + tr("%d suspicious") % bad) if bad > 0 else "")
	if collapsed:
		return
	if data.get("audit", false):
		_status.text = "[color=#00e436]%s[/color]  [color=#83769c]%s[/color]" % [tr("API audit log: ON"), tr("real identities (user, groups, IP, tool)")]
	else:
		var dir: String = data.get("audit_dir", "~/.kubecraft/audit/<context>")
		_status.text = "[color=#ffa300]%s[/color] %s\n[color=#83769c]%s[/color]\n[color=#ffec27]$[/color] [url=make cluster-ha]make cluster-ha[/url]  [color=#83769c]%s[/color]\n[color=#83769c]%s[/color] %s" % [
			tr("No audit log:"), tr("Kubernetes has no 'who is connected' API. Without audit I only see which TOOL changed things (managedFields) and Kubiverse players."),
			tr("Turn on API server audit logging and let the bridge read it:"),
			tr("(kind cluster with audit, see deploy/kind-ha.yaml)"),
			tr("Bridge reads:"), dir + "/**/audit.log"]
	for c in _list.get_children():
		c.queue_free()
	var now := Time.get_unix_time_from_system()
	var shown := visible_visitors()
	if shown.is_empty():
		_list.add_child(hud._label(tr("Nobody yet."), 22, Vox.LAVENDER))
	for vis in shown.slice(0, 14):
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var sw := ColorRect.new()
		sw.custom_minimum_size = Vector2(14, 14)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		sw.color = color_for(vis.key)
		row.add_child(sw)
		var t: RichTextLabel = hud._rich(20)
		t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var who: String = vis.user if vis.user != "" else "?"
		var flags := ""
		if vis.get("self", false):
			flags += " [color=#29adff](%s)[/color]" % tr("this bridge")
		if int(vis.get("denied", 0)) > 0:
			flags += " [color=#ff004d]%s %d[/color]" % [tr("DENIED"), vis.denied]
		if vis.get("secrets", false):
			flags += " [color=#ffa300]%s[/color]" % tr("SECRETS")
		var src: String = {"audit": tr("audit"), "fields": tr("changes"), "player": tr("player")}.get(vis.source, vis.source)
		t.text = "[color=#fff1e8]%s[/color] [color=#ffec27]%s[/color]%s\n[color=#83769c]%s · %s · %s %d · %s %d · %s[/color]" % [
			hud._esc(who), tool_name(vis.agent), flags,
			", ".join(vis.get("ips", [])) if vis.get("ips") else "-", src,
			tr("requests"), int(vis.get("requests", 0)), tr("writes"), int(vis.get("writes", 0)),
			_ago(now - float(vis.get("last", now)))]
		if str(vis.get("last_action", "")) != "":
			t.text += "\n[color=#c2c3c7]%s %s %s %s[/color]" % [tr("last:"), vis.last_action, vis.get("last_resource", ""),
				_where(str(vis.get("last_ns", "")), str(vis.get("last_name", "")))]
		row.add_child(t)
		_list.add_child(row)
	_feed.clear()
	for i in range(_recent.size() - 1, -1, -1):
		var a: Dictionary = _recent[i]
		if a.get("self", false) and not show_self:
			continue
		var col := "#ff004d" if int(a.get("code", 0)) in [401, 403] else ("#ffa300" if a.get("write", false) else "#c2c3c7")
		_feed.append_text("[color=%s]%s[/color] [color=#fff1e8]%s[/color] (%s) %s %s%s%s\n" % [
			col, Time.get_time_string_from_unix_time(int(a.get("time", now)) + _tz()), hud._esc(str(a.get("user", "?"))),
			tool_name(str(a.get("agent", ""))), a.get("verb", ""), a.get("resource", ""),
			" " + _where(str(a.get("ns", "")), str(a.get("name", ""))),
			(" [color=#ff004d]%d[/color]" % a.code) if int(a.get("code", 0)) >= 400 else ""])


static func _where(ns: String, name: String) -> String:
	if ns != "" and name != "":
		return ns + "/" + name
	return ns + name


static func _tz() -> int:
	return int(Time.get_time_zone_from_system().get("bias", 0)) * 60


static func _ago(s: float) -> String:
	if s < 60:
		return TranslationServer.translate("now")
	if s < 3600:
		return TranslationServer.translate("%d min ago") % int(s / 60)
	return TranslationServer.translate("%d h ago") % int(s / 3600)
