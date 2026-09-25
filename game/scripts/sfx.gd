extends Node
## Autoload "Sfx": a tiny chiptune synthesizer. Every sound effect and the
## music are generated in code (square / triangle / saw / noise voices with
## pitch sweeps and envelopes), so the game ships without audio files.

const RATE := 22050

var _sounds := {}          # name -> AudioStreamWAV
var _players: Array[AudioStreamPlayer] = []
var _next := 0
var _music_day: AudioStreamPlayer
var _music_night: AudioStreamPlayer
var _night := 0.0          # 0 = day music, 1 = night music
var _listener := Vector3.ZERO
var _last_play := {}       # name -> msec, to avoid machine-gun repeats
var _music_task := -1
var _jet: AudioStreamPlayer  # jetpack engine loop
var _jet_level := 0.0


func _exit_tree() -> void:
	if _music_task >= 0:
		WorkerThreadPool.wait_for_task_completion(_music_task)


func _ready() -> void:
	for i in 12:
		var p := AudioStreamPlayer.new()
		p.bus = "Master"
		add_child(p)
		_players.append(p)
	_build_sfx()
	# Jetpack: a seamless loop of hiss + rumble (flat envelope so it loops).
	var jet := mix(voice("noise", 2600, 2600, 1.0, 0.35, 0.0, 0.0), voice("noise", 260, 260, 1.0, 0.6, 0.0, 0.0))
	_jet = AudioStreamPlayer.new()
	_jet.stream = to_wav(normalize(jet, 0.7), true)
	_jet.volume_db = -80.0
	add_child(_jet)
	_music_day = AudioStreamPlayer.new()
	_music_night = AudioStreamPlayer.new()
	for m in [_music_day, _music_night]:
		m.volume_db = -80.0
		add_child(m)
	# Music takes a moment to synthesize: do it off the main thread.
	_music_task = WorkerThreadPool.add_task(_build_music)


# ------------------------------------------------------------------ synth

## One voice: wave from f0 to f1 Hz over `dur` s, attack/decay envelope.
static func voice(wave: String, f0: float, f1: float, dur: float, vol := 0.5, attack := 0.005, curve := 1.0) -> PackedFloat32Array:
	var n := int(dur * RATE)
	var out := PackedFloat32Array()
	out.resize(n)
	var phase := 0.0
	var noise := 0.0
	var hold := 0
	for i in n:
		var t := float(i) / n
		var f := f0 + (f1 - f0) * t
		phase = fmod(phase + f / RATE, 1.0)
		var v := 0.0
		match wave:
			"square": v = 1.0 if phase < 0.5 else -1.0
			"pulse": v = 1.0 if phase < 0.25 else -1.0
			"tri": v = 4.0 * absf(phase - 0.5) - 1.0
			"saw": v = 2.0 * phase - 1.0
			"sine": v = sin(phase * TAU)
			"noise":
				# Sample-and-hold noise: lower f = rumblier.
				hold -= 1
				if hold <= 0:
					noise = randf_range(-1.0, 1.0)
					hold = maxi(1, int(RATE / maxf(f, 1.0)))
				v = noise
		var env := minf(1.0, float(i) / maxf(1.0, attack * RATE)) * pow(1.0 - t, curve)
		out[i] = v * env * vol
	return out


## Mixes `src` into `dst` starting at `at` seconds (dst grows as needed).
static func mix(dst: PackedFloat32Array, src: PackedFloat32Array, at := 0.0) -> PackedFloat32Array:
	var off := int(at * RATE)
	if dst.size() < off + src.size():
		dst.resize(off + src.size())
	for i in src.size():
		dst[off + i] += src[i]
	return dst


## Scales the samples down so the loudest one is at most `peak` (no clipping).
static func normalize(samples: PackedFloat32Array, peak: float, boost := false) -> PackedFloat32Array:
	var m := 0.0
	for v in samples:
		m = maxf(m, absf(v))
	if m <= 0.0 or (m <= peak and not boost):
		return samples
	var k := peak / m
	for i in samples.size():
		samples[i] *= k
	return samples


static func to_wav(samples: PackedFloat32Array, loop := false) -> AudioStreamWAV:
	var data := PackedByteArray()
	data.resize(samples.size() * 2)
	for i in samples.size():
		data.encode_s16(i * 2, int(clampf(samples[i], -1.0, 1.0) * 32000.0))
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	if loop:
		w.loop_mode = AudioStreamWAV.LOOP_FORWARD
		w.loop_end = samples.size()
	return w


# -------------------------------------------------------------- effects

func _build_sfx() -> void:
	var s := {}
	s.blaster = mix(voice("square", 1400, 180, 0.18, 0.35, 0.001, 1.5), voice("noise", 4000, 800, 0.08, 0.15))
	s.hammer = mix(mix(voice("sine", 160, 40, 0.35, 0.8, 0.001, 2.0), voice("noise", 900, 200, 0.25, 0.4, 0.001, 3.0)), voice("square", 880, 860, 0.25, 0.12), 0.02)
	s.ray = PackedFloat32Array()
	for k in 5:
		s.ray = mix(s.ray, voice("tri", 300 + k * 90, 600 + k * 120, 0.12, 0.35), k * 0.08)
	s.freeze = mix(voice("noise", 9000, 5000, 0.5, 0.25, 0.01, 1.2), mix(voice("sine", 1760, 1760, 0.4, 0.15), voice("sine", 2637, 2637, 0.35, 0.1), 0.05))
	s.cutter = mix(voice("noise", 1500, 5000, 0.35, 0.3, 0.05, 0.8), voice("saw", 300, 900, 0.3, 0.12))
	s.nuke_launch = mix(voice("noise", 600, 2500, 0.8, 0.35, 0.1, 0.6), voice("saw", 90, 180, 0.8, 0.15))
	s.explosion = mix(voice("noise", 1200, 60, 1.6, 0.9, 0.001, 2.2), voice("sine", 90, 30, 1.2, 0.8, 0.001, 1.5))
	s.pod_death = mix(voice("noise", 3000, 300, 0.3, 0.45, 0.001, 2.0), voice("square", 660, 110, 0.25, 0.2), 0.03)
	s.hit = voice("noise", 5000, 2000, 0.06, 0.4, 0.001, 2.0)
	s.miss = voice("noise", 1500, 400, 0.15, 0.15, 0.001, 2.0)
	s.jump = voice("square", 280, 700, 0.16, 0.25, 0.002, 0.6)
	s.land = voice("noise", 900, 300, 0.07, 0.25, 0.001, 2.0)
	s.step = voice("noise", 1400, 700, 0.035, 0.12, 0.001, 2.0)
	s.coin = mix(voice("square", 988, 988, 0.08, 0.25), voice("square", 1319, 1319, 0.3, 0.25, 0.001, 1.5), 0.07)
	s.pipe = PackedFloat32Array()
	for k in 3:
		s.pipe = mix(s.pipe, voice("square", 440 - k * 110, 220 - k * 55, 0.15, 0.25), k * 0.12)
	s.door = mix(voice("noise", 800, 2000, 0.3, 0.2, 0.05, 1.0), voice("tri", 330, 660, 0.25, 0.2))
	s.fall = voice("tri", 1200, 150, 0.9, 0.3, 0.01, 0.5)
	s.click = voice("pulse", 1800, 1800, 0.025, 0.15)
	s.key = voice("pulse", 2600, 2400, 0.015, 0.08)
	s.error = mix(voice("square", 180, 170, 0.12, 0.25), voice("square", 140, 130, 0.18, 0.25), 0.1)
	s.alarm = mix(voice("square", 880, 880, 0.1, 0.18), voice("square", 660, 660, 0.12, 0.18), 0.12)
	var jingle := PackedFloat32Array()
	for k in [[523, 0.0], [659, 0.1], [784, 0.2], [1047, 0.3]]:
		jingle = mix(jingle, voice("square", k[0], k[0], 0.18, 0.2), k[1])
	jingle = mix(jingle, voice("tri", 1047, 1047, 0.5, 0.25), 0.4)
	s.jingle = jingle
	s.jet_on = mix(voice("noise", 400, 3000, 0.35, 0.4, 0.02, 0.7), voice("saw", 90, 260, 0.3, 0.15))
	s.jet_off = mix(voice("noise", 2400, 300, 0.3, 0.3, 0.001, 1.2), voice("saw", 200, 70, 0.25, 0.12))
	for k in s:
		_sounds[k] = to_wav(normalize(s[k], 0.85))


## Plays an effect. With `at`, it is quieter the further it is from the player.
func play(name: String, at = null, pitch_jitter := 0.06) -> void:
	if not _sounds.has(name) or Settings.sfx_volume * Settings.master_gain() <= 0.0:
		return
	var now := Time.get_ticks_msec()
	if now - int(_last_play.get(name, 0)) < 30:
		return
	_last_play[name] = now
	var vol := 1.0
	if at is Vector3:
		vol = clampf(1.0 - _listener.distance_to(at) / 40.0, 0.0, 1.0)
		if vol <= 0.02:
			return
	var p := _players[_next]
	_next = (_next + 1) % _players.size()
	p.stream = _sounds[name]
	p.pitch_scale = 1.0 + randf_range(-pitch_jitter, pitch_jitter)
	p.volume_db = linear_to_db(vol * Settings.sfx_volume * Settings.master_gain())
	p.play()


## Jetpack engine: 0 = off, 1 = idle hover, 2 = full thrust.
func set_jet(level: float) -> void:
	if _jet == null:
		return
	_jet_level = move_toward(_jet_level, level, 0.15)
	if _jet_level <= 0.01 or Settings.sfx_volume * Settings.master_gain() <= 0.0:
		if _jet.playing:
			_jet.stop()
		return
	if not _jet.playing:
		_jet.play()
	_jet.pitch_scale = 0.8 + _jet_level * 0.25
	_jet.volume_db = linear_to_db(maxf(0.0001, clampf(0.18 + _jet_level * 0.2, 0.0, 1.0) * Settings.sfx_volume * Settings.master_gain()))


func set_listener(pos: Vector3) -> void:
	_listener = pos


# ---------------------------------------------------------------- music

const NOTES := {"A2": 110.0, "C3": 130.81, "D3": 146.83, "E3": 164.81, "F3": 174.61, "G3": 196.0,
	"A3": 220.0, "C4": 261.63, "D4": 293.66, "E4": 329.63, "F4": 349.23, "G4": 392.0, "A4": 440.0,
	"B3": 246.94, "B4": 493.88, "C5": 523.25, "E5": 659.25, "G5": 783.99}


## Two loops in the same key: an upbeat "day" factory theme and a calm
## "night" one. Chords: Am F C G (day) / Am F Am E (night).
func _build_music() -> void:
	var day := _song(132.0, [["A2", "A3", "C4", "E4"], ["F3", "A3", "C4", "F4"], ["C3", "C4", "E4", "G4"], ["G3", "B3", "D4", "G4"]], true)
	var night := _song(84.0, [["A2", "A3", "C4", "E4"], ["F3", "A3", "C4", "F4"], ["A2", "A3", "C4", "E4"], ["E3", "B3", "E4", "G4"]], false)
	# Same loudness for both themes so the day/night crossfade is smooth.
	call_deferred("_start_music", to_wav(normalize(day, 0.7, true), true), to_wav(normalize(night, 0.7, true), true))


func _song(bpm: float, chords: Array, busy: bool) -> PackedFloat32Array:
	var beat := 60.0 / bpm
	var out := PackedFloat32Array()
	var bars := 8
	for bar in bars:
		var ch: Array = chords[bar % chords.size()]
		var t0 := bar * beat * 4.0
		# Bass: root on eighths (day) or quarters (night)
		var step := beat * (0.5 if busy else 1.0)
		var n := int(beat * 4.0 / step)
		for i in n:
			var f: float = NOTES[ch[0]] * (1.0 if i % 2 == 0 or not busy else 2.0)
			out = mix(out, voice("tri" if not busy else "square", f, f, step * 0.9, 0.16 if busy else 0.2, 0.005, 0.8), t0 + i * step)
		# Arpeggio over the chord
		var arp := beat * (0.25 if busy else 0.5)
		for i in int(beat * 4.0 / arp):
			var note: String = ch[1 + (i % 3)] if busy else ch[1 + ((i / 2) % 3)]
			var f2: float = NOTES[note] * (2.0 if busy and (i / 4) % 2 == 1 else 1.0)
			out = mix(out, voice("pulse" if busy else "tri", f2, f2, arp * 0.85, 0.07 if busy else 0.09, 0.003, 1.2), t0 + i * arp)
		# Drums (day only): kick on 1 and 3, hats on eighths, snare on 2 and 4
		if busy:
			for b in 4:
				if b % 2 == 0:
					out = mix(out, voice("sine", 120, 40, 0.18, 0.5, 0.001, 2.0), t0 + b * beat)
				else:
					out = mix(out, voice("noise", 3000, 1500, 0.12, 0.18, 0.001, 2.0), t0 + b * beat)
				for h in 2:
					out = mix(out, voice("noise", 9000, 8000, 0.03, 0.05, 0.001, 2.0), t0 + b * beat + h * beat * 0.5)
		else:
			# Night: a soft pad note per bar
			out = mix(out, voice("sine", NOTES[ch[2]], NOTES[ch[2]], beat * 4.0, 0.07, 0.8, 0.5), t0)
	out.resize(int(bars * beat * 4.0 * RATE))
	return out


func _start_music(day: AudioStreamWAV, night: AudioStreamWAV) -> void:
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--dump-audio="):
			var dir := arg.substr(13)
			for k in _sounds:
				_sounds[k].save_to_wav(dir + "/" + k + ".wav")
			day.save_to_wav(dir + "/music_day.wav")
			night.save_to_wav(dir + "/music_night.wav")
			print("AUDIO dumped after %d ms" % Time.get_ticks_msec())
	_music_day.stream = day
	_music_night.stream = night
	_music_day.play()
	_music_night.play()


## 0 = full day theme, 1 = full night theme (crossfaded).
func set_night(amount: float) -> void:
	_night = clampf(amount, 0.0, 1.0)


func _process(_delta: float) -> void:
	var mv: float = Settings.music_volume * 0.6 * Settings.master_gain()
	_music_day.volume_db = linear_to_db(maxf(0.0001, mv * (1.0 - _night)))
	_music_night.volume_db = linear_to_db(maxf(0.0001, mv * _night))
