extends "res://tests/harness.gd"
## Headless checks that a party guest's game only asks the bridge for the
## routes a guest may use (guestRoutes in bridge/party.go): no GitHub, no
## assistant, no cluster kind, no audit log... The bridge refuses those, so
## asking is only noise (and errors) in the guest's output.
##   godot --headless --path game --script res://tests/test_guest_client.gd


var Spy: GDScript  # tests/guest_spy.gd, loaded once the autoloads exist


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # k8s_client.gd uses autoloads (Settings): load it once they exist
	Spy = load("res://tests/guest_spy.gd")
	_routes()
	await _guest_from_whoami()
	await _state_before_whoami()
	await _party_guest_before_whoami()
	await _host_asks_everything()
	finish("guest client tests")


func _spy(who: Dictionary) -> Node:
	var s = Spy.new()
	s.mode = s.Mode.BRIDGE
	s.base_url = "http://127.0.0.1:9"
	s.token = "abcdefghjk"
	s.context = "test"
	s.whoami = who
	return s


## Every request a guest sends is one the bridge lets a guest make.
func _only_guest_routes(s: Node, what: String) -> void:
	for r in s.sent:
		var parts: PackedStringArray = r.split(" ")
		check(parts[0] == "GET" and parts[1] in s.GUEST_ROUTES, "%s: a guest asked for %s" % [what, r])


## Frees a spy once what it answers deferred has been answered.
func _free_later(s: Node) -> void:
	await process_frame
	s.free()


func _asked(s: Node, prefix: String) -> bool:
	return s.sent.any(func(r: String): return r.begins_with(prefix))


func _routes() -> void:
	var K: GDScript = load("res://scripts/k8s_client.gd")
	check(K.guest_may(HTTPClient.METHOD_GET, "/api/obs?context=test&token=x"), "GET /api/obs with a query: allowed")
	check(K.guest_may(HTTPClient.METHOD_GET, "/api/whoami"), "GET /api/whoami: allowed")
	check(not K.guest_may(HTTPClient.METHOD_POST, "/api/whoami"), "POST is never a guest's")
	for path in ["/api/github", "/api/assistant", "/api/kind", "/api/audit", "/api/kubectl", "/api/charts", "/api/manifest", "/api/party/invite"]:
		check(not K.guest_may(HTTPClient.METHOD_GET, path), "%s is not a guest's route" % path)


## Joined with an invitation code: the bridge says guest in /api/whoami, and
## from then on nothing but the read-only routes is asked for.
func _guest_from_whoami() -> void:
	var s = _spy({"guest": true, "guest_context": "test"})
	s._who_am_i()
	check(s.is_guest_conn() and s.guest, "whoami guest: true makes the connection a guest's")
	check(_asked(s, "GET /api/whoami") and _asked(s, "GET /api/obs"), "a guest still asks who it is and what observability there is: %s" % [s.sent])
	check(not _asked(s, "GET /api/github"), "a guest doesn't ask for GitHub: %s" % [s.sent])
	s._on_state({"context": "test"})
	check(not _asked(s, "GET /api/kind") and not _asked(s, "POST /api/kind"), "a guest doesn't ask for the cluster kind: %s" % [s.sent])
	# What the HUD and panels ask for later is refused in the game too.
	var refused := []
	s.github_status()
	s.audit(func(ok, msg): refused.append([ok, msg]))
	s._post_kind("sandbox")
	s.assistant_status(func(st: Dictionary): refused.append([false, st.get("why", "")]))
	s.run_kubectl("get pods", func(ok, msg): refused.append([ok, msg]))
	s.charts("default", "web", func(ok, _d): refused.append([ok, ""]))
	s.can_i("default", func(_ok, _d): pass)   # /api/cani: a guest's route
	_only_guest_routes(s, "after joining")
	check(_asked(s, "GET /api/cani"), "a guest's own routes still go out")
	await process_frame  # the refusals answer deferred, like a request would
	check(refused.size() == 4 and refused.all(func(r): return r[0] == false), "the refused calls answer not-ok: %s" % [refused])
	check(str(refused[0][1]).contains("guests"), "and say why: %s" % [refused[0]])
	# Leaving the party doesn't make the code a host's token.
	s.guest = false
	s.github_status()
	_only_guest_routes(s, "after leaving the party")
	await _free_later(s)


## The state can arrive before /api/whoami answers: the kind waits for it.
func _state_before_whoami() -> void:
	var s = _spy({"guest": true})
	s.hold = true
	s._who_am_i()
	s._on_state({"context": "test"})
	check(s.sent == ["GET /api/whoami"], "nothing but whoami before the bridge says who we are: %s" % [s.sent])
	s.release()
	check(not _asked(s, "GET /api/kind") and not _asked(s, "GET /api/github"), "whoami late, still no host routes: %s" % [s.sent])
	_only_guest_routes(s, "whoami after the state")
	await _free_later(s)


## The relay said guest (welcome) before whoami was asked: also read-only.
func _party_guest_before_whoami() -> void:
	var s = _spy({})
	s.guest = true
	s.github_status()
	s._post_kind("prod")
	check(s.sent.is_empty(), "a party guest's game sends nothing it would be refused: %s" % [s.sent])
	await _free_later(s)


## The host (whoami without guest) still asks for everything: the checks
## above aren't true just because nothing is ever sent.
func _host_asks_everything() -> void:
	var s = _spy({"guest": false})
	s._who_am_i()
	s._on_state({"context": "test"})
	check(not s.is_guest_conn(), "whoami without guest: the host")
	check(_asked(s, "GET /api/github") and _asked(s, "GET /api/obs"), "the host asks for GitHub and observability: %s" % [s.sent])
	check(_asked(s, "GET /api/kind"), "the host asks for the cluster kind: %s" % [s.sent])
	await _free_later(s)
