class_name PartyRules
## Multiplayer rules with no nodes in them (tested headless): when the
## party turns from shooter into a shared mission and back, which mission
## everyone plays, paintball damage, hits, and how remote players move
## smoothly between the position updates the bridge relays.

const SEND_EVERY := 0.1     # seconds between position updates (10 Hz)
const INTERP_DELAY := 0.1   # remote players are drawn this far in the past
const CALM_FOR := 10.0      # seconds without alarm before going back to the shooter
const MAX_HP := 100
const RESPAWN := 3.0        # seconds dead before coming back
const HIT_RADIUS := 0.9     # a shot passing this close to a player hits them
const SAMPLES := 6          # position samples kept per remote player

## Paintball: every weapon only hurts players (never the cluster).
const DAMAGE := {"blaster": 20, "hammer": 35, "ray": 15, "freeze": 10, "cutter": 30, "nuke": 60}


## Mode after a new reading of the cluster. calm_s: seconds the cluster has
## been out of alarm. Only an alarm starts a mission (the user's choice).
static func next_mode(mode: String, level: String, calm_s: float) -> String:
	if level == "alarm":
		return "mission"
	if mode == "mission" and calm_s < CALM_FOR:
		return "mission"
	return "shooter"


## The cluster's level the way the CONTROL ROOM sees it.
static func level_of_state(s: Dictionary) -> String:
	return ControlRoom.level_of(ControlRoom.summarize_state(s))


## The mission everyone plays: the most urgent of Kubi's (they come sorted
## and with stable ids, so every game picks the same one from the same
## snapshot). {} when Kubi has nothing to say.
static func pick_mission(missions: Array, keep_id := "") -> Dictionary:
	if missions.is_empty():
		return {}
	for m in missions:
		if keep_id != "" and m.get("id", "") == keep_id:
			return m   # don't jump to another one mid-mission
	return missions[0]


## Shared progress: a step done by anyone counts for everyone.
static func merge_step(mine: int, theirs: int) -> int:
	return maxi(mine, theirs)


static func damage(weapon_id: String) -> int:
	return int(DAMAGE.get(weapon_id, 20))


## Hit points after a hit (never below 0).
static func after_hit(hp: int, dmg: int) -> int:
	return maxi(0, hp - maxi(0, dmg))


## Distance from point p to the segment a-b.
static func seg_dist(a: Vector3, b: Vector3, p: Vector3) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 0.000001:
		return p.distance_to(a)
	var t := clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


## Which player a shot from `from` to `to` hits: the one closest to the
## shooter among those the line passes near. players: {id: Vector3 (chest)}.
## -1 = nobody.
static func shot_hits(from: Vector3, to: Vector3, players: Dictionary) -> int:
	var best := -1
	var best_d := INF
	for id in players:
		var p: Vector3 = players[id]
		if seg_dist(from, to, p) <= HIT_RADIUS:
			var d := from.distance_to(p)
			if d < best_d:
				best_d = d
				best = int(id)
	return best


## Adds a position sample (time-ordered, at most SAMPLES kept).
static func push_sample(samples: Array, t: float, pos: Vector3, yaw: float) -> void:
	if not samples.is_empty() and t <= float(samples[-1].t):
		return   # late or repeated packet
	samples.append({"t": t, "p": pos, "y": yaw})
	while samples.size() > SAMPLES:
		samples.pop_front()


## Where a remote player is at time t: between the two samples around it,
## held at the newest one after it (no guessing ahead), at the oldest before.
static func interp(samples: Array, t: float) -> Dictionary:
	if samples.is_empty():
		return {}
	if t <= float(samples[0].t):
		return {"p": samples[0].p, "y": samples[0].y}
	for i in range(1, samples.size()):
		var a: Dictionary = samples[i - 1]
		var b: Dictionary = samples[i]
		if t <= float(b.t):
			var k := (t - float(a.t)) / maxf(0.0001, float(b.t) - float(a.t))
			return {"p": (a.p as Vector3).lerp(b.p, k), "y": lerp_angle(float(a.y), float(b.y), k)}
	return {"p": samples[-1].p, "y": samples[-1].y}


## Position message for the relay (short keys: it goes out 10 times a second).
static func pos_msg(p: Vector3, yaw: float, level: String, hp: int) -> Dictionary:
	return {"t": "pos", "p": [snappedf(p.x, 0.01), snappedf(p.y, 0.01), snappedf(p.z, 0.01)], "y": snappedf(yaw, 0.01), "l": level, "hp": hp}


## A Vector3 out of a relayed [x, y, z] (anything else: INF, ignored).
static func vec(a) -> Vector3:
	if typeof(a) != TYPE_ARRAY or (a as Array).size() != 3:
		return Vector3.INF
	for x in a:
		if typeof(x) != TYPE_FLOAT and typeof(x) != TYPE_INT:
			return Vector3.INF
	return Vector3(float(a[0]), float(a[1]), float(a[2]))


static func vec_arr(v: Vector3) -> Array:
	return [snappedf(v.x, 0.01), snappedf(v.y, 0.01), snappedf(v.z, 0.01)]


## Invitation link -> {url, code} (or {} if it isn't one). Takes the link the
## host shares (https://host:8088/?token=CODE&party=1) or "url code".
static func parse_invite(text: String) -> Dictionary:
	var s := text.strip_edges()
	var parts := s.split(" ", false)
	if parts.size() == 2:
		return {"url": parts[0].trim_suffix("/"), "code": parts[1]}
	var q := s.find("?")
	if q < 0 or not s.begins_with("http"):
		return {}
	var code := ""
	for kv in s.substr(q + 1).split("&"):
		if kv.begins_with("token="):
			code = kv.substr(6).uri_decode()
	if code == "":
		return {}
	return {"url": s.substr(0, q).trim_suffix("/"), "code": code}


## The link to share: the bridge's URL with the code (the web build served by
## the bridge reads ?token= and joins with ?party=1).
static func invite_link(base_url: String, code: String) -> String:
	return "%s/?token=%s&party=1" % [base_url.trim_suffix("/"), code.uri_encode()]
