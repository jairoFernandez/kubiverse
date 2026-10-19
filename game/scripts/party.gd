class_name Party
extends Node
## Multiplayer: the players in one cluster's world. Positions, shots and
## mission progress go through the bridge's relay (/api/play); in demo mode
## a few bots play instead, so the whole thing can be tried without a
## cluster. Two modes:
##   shooter  paintball: shots only hurt players, never the cluster (chaos
##            mode is off while a party is on)
##   mission  the cluster is in alarm (ControlRoom.level_of): everyone plays
##            the same Kubi mission, progress is shared, no friendly fire.
## Guests are read-only on the bridge; a change they try is sent to the host
## as an "ask", who applies it with the usual production confirmation.

signal changed                       # roster, mode, mission, hp or score
signal shot_seen(id: int, from: Vector3, to: Vector3, weapon: String)
signal feed(text: String, good: bool)
signal mode_changed(mode: String)
signal hurt(dmg: int, by: int)
signal ask_received(id: int, req: Dictionary)

var active := false
var demo := false
var me := {"id": 0, "name": "", "color": 0, "host": true}
## id -> {id, name, color, host, samples, level, hp, score, bot}
var players := {}
var hp := PartyRules.MAX_HP
var score := 0
var dead_t := 0.0                    # > 0: dead, seconds until respawn
var mode := "shooter"
## The shared mission: {id, title, steps: [{phase, text}], step, by: {step: name}} or {}
var mission := {}
var level := "ok"                    # the cluster's, as the control room sees it
var missions: Missions               # the local mission log (kept on the shared one)

var _ws: WebSocketPeer
var _url := ""
var _ws_state := -1
var _clock := 0.0
var _send_t := 0.0
var _calm := 0.0
var _kubi_before := false            # Settings.mission_kubi before the mission took over
var _my_pos := Vector3.ZERO
var _my_level := ""
var _bots := []                      # demo: [{id, goal, t_fire, t_goal, t_work}]
var _drill_t := -1.0                 # demo: seconds until the alarm drill starts
var ground: Callable                 # demo bots: Vector3 -> Vector3 on the floor (or itself)

const BOT_NAMES := ["Ana", "Bruno", "Carla"]


# ------------------------------------------------------------ start / stop

## Demo party: bots that walk, shoot and help with the mission. The alarm
## drill (something breaking in the demo cluster) starts after drill_in s.
func start_demo(my_name: String, drill_in := 60.0) -> void:
	leave()
	active = true
	demo = true
	me = {"id": 1, "name": my_name if my_name != "" else "You", "color": 0, "host": true}
	for i in BOT_NAMES.size():
		var id := 101 + i
		players[id] = _new_player(id, BOT_NAMES[i], i + 1, false)
		players[id].bot = true
		_bots.append({"id": id, "goal": Vector3.ZERO, "t_fire": randf_range(2.0, 4.0), "t_goal": 0.0, "t_work": randf_range(5.0, 9.0)})
	_drill_t = drill_in
	_reset_me()
	feed.emit(tr("Party started: %d bots joined") % _bots.size(), true)
	changed.emit()


## Joins the relay of the cluster K8s is connected to (host with the bridge's
## token, guest with an invitation code).
func join(base_url: String, token: String, context: String, my_name: String) -> void:
	leave()
	active = true
	demo = false
	me.name = my_name
	var q := "?name=" + my_name.uri_encode()
	if token != "":
		q += "&token=" + token.uri_encode()
	if context != "":
		q += "&context=" + context.uri_encode()
	_url = "ws" + base_url.substr(4) + "/api/play" + q
	_ws = WebSocketPeer.new()
	_ws_state = -1
	if _ws.connect_to_url(_url) != OK:
		_ws = null
		active = false
		feed.emit(tr("Could not open the party"), false)
		return
	_reset_me()
	changed.emit()


func leave() -> void:
	if _ws:
		_ws.close()
		_ws = null
	if mode == "mission":
		_end_mission()
	active = false
	demo = false
	players.clear()
	_bots.clear()
	mission = {}
	mode = "shooter"
	_calm = 0.0
	_drill_t = -1.0
	K8s.guest = false
	changed.emit()


func _reset_me() -> void:
	hp = PartyRules.MAX_HP
	score = 0
	dead_t = 0.0
	mode = "shooter"
	mission = {}


func _new_player(id: int, name: String, color: int, host: bool) -> Dictionary:
	return {"id": id, "name": name, "color": color, "host": host, "samples": [], "level": "", "hp": PartyRules.MAX_HP, "score": 0, "bot": false}


func is_guest() -> bool:
	return active and not demo and not bool(me.get("host", true))


func can_shoot() -> bool:
	return active and mode == "shooter" and dead_t <= 0.0


# ------------------------------------------------------------ my side

## Called every frame with where I am; sends at 10 Hz.
func tick_me(pos: Vector3, yaw: float, lvl: String) -> void:
	_my_pos = pos
	_my_level = lvl
	if _send_t > 0.0:
		return
	_send_t = PartyRules.SEND_EVERY
	_send(PartyRules.pos_msg(pos, yaw, lvl, hp))


## I fired: tell the others, and if the shot passes by someone on my level,
## they are hit. Returns the id hit (-1 none).
func fire(from: Vector3, to: Vector3, weapon: String) -> int:
	if not can_shoot():
		return -1
	_send({"t": "shot", "from": PartyRules.vec_arr(from), "to": PartyRules.vec_arr(to), "w": weapon})
	var victim := PartyRules.shot_hits(from, to, chests(_my_level))
	if victim < 0:
		return -1
	var d := PartyRules.damage(weapon)
	_send({"t": "hit", "v": victim, "d": d, "w": weapon})
	if players.has(victim) and players[victim].bot:
		_bot_hit(victim, d)
	return victim


## Chest position of everyone alive on a level: {id: Vector3}.
func chests(lvl: String) -> Dictionary:
	var out := {}
	for id in players:
		var pl: Dictionary = players[id]
		if pl.level != lvl or int(pl.hp) <= 0:
			continue
		var at := where(id)
		if not at.is_empty():
			out[id] = (at.p as Vector3) + Vector3(0, 0.9, 0)
	return out


## Where a remote player is drawn now (INTERP_DELAY in the past): {p, y} or {}.
func where(id: int) -> Dictionary:
	if not players.has(id):
		return {}
	return PartyRules.interp(players[id].samples, _clock - PartyRules.INTERP_DELAY)


## A guest's change, sent to the host to apply.
func ask(req: Dictionary) -> void:
	_send({"t": "ask", "req": req})
	feed.emit(tr("Guests can't change the cluster: sent to the host to apply"), true)


func _take_hit(dmg: int, by: int) -> void:
	if dead_t > 0.0 or mode != "shooter":
		return
	hp = PartyRules.after_hit(hp, dmg)
	hurt.emit(dmg, by)
	if hp == 0:
		dead_t = PartyRules.RESPAWN
		_send({"t": "dead", "by": by})
		_scored(by)
		feed.emit(tr("%s got you") % _name(by), false)
	changed.emit()


func _scored(by: int) -> void:
	if by == int(me.id):
		score += 1
	elif players.has(by):
		players[by].score += 1


func _name(id: int) -> String:
	if id == int(me.id):
		return tr("you")
	return str(players[id].name) if players.has(id) else "?"


# ------------------------------------------------------------ the cluster

## A new state of the cluster: shooter or mission?
func on_state(s: Dictionary) -> void:
	if not active:
		return
	level = PartyRules.level_of_state(s)
	if level == "alarm":
		_calm = 0.0
	var next := PartyRules.next_mode(mode, level, _calm)
	if next == "mission":
		var m := PartyRules.pick_mission(KubiMissions.generate(s), str(mission.get("id", "")))
		if mode != "mission" or (not m.is_empty() and m.id != mission.get("id", "")):
			_start_mission(m)
	changed.emit()


func _start_mission(m: Dictionary) -> void:
	var first := mode != "mission"
	mode = "mission"
	mission = {}
	if not m.is_empty():
		mission = {"id": m.id, "title": m.title, "steps": m.steps.map(func(st): return {"phase": st.phase, "text": st.text}),
			"step": 0, "by": {}}
		if missions:
			if first:
				_kubi_before = Settings.mission_kubi
			Settings.mission_kubi = true
			Settings.kubi_active = m.id
			mission.step = int(Settings.kubi_steps.get(m.id, 0))
			missions.progress_changed.emit()
	if first:
		hp = PartyRules.MAX_HP
		dead_t = 0.0
		feed.emit(tr("ALARM: everyone on the mission together"), false)
		mode_changed.emit(mode)


func _end_mission() -> void:
	if missions:
		Settings.mission_kubi = _kubi_before
		missions.progress_changed.emit()
	mission = {}


## The local mission log moved on: share it.
func local_progress() -> void:
	if mission.is_empty() or not missions:
		return
	var mine := int(Settings.kubi_steps.get(mission.id, 0))
	if mine > int(mission.step):
		report_step(mine)


## The local mission log finished the shared mission.
func local_completed(m: Dictionary) -> void:
	if not mission.is_empty() and m.get("id", "") == mission.id:
		report_step(mission.steps.size())


func report_step(step: int) -> void:
	if mission.is_empty():
		return
	_progress(int(me.id), step)
	_send({"t": "prog", "m": mission.id, "s": step})


func _progress(by: int, step: int) -> void:
	var was := int(mission.step)
	mission.step = PartyRules.merge_step(was, step)
	if mission.step == was:
		return
	mission.by[mission.step - 1] = _name(by)
	var i: int = mini(mission.step - 1, mission.steps.size() - 1)
	var phase: String = KubiMissions.PHASES[int(mission.steps[i].phase)]
	feed.emit(tr("%s: %s done") % [_name(by), tr(phase)], true)
	if missions and by != int(me.id) and mission.step < mission.steps.size():
		Settings.kubi_steps[mission.id] = maxi(int(Settings.kubi_steps.get(mission.id, 0)), mission.step)
		missions.progress_changed.emit()
	if demo and mission.step >= mission.steps.size() - 1 and K8s.is_demo():
		K8s.demo_drill(false)   # the demo's fix: the cluster heals for VERIFY
	changed.emit()


## Text of a mission pair ([format, args]), translated.
static func text(pair) -> String:
	if typeof(pair) != TYPE_ARRAY or (pair as Array).size() < 2:
		return str(pair)
	var f := TranslationServer.translate(str(pair[0]))
	var args: Array = pair[1].map(func(x): return TranslationServer.translate(x) if typeof(x) == TYPE_STRING else x)
	return f % args if not args.is_empty() else f


# ------------------------------------------------------------ network

func _send(msg: Dictionary) -> void:
	if _ws and _ws.get_ready_state() == WebSocketPeer.STATE_OPEN:
		_ws.send_text(JSON.stringify(msg))


func _process(delta: float) -> void:
	if not active:
		return
	_clock += delta
	_send_t -= delta
	if level != "alarm":
		_calm += delta
		if mode == "mission" and PartyRules.next_mode(mode, level, _calm) == "shooter":
			_end_mission()
			mode = "shooter"
			feed.emit(tr("Cluster calm again: back to the shooter"), true)
			mode_changed.emit(mode)
			changed.emit()
	if dead_t > 0.0:
		dead_t -= delta
		if dead_t <= 0.0:
			hp = PartyRules.MAX_HP
			changed.emit()
	if demo:
		_bots_tick(delta)
		return
	if _ws == null:
		return
	_ws.poll()
	var st := _ws.get_ready_state()
	if st != _ws_state:
		_ws_state = st
		if st == WebSocketPeer.STATE_CLOSED:
			var why := _ws.get_close_reason()
			feed.emit(tr("Party closed") + (": " + why if why != "" else ""), false)
			_ws = null
			active = false
			K8s.guest = false
			changed.emit()
			return
	while st == WebSocketPeer.STATE_OPEN and _ws.get_available_packet_count() > 0:
		var msg = JSON.parse_string(_ws.get_packet().get_string_from_utf8())
		if typeof(msg) == TYPE_DICTIONARY:
			handle(msg)


## One message from the relay (public: the tests feed it directly).
func handle(msg: Dictionary) -> void:
	var id := int(msg.get("id", 0))
	match str(msg.get("t", "")):
		"welcome":
			me = {"id": id, "name": str(msg.get("name", me.name)), "color": int(msg.get("color", 0)), "host": bool(msg.get("host", true))}
			K8s.guest = not me.host
			for p in msg.get("players", []):
				if int(p.id) != id:
					players[int(p.id)] = _new_player(int(p.id), str(p.name), int(p.color), bool(p.host))
			feed.emit(tr("Joined the party as %s") % me.name + ("" if me.host else "  " + tr("(guest: read-only)")), true)
		"join":
			var p: Dictionary = msg.get("p", {})
			players[int(p.get("id", 0))] = _new_player(int(p.get("id", 0)), str(p.get("name", "?")), int(p.get("color", 0)), bool(p.get("host", false)))
			feed.emit(tr("%s joined") % str(p.get("name", "?")), true)
		"leave":
			if players.has(id):
				feed.emit(tr("%s left") % players[id].name, false)
				players.erase(id)
		"pos":
			if players.has(id):
				var v := PartyRules.vec(msg.get("p"))
				if v != Vector3.INF:
					PartyRules.push_sample(players[id].samples, _clock, v, float(msg.get("y", 0.0)))
					players[id].level = str(msg.get("l", ""))
					players[id].hp = int(msg.get("hp", PartyRules.MAX_HP))
				return   # 10 Hz: no "changed" for positions
		"shot":
			var a := PartyRules.vec(msg.get("from"))
			var b := PartyRules.vec(msg.get("to"))
			if players.has(id) and a != Vector3.INF and b != Vector3.INF and players[id].level == _my_level:
				shot_seen.emit(id, a, b, str(msg.get("w", "blaster")))
			return
		"hit":
			if int(msg.get("v", -1)) == int(me.id):
				_take_hit(clampi(int(msg.get("d", 0)), 0, 100), id)
			return
		"dead":
			var by := int(msg.get("by", 0))
			_scored(by)
			feed.emit(tr("%s got %s") % [_name(by), _name(id)], true)
		"prog":
			if not mission.is_empty() and str(msg.get("m", "")) == mission.id:
				_progress(id, clampi(int(msg.get("s", 0)), 0, mission.steps.size()))
		"ask":
			if me.host and typeof(msg.get("req")) == TYPE_DICTIONARY:
				ask_received.emit(id, msg.req)
	changed.emit()


# ------------------------------------------------------------ demo bots

func _bots_tick(delta: float) -> void:
	if _drill_t > 0.0:
		_drill_t -= delta
		if _drill_t <= 0.0 and K8s.is_demo():
			feed.emit(tr("Drill: something breaks in the cluster..."), false)
			K8s.demo_drill(true)
	if _my_level == "":
		return   # where I am isn't known yet: the bots appear around me
	for b in _bots:
		var pl: Dictionary = players[b.id]
		pl.level = _my_level
		var at := where(b.id)
		var pos: Vector3 = at.p if not at.is_empty() else _my_pos + Vector3(randf_range(-8, 8), 0, randf_range(-8, 8))
		if int(pl.hp) <= 0:
			b.t_fire -= delta
			if b.t_fire <= 0.0:   # respawn
				pl.hp = PartyRules.MAX_HP
				pos = _my_pos + Vector3(randf_range(-10, 10), 0, randf_range(-10, 10))
				pl.samples.clear()
				b.t_fire = randf_range(2.0, 4.0)
			_bot_sample(pl, pos, 0.0)
			continue
		b.t_goal -= delta
		if b.t_goal <= 0.0 or pos.distance_to(b.goal) < 0.5:
			b.t_goal = randf_range(2.0, 5.0)
			var r := 4.0 if mode == "mission" else 9.0
			b.goal = _my_pos + Vector3(randf_range(-r, r), 0, randf_range(-r, r))
		var to: Vector3 = b.goal - pos
		to.y = 0
		var step := minf(to.length(), 4.0 * delta)
		var npos := pos + (to.normalized() * step if to.length() > 0.01 else Vector3.ZERO)
		if ground.is_valid():
			npos = ground.call(npos)
		_bot_sample(pl, npos, atan2(to.x, to.z) if to.length() > 0.01 else float(at.get("y", 0.0)))
		if mode == "shooter":
			b.t_fire -= delta
			if b.t_fire <= 0.0 and dead_t <= 0.0 and npos.distance_to(_my_pos) < 14.0:
				b.t_fire = randf_range(1.5, 3.5)
				var from := npos + Vector3(0, 1.0, 0)
				var hit := randf() < 0.45
				var aim := _my_pos + Vector3(0, 0.9, 0) + (Vector3.ZERO if hit else Vector3(randf_range(-2, 2), randf_range(0.5, 1.5), randf_range(-2, 2)))
				var w: String = ["blaster", "ray", "freeze"].pick_random()
				shot_seen.emit(b.id, from, aim, w)
				if hit:
					_take_hit(PartyRules.damage(w), b.id)
		elif not mission.is_empty():
			b.t_work -= delta
			if b.t_work <= 0.0:
				b.t_work = randf_range(7.0, 12.0)
				if int(mission.step) < mission.steps.size() - 1:
					_progress(b.id, int(mission.step) + 1)


func _bot_sample(pl: Dictionary, pos: Vector3, yaw: float) -> void:
	PartyRules.push_sample(pl.samples, _clock, pos, yaw)


func _bot_hit(id: int, dmg: int) -> void:
	var pl: Dictionary = players[id]
	if int(pl.hp) <= 0:
		return
	pl.hp = PartyRules.after_hit(int(pl.hp), dmg)
	if pl.hp == 0:
		score += 1
		feed.emit(tr("You got %s") % pl.name, true)
		for b in _bots:
			if b.id == id:
				b.t_fire = PartyRules.RESPAWN
	changed.emit()
