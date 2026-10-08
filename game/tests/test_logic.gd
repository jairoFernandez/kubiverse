extends "res://tests/harness.gd"
## Headless checks of pure helpers (no world, no scene):
##   godot --headless --path game --script res://tests/test_logic.gd

## i18n: tr("...") literals with no Spanish entry that predate the check.
## Only NEW missing keys fail; shrink this list as they get translated.
const I18N_BASELINE := "res://tests/i18n_missing_baseline.txt"


## Counts its draws, to know the chart really drew (headless included).
class ChartProbe extends TrendChart:
	var drew := 0

	func _draw() -> void:
		super()
		drew += 1


func _init() -> void:
	_pod_categories()
	_gitops_dock()
	_rollouts()
	_trend_math()
	_search_kinds()
	_updates()
	_i18n()
	_local_bridge()
	_local_bridge_pick()
	_kubi_terminal_commands()
	await _trend_draw()
	await _radio_links()
	await _radio_dial()
	finish("logic tests")


## The radio tells streams from YouTube and refuses anything that isn't web.
func _radio_links() -> void:
	await process_frame  # radio.gd uses autoloads: load it once they exist
	var R: GDScript = load("res://scripts/radio.gd")
	check(R.kind_of("https://ice2.somafm.com/defcon-128-mp3") == "stream", "an Icecast URL is a stream")
	check(R.kind_of(" http://radio.example:8000/live ") == "stream", "http with a port, spaces trimmed")
	for u in ["https://www.youtube.com/watch?v=jfKfPfyJRdk", "https://youtu.be/jfKfPfyJRdk", "https://m.youtube.com/live/jfKfPfyJRdk", "https://music.youtube.com/watch?v=jfKfPfyJRdk&list=x"]:
		check(R.kind_of(u) == "youtube", "YouTube: " + u)
		check(R.youtube_id(u) == "jfKfPfyJRdk", "video id of " + u)
	check(R.youtube_id("https://www.youtube.com/shorts/abcdefghijk") == "abcdefghijk", "shorts id")
	check(R.youtube_id("https://www.youtube.com/") == "", "no id on the home page")
	for bad in ["", "file:///etc/passwd", "ftp://x/y", "javascript:alert(1)", "https://", "https://a b/c", "youtube.com/watch?v=jfKfPfyJRdk"]:
		check(R.kind_of(bad) == "", "not a station: '%s'" % bad)
	check(R.kind_of("https://notyoutube.com/x") == "stream", "a lookalike host is not YouTube")
	check(R.name_for("https://www.radio.example:8000/live") == "RADIO.EXAMPLE:8000", "a custom stream is named after its host")
	check(R.name_for("https://youtu.be/jfKfPfyJRdk") == "YOUTUBE jfKfPfyJRdk", "a YouTube link is named after its video")
	check(R.frequency(0) == "88.1" and R.frequency(5) == "94.1", "FM dial frequencies")
	check(R.stream_volume(0.5, 1.0) == 35, "half music volume")
	check(R.stream_volume(1.0, 0.0) == 0, "muted means silent")
	check(R.stream_volume(5.0, 1.0) == 100, "never above 100")
	check(R.embed_src("abcdefghijk") == "https://www.youtube-nocookie.com/embed/abcdefghijk?autoplay=1&playsinline=1", "web embed of a video")
	check(R.embed_src("live_stream?channel=UC1") == "https://www.youtube-nocookie.com/embed/live_stream?channel=UC1&autoplay=1&playsinline=1", "web embed of a channel's live stream")
	check(R.is_playlist_link("https://www.youtube.com/playlist?list=PL123") and R.is_playlist_link("https://www.youtube.com/watch?v=abcdefghijk&list=PL1"), "YouTube playlist links")
	check(not R.is_playlist_link("https://youtu.be/abcdefghijk") and not R.is_playlist_link("https://radio.example/?list=1"), "not playlists")
	var fr: PackedVector2Array = R.to_frames(PackedFloat32Array([0.5, -0.5, 0.25, 1.0, 0.75]))
	check(fr.size() == 2 and fr[0] == Vector2(0.5, -0.5) and fr[1] == Vector2(0.25, 1.0), "PCM from the bridge: interleaved L R pairs (a stray sample dropped)")
	var lofi := {}
	for st in R.STATIONS:
		if st.id == "lofigirl":
			lofi = st
	check(R.kind_of(lofi.url) == "youtube" and str(lofi.get("embed", "")).begins_with("live_stream?channel="), "Lofi Girl follows the channel's live stream (native and web)")
	var ids := {}
	for st in R.STATIONS:
		check(not ids.has(st.id), "unique station id " + st.id)
		ids[st.id] = true
		if st.kind == "synth":
			check(st.song == "kubi" or root.get_node("Sfx").SONGS.has(st.song), "a built-in station has a song: " + st.id)
		else:
			check(R.kind_of(st.url) == st.kind, "station %s is a %s" % [st.id, st.kind])


## Turning the dial: built-in songs swap in Sfx, links can be added and
## removed, and an online station with no bridge falls back to the music.
func _radio_dial() -> void:
	await process_frame  # the autoloads are in the tree from here on
	var settings: Node = root.get_node("Settings")
	var sfx: Node = root.get_node("Sfx")
	var radio: Node = root.get_node("Radio")
	var saved_station: String = settings.radio_station
	var saved_custom: Array = settings.radio_custom.duplicate(true)
	settings.radio_custom = []
	radio.tune(1)
	check(radio.current().id == "lofi" and sfx.song() == "lofi", "the dial plays CHIP LOFI")
	radio.step(-1)
	check(radio.current().id == "kubi" and sfx.song() == "kubi", "back to KUBI FM")
	radio.step(-1)
	check(radio.index() == radio.stations().size() - 1, "the dial wraps around")
	radio.tune(0)
	var err := [""]
	var got := func(e: String): err[0] = e
	radio.add("not a link", got)
	check(err[0] != "", "a non-link is refused")
	var n: int = radio.stations().size()
	radio.add("https://radio.example/live", got)
	check(err[0] == "", "a stream link is added")
	check(radio.stations().size() == n + 1 and radio.current().get("custom", false), "and tuned in")
	radio.add("https://radio.example/live", got)
	check(radio.stations().size() == n + 1, "no duplicates")
	# Headless there is no bridge: the station says so and the music stays.
	check(radio.state == "error" and radio.error != "", "no bridge: an error the player can read")
	check(sfx.song() == "kubi", "the built-in music plays instead")
	radio.remove_current()
	check(radio.stations().size() == n and radio.current().id == "kubi", "removed, back to KUBI FM")
	radio.add("https://youtu.be/jfKfPfyJRdk", got)
	check(err[0] == "" and radio.current().kind == "youtube", "a YouTube link is added, as a YouTube station")
	radio.remove_current()
	await _radio_lists(settings, radio)
	settings.radio_custom = saved_custom
	settings.radio_station = saved_station
	settings.save()


## Favorites, MY LIST, the backup of the player's links and COPY LINKS.
func _radio_lists(settings: Node, radio: Node) -> void:
	var saved := [settings.radio_favorites.duplicate(), settings.radio_playlist.duplicate(), radio.backup_path]
	settings.radio_favorites = []
	settings.radio_playlist = []
	radio.backup_path = OS.get_temp_dir().path_join("kubiverse-test-radio-%d.json" % OS.get_process_id())
	radio.toggle_favorite("defcon")
	check(radio.is_favorite("defcon"), "a favorite")
	radio.toggle_favorite("defcon")
	check(not radio.is_favorite("defcon"), "and not anymore")
	# Several links at once, as COPY LINKS writes them: names are kept.
	radio.add("My stream | https://a.example/live\nhttps://b.example/live\n  junk  ", func(_e): pass)
	check(settings.radio_custom.size() == 2 and settings.radio_custom[0].name == "My stream", "pasted links keep their names: %s" % [settings.radio_custom])
	check(radio.current().url == "https://a.example/live", "the first one is tuned in")
	var exported: String = radio.export_links()
	check(exported == "My stream | https://a.example/live\nA.EXAMPLE | https://b.example/live".replace("A.EXAMPLE", "B.EXAMPLE"), "COPY LINKS: " + exported)
	check(Array(radio.links_in(exported)) == ["https://a.example/live", "https://b.example/live"], "the copied text pastes back")
	# MY LIST: order, moves, stepping along it.
	for id in ["kubi", "custom:https://a.example/live", "lofi"]:
		radio.playlist_add(id)
	radio.playlist_add("kubi")
	check(settings.radio_playlist == ["kubi", "custom:https://a.example/live", "lofi"], "MY LIST, no duplicates")
	radio.playlist_move("lofi", -1)
	check(settings.radio_playlist == ["kubi", "lofi", "custom:https://a.example/live"], "moved up")
	radio.playlist_move("kubi", -1)
	check(settings.radio_playlist[0] == "kubi", "the first can't go higher")
	radio.play_playlist(1)
	check(radio.list_mode and radio.current().id == "lofi", "MY LIST plays from entry 2")
	radio.step(-1)
	check(radio.current().id == "kubi" and radio.list_mode, "< goes back along MY LIST, not the dial")
	radio.step(-1)
	check(radio.current().id == "custom:https://a.example/live", "and wraps to its end")
	# That one can't play at all (no bridge headless): MY LIST stops there
	# instead of spinning through every entry.
	check(radio.state == "error" and not radio.list_mode, "no bridge: MY LIST stops at the online entry")
	radio.stop_playlist()
	# The TV's knobs only go to YouTube channels.
	radio.tune(radio.find("lofigirl"))
	check(not radio.step_video(1), "one YouTube channel: the knob has nowhere to go")
	radio.add("https://youtu.be/abcdefghijk", func(_e): pass)
	radio.tune(radio.find("lofigirl"))
	check(radio.step_video(1) and radio.current().id == "custom:https://youtu.be/abcdefghijk", "CH+ skips every radio to the next video")
	check(radio.step_video(1) and radio.current().id == "lofigirl", "and wraps among videos only")
	radio.remove("custom:https://youtu.be/abcdefghijk")
	radio.tune(0)
	# Removing a station takes it off the lists too.
	radio.toggle_favorite("custom:https://b.example/live")
	radio.playlist_add("custom:https://b.example/live")
	radio.remove("custom:https://b.example/live")
	check(not radio.is_favorite("custom:https://b.example/live") and not radio.in_playlist("custom:https://b.example/live"), "removed everywhere")
	check(radio.playlist().size() == 3, "the rest of MY LIST stays")
	# The backup brings the links back if settings.cfg loses them.
	check(FileAccess.file_exists(radio.backup_path), "a backup next to the settings")
	var custom: Array = settings.radio_custom.duplicate(true)
	settings.radio_custom = []
	settings.radio_playlist = []
	check(radio.restore_backup(), "restored from the backup")
	check(settings.radio_custom == custom and settings.radio_playlist.size() == 3, "same links and MY LIST: %s" % [settings.radio_custom])
	check(not radio.restore_backup(), "never over links the settings still have")
	DirAccess.remove_absolute(radio.backup_path)
	for c in custom:
		radio.remove("custom:" + c.url)
	settings.radio_favorites = saved[0]
	settings.radio_playlist = saved[1]
	radio.backup_path = saved[2]


## Kubi's suggestions get RUN only if the game terminal can run them.
func _kubi_terminal_commands() -> void:
	var ok := ["kubectl get pods -A", "kubectl -n kube-system logs <pod> --previous",
		"kubectl -n shop describe pod api-1", "kubectl get pod -l k8s-app=kube-dns -o jsonpath='{.items[0].metadata.name}'"]
	for c in ok:
		check(TerminalRules.can_run(c), "runs in the terminal: " + c)
	var bad := ["kubectl -n kube-system exec -it `kubectl -n kube-system get pod -o name` -- sh",
		"kubectl -n kube-system exec coredns-1 -- ls", "kubectl get pods | grep api", "kubectl get pods -w",
		"kubectl logs api-1 -f", "kubectl edit deploy api", "kubectl get pod $(cat name)", "kubectl apply -f x.yaml",
		"kubectl --namespace shop port-forward svc/api 8080:80"]
	for c in bad:
		check(not TerminalRules.can_run(c), "copy only, the terminal refuses it: " + c)


## The game starts the newest bridge it finds, not the first one.
func _local_bridge_pick() -> void:
	var old := "/home/u/.kubecraft/bin/kubiverse-bridge"
	var brew := "/opt/homebrew/bin/kubiverse-bridge"
	check(LocalBridge.pick([[old, "0.1.16"], [brew, "0.1.23"]]) == brew, "an upgraded Homebrew bridge beats an old ~/.kubecraft one")
	check(LocalBridge.pick([[brew, "0.1.23"], [old, "0.1.16"]]) == brew, "order doesn't matter when versions differ")
	check(LocalBridge.pick([[old, "0.1.23"], [brew, "0.1.23"]]) == old, "same version: the first one wins")
	check(LocalBridge.pick([[old, ""], [brew, "0.1.2"]]) == brew, "a known version beats an unknown one")
	check(LocalBridge.pick([[old, "dev"], [brew, ""]]) == old, "no known versions: the first one")
	check(LocalBridge.pick([]) == "", "nothing found")


func _local_bridge() -> void:
	check(LocalBridge.DEFAULT_PORT != LocalBridge.CLASSIC_PORT, "the game's bridge port is not the classic 8088")
	check(LocalBridge.valid_port(LocalBridge.DEFAULT_PORT), "default port is valid")
	check(LocalBridge.DEFAULT_PORT < 32768, "default port is below the Linux ephemeral range")
	check(not LocalBridge.valid_port(80) and not LocalBridge.valid_port(70000) and not LocalBridge.valid_port(0), "privileged/out-of-range ports rejected")
	check(LocalBridge.url_for(28088) == "http://127.0.0.1:28088", "url_for")
	var a := LocalBridge.args_for(31000)
	check(a.size() == 2 and a[0] == "--addr" and a[1] == "127.0.0.1:31000", "listens on 127.0.0.1 only: %s" % [a])
	var c := LocalBridge.candidates("/usr/bin:/bin", "/home/u", false)
	check(c[0] == "/usr/bin/kubiverse-bridge" and c[1] == "/bin/kubiverse-bridge", "PATH first, in order: %s" % [c])
	check(c.find("/home/u/.kubecraft/bin/kubiverse-bridge") == 2, "then ~/.kubecraft/bin: %s" % [c])
	check(c.has("/opt/homebrew/bin/kubiverse-bridge") and c.has("/usr/local/bin/kubiverse-bridge"), "Homebrew even with a bare Finder PATH")
	var dup := LocalBridge.candidates("/opt/homebrew/bin/:/opt/homebrew/bin", "/home/u", false)
	check(dup.count("/opt/homebrew/bin/kubiverse-bridge") == 1, "no duplicates: %s" % [dup])
	var w := LocalBridge.candidates("C:\\tools;C:\\bin\\", "C:\\Users\\u", true)
	check(w[0] == "C:\\tools/kubiverse-bridge.exe" and w[1] == "C:\\bin/kubiverse-bridge.exe", "Windows: ; separator and .exe: %s" % [w])
	check(not w.has("/opt/homebrew/bin/kubiverse-bridge.exe"), "no Homebrew folders on Windows")
	var p := LocalBridge.widen_path("/usr/local/bin:/usr/bin", "/home/u")
	check(p.begins_with("/usr/local/bin:/usr/bin:"), "widen_path keeps the PATH first: %s" % p)
	check(p.count("/usr/local/bin") == 1 and "/opt/homebrew/bin" in p, "widen_path adds Homebrew once: %s" % p)
	check(not LocalBridge.supported(), "headless runs never start a bridge")
	var to := "http://127.0.0.1:28088"
	var servers := [
		{"name": "a", "url": "http://127.0.0.1:8088", "token": "", "context": "x"},
		{"name": "b", "url": "http://localhost:8088/", "token": "t", "context": ""},
		{"name": "c", "url": "https://team.example", "token": "", "context": "y"},
	]
	var r := LocalBridge.rehome_servers(servers, to)
	check(r[1] and r[0][0].url == to and r[0][1].url == to, "saved local clusters move to the game's bridge: %s" % [r[0]])
	check(r[0][2].url == "https://team.example" and r[0][1].token == "t", "remote ones and tokens untouched")
	check(servers[0].url == "http://127.0.0.1:8088", "rehome_servers doesn't change its input")
	check(not LocalBridge.rehome_servers([servers[2]], to)[1], "nothing to move: reported as such")
	var kinds := {"http://127.0.0.1:8088|x": "prod", "http://localhost:8088|": "sandbox", "https://team.example|y": "prod", "demo": "sandbox"}
	var k2 := LocalBridge.rehome_keys(kinds, to)
	check(k2.get(to + "|x") == "prod" and k2.get(to + "|") == "sandbox", "production marks follow: %s" % [k2])
	check(not k2.has("http://127.0.0.1:8088|x") and k2.get("https://team.example|y") == "prod" and k2.get("demo") == "sandbox", "old keys gone, others kept: %s" % [k2])
	var k3 := LocalBridge.rehome_keys({"http://127.0.0.1:8088|x": "sandbox", to + "|x": "prod"}, to)
	check(k3.size() == 1 and k3.get(to + "|x") == "prod", "an existing new key wins: %s" % [k3])


func _pod_categories() -> void:
	var cases := [
		[{"status": "Running", "ready": 2, "total": 2}, "ok"],
		[{"status": "Running", "ready": 1, "total": 2}, "warn"],
		[{"status": "Running"}, "warn"],  # no ready count: not ready
		[{"status": "Running", "ready": 1, "total": 1, "deleting": true}, "term"],
		[{"status": "Terminating"}, "term"],
		[{"status": "CrashLoopBackOff"}, "crash"],
		[{"status": "OOMKilled"}, "crash"],
		[{"status": "Init:CrashLoopBackOff"}, "crash"],
		[{"status": "ImagePullBackOff"}, "pull"],
		[{"status": "Init:ErrImagePull"}, "pull"],
		[{"status": "Completed"}, "done"],
		[{"status": "Evicted"}, "failed"],
		[{"status": "Pending"}, "pending"],
		[{"status": "ContainerCreating"}, "pending"],
		[{}, "pending"],
	]
	for c in cases:
		var got := PodBot.categorize(c[0])
		check(got == c[1], "PodBot.categorize(%s) = %s, want %s" % [c[0], got, c[1]])
	for cat in ["ok", "warn", "pending", "crash", "pull", "done", "failed"]:
		check(PodBot.category_color(cat) != Vox.SLATE, "category %s has its own color" % cat)
	check(PodBot.category_color("term") == Vox.SLATE, "terminating pods are grey")


func _gitops_dock() -> void:
	check(GitOpsDock.what({"tool": "argocd"}) == "Argo CD app", "argo what")
	check(GitOpsDock.what({}) == "Argo CD app", "no tool = Argo CD")
	check(GitOpsDock.what({"tool": "flux"}) == "Flux Kustomization", "flux default kind")
	check(GitOpsDock.what({"tool": "flux", "kind": "HelmRelease"}) == "Flux HelmRelease", "flux helm release")
	check(GitOpsDock.tool_color({"tool": "flux"}) == GitOpsDock.FLUX, "flux color")
	check(GitOpsDock.tool_color({"tool": "argocd"}) == GitOpsDock.ARGO, "argo color")
	check(GitOpsDock.ARGO != GitOpsDock.FLUX, "tools look different")


func _rollouts() -> void:
	check(World.is_rolling({"kind": "Deployment", "desired": 3, "updated": 1}), "1/3 updated is rolling")
	check(World.is_rolling({"kind": "DaemonSet", "desired": 2, "updated": 0}), "daemonset rolling")
	check(not World.is_rolling({"kind": "Deployment", "desired": 3, "updated": 3}), "all updated")
	check(not World.is_rolling({"kind": "Deployment", "desired": 3}), "no updated count: not rolling")
	check(not World.is_rolling({"kind": "StatefulSet", "desired": 0, "updated": 0}), "scaled to zero")
	check(not World.is_rolling({"kind": "Job", "desired": 3, "updated": 0}), "only rollout kinds")
	check(not World.is_rolling({"kind": "Deployment", "desired": 2, "updated": 5}), "more updated than desired (scaling down)")


func _trend_math() -> void:
	var sq := PackedVector2Array([Vector2(0, 0), Vector2(10, 0), Vector2(10, 10), Vector2(0, 10)])
	check(is_equal_approx(TrendChart._area(sq), 100.0), "square area %f" % TrendChart._area(sq))
	sq.reverse()
	check(is_equal_approx(TrendChart._area(sq), -100.0), "clockwise area is negative")
	var flat := PackedVector2Array([Vector2(0, 5), Vector2(5, 5), Vector2(10, 5), Vector2(10, 5), Vector2(0, 5)])
	check(absf(TrendChart._area(flat)) <= 1.0, "a flat line has no area (no fill)")
	check(TrendChart._area(PackedVector2Array()) == 0.0, "empty polygon")
	check(TrendChart.fmt(0.25, "cores") == "250m", "cores " + TrendChart.fmt(0.25, "cores"))
	check(TrendChart.fmt(1.5, "cores") == "1.5", "cores " + TrendChart.fmt(1.5, "cores"))
	check(TrendChart.fmt(512.0 * 1048576.0, "bytes") == "512 MiB", "MiB")
	check(TrendChart.fmt(3.0 * 1073741824.0, "bytes") == "3.0 GiB", "GiB")
	check(TrendChart.fmt(7.9, "count") == "7", "count")
	check(TrendChart._mins(5) == "5 min" and TrendChart._mins(180) == "3 h", "minutes / hours")
	check(TrendChart.change_since([[0, 1.0], [60, 1.0], [120, 5.0]], "bytes") == 0.0, "too few points")
	var down := []
	for i in 10:
		down.append([i * 60.0, 10.0 - i])
	check(TrendChart.change_since(down, "bytes") == 0.0, "going down is not 'up since'")
	check(TrendChart.change_since(down, "count") == 0.0, "restarts never go down")


## A chart with flat-zero, NaN / Inf and single-point series must draw
## without script errors (make test-game fails on any SCRIPT ERROR). The
## headless renderer doesn't triangulate, so the "no fill for a flat line"
## guard is checked through _area above.
func _trend_draw() -> void:
	var chart := ChartProbe.new()
	chart.size = Vector2(320, 300)
	root.add_child(chart)
	var zero := []
	var noisy := []
	var climb := []
	for i in 30:
		zero.append([i * 60.0, 0.0])
		noisy.append([i * 60.0, NAN if i % 3 == 0 else (INF if i % 7 == 0 else float(i))])
		climb.append([i * 60.0, 100.0 if i < 20 else 100.0 + (i - 20) * 50.0])
	chart.set_rows([
		{"label": "cpu", "points": zero, "unit": "cores"},
		{"label": "mem", "points": noisy, "unit": "bytes"},
		{"label": "restarts", "points": [[0.0, NAN], [60.0, 1.0]], "unit": "count"},
		{"label": "leak", "points": climb, "unit": "bytes", "color": Color.RED},
	])
	check(chart.custom_minimum_size.y == 4 * TrendChart.ROW, "one row per series")
	await process_frame
	await process_frame
	check(chart.drew > 0, "the chart drew")
	var drawn := chart.drew
	chart.set_rows([], "no Prometheus")
	check(chart.custom_minimum_size.y == 34.0, "empty chart keeps a line for its message")
	await process_frame
	await process_frame
	check(chart.drew > drawn, "set_rows redraws")
	chart.queue_free()


func _search_kinds() -> void:
	var s := {"helm": [
			{"ns": "monitoring", "name": "kube-prometheus-stack", "chart": "kube-prometheus-stack-65.1.0", "status": "deployed", "revision": 7, "umbrella": true,
				"charts": [{"name": "kube-state-metrics", "version": "5.25.1"}, {"name": "grafana", "version": "8.5.0"}]},
			{"ns": "shop", "name": "redis", "chart": "", "status": "failed", "revision": 2, "charts": [{"name": "redis", "version": "17.3.2"}]}],
		"apps": [{"ns": "flux-system", "name": "apps", "tool": "flux", "kind": "Kustomization", "dest_ns": "", "sync": "Synced", "health": "Healthy"},
			{"ns": "argocd", "name": "payments", "dest_ns": "payments", "sync": "OutOfSync", "health": "Missing"}]}
	var h: Array = ClusterSearch.find(s, "grafana")
	check(h.size() == 1 and h[0].kind == "helm" and h[0].key == "monitoring/kube-prometheus-stack", "a subchart finds its release: %s" % [h])
	if h.size() == 1:
		check(str(h[0].detail).begins_with("umbrella helm release · kube-prometheus-stack-65.1.0 · rev 7"), "umbrella detail: " + str(h[0].detail))
	check(ClusterSearch.find(s, "kind:umbrella").size() == 2, "umbrella is an alias of helm")
	var bad: Array = ClusterSearch.find(s, "bad kind:release")
	check(bad.size() == 1 and bad[0].key == "shop/redis" and str(bad[0].detail).contains("1 charts"), "failed release is bad: %s" % [bad])
	var fx: Array = ClusterSearch.find(s, "kind:flux apps")
	check(fx.size() == 1 and fx[0].ns == "flux-system" and str(fx[0].detail).begins_with("Flux Kustomization"), "flux app with no dest ns: %s" % [fx])
	check(ClusterSearch.find(s, "kind:gitops bad").size() == 1, "a missing app is bad")
	check(ClusterSearch.find(s, "status:outofsync")[0].key == "argocd/payments", "status filter on apps")
	var q := ClusterSearch.parse("ns:shop  roto :x y:")
	check(q.filters == {"ns": "shop"} and q.bad and q.words == [":x", "y:"], "parse: %s" % [q])
	check(ClusterSearch.find({}, "   ").is_empty(), "an empty query finds nothing")
	check(ClusterSearch.find({"pods": null, "nodes": null}, "x").is_empty(), "null lists are empty")


func _updates() -> void:
	check(Updates.parse("v1.2.3+build.5") == ([1, 2, 3, 1] as Array[int]), "build metadata ignored")
	check(Updates.parse("1.2.3-rc.1") == ([1, 2, 3, 0] as Array[int]), "pre-release")
	check(Updates.parse("1.-2.3").is_empty() and Updates.parse(" ").is_empty(), "not versions")
	check(Updates.compare("dev", "1.0.0") == 0, "dev compares equal (no nagging)")
	check(not Updates.should_notify("v0.2.0", [] as Array[String], ""), "nothing behind")
	check(not Updates.should_notify("dev", ["bridge"] as Array[String], ""), "unknown latest")
	check(Updates.hints("nothing").is_empty(), "unknown target")
	check(Updates.hints("bridge").size() == 3 and not str(Updates.hints("bridge")[1].cmd).contains("allow-origin"), "bridge without origin")
	var long := "x".repeat(200)
	var sm := Updates.summary("<!-- hidden -->\n" + long, 8, 20)
	check(sm.length() == 20 and sm.ends_with("..."), "long lines are cut: " + sm)
	check(Updates.summary("a\nb\nc\nd", 2) == "a\nb", "max lines")


## Every tr("...") literal in the scripts that reads like text for people has
## a Spanish entry (I18n.ES or a mission's *_es fields).
func _i18n() -> void:
	# Read from the sources: i18n.gd and missions.gd use the Settings autoload,
	# and autoloads don't exist when Godot runs a --script.
	var lit := "\"((?:[^\"\\\\]|\\\\.)*)\""
	var known := {}
	var in_es := false
	var es_key := RegEx.create_from_string("^\\t" + lit + "\\s*:")
	for l in FileAccess.get_file_as_string("res://scripts/i18n.gd").split("\n"):
		if l.begins_with("const ES := {"):
			in_es = true
		elif in_es and l.begins_with("}"):
			break
		elif in_es:
			var m := es_key.search(l)
			if m:
				known[m.get_string(1).c_unescape()] = true
	var mission := RegEx.create_from_string("\"(?:title|goal|learn)\": " + lit)
	for m in mission.search_all(FileAccess.get_file_as_string("res://scripts/missions.gd")):
		known[m.get_string(1).c_unescape()] = true
	check(known.size() > 1000, "read I18n.ES (%d keys)" % known.size())
	var used := {}  # key -> "file:line" of its first use
	var re := RegEx.create_from_string("\\btr\\(" + lit)
	for path in _scripts("res://scripts"):
		var lines := FileAccess.get_file_as_string(path).split("\n")
		for i in lines.size():
			for m in re.search_all(lines[i]):
				var key := m.get_string(1).c_unescape()
				if not used.has(key):
					used[key] = "%s:%d" % [path.get_file(), i + 1]
	var baseline := {}
	for l in FileAccess.get_file_as_string(I18N_BASELINE).split("\n"):
		if l != "" and not l.begins_with("#"):
			baseline[l.c_unescape()] = true
	var missing := []
	var fixed := 0
	for key in used:
		if known.has(key) or not _reads_like_text(key):
			if baseline.has(key):
				fixed += 1
			continue
		if not baseline.has(key):
			missing.append(key)
			print("FAIL: no Spanish for tr(\"%s\") (%s): add it to I18n.ES" % [key.c_escape(), used[key]])
	fails += missing.size()
	check(used.size() > 100, "found the tr() calls (%d)" % used.size())
	print("i18n: %d tr() keys, %d still untranslated (baseline), %d new missing%s" % [used.size(), baseline.size() - fixed, missing.size(),
		(", %d baseline keys are done: remove them from %s" % [fixed, I18N_BASELINE.get_file()]) if fixed > 0 else ""])


## Text for people: has letters and is more than a symbol, unit or a name
## that reads the same in both languages ("CPU", "%s/%s", "kubectl").
static func _reads_like_text(s: String) -> bool:
	var letters := RegEx.create_from_string("[A-Za-z]{2,}")
	var plain := RegEx.create_from_string("%[-0-9.]*[sd]|\\{[a-z_]*\\}").sub(s, "", true)
	return plain.contains(" ") and letters.search(plain) != null


static func _scripts(dir: String) -> Array:
	var out := []
	for f in DirAccess.get_files_at(dir):
		if f.ends_with(".gd") and f != "i18n.gd":
			out.append(dir.path_join(f))
	for d in DirAccess.get_directories_at(dir):
		out.append_array(_scripts(dir.path_join(d)))
	return out
