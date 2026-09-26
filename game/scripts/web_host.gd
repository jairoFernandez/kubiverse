class_name WebHost
## Where a web build is served from.

## True for localhost and private-network addresses: the hosts a kubiverse-bridge
## serves the web build from.
static func is_local(origin: String) -> bool:
	var host := origin.get_slice("://", 1).get_slice("/", 0)
	if host.begins_with("["):
		host = host.get_slice("]", 0).trim_prefix("[")
	else:
		host = host.get_slice(":", 0)
	if host == "localhost" or host == "::1" or host.ends_with(".local"):
		return true
	var p := host.split(".")
	if p.size() != 4 or not host.replace(".", "").is_valid_int():
		return false
	var a := int(p[0])
	var b := int(p[1])
	return a == 127 or a == 10 or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31)
