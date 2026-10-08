extends Node
## Autoload "Radio": the retro radio in the SOUND menu. A dial of stations:
## the built-in chiptune songs (synthesized by Sfx, no network), a few online
## stations, YouTube, and links the player adds.
##
## Light on the machine by design. Natively the local bridge decodes the
## station with a headless ffmpeg (POST /api/radio, see bridge/radio.go) and
## sends raw PCM + small JPEG frames over a WebSocket: the game mixes the
## sound itself (the volume sliders and mute just work) and paints YouTube
## in a mini player in the HUD, so there is no second window (on macOS any
## window that draws video costs ~300 MB of graphics memory). On the web the
## browser plays it (<audio>, or a small YouTube embed). While an online
## station plays, the synth music stops; switching songs frees the previous
## one. Nothing is fetched until the player tunes in.

signal changed

## kind: synth (a Sfx song) | stream (internet radio) | youtube
const STATIONS := [
	{"id": "kubi", "name": "KUBI FM", "kind": "synth", "song": "kubi", "about": "The game's own chiptune (day / night)"},
	{"id": "lofi", "name": "CHIP LOFI", "kind": "synth", "song": "lofi", "about": "Slow 8-bit beats"},
	{"id": "turbo", "name": "TURBO 8-BIT", "kind": "synth", "song": "turbo", "about": "Fast arcade loop"},
	{"id": "defcon", "name": "DEF CON RADIO", "kind": "stream", "url": "https://ice2.somafm.com/defcon-128-mp3", "about": "SomaFM: music for hacking"},
	{"id": "groovesalad", "name": "GROOVE SALAD", "kind": "stream", "url": "https://ice2.somafm.com/groovesalad-128-mp3", "about": "SomaFM: ambient / downtempo"},
	{"id": "spacestation", "name": "SPACE STATION", "kind": "stream", "url": "https://ice2.somafm.com/spacestation-128-mp3", "about": "SomaFM: spaced-out electronica"},
	{"id": "vaporwaves", "name": "VAPORWAVES", "kind": "stream", "url": "https://ice2.somafm.com/vaporwaves-128-mp3", "about": "SomaFM: retro vaporwave"},
	{"id": "u80s", "name": "UNDERGROUND 80S", "kind": "stream", "url": "https://ice2.somafm.com/u80s-128-mp3", "about": "SomaFM: 80s synthpop"},
	# The channel's /live page always points at its current live stream.
	{"id": "lofigirl", "name": "LOFI GIRL", "kind": "youtube", "url": "https://www.youtube.com/@LofiGirl/live", "embed": "live_stream?channel=UCSJ4gkVC6NrvII8umztf0Ow", "about": "YouTube live: lofi hip hop"},
]

const MAX_CUSTOM := 300   # links the player added (a YouTube playlist brings up to 200)
const QUALITIES := ["low", "medium", "high"]  # YouTube video, see bridge radioQualities
const QUALITY_FPS := {"low": 15.0, "medium": 24.0, "high": 30.0}
const POLL := 3.0        # s between status checks while an online station plays
const GRACE := 12.0      # s a station may take to start before "not playing" is an error
## What the bridge sends (bridge/radio.go: radioRate, 'A' / 'V' messages).
const RATE := 44100.0

## "" | tuning | playing | paused | error
var state := ""
var title := ""          # what is on now (the stream's "now playing")
var error := ""
## Native: what the bridge can play (from GET /api/radio). Unknown until asked.
var has_ffmpeg := true
var has_ytdl := true
var bridge_ok := true    # false: no local bridge, or one too old for the radio
## Native YouTube: the latest frame (nil when there is no picture).
var video: ImageTexture
signal frame

var _poll_t := 0.0
var _since_tune := 0.0
var _sent_vol := -1
var _vol_t := 0.0
var _busy := false       # a status request is in flight
var _ws: WebSocketPeer
var _out: AudioStreamPlayer
var _pb: AudioStreamGeneratorPlayback
var _img := Image.new()
## Native: sound frames played / dropped (buffer full) and video frames shown.
var stats := {"played": 0, "dropped": 0, "frames": 0}
## Playing MY LIST: > and < move along it and the next one starts when one ends.
var list_mode := false
var _list_fails := 0       # stations in a row that failed (stop instead of looping forever)
var _cap := 0              # sound buffer size in frames (to know how far behind the speakers are)
var _frames: Array = []    # [due time s, jpeg] waiting for their sound to be heard
var _last_due := 0.0       # when the newest queued frame is due
## A copy of the player's stations outside settings.cfg, in case that file
## is lost or reset (tests point it elsewhere).
var backup_path := "user://radio-stations.json"


# ------------------------------------------------------------ pure helpers

## "youtube", "stream" or "" (not a web address).
static func kind_of(url: String) -> String:
	var u := url.strip_edges()
	var lower := u.to_lower()
	if not (lower.begins_with("http://") or lower.begins_with("https://")) or u.length() > 2048:
		return ""
	var host := lower.get_slice("://", 1).get_slice("/", 0).get_slice("?", 0).get_slice(":", 0)
	if host == "" or " " in u or "\n" in u:
		return ""
	host = host.trim_prefix("www.").trim_prefix("m.")
	if host in ["youtube.com", "youtu.be", "music.youtube.com", "youtube-nocookie.com"]:
		return "youtube"
	return "stream"


## The video id of a YouTube link ("" if there is none): watch?v=, youtu.be/,
## /live/, /shorts/, /embed/.
static func youtube_id(url: String) -> String:
	if kind_of(url) != "youtube":
		return ""
	var u := url.strip_edges()
	var re := RegEx.create_from_string("(?:[?&]v=|youtu\\.be/|/live/|/shorts/|/embed/)([A-Za-z0-9_-]{11})")
	var m := re.search(u)
	return m.get_string(1) if m else ""


## The YouTube embed for a video id or an embed path ("live_stream?channel=...").
static func embed_src(vid: String) -> String:
	return "https://www.youtube-nocookie.com/embed/%s%sautoplay=1&playsinline=1" % [vid, "&" if "?" in vid else "?"]


## A short name for a link the player added: the host, or "YOUTUBE".
static func name_for(url: String) -> String:
	var k := kind_of(url)
	if k == "youtube":
		return "YOUTUBE " + youtube_id(url)
	if k == "":
		return ""
	return url.strip_edges().get_slice("://", 1).get_slice("/", 0).trim_prefix("www.").to_upper().left(24)


## Fake FM dial frequency for station i: 88.1, 89.3... (it's a retro radio).
static func frequency(i: int) -> String:
	return "%.1f" % (88.1 + i * 1.2)


## Player volume (0-100) for an online station: music slider x master.
## Streams are mastered loud next to the chiptune, so they get 70%.
static func stream_volume(music: float, master_gain: float) -> int:
	return clampi(roundi(music * master_gain * 70.0), 0, 100)


## Interleaved stereo float samples -> frames for an AudioStreamGenerator.
static func to_frames(f: PackedFloat32Array) -> PackedVector2Array:
	var n := f.size() / 2
	var out := PackedVector2Array()
	out.resize(n)
	for i in n:
		out[i] = Vector2(f[2 * i], f[2 * i + 1])
	return out


## Every station on the dial: built-in ones, then the player's.
func stations() -> Array:
	var out: Array = STATIONS.duplicate()
	for c in Settings.radio_custom:
		var url := str(c.get("url", ""))
		var k := kind_of(url)
		if k != "":
			out.append({"id": "custom:" + url, "name": str(c.get("name", name_for(url))), "kind": k, "url": url, "about": url, "custom": true})
	return out


func index() -> int:
	var all := stations()
	for i in all.size():
		if all[i].id == Settings.radio_station:
			return i
	return 0


func current() -> Dictionary:
	return stations()[index()]


func is_online() -> bool:
	return current().kind != "synth"


func find(id: String) -> int:
	var all := stations()
	for i in all.size():
		if all[i].id == id:
			return i
	return -1


func is_favorite(id: String) -> bool:
	return id in Settings.radio_favorites


func toggle_favorite(id: String) -> void:
	if is_favorite(id):
		Settings.radio_favorites.erase(id)
	else:
		Settings.radio_favorites.append(id)
	_save()


## Stations of MY LIST, in order (entries whose station is gone are skipped).
func playlist() -> Array:
	var out := []
	var all := stations()
	for id in Settings.radio_playlist:
		for st in all:
			if st.id == str(id):
				out.append(st)
				break
	return out


func in_playlist(id: String) -> bool:
	return id in Settings.radio_playlist


func playlist_add(id: String) -> void:
	if not in_playlist(id) and find(id) >= 0:
		Settings.radio_playlist.append(id)
		_save()


func playlist_remove(id: String) -> void:
	Settings.radio_playlist.erase(id)
	_save()


## Moves an entry of MY LIST up (-1) or down (+1).
func playlist_move(id: String, dir: int) -> void:
	var i := Settings.radio_playlist.find(id)
	var j := i + dir
	if i < 0 or j < 0 or j >= Settings.radio_playlist.size():
		return
	Settings.radio_playlist[i] = Settings.radio_playlist[j]
	Settings.radio_playlist[j] = id
	_save()


## Plays MY LIST from entry i.
func play_playlist(i := 0) -> void:
	var pl := playlist()
	if pl.is_empty():
		return
	list_mode = true
	_list_fails = 0
	tune(find(pl[posmod(i, pl.size())].id))


func stop_playlist() -> void:
	list_mode = false
	changed.emit()


## Position of station id (default: the current one) in MY LIST, -1 if absent.
func list_pos(id := "") -> int:
	if id == "":
		id = Settings.radio_station
	var pl := playlist()
	for i in pl.size():
		if pl[i].id == id:
			return i
	return -1


func set_quality(q: String) -> void:
	if not q in QUALITIES:
		return
	Settings.radio_quality = q
	Settings.save()
	if current().kind == "youtube" and Settings.radio_video and state in ["playing", "tuning"]:
		_stop_external()
		_apply()
	changed.emit()


## Every link the player added, one per line ("name | link"): to keep
## somewhere safe, or to paste back into the box on another computer.
func export_links() -> String:
	var lines := PackedStringArray()
	for c in Settings.radio_custom:
		lines.append("%s | %s" % [c.get("name", ""), c.get("url", "")])
	return "\n".join(lines)


## The links in a text (one or many, as export_links writes them, or loose).
static func links_in(text: String) -> PackedStringArray:
	var out := PackedStringArray()
	for word in text.replace("|", " ").replace("\n", " ").replace("\t", " ").split(" ", false):
		if kind_of(word) != "" and not out.has(word):
			out.append(word)
	return out


## Settings + the backup copy of the player's stations.
func _save() -> void:
	Settings.save()
	_write_backup()
	changed.emit()


func _write_backup() -> void:
	var f := FileAccess.open(backup_path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify({"custom": Settings.radio_custom, "favorites": Settings.radio_favorites, "playlist": Settings.radio_playlist}, "\t"))


## Brings the stations back from the backup when settings.cfg has none.
func restore_backup() -> bool:
	if not Settings.radio_custom.is_empty() or not FileAccess.file_exists(backup_path):
		return false
	var d = JSON.parse_string(FileAccess.get_file_as_string(backup_path))
	if not d is Dictionary or not d.get("custom") is Array:
		return false
	for c in d.custom:
		if c is Dictionary and kind_of(str(c.get("url", ""))) != "":
			Settings.radio_custom.append({"url": str(c.url), "name": str(c.get("name", name_for(str(c.url))))})
	for key in ["favorites", "playlist"]:
		if d.get(key) is Array:
			var arr: Array = Settings.get("radio_" + key)
			for id in d[key]:
				if not str(id) in arr:
					arr.append(str(id))
	Settings.save()
	return not Settings.radio_custom.is_empty()


# ------------------------------------------------------------------ dial

func _ready() -> void:
	# Never start the network on launch: an online station saved last time
	# comes back as the built-in music until the player turns the dial.
	if is_online():
		Settings.radio_station = "kubi"
	if not Settings.under_test():
		if not restore_backup() and not Settings.radio_custom.is_empty() and not FileAccess.file_exists(backup_path):
			_write_backup()  # links added before there was a backup
	_apply()


func tune(i: int) -> void:
	var all := stations()
	i = posmod(i, all.size())
	if all[i].id == Settings.radio_station and state in ["playing", "tuning"]:
		return
	_stop_external()
	Settings.radio_station = all[i].id
	Settings.save()
	_apply()


## Next / previous station: along MY LIST while it plays, else the dial.
func step(dir: int) -> void:
	var pos := list_pos()
	if list_mode and pos >= 0:
		var pl := playlist()
		tune(find(pl[posmod(pos + dir, pl.size())].id))
		return
	list_mode = false
	tune(index() + dir)


## The TV's channel knobs: next / previous YouTube station (along MY LIST
## while it plays), so the picture never turns into a radio. False when
## there is no other YouTube channel to go to.
func step_video(dir: int) -> bool:
	var pool: Array = playlist() if list_mode and list_pos() >= 0 else stations()
	var tv := pool.filter(func(st): return st.kind == "youtube")
	if tv.size() < 2 and (tv.is_empty() or tv[0].id == Settings.radio_station):
		return false
	var at := -1
	for i in tv.size():
		if tv[i].id == Settings.radio_station:
			at = i
	var next: Dictionary = tv[posmod(at + dir, tv.size())] if at >= 0 else tv[0 if dir > 0 else tv.size() - 1]
	tune(find(next.id))
	return true


## Adds stations from a link (or several, as export_links writes them) and
## tunes in the first. A YouTube playlist link brings its videos, into MY
## LIST too (natively; the bridge asks yt-dlp). cb(error: String) is called
## when done ("" = fine): playlists take a few seconds.
func add(text: String, cb := Callable()) -> void:
	var links := links_in(text)
	if links.is_empty():
		_done(cb, tr("Paste a web address (http:// or https://)"))
		return
	if links.size() == 1 and is_playlist_link(links[0]) and _bridge_url() != "":
		_post({"action": "expand", "url": links[0]}, func(ok: bool, d):
			if not ok:
				_done(cb, tr("Couldn't open that playlist: %s") % _explain(d))
				return
			var first := ""
			for it in d.get("items", []):
				var u := str(it.get("url", ""))
				var e := _add_one(u, str(it.get("title", "")).left(40))
				if e == "" or e == "dup":
					Settings.radio_playlist.erase("custom:" + u)
					Settings.radio_playlist.append("custom:" + u)
					if first == "":
						first = u
			_save()
			if first != "":
				play_playlist(list_pos("custom:" + first))
			_done(cb, "" if first != "" else tr("The dial is full: remove a station first")))
		return
	var err := ""
	var first := ""
	for u in links:
		var e := _add_one(u)
		if e == "" or e == "dup":
			if first == "":
				first = u
		else:
			err = e
	# A name written before the link ("name | link") is kept.
	for line in text.split("\n", false):
		if " | " in line:
			_rename("custom:" + line.get_slice(" | ", 1).strip_edges(), line.get_slice(" | ", 0).strip_edges())
	_save()
	if first != "":
		list_mode = false
		tune(find("custom:" + first))
	_done(cb, err if first == "" else "")


static func is_playlist_link(url: String) -> bool:
	return kind_of(url) == "youtube" and ("list=" in url or "/playlist" in url)


## "" added, "dup" already there, or what's wrong.
func _add_one(url: String, name := "") -> String:
	if kind_of(url) == "":
		return tr("Paste a web address (http:// or https://)")
	for c in Settings.radio_custom:
		if str(c.get("url", "")) == url:
			return "dup"
	if Settings.radio_custom.size() >= MAX_CUSTOM:
		return tr("The dial is full: remove a station first")
	Settings.radio_custom.append({"url": url, "name": name if name != "" else name_for(url)})
	return ""


func _rename(id: String, name: String) -> void:
	if name == "":
		return
	for c in Settings.radio_custom:
		if "custom:" + str(c.get("url", "")) == id:
			c.name = name.left(40)


func _done(cb: Callable, err: String) -> void:
	if cb.is_valid():
		cb.call(err)


func remove_current() -> void:
	remove(Settings.radio_station)


## Takes a station the player added off the dial (and their lists).
func remove(id: String) -> void:
	var i := find(id)
	if i < 0 or not stations()[i].get("custom", false):
		return
	var playing := id == Settings.radio_station
	if playing:
		_stop_external()
	var url: String = stations()[i].url
	var keep := []
	for c in Settings.radio_custom:
		if str(c.get("url", "")) != url:
			keep.append(c)
	Settings.radio_custom = keep
	Settings.radio_favorites.erase(id)
	Settings.radio_playlist.erase(id)
	if playing:
		Settings.radio_station = "kubi"
		list_mode = false
	_save()
	if playing:
		_apply()


func set_video(on: bool) -> void:
	Settings.radio_video = on
	Settings.save()
	if current().kind == "youtube" and state != "error":
		_stop_external()
		_apply()


## Live radio has nothing to resume from: pause stops it, play tunes in again.
func toggle_pause() -> void:
	if not is_online() or state not in ["playing", "paused", "tuning"]:
		return
	if state == "paused":
		_apply()
		return
	_stop_external()
	Sfx.set_external(true)  # silence, not the built-in music
	_set_state("paused")


func has_video() -> bool:
	return video != null and is_online() and state == "playing"


func _set_state(s: String, err := "") -> void:
	state = s
	error = err
	changed.emit()


## Starts the current station.
func _apply() -> void:
	var st := current()
	title = ""
	_since_tune = 0.0
	_poll_t = 0.0
	if st.kind == "synth":
		Sfx.set_external(false)
		Sfx.set_song(st.song)
		_set_state("playing")
		return
	_sent_vol = stream_volume(Settings.music_volume, Settings.master_gain())
	if OS.has_feature("web"):
		_web_play(st)
		return
	if _bridge_url() == "":
		bridge_ok = false
		_fallback(tr("Online stations need the game's bridge, and it isn't running"))
		return
	_set_state("tuning")
	Sfx.set_external(true)
	_listen()
	var want_video: bool = st.kind == "youtube" and Settings.radio_video
	_post({"action": "play", "url": st.url, "video": want_video, "quality": Settings.radio_quality}, func(ok: bool, d):
		if Settings.radio_station != st.id:
			return
		if ok:
			bridge_ok = true
		else:
			_fallback(_explain(d)))


## The station can't play: say why and bring the built-in music back. While
## MY LIST plays, the next entry starts instead (a video ended, or failed).
func _fallback(why: String) -> void:
	if list_mode and list_pos() >= 0 and _list_fails < playlist().size() and bridge_ok and has_ffmpeg:
		if why != tr("The station stopped"):
			_list_fails += 1
		_close()
		state = "error"  # the bridge already stopped it: nothing to stop
		step(1)
		return
	list_mode = false
	_close()
	Sfx.set_external(false)
	Sfx.set_song("kubi")
	_set_state("error", why)


func _explain(d) -> String:
	var e := str(d.get("error", "")) if d is Dictionary else str(d)
	if e.contains("404"):
		bridge_ok = false
		return tr("This bridge is too old for the radio: update it")
	if e.contains("ffmpeg is not installed"):
		has_ffmpeg = false
		return tr("Install ffmpeg to hear online stations")
	if e.contains("yt-dlp"):
		has_ytdl = false
		return tr("Install yt-dlp to play YouTube")
	return e


func _stop_external() -> void:
	if not is_online() or state in ["error", "paused"]:
		return
	if OS.has_feature("web"):
		_web_stop()
	else:
		_close()
		_post({"action": "stop"}, func(_ok, _d): pass)


func _process(delta: float) -> void:
	if not is_online() or state in ["error", "paused"]:
		return
	_since_tune += delta
	if OS.has_feature("web"):
		# The volume sliders drive the browser's player (a short wait while dragging).
		var v := stream_volume(Settings.music_volume, Settings.master_gain())
		if v != _sent_vol:
			_vol_t += delta
			if _vol_t > 0.25:
				_vol_t = 0.0
				_sent_vol = v
				_js("if(window.kubiRadio){window.kubiRadio.volume=%.2f}" % (v / 100.0))
		return
	_receive()
	_poll_t -= delta
	if _poll_t <= 0.0 and not _busy:
		_poll_t = POLL
		_poll()


## Native: what ffmpeg is playing (and keeps the bridge's radio alive, see
## radio.watch in the bridge).
func _poll() -> void:
	var url := _bridge_url()
	if url == "":
		_fallback(tr("Online stations need the game's bridge, and it isn't running"))
		return
	_busy = true
	var id: String = Settings.radio_station
	K8s.fetch_json(url + "/api/radio", func(code: int, d):
		_busy = false
		if Settings.radio_station != id or state == "error":
			return
		if code != 200 or not d is Dictionary:
			if _since_tune > GRACE:
				_fallback(tr("The radio isn't answering"))
			return
		has_ffmpeg = bool(d.get("available", true))
		has_ytdl = bool(d.get("youtube", true))
		if d.get("playing", false) or d.get("tuning", false):
			var t := str(d.get("title", ""))
			var s := "playing" if d.get("playing", false) else "tuning"
			if s == "playing":
				_list_fails = 0
			_auto_name(id, str(d.get("station", "")), t)
			if t != title or s != state:
				title = t
				_set_state(s)
		elif _since_tune > 2.0:
			var why := str(d.get("error", ""))
			if why == "the station stopped" or why == "":
				_fallback(tr("The station stopped"))  # it ended by itself
			else:
				_fallback(tr("The station stopped") + " (%s)" % why), _headers())


## A link added without a name gets the stream's own name or the video's title.
func _auto_name(id: String, station: String, video_title: String) -> void:
	var i := find(id)
	if i < 0 or not stations()[i].get("custom", false):
		return
	var st: Dictionary = stations()[i]
	if st.name != name_for(st.url):
		return  # named by the player (or already named)
	var n := station if st.kind == "stream" else video_title
	if n != "":
		_rename(id, n)
		_save()


# --------------------------------------------------------- native backend

## Opens the bridge's sound socket and a generator to play it through.
func _listen() -> void:
	_close()
	_ws = WebSocketPeer.new()
	_ws.inbound_buffer_size = 1 << 21   # an Icecast server sends a few seconds at once
	_ws.max_queued_packets = 512
	var url := _bridge_url().replace("http://", "ws://") + "/api/radio/ws"
	var h := _headers()
	if h.size() > 0:
		url += "?token=" + h[0].get_slice(": ", 1).uri_encode()
	if _ws.connect_to_url(url) != OK:
		_ws = null
		return
	_frames.clear()
	_last_due = 0.0
	if _out == null:
		_out = AudioStreamPlayer.new()
		var gen := AudioStreamGenerator.new()
		gen.mix_rate = RATE
		gen.buffer_length = 1.5   # s: rides out network hiccups, ~0.5 MB
		_out.stream = gen
		add_child(_out)
	_out.play()
	_pb = _out.get_stream_playback()
	_cap = _pb.get_frames_available()


## Lets go of the socket, the sound buffer and the last frame.
func _close() -> void:
	if _ws:
		_ws.close()
		_ws = null
	if _out:
		_out.stop()  # frees the generator's buffer
	_pb = null
	_frames.clear()
	if video:
		video = null
		frame.emit()


func _receive() -> void:
	if _out:
		_out.volume_db = linear_to_db(maxf(0.0001, stream_volume(Settings.music_volume, Settings.master_gain()) / 100.0))
	if _ws == null:
		return
	_ws.poll()
	if _ws.get_ready_state() == WebSocketPeer.STATE_CLOSED:
		_ws = null
		return
	# A frame waits as long as the sound already queued in front of it, so
	# the picture keeps time with the speakers.
	var now := Time.get_ticks_msec() / 1000.0
	var lag := 0.0
	if _pb and _cap > 0:
		lag = float(_cap - _pb.get_frames_available()) / RATE
	while _ws.get_available_packet_count() > 0:
		var pkt := _ws.get_packet()
		if pkt.size() < 2:
			continue
		match pkt[0]:
			65:  # 'A': stereo float32 PCM
				var f := to_frames(pkt.slice(1).to_float32_array())
				if _pb and _pb.can_push_buffer(f.size()):
					_pb.push_buffer(f)
					stats.played += f.size()
				else:
					stats.dropped += f.size()
			86:  # 'V': a JPEG frame
				# YouTube hands out whole segments: frames come in bursts.
				# Space them at the video's rate so it plays smoothly.
				var due := maxf(now + lag, _last_due + 1.0 / float(QUALITY_FPS.get(Settings.radio_quality, 24.0)))
				if due - now > lag + 3.0:
					due = now + lag  # fell far behind (a stall): catch up
					_frames.clear()
				_last_due = due
				if _frames.size() < 150:
					_frames.append([due, pkt])
	var shown := PackedByteArray()
	while not _frames.is_empty() and _frames[0][0] <= now:
		shown = _frames.pop_front()[1]
	if shown.size() > 0:  # only the newest one that is due is decoded
		_show(shown.slice(1))
		stats.frames += 1
		frame.emit()


func _show(jpeg: PackedByteArray) -> void:
	if _img.load_jpg_from_buffer(jpeg) != OK:
		return
	if video == null or video.get_size() != Vector2(_img.get_size()):
		video = ImageTexture.create_from_image(_img)
	else:
		video.update(_img)

## The bridge on this machine (the one the game started or found).
func _bridge_url() -> String:
	if not LocalBridge.supported():
		return ""
	return K8s.local.ready_url()


## A hand-started bridge may want its token: the saved cluster that uses it.
func _headers() -> PackedStringArray:
	var h := PackedStringArray()
	var url := _bridge_url().trim_suffix("/")
	for sv in Settings.servers:
		if str(sv.get("url", "")).trim_suffix("/") == url and str(sv.get("token", "")) != "":
			h.append("X-Bridge-Token: " + str(sv.token))
			break
	return h


func _post(body: Dictionary, cb: Callable) -> void:
	var url := _bridge_url()
	if url == "":
		cb.call(false, tr("Online stations need the game's bridge, and it isn't running"))
		return
	var req := HTTPRequest.new()
	req.timeout = 10.0
	add_child(req)
	req.request_completed.connect(func(result: int, code: int, _h, raw: PackedByteArray):
		req.queue_free()
		var d = JSON.parse_string(raw.get_string_from_utf8())
		if result != HTTPRequest.RESULT_SUCCESS:
			cb.call(false, "request failed (result %d)" % result)
		elif code == 200:
			cb.call(true, d)
		else:
			cb.call(false, d if d is Dictionary else "HTTP %d" % code))
	var headers := _headers()
	headers.append("Content-Type: application/json")
	if req.request(url + "/api/radio", headers, HTTPClient.METHOD_POST, JSON.stringify(body)) != OK:
		req.queue_free()
		cb.call(false, "cannot send request")


# ------------------------------------------------------------ web backend

func _js(code: String) -> Variant:
	if not OS.has_feature("web"):
		return null
	return JavaScriptBridge.eval(code, true)


## The browser streams it: one <audio> reused for every station (it buffers
## a few seconds, nothing more), or a 320x180 YouTube embed in a corner.
func _web_play(st: Dictionary) -> void:
	Sfx.set_external(true)
	_web_stop()
	if st.kind == "youtube":
		var vid: String = st.get("embed", youtube_id(st.url))
		if vid == "":
			_fallback(tr("That YouTube link has no video id"))
			return
		_js("""(function(){var d=document.createElement('div');d.id='kubiRadioVideo';
d.style.cssText='position:fixed;right:16px;bottom:16px;width:320px;height:180px;z-index:9999;border:3px solid #10142a;box-shadow:0 0 0 3px #7b8cde;background:#000';
var f=document.createElement('iframe');f.width='320';f.height='180';f.style.border='0';
f.allow='autoplay; encrypted-media';f.src=%s;
d.appendChild(f);document.body.appendChild(d);})()""" % JSON.stringify(embed_src(vid)))
		_set_state("playing")
		return
	_js("""(function(){var a=window.kubiRadio||(window.kubiRadio=new Audio());a.preload='none';
a.src=%s;a.volume=%.2f;window.kubiRadioErr='';
a.play().catch(function(e){window.kubiRadioErr=String(e)});})()""" % [JSON.stringify(st.url), _sent_vol / 100.0])
	_set_state("playing")


func _web_stop() -> void:
	# Emptying src (and load()) drops the buffered audio and the connection.
	_js("""(function(){var a=window.kubiRadio;if(a){a.pause();a.removeAttribute('src');a.load();}
var d=document.getElementById('kubiRadioVideo');if(d){d.remove();}})()""")
