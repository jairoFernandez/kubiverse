class_name Updates
## Is there a newer Kubiverse release, and how does this player get it?
## Pure helpers (no autoloads, no nodes): tests/test_world.gd checks them.

const LATEST_API := "https://api.github.com/repos/jairoFernandez/kubiverse/releases/latest"
const RELEASES := "https://github.com/jairoFernandez/kubiverse/releases/latest"
const GET_BRIDGE := "https://raw.githubusercontent.com/jairoFernandez/kubiverse/main/bridge/get-bridge"
const CHECK_EVERY := 6.0 * 3600.0
## Bridges without GET /api/version (404) are this release or older.
const LEGACY_BRIDGE := "0.1.7"
## Where the running game comes from: native builds, or the web build served
## by a bridge (it comes inside it) or by a public static host (always latest).
const NATIVE := ["macos", "windows", "linux"]


## [major, minor, patch, 1 = release / 0 = pre-release], or [] when v is not
## a version ("dev", "", "1.2", "1.x.3"). A leading v and +build are ignored.
static func parse(v: String) -> Array[int]:
	var out: Array[int] = []
	var s := v.strip_edges().trim_prefix("v").trim_prefix("V").get_slice("+", 0)
	var pre := s.contains("-")
	var p := s.get_slice("-", 0).split(".")
	if p.size() != 3:
		return out
	for x in p:
		if not x.is_valid_int() or x.begins_with("+") or x.begins_with("-"):
			out.clear()
			return out
		out.append(int(x))
	out.append(0 if pre else 1)
	return out


## A real release version: semver and not 0.0.0 (dev builds don't nag).
static func is_known(v: String) -> bool:
	var p := parse(v)
	return p.size() == 4 and (p[0] > 0 or p[1] > 0 or p[2] > 0)


## -1, 0 or 1 like a <=> b (0 as well when either is not a version).
static func compare(a: String, b: String) -> int:
	var pa := parse(a)
	var pb := parse(b)
	if pa.is_empty() or pb.is_empty():
		return 0
	for i in 4:
		if pa[i] != pb[i]:
			return 1 if pa[i] > pb[i] else -1
	return 0


static func is_newer(latest: String, current: String) -> bool:
	return is_known(latest) and is_known(current) and compare(latest, current) > 0


## What is behind `latest`: the native app itself ("macos" / "windows" /
## "linux") and / or "bridge". The web build is updated with the bridge that
## serves it ("web_bridge") or is always the latest ("web_pages").
static func targets(platform: String, app_version: String, bridge_version: String, latest: String) -> Array[String]:
	var out: Array[String] = []
	if platform in NATIVE and is_newer(latest, app_version):
		out.append(platform)
	if is_newer(latest, bridge_version):
		out.append("bridge")
	return out


## Tell the player unless they skipped this version (or a newer one).
static func should_notify(latest: String, targets_behind: Array[String], skipped: String) -> bool:
	if targets_behind.is_empty() or not is_known(latest):
		return false
	return not is_known(skipped) or compare(latest, skipped) > 0


## How to update one target: [{label, cmd}] to copy, or [{label, url}] to open.
## allow_origin: the web page's origin when a bridge must trust it (Pages).
static func hints(target: String, allow_origin := "") -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	match target:
		"macos":
			out.append({"label": "Homebrew", "cmd": "brew upgrade --cask jairofernandez/kubiverse/kubiverse"})
			out.append({"label": "Download kubiverse-macos.zip", "url": RELEASES})
		"windows":
			out.append({"label": "Download kubiverse-windows-x86_64.zip", "url": RELEASES})
		"linux":
			out.append({"label": "Download kubiverse-linux-x86_64.tar.gz", "url": RELEASES})
		"bridge":
			var args := " --allow-origin " + allow_origin if allow_origin != "" else ""
			out.append({"label": "Homebrew", "cmd": "brew upgrade jairofernandez/kubiverse/kubiverse-bridge"})
			out.append({"label": "macOS / Linux", "cmd": "curl -fsSL %s.sh | sh -s --%s" % [GET_BRIDGE, args]})
			out.append({"label": "Windows (PowerShell)", "cmd": "& ([scriptblock]::Create((irm %s.ps1)))%s" % [GET_BRIDGE, args]})
	return out


## The first lines of the release notes as plain text (no Markdown marks,
## links reduced to their text, blank lines dropped, long lines cut).
static func summary(body: String, max_lines := 8, max_len := 110) -> String:
	var link := RegEx.create_from_string("\\[([^\\]]*)\\]\\([^)]*\\)")
	var lines: PackedStringArray = []
	for raw in body.replace("\r", "").split("\n"):
		var l := raw.strip_edges()
		l = l.lstrip("#").strip_edges()
		l = link.sub(l, "$1", true)
		l = l.replace("**", "").replace("__", "").replace("`", "")
		if l.begins_with("* "):
			l = "- " + l.substr(2)
		if l == "" or l.begins_with("<!--"):
			continue
		if l.length() > max_len:
			l = l.left(max_len - 3).strip_edges() + "..."
		lines.append(l)
		if lines.size() >= max_lines:
			break
	return "\n".join(lines)
