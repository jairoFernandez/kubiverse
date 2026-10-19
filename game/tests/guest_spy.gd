extends "res://scripts/k8s_client.gd"
## For tests/test_guest_client.gd: the real client with the network replaced: records what would be sent
## and answers like a bridge would.
var sent: Array = []        # "GET /api/whoami", ...
var whoami := {}            # what /api/whoami answers
var held: Array = []        # /api/whoami callbacks not answered yet (hold = true)
var hold := false


func _send(_url: String, _tok: String, method: int, path: String, _body: String, cb: Callable, _timeout: float) -> void:
	var m: String = {HTTPClient.METHOD_GET: "GET", HTTPClient.METHOD_POST: "POST", HTTPClient.METHOD_DELETE: "DELETE"}.get(method, "?")
	sent.append(m + " " + path.get_slice("?", 0))
	if path.begins_with("/api/whoami"):
		if hold:
			held.append(cb)
		else:
			cb.call(true, whoami)
		return
	cb.call(true, {"ok": true})


func release() -> void:
	for cb in held:
		cb.call(true, whoami)
	held.clear()
