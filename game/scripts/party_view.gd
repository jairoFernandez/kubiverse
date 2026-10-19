class_name PartyView
extends Node
## The party on screen: the other players in the world, their shots, the
## status line (SHOOTER / MISSION), the scoreboard, a feed of what happens
## and the PARTY panel (F4): start a party, invite (code + link), join one.
## Main calls fire() instead of its chaos blast while a party is on.

var party: Party
var main: Node                       # main.gd (player, world, hud, missions...)
var _avatars := {}                   # id -> RemotePlayer
var _layer: CanvasLayer
var _status: Label
var _board: Label
var _feed: Label
var _feed_lines: Array = []          # [{text, t}]
var _panel: PanelContainer
var _name_edit: LineEdit
var _join_edit: LineEdit
var _invite_label: Label
var _start_btn: Button
var _invite_btn: Button
var _leave_btn: Button
var _auto_join := false              # web: ?party=1 joins once connected
var _drill_in := 60.0                # demo: seconds until the alarm drill


func setup(m: Node) -> void:
	main = m
	party = Party.new()
	party.missions = main.missions
	party.ground = func(p: Vector3) -> Vector3:
		var y: float = main.world.floor_y(Vector2(p.x, p.z))
		return Vector3(p.x, y if y != -INF else p.y, p.z)
	add_child(party)
	party.changed.connect(_refresh)
	party.feed.connect(_add_feed)
	party.shot_seen.connect(_on_shot)
	party.hurt.connect(_on_hurt)
	party.mode_changed.connect(_on_mode)
	party.ask_received.connect(_on_ask)
	K8s.state_updated.connect(func(s): party.on_state(s))
	K8s.guest_change.connect(func(req): party.ask(req))
	K8s.connection_changed.connect(_on_connection)
	main.missions.progress_changed.connect(party.local_progress)
	main.missions.completed.connect(party.local_completed)
	_auto_join = K8s.web_query_param("party") == "1"
	# Dev: `-- --demo --party[=DRILL_SECONDS]` starts a demo party at once.
	for a in OS.get_cmdline_user_args():
		if a == "--party" or a.begins_with("--party="):
			_auto_join = true
			if "=" in a:
				_drill_in = float(a.get_slice("=", 1))
	_build_ui()
	_refresh()


func active() -> bool:
	return party.active


# ------------------------------------------------------------ shooting

## Fires weapon w (paintball): aims at the closest player in front, animates
## like the real weapon, and only ever hurts players.
func fire(w: Dictionary) -> void:
	if party.mode == "mission":
		main.hud.toast(tr("Mission mode: no friendly fire. Fix the cluster together!"), false)
		return
	if not party.can_shoot():
		return
	var from: Vector3 = main._fpv_muzzle() if main._fpv else main.player.muzzle()
	var to: Vector3 = main._miss_point()
	var best := INF
	var me: Vector3 = main.player.global_position
	var fwd: Vector3 = main.player.forward()
	for id in party.chests(main.world.level):
		var c: Vector3 = party.chests(main.world.level)[id]
		var d := c - me
		d.y = 0
		if d.length() < 14.0 and d.normalized().dot(fwd) > 0.6 and d.length() < best:
			best = d.length()
			to = c
	var victim := party.fire(from, to, w.id)
	main._fire_anim(w, from, to, func():
		main.world.poof(to, w.color)
		if _avatars.has(victim):
			_avatars[victim].flash())


func _on_shot(id: int, from: Vector3, to: Vector3, weapon: String) -> void:
	var col: Color = Vox.YELLOW
	for w in Weapons.LIST:
		if w.id == weapon:
			col = w.color
	match weapon:
		"ray":
			main.world.beam(from, to, col, 0.4)
		"freeze":
			main.world.spray(from, to, col)
		_:
			main.world.bolt(from, to, col, func(): main.world.poof(to, col))
	main.world.sfx("blaster", from)


func _on_hurt(dmg: int, _by: int) -> void:
	main._shake = maxf(main._shake, 0.25)
	main.world.poof(main.player.global_position + Vector3(0, 1, 0), Vox.RED)
	if party.hp > 0:
		main.hud.toast("-%d ♥%d" % [dmg, party.hp], false)


func _on_mode(mode: String) -> void:
	if mode == "mission":
		Sfx.play("alarm")
		var t: String = Party.text(party.mission.get("title", ["The cluster is in ALARM", []]))
		main.hud.banner(tr("MISSION: EVERYONE TOGETHER"), t)
	else:
		main.hud.banner(tr("BACK TO THE SHOOTER"), tr("The cluster is calm. Paintball on!"))


## A guest asks the host to apply a change: the host decides (and on a
## production cluster K8s.action asks for its confirmation too).
func _on_ask(id: int, req: Dictionary) -> void:
	var who: String = party.players[id].name if party.players.has(id) else "?"
	var allowed := ["delete_pod", "restart", "scale", "rollout_undo", "resume", "pause", "cordon", "uncordon"]
	if not str(req.get("action", "")) in allowed:
		_add_feed(tr("%s asked for something a guest can't ask for") % who, false)
		return
	main.hud.confirm(tr("%s (guest) asks you to apply: %s") % [who, Kubectl.for_action(req)], func(): K8s.action(req), Kubectl.for_action(req))


# ------------------------------------------------------------ every frame

## Name tags for main's label overlay.
func tags() -> Array:
	var out := []
	for av in _avatars.values():
		out.append({"pos": av.global_position + Vector3(0, 1.9, 0), "text": av.label, "color": av.color, "big": false, "small": true})
	return out


func _process(_delta: float) -> void:
	if not party.active:
		if not _avatars.is_empty():
			_clear_avatars()
		return
	var pl: Player = main.player
	party.tick_me(pl.global_position, pl.body().rotation.y if pl.body() else 0.0, main.world.level)
	var seen := {}
	for id in party.players:
		var p: Dictionary = party.players[id]
		if p.level != main.world.level:
			continue
		var at := party.where(id)
		if at.is_empty():
			continue
		seen[id] = true
		var av: RemotePlayer = _avatars.get(id)
		if av == null:
			av = RemotePlayer.new()
			main._vp.add_child(av)
			av.setup(id, int(p.color), str(p.name))
			_avatars[id] = av
			main.world.poof(at.p + Vector3(0, 1, 0), av.color)
		av.place(at.p, at.y)
		av.set_info(str(p.name), int(p.hp))
	for id in _avatars.keys():
		if not seen.has(id):
			_avatars[id].queue_free()
			_avatars.erase(id)
	var now := Time.get_ticks_msec() / 1000.0
	if not _feed_lines.is_empty() and now - float(_feed_lines[0].t) > 6.0:
		_feed_lines.pop_front()
		_render_feed()


func _clear_avatars() -> void:
	for av in _avatars.values():
		av.queue_free()
	_avatars.clear()


# ------------------------------------------------------------ party panel

func toggle_panel() -> void:
	_panel.visible = not _panel.visible
	_refresh()


func start() -> void:
	var name := _name_edit.text.strip_edges()
	if K8s.is_demo():
		party.start_demo(name, _drill_in)
	elif K8s.mode == K8s.Mode.BRIDGE:
		party.join(K8s.base_url, K8s.token, K8s.context, name if name != "" else "Player")
	else:
		main.hud.toast(tr("Connect to a cluster (or start the demo) first"), false)
		return
	main.hud.chaos = false   # paintball only while the party lasts
	main.hud._update_chaos_btn()


func invite() -> void:
	if party.is_guest() or K8s.mode != K8s.Mode.BRIDGE:
		return
	K8s._http_to(K8s.base_url, K8s.token, HTTPClient.METHOD_POST, "/api/party/invite",
		JSON.stringify({"context": K8s.context, "label": _name_edit.text}), func(ok: bool, data):
			if not ok or not data.get("ok", false):
				_invite_label.text = tr("Could not invite: %s") % (str(data.get("error", "")) if ok else str(data))
				return
			var code: String = data.invite.code
			var urls: Array = data.get("urls", [])
			var base: String = urls[0] if not urls.is_empty() else K8s.base_url
			var link := PartyRules.invite_link(base, code)
			DisplayServer.clipboard_set(link)
			_invite_label.text = tr("Code: %s  (24 h, read-only)\n%s\nLink copied. Over the internet, use your tunnel's URL instead of the host.") % [code, link])


func join_link() -> void:
	var inv := PartyRules.parse_invite(_join_edit.text)
	if inv.is_empty():
		main.hud.toast(tr("Paste the link (or 'URL CODE') your host sent"), false)
		return
	K8s.connect_bridge(inv.url, inv.code)
	_auto_join = true


func _on_connection(status: String, _detail: String) -> void:
	if status == "online" and _auto_join and K8s.mode != K8s.Mode.OFFLINE:
		_auto_join = false
		start()


func _build_ui() -> void:
	_layer = CanvasLayer.new()
	_layer.layer = 6
	add_child(_layer)
	# Below the top bars: status in the middle, scoreboard on the right,
	# the feed bottom-left above the key hints.
	_status = _label(Control.PRESET_CENTER_TOP, Rect2(-330, 100, 660, 0), 16)
	_status.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_board = _label(Control.PRESET_TOP_RIGHT, Rect2(-236, 140, 220, 0), 14)
	_board.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_feed = _label(Control.PRESET_BOTTOM_LEFT, Rect2(16, -200, 520, 150), 14)
	_feed.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_feed.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER)
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.grow_vertical = Control.GROW_DIRECTION_BOTH
	_panel.visible = false
	_layer.add_child(_panel)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(460, 0)
	_panel.add_child(box)
	var title := Label.new()
	title.text = tr("PARTY (multiplayer)")
	box.add_child(title)
	var help := Label.new()
	help.text = tr("Paintball while the cluster is fine; a shared mission when it goes into ALARM. Guests only watch: changes go to the host.")
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(help)
	_name_edit = LineEdit.new()
	_name_edit.placeholder_text = tr("Your name")
	_name_edit.max_length = 20
	box.add_child(_name_edit)
	_start_btn = _button(box, tr("START / JOIN THIS CLUSTER'S PARTY"), start)
	_invite_btn = _button(box, tr("INVITE A FRIEND (code + link)"), invite)
	_invite_label = Label.new()
	_invite_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_invite_label)
	_join_edit = LineEdit.new()
	_join_edit.placeholder_text = tr("Invitation link from your host")
	box.add_child(_join_edit)
	_button(box, tr("JOIN WITH LINK"), join_link)
	_leave_btn = _button(box, tr("LEAVE THE PARTY"), func(): party.leave())
	_button(box, tr("CLOSE (F4)"), toggle_panel)


func _label(preset: Control.LayoutPreset, r: Rect2, size: int) -> Label:
	var l := Label.new()
	_layer.add_child(l)
	l.set_anchors_preset(preset)
	l.offset_left = r.position.x
	l.offset_top = r.position.y
	l.offset_right = r.position.x + r.size.x
	l.offset_bottom = r.position.y + r.size.y
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_outline_color", Color.BLACK)
	l.add_theme_constant_override("outline_size", 6)
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0, 0, 0, 0.55)
	bg.set_content_margin_all(6)
	l.add_theme_stylebox_override("normal", bg)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.visible = false
	return l


func _button(parent: Node, text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _add_feed(text: String, _good: bool) -> void:
	_feed_lines.append({"text": text, "t": Time.get_ticks_msec() / 1000.0})
	while _feed_lines.size() > 6:
		_feed_lines.pop_front()
	_render_feed()


func _render_feed() -> void:
	_feed.text = "\n".join(_feed_lines.map(func(l): return l.text))
	_feed.visible = _feed.text != ""


func _refresh() -> void:
	_status.text = status_text(party)
	_board.text = board_text(party)
	_status.visible = _status.text != ""
	_board.visible = _board.text != ""
	if _start_btn:
		_start_btn.disabled = party.active
		_invite_btn.disabled = not party.active or party.demo or party.is_guest()
		_leave_btn.disabled = not party.active


## Status line: mode, players, my HP, and the mission with who did what.
static func status_text(p: Party) -> String:
	if not p.active:
		return ""
	var n := p.players.size() + 1
	if p.mode == "shooter":
		var life: String = "♥%d" % p.hp if p.dead_t <= 0.0 else TranslationServer.translate("respawning...")
		return TranslationServer.translate("SHOOTER  ·  %d players  ·  %s  ·  score %d") % [n, life, p.score]
	if p.mission.is_empty():
		return TranslationServer.translate("MISSION  ·  the cluster is in ALARM: open the missions (J)")
	var lines := [TranslationServer.translate("MISSION  ·  %s") % Party.text(p.mission.title)]
	for i in p.mission.steps.size():
		var st: Dictionary = p.mission.steps[i]
		var mark := "✔" if i < int(p.mission.step) else ("▶" if i == int(p.mission.step) else "·")
		var by := " (%s)" % p.mission.by[i] if p.mission.by.has(i) else ""
		lines.append("%s %s: %s%s" % [mark, TranslationServer.translate(KubiMissions.PHASES[int(st.phase)]), Party.text(st.text), by])
	return "\n".join(lines)


static func board_text(p: Party) -> String:
	if not p.active:
		return ""
	var rows := [[str(p.me.name) + (" ★" if p.me.get("host", false) else ""), p.score]]
	for id in p.players:
		rows.append([str(p.players[id].name) + (" ★" if p.players[id].host else ""), int(p.players[id].score)])
	rows.sort_custom(func(a, b): return a[1] > b[1])
	return "\n".join(rows.map(func(r): return "%s  %d" % [r[0], r[1]]))
