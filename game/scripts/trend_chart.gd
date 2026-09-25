class_name TrendChart
extends Control
## Small history charts from Prometheus in the inspector: one row per series
## (CPU, memory, restarts), with "now", the peak and since when it changed.

const ROW := 70.0
const LINE := Color(0.16, 0.68, 1.0)

var font: Font
var rows: Array = []   # {label, points: [[t, v]...], color, unit: cores|bytes|count}
var message := ""


func set_rows(r: Array, msg := "") -> void:
	rows = r
	message = msg
	custom_minimum_size.y = maxf(34.0, rows.size() * ROW)
	queue_redraw()


func _draw() -> void:
	if font == null:
		font = get_theme_default_font()
	if rows.is_empty():
		draw_string(font, Vector2(0, 24), message, HORIZONTAL_ALIGNMENT_LEFT, size.x, 20, Color(0.55, 0.52, 0.66))
		return
	for i in rows.size():
		var r: Dictionary = rows[i]
		var y0 := i * ROW
		var pts: Array = r.points
		var col: Color = r.get("color", LINE)
		var area := Rect2(0, y0 + 30, size.x, ROW - 36)
		draw_rect(area, Color(1, 1, 1, 0.04))
		if pts.size() < 2:
			draw_string(font, Vector2(0, y0 + 22), "%s  %s" % [r.label, tr("no data")], HORIZONTAL_ALIGNMENT_LEFT, size.x, 20, Color(0.55, 0.52, 0.66))
			continue
		var lo := INF
		var hi := -INF
		for p in pts:
			lo = minf(lo, float(p[1]))
			hi = maxf(hi, float(p[1]))
		var peak := hi
		var base := 0.0 if r.unit != "count" else lo
		if hi - base < 1e-9:
			hi = base + 1.0
		var t0 := float(pts[0][0])
		var t1 := float(pts[pts.size() - 1][0])
		var line := PackedVector2Array()
		for p in pts:
			var x := area.position.x + (float(p[0]) - t0) / maxf(t1 - t0, 1.0) * area.size.x
			var y := area.end.y - (float(p[1]) - base) / (hi - base) * area.size.y
			line.append(Vector2(x, y))
		var fill := line.duplicate()
		fill.append(Vector2(area.end.x, area.end.y))
		fill.append(Vector2(area.position.x, area.end.y))
		draw_colored_polygon(fill, Color(col, 0.18))
		draw_polyline(line, col, 2.0)
		var now_v := float(pts[pts.size() - 1][1])
		var txt := "%s  %s  (%s %s)" % [r.label, fmt(now_v, r.unit), tr("peak"), fmt(peak, r.unit)]
		var since := change_since(pts, r.unit)
		if since > 0.0:
			var mins := int((t1 - since) / 60.0)
			var mark := area.position.x + (since - t0) / maxf(t1 - t0, 1.0) * area.size.x
			draw_line(Vector2(mark, area.position.y), Vector2(mark, area.end.y), Color(1, 0.93, 0.15, 0.8), 1.0)
			txt += "   " + (tr("restarting for %s") if r.unit == "count" else tr("up since %s ago")) % _mins(mins)
		draw_string(font, Vector2(0, y0 + 22), txt, HORIZONTAL_ALIGNMENT_LEFT, size.x, 20, Color(0.85, 0.85, 0.9))


static func _mins(m: int) -> String:
	return "%d min" % m if m < 120 else "%d h" % int(m / 60.0)


static func fmt(v: float, unit: String) -> String:
	# (same format as StatsPanel, without depending on it: the tests load this)
	match unit:
		"cores":
			var m := v * 1000.0
			return "%dm" % roundi(m) if m < 1000 else "%.1f" % (m / 1000.0)
		"bytes":
			if v >= 1073741824.0:
				return "%.1f GiB" % (v / 1073741824.0)
			return "%d MiB" % roundi(v / 1048576.0)
	return str(int(v))


## When the series changed and stayed changed: restarts that started going up,
## or a value that rose above the middle of its range and never came back.
## 0 when nothing like that happened.
static func change_since(pts: Array, unit: String) -> float:
	if pts.size() < 4:
		return 0.0
	var first := float(pts[0][1])
	var last := float(pts[pts.size() - 1][1])
	if unit == "count":
		if last <= first:
			return 0.0
		for p in pts:
			if float(p[1]) > first:
				return float(p[0])
		return 0.0
	var lo := INF
	var hi := -INF
	for p in pts:
		lo = minf(lo, float(p[1]))
		hi = maxf(hi, float(p[1]))
	# only a real change: the end is well above the start
	if hi <= 0.0 or last < first * 1.5 or last - first < (hi - lo) * 0.5:
		return 0.0
	var mid := lo + (hi - lo) * 0.5
	var since := 0.0
	for p in pts:
		if float(p[1]) >= mid:
			if since == 0.0:
				since = float(p[0])
		else:
			since = 0.0
	return since
