class_name StartupBar
extends PanelContainer
## Inside a pod: where its start-up time went, as one stacked bar.
## Scheduling (waiting for a node), init containers, the image pull,
## creating the containers, and the app booting until its readiness probe
## says yes. Under it, one tip about the biggest piece (from the bridge's
## /api/pod "startup": see bridge/startup.go).

const COLORS := {"sched": Color("7fb2ff"), "init": Color("b48cff"), "pull": Color("ff9e4a"),
	"create": Color("ffd54a"), "app": Color("6dff6d")}

var st: Dictionary = {}
var _bar: Control
var _title: Label
var _tip: Label


## [[key, seconds]] in order, only the phases that can be measured.
static func phases(s: Dictionary) -> Array:
	var sched := float(s.get("scheduled", -1))
	var init := float(s.get("initialized", -1))
	var started := float(s.get("started", -1))
	var ready := float(s.get("ready", -1))
	var pull := float(s.get("pull", -1))
	var out := []
	if sched < 0:
		return out
	out.append(["sched", sched])
	if init < 0:
		return out
	if init - sched > 0.05:
		out.append(["init", init - sched])
	if started < 0:
		return out
	var boot := maxf(0.0, started - maxf(init, sched))
	if pull >= 0.0:
		out.append(["pull", minf(pull, boot)])
		out.append(["create", maxf(0.0, boot - pull)])
	else:
		out.append(["create", boot])   # image + create: no Pulled events left to split them
	if ready >= started:
		out.append(["app", ready - started])
	return out


static func label_of(key: String, pull_known := true) -> String:
	match key:
		"sched": return I18n.t("scheduling")
		"init": return I18n.t("init containers")
		"pull": return I18n.t("image pull")
		"create": return I18n.t("create + start") if pull_known else I18n.t("image + start")
		"app": return I18n.t("app + readiness")
	return key


## The one thing to try first, about the biggest piece of the start-up.
static func tip(s: Dictionary) -> String:
	var ph := phases(s)
	if ph.is_empty():
		return I18n.t("Not scheduled yet: no node has room for it (see the pod's events).")
	var big: Array = ph[0]
	for p in ph:
		if p[1] > big[1]:
			big = p
	var secs: float = big[1]
	var restarted := I18n.t(" (times from its last restart)") if s.get("restarted", false) else ""
	if float(s.get("ready", -1)) < 0.0:
		if float(s.get("started", -1)) >= 0.0:
			return I18n.t("Running but not Ready: its readiness probe doesn't pass yet (check that endpoint and the app's logs).") + restarted
		return I18n.t("Still starting: the containers are not running yet (see the pod's events).") + restarted
	if secs < 3.0:
		return I18n.t("Fast start: nothing to fix here.") + restarted
	match big[0]:
		"sched":
			return I18n.t("%ds waiting for a node: the cluster is full or the requests are big. Room on the nodes (autoscaler, Karpenter) or smaller requests.") % int(secs) + restarted
		"init":
			return I18n.t("Init containers took %ds: move waits and migrations out (a Job before the rollout).") % int(secs) + restarted
		"pull":
			var mb := int(s.get("pull_bytes", 0)) / 1000000
			var size := (I18n.t(" for %d MB") % mb) if mb > 0 else ""
			return I18n.t("Pulling the image took %ds%s: a smaller image (multi-stage, distroless), a pinned tag with IfNotPresent, or pre-pull it on the nodes.") % [int(secs), size] + restarted
		"create":
			return I18n.t("%ds creating the containers (image included when it isn't known): check volumes being mounted and the image size.") % int(secs) + restarted
		"app":
			var delay := int(s.get("ready_delay", 0))
			var period := int(s.get("ready_period", 0))
			var cpu := int(s.get("cpu_limit_m", 0))
			if delay >= 5 and secs >= delay * 0.8 and not s.get("startup_probe", false):
				return I18n.t("The readiness probe waits initialDelaySeconds: %d. A startupProbe with periodSeconds: 1 lets it pass as soon as the app is up.") % delay + restarted
			if period >= 10:
				return I18n.t("Readiness checks every %ds: the pod may sit ready but unchecked. periodSeconds: 2 sends traffic sooner.") % period + restarted
			if cpu > 0 and cpu <= 500:
				return I18n.t("The app took %ds to boot with a CPU limit of %dm: booting is the CPU peak, a higher limit (or none) helps.") % [int(secs), cpu] + restarted
			return I18n.t("The app itself took %ds to be ready: lazy init, migrations out of the boot, warm caches in the background.") % int(secs) + restarted
	return ""


func _init() -> void:
	visible = false
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 6)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(v)
	_title = Label.new()
	_title.add_theme_font_size_override("font_size", 18)
	_title.add_theme_color_override("font_color", Vox.LAVENDER)
	_title.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	v.add_child(_title)
	_bar = Control.new()
	_bar.custom_minimum_size = Vector2(0, 46)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_bar.draw.connect(_draw_bar)
	v.add_child(_bar)
	_tip = Label.new()
	_tip.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip.custom_minimum_size = Vector2(580, 0)   # wraps inside the panel instead of widening it
	_tip.add_theme_font_size_override("font_size", 15)
	_tip.add_theme_color_override("font_color", Vox.YELLOW)
	_tip.auto_translate_mode = Node.AUTO_TRANSLATE_MODE_DISABLED
	v.add_child(_tip)


## The pod's "startup" from /api/pod; empty hides the bar.
func show_startup(s) -> void:
	st = s if s is Dictionary else {}
	visible = not st.is_empty()
	if not visible:
		return
	var ready := float(st.get("ready", -1))
	_title.text = (I18n.t("STARTUP  %.1fs to Ready") % ready) if ready >= 0 else I18n.t("STARTUP  still starting...")
	_tip.text = tip(st)
	_bar.queue_redraw()


func _draw_bar() -> void:
	var ph := phases(st)
	var total := 0.0
	for p in ph:
		total += p[1]
	var w := _bar.size.x
	var font := get_theme_default_font()
	_bar.draw_rect(Rect2(0, 0, w, 22), Color(1, 1, 1, 0.08))
	if total <= 0.0:
		return
	var x := 0.0
	var pull_known := float(st.get("pull", -1)) >= 0.0
	for p in ph:
		var pw: float = w * p[1] / total
		var col: Color = COLORS.get(p[0], Vox.SILVER)
		_bar.draw_rect(Rect2(x, 0, maxf(pw, 2.0), 22), col)
		if pw > 34:
			_bar.draw_string(font, Vector2(x + 4, 16), "%.1fs" % p[1], HORIZONTAL_ALIGNMENT_LEFT, pw - 6, 13, Color(0, 0, 0, 0.85))
		if pw > 70:
			_bar.draw_string(font, Vector2(x + 2, 40), label_of(p[0], pull_known), HORIZONTAL_ALIGNMENT_LEFT, pw - 4, 13, col)
		x += pw
