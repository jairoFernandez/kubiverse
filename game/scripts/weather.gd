class_name Weather
extends Node3D
## Weather over the plant. By default it is the CLUSTER's weather: clear when
## everything is healthy, clouds when pods wait, rain when pods fail, a
## thunderstorm when nodes are down or many things fail. Optionally the real
## weather of a city (Open-Meteo, no account) or none. Rain and snow only
## fall outdoors (plant and energy room).

const REAL_EVERY := 900.0      # re-check the real weather every 15 minutes

var kind := "clear"            # clear | cloudy | rain | storm | snow | fog
var amount := 0.0              # 0..1 how heavy
var why := ""                  # short explanation for the HUD
var outdoors := true
var _rain: CPUParticles3D
var _snow: CPUParticles3D
var _flash := 0.0
var _bolt_cd := 4.0
var _real := {}                # {kind, amount, temp, city, t}
var _real_t := -1.0
var _geo := {}                 # city -> {lat, lon}


func _ready() -> void:
	_rain = _particles(Color(0.7, 0.8, 1.0, 0.8), Vector3(0.05, 0.6, 0.05), 900, Vector3(0, -30, 0), 1.1)
	_snow = _particles(Color(1, 1, 1, 0.95), Vector3(0.14, 0.14, 0.14), 500, Vector3(0, -3.5, 0), 6.0)


func _particles(col: Color, size: Vector3, n: int, grav: Vector3, life: float) -> CPUParticles3D:
	var p := CPUParticles3D.new()
	var m := BoxMesh.new()
	m.size = size
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = col
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.material = mat
	p.mesh = m
	p.amount = n
	p.lifetime = life
	p.emission_shape = CPUParticles3D.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(45, 0.5, 45)
	p.direction = Vector3(0.1, -1, 0)
	p.spread = 5.0
	p.gravity = grav
	p.initial_velocity_min = 2.0
	p.initial_velocity_max = 4.0
	p.emitting = false
	p.position = Vector3(0, 22, 0)
	add_child(p)
	return p


## Called every frame with the camera focus; returns nothing, updates state.
var _since_count := 99.0


func tick(delta: float, focus: Vector3, state: Dictionary, is_outdoors: bool) -> void:
	outdoors = is_outdoors
	match Settings.weather:
		"off":
			_set_w("clear", 0.0, "")
		"real":
			_real_tick(delta)
			if _real.is_empty():
				_set_w("clear", 0.0, tr("real weather: set a city in VIEW") if Settings.weather_city == "" else tr("real weather: loading %s...") % Settings.weather_city)
			else:
				_set_w(_real.kind, _real.amount, "%s %d°C" % [Settings.weather_city, int(_real.temp)])
		_:
			# Counting every pod each frame hurts on big clusters: twice a second.
			_since_count += delta
			if _since_count >= 0.5 or kind == "":
				_since_count = 0.0
				_cluster(state)
	global_position = Vector3(focus.x, 0, focus.z)
	var want := 900 if kind == "storm" else int(250 + 650 * clampf(amount, 0.0, 1.0))
	if kind in ["rain", "storm"] and absi(_rain.amount - want) > 120:
		_rain.amount = want  # (restarts the emitter: only when it changes a lot)
	_rain.emitting = outdoors and kind in ["rain", "storm"]
	_snow.emitting = outdoors and kind == "snow"
	_flash = maxf(0.0, _flash - delta * 3.0)
	if kind == "storm":
		_bolt_cd -= delta
		if _bolt_cd <= 0.0:
			_bolt_cd = randf_range(3.0, 9.0)
			_flash = 1.0
			Sfx.play("explode", null, 0.2)


func _set_w(k: String, a: float, w: String) -> void:
	kind = k
	amount = a
	why = w


## The cluster's own weather, from how healthy it is.
func _cluster(s: Dictionary) -> void:
	var bad := 0
	var wait := 0
	for p in s.get("pods", []):
		match PodBot.categorize(p):
			"crash", "pull", "failed": bad += 1
			"pending", "warn": wait += 1
	var down := 0
	for n in s.get("nodes", []):
		if not n.get("ready", true):
			down += 1
	if down > 0 or bad >= 8:
		_set_w("storm", 1.0, tr("storm: %d nodes down, %d pods failing") % [down, bad])
	elif bad > 0:
		_set_w("rain", clampf(bad / 8.0, 0.2, 1.0), tr("rain: %d pods failing") % bad)
	elif wait > 0:
		_set_w("cloudy", clampf(wait / 10.0, 0.3, 1.0), tr("clouds: %d pods waiting") % wait)
	else:
		_set_w("clear", 0.0, tr("clear: all healthy"))


## How the weather tints the light: [sun factor, sky tint, sky mix, fog density].
func light() -> Array:
	match kind:
		"cloudy": return [1.0 - 0.45 * amount, Color("6b7390"), 0.45 * amount, 0.012]
		"rain": return [0.45, Color("4d5570"), 0.6, 0.018]
		"storm": return [0.25, Color("2e3348").lerp(Color("d8e4ff"), _flash), 0.75 + 0.25 * _flash, 0.022]
		"snow": return [0.7, Color("a8b0c8"), 0.5, 0.02]
		"fog": return [0.6, Color("8a8fa0"), 0.6, 0.045]
	return [1.0, Color.WHITE, 0.0, 0.006]


func flash() -> float:
	return _flash


# ------------------------------------------------------------- real weather

func _real_tick(delta: float) -> void:
	var city := Settings.weather_city.strip_edges()
	if city == "":
		_real = {}
		return
	if _real.get("city", "") != city:
		_real = {}
		_real_t = -1.0
	if _real_t >= 0.0:
		_real_t += delta
		if _real_t < REAL_EVERY:
			return
	_real_t = 0.0
	if _geo.has(city):
		_fetch(city)
		return
	_http_get("https://geocoding-api.open-meteo.com/v1/search?count=1&name=" + city.uri_encode(), func(d):
		var r: Array = d.get("results", []) if d.get("results") != null else []
		if r.is_empty():
			_real = {"city": city, "kind": "clear", "amount": 0.0, "temp": 0.0}
			return
		_geo[city] = {"lat": r[0].latitude, "lon": r[0].longitude}
		_fetch(city))


func _fetch(city: String) -> void:
	var g: Dictionary = _geo[city]
	_http_get("https://api.open-meteo.com/v1/forecast?current=weather_code,temperature_2m&latitude=%s&longitude=%s" % [g.lat, g.lon], func(d):
		var cur: Dictionary = d.get("current", {})
		var code := int(cur.get("weather_code", 0))
		var k := "clear"
		var a := 0.5
		if code in [1, 2, 3]: k = "cloudy"; a = code / 3.0
		elif code in [45, 48]: k = "fog"
		elif (code >= 51 and code <= 67) or (code >= 80 and code <= 82): k = "rain"; a = 0.4 if code in [51, 61, 80] else 0.9
		elif (code >= 71 and code <= 77) or code in [85, 86]: k = "snow"
		elif code >= 95: k = "storm"
		_real = {"city": city, "kind": k, "amount": a, "temp": float(cur.get("temperature_2m", 0))})


func _http_get(url: String, cb: Callable) -> void:
	var req := HTTPRequest.new()
	req.timeout = 15.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h, body: PackedByteArray):
		req.queue_free()
		if result != HTTPRequest.RESULT_SUCCESS or code != 200:
			return
		var d = JSON.parse_string(body.get_string_from_utf8())
		if typeof(d) == TYPE_DICTIONARY:
			cb.call(d))
	req.request(url)
