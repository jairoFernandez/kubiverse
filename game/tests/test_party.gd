extends "res://tests/harness.gd"
## Headless checks of the multiplayer party (rules, relay messages, the
## switch to a shared mission and back, guests being read-only, demo bots):
##   godot --headless --path game --script res://tests/test_party.gd


func _init() -> void:
	_run.call_deferred()


var k8s: Node
var R: GDScript
var PartyScript: GDScript
var KM: GDScript


func _run() -> void:
	await process_frame  # party.gd uses autoloads (K8s, Settings): load them once they exist
	k8s = root.get_node("K8s")
	R = load("res://scripts/party_rules.gd")
	PartyScript = load("res://scripts/party.gd")
	KM = load("res://scripts/kubi_missions.gd")
	_modes(R)
	_shots(R)
	_samples(R)
	_invites(R)
	_messages()
	_mission_switch()
	_guest_is_read_only()
	_demo()
	finish("party tests")


func _modes(R: GDScript) -> void:
	check(R.next_mode("shooter", "ok", 0.0) == "shooter", "calm cluster: shooter")
	check(R.next_mode("shooter", "warn", 0.0) == "shooter", "a warning is not a mission (only alarm)")
	check(R.next_mode("shooter", "alarm", 99.0) == "mission", "alarm: mission")
	check(R.next_mode("mission", "ok", R.CALM_FOR - 1.0) == "mission", "stays on the mission until calm for a while")
	check(R.next_mode("mission", "warn", R.CALM_FOR) == "shooter", "back to the shooter after CALM_FOR without alarm")
	check(R.next_mode("mission", "alarm", 999.0) == "mission", "still in alarm: still the mission")
	var ms := [{"id": "a"}, {"id": "b"}]
	check(R.pick_mission(ms).id == "a", "the most urgent mission")
	check(R.pick_mission(ms, "b").id == "b", "keeps the one being played")
	check(R.pick_mission(ms, "gone").id == "a", "the played one is gone: the most urgent")
	check(R.pick_mission([]).is_empty(), "no missions: none")
	check(R.merge_step(1, 3) == 3 and R.merge_step(3, 1) == 3, "shared progress never goes back")
	var alarm := {"nodes": [{"name": "n1", "ready": false}], "pods": []}
	check(R.level_of_state(alarm) == "alarm", "node down: alarm, as the control room says")
	check(R.level_of_state({"nodes": [{"name": "n1", "ready": true}], "pods": []}) == "ok", "healthy: ok")


func _shots(R: GDScript) -> void:
	check(R.damage("nuke") > R.damage("blaster") and R.damage("unknown") == 20, "damage per weapon, a default for others")
	check(R.after_hit(30, 50) == 0 and R.after_hit(100, 20) == 80 and R.after_hit(50, -10) == 50, "hp never below 0, no healing hits")
	check(is_equal_approx(R.seg_dist(Vector3.ZERO, Vector3(10, 0, 0), Vector3(5, 2, 0)), 2.0), "distance to the middle of a shot")
	check(is_equal_approx(R.seg_dist(Vector3.ZERO, Vector3(10, 0, 0), Vector3(-3, 0, 0)), 3.0), "behind the shooter: distance to the muzzle")
	check(is_equal_approx(R.seg_dist(Vector3.ONE, Vector3.ONE, Vector3(1, 1, 3)), 2.0), "zero-length shot")
	var players := {7: Vector3(4, 1, 0.3), 8: Vector3(2, 1, -0.2), 9: Vector3(5, 1, 3)}
	check(R.shot_hits(Vector3(0, 1, 0), Vector3(10, 1, 0), players) == 8, "the closest player on the line is hit")
	check(R.shot_hits(Vector3(0, 1, 0), Vector3(0, 1, 10), players) == -1, "a shot elsewhere hits nobody")
	check(R.shot_hits(Vector3(0, 1, 0), Vector3(1, 1, 0), players) == -1, "a short shot doesn't reach")


func _samples(R: GDScript) -> void:
	var s := []
	R.push_sample(s, 1.0, Vector3(0, 0, 0), 0.0)
	R.push_sample(s, 1.1, Vector3(1, 0, 0), 1.0)
	R.push_sample(s, 1.05, Vector3(9, 9, 9), 0.0)
	check(s.size() == 2, "a late packet is ignored")
	var mid: Dictionary = R.interp(s, 1.05)
	check(mid.p.is_equal_approx(Vector3(0.5, 0, 0)) and is_equal_approx(mid.y, 0.5), "halfway between samples: %s" % [mid])
	check(R.interp(s, 0.5).p == Vector3.ZERO, "before the first sample: the first")
	check(R.interp(s, 5.0).p == Vector3(1, 0, 0), "after the last: held there, no guessing")
	check(R.interp([], 1.0).is_empty(), "no samples: nowhere")
	for i in 20:
		R.push_sample(s, 2.0 + i, Vector3(i, 0, 0), 0.0)
	check(s.size() == R.SAMPLES, "only the last few samples are kept")
	check(R.vec([1, 2.5, 3]) == Vector3(1, 2.5, 3), "relayed position")
	check(R.vec([1, "x", 3]) == Vector3.INF and R.vec("1,2,3") == Vector3.INF and R.vec([1, 2]) == Vector3.INF, "junk positions are refused")
	var m: Dictionary = R.pos_msg(Vector3(1.2345, 0, -2), 0.5, "plant", 80)
	check(m.t == "pos" and m.p == [1.23, 0.0, -2.0] and m.l == "plant" and m.hp == 80, "position message: %s" % [m])


func _invites(R: GDScript) -> void:
	var link: String = R.invite_link("https://192.0.2.10:8088/", "abcd23efgh")
	check(link == "https://192.0.2.10:8088/?token=abcd23efgh&party=1", "invitation link: %s" % link)
	var inv: Dictionary = R.parse_invite("  " + link + " ")
	check(inv.url == "https://192.0.2.10:8088" and inv.code == "abcd23efgh", "link parsed back: %s" % [inv])
	inv = R.parse_invite("http://127.0.0.1:8088 abcd23efgh")
	check(inv.url == "http://127.0.0.1:8088" and inv.code == "abcd23efgh", "'URL CODE' works too")
	check(R.parse_invite("hello").is_empty() and R.parse_invite("https://x/?party=1").is_empty(), "not an invitation")


func _party() -> Node:
	var p = PartyScript.new()
	root.add_child(p)
	return p


## What the relay sends, fed straight in.
func _messages() -> void:
	var p = _party()
	p.active = true
	p.handle({"t": "welcome", "id": 2, "name": "me", "color": 1, "host": true, "players": [
		{"id": 1, "name": "ana", "color": 0, "host": false}, {"id": 2, "name": "me", "color": 1, "host": true}]})
	check(p.me.id == 2 and p.players.size() == 1 and p.players[1].name == "ana", "welcome: me and the others")
	check(not k8s.guest, "the host is not a guest")
	p.handle({"t": "join", "p": {"id": 3, "name": "bob", "color": 2, "host": false}})
	p.handle({"t": "pos", "id": 3, "p": [1, 0, 2], "y": 0.3, "l": "plant", "hp": 90})
	p.handle({"t": "pos", "id": 3, "p": "junk", "l": "x"})
	p.handle({"t": "pos", "id": 42, "p": [1, 0, 2]})
	check(p.players[3].samples.size() == 1 and p.players[3].level == "plant" and p.players[3].hp == 90, "positions from the relay")
	check(not p.players.has(42), "positions of unknown players are ignored")
	var hurt := [0]
	p.hurt.connect(func(d, _by): hurt[0] += d)
	p.handle({"t": "hit", "id": 3, "v": 1, "d": 50})
	check(p.hp == 100 and hurt[0] == 0, "a hit on someone else doesn't hurt me")
	for i in 5:
		p.handle({"t": "hit", "id": 3, "v": 2, "d": 25})
	check(p.hp == 0 and p.dead_t > 0.0 and hurt[0] == 100, "four hits of 25 and I'm down (a fifth does nothing)")
	check(p.players[3].score == 1, "the one who got me scores")
	p.handle({"t": "dead", "id": 1, "by": 2})
	check(p.score == 1, "I got ana")
	p.handle({"t": "hit", "id": 3, "v": 2, "d": 9999})
	check(p.hp == 0, "no extra hits while down")
	var asks := []
	p.ask_received.connect(func(id, req): asks.append([id, req]))
	p.handle({"t": "ask", "id": 1, "req": {"action": "restart"}})
	p.handle({"t": "ask", "id": 1, "req": "junk"})
	check(asks.size() == 1 and asks[0][0] == 1, "the host gets a guest's ask")
	p.handle({"t": "leave", "id": 3})
	check(not p.players.has(3), "leave")
	p.leave()
	check(not p.active and p.players.is_empty(), "leaving clears the party")
	p.queue_free()


func _alarm_state() -> Dictionary:
	return {"nodes": [{"name": "n1", "ready": false}, {"name": "n2", "ready": true}],
		"pods": [{"ns": "shop", "name": "cart-1", "status": "CrashLoopBackOff", "ready": 0, "total": 1, "restarts": 9, "age": 300,
			"owner_kind": "", "owner_name": "", "node": "n2"}], "workloads": [], "services": [], "alerts": []}


func _mission_switch() -> void:
	var p = _party()
	p.active = true
	p.me = {"id": 1, "name": "me", "color": 0, "host": true}
	p.players[2] = {"id": 2, "name": "ana", "color": 1, "host": false, "samples": [], "level": "", "hp": 100, "score": 0, "bot": false}
	var modes := []
	p.mode_changed.connect(func(m): modes.append(m))
	p.on_state({"nodes": [{"name": "n1", "ready": true}], "pods": []})
	check(p.mode == "shooter", "healthy cluster: shooter")
	p.hp = 40
	p.on_state(_alarm_state())
	check(p.mode == "mission" and modes == ["mission"], "alarm: everyone to the mission")
	check(p.hp == 100, "the mission starts with everyone healed")
	var expected: Array = KM.generate(_alarm_state())
	check(not p.mission.is_empty() and p.mission.id == expected[0].id, "the shared mission is Kubi's most urgent one")
	check(p.mission.step == 0 and p.mission.steps.size() == expected[0].steps.size(), "it starts at the first step")
	p.handle({"t": "hit", "id": 2, "v": 1, "d": 50})
	check(p.hp == 100, "no friendly fire during a mission")
	check(not p.can_shoot(), "no shooting during a mission")
	p.handle({"t": "prog", "id": 2, "m": p.mission.id, "s": 1})
	check(p.mission.step == 1 and p.mission.by.get(0) == "ana", "ana's step counts for everyone, and says who did it")
	p.handle({"t": "prog", "id": 2, "m": "other", "s": 3})
	p.handle({"t": "prog", "id": 2, "m": p.mission.id, "s": 0})
	check(p.mission.step == 1, "progress of another mission, or going back, is ignored")
	p.report_step(2)
	check(p.mission.step == 2 and p.mission.by.get(1) == "you", "my own step")
	# Fixed: calm for a while, then back to the shooter.
	p.on_state({"nodes": [{"name": "n1", "ready": true}, {"name": "n2", "ready": true}], "pods": []})
	check(p.mode == "mission", "not straight back: the calm has to last")
	p._process(R.CALM_FOR + 0.5)
	check(p.mode == "shooter" and modes == ["mission", "shooter"] and p.mission.is_empty(), "calm for long enough: shooter again")
	check(p.can_shoot(), "shooting again")
	p.leave()
	p.queue_free()


## A guest's change never reaches the cluster: it becomes an ask.
func _guest_is_read_only() -> void:
	k8s.start_demo("starter")
	var p = _party()
	p.active = true
	p.handle({"t": "welcome", "id": 5, "name": "guest", "color": 2, "host": false, "players": []})
	check(k8s.guest and p.is_guest(), "welcome as a guest: read-only")
	var asked := []
	k8s.guest_change.connect(func(req): asked.append(req))
	var started := [0]
	k8s.action_started.connect(func(_r): started[0] += 1)
	var pod: Dictionary = k8s.state.pods[0]
	k8s.action({"action": "delete_pod", "ns": pod.ns, "name": pod.name})
	check(asked.size() == 1 and started[0] == 0, "a guest's change goes to the host, not to the cluster")
	p.leave()
	check(not k8s.guest, "leaving the party: no longer a guest")
	p.queue_free()


## Demo: bots shoot paintball (never the cluster), the drill puts the demo
## cluster into alarm and the party into the mission, the fix heals it.
func _demo() -> void:
	k8s.start_demo("shop")
	var p = _party()
	var actions := [0]
	k8s.action_started.connect(func(_r): actions[0] += 1)
	p.start_demo("me", 999.0)
	check(p.active and p.demo and p.players.size() == 3, "demo party: three bots")
	var seen := [0]
	p.shot_seen.connect(func(_id, _a, _b, _w): seen[0] += 1)
	for i in 200:
		p.tick_me(Vector3.ZERO, 0.0, "plant")
		p._process(0.05)
	check(seen[0] > 0, "the bots shoot (%d shots)" % seen[0])
	var near: Dictionary = p.chests("plant")
	check(near.size() >= 1, "the bots are on my level")
	var id: int = near.keys()[0]
	var victim: int = p.fire(Vector3(0, 0.9, 0) + (near[id] - Vector3(0, 0.9, 0)).normalized() * 0.1, near[id], "nuke")
	check(victim == id or victim in near.keys(), "my shot hits a bot")
	check(actions[0] == 0, "paintball: no shot ever touched the cluster")
	k8s.demo_drill(true)
	k8s._mock._emit()
	check(R.level_of_state(k8s.state) == "alarm", "the drill puts the demo cluster in alarm")
	p.on_state(k8s.state)
	check(p.mode == "mission", "and the party into the mission")
	k8s.demo_drill(false)
	for i in 40:
		k8s._mock._reconcile(0.25)
	k8s._mock._emit()
	check(not k8s._mock.drilling() and k8s.state.nodes.all(func(n): return n.ready), "the fix brings the node back")
	p.leave()
	p.queue_free()
