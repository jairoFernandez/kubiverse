class_name KubeconfigInput
extends RefCounted
## What the player puts in the kubeconfig box: the YAML itself, or (a common
## first try) the path of the file: "~/.kube/config", a path copied from
## Finder, a file dropped on the window. The bridge only takes the content,
## so on native builds a path is read here first; when it can't be read the
## player is told why in words (not the bridge's YAML parse error).


## The file path the text names, expanded ("" when it's not a path).
## Takes ~, quotes, file:// URLs and the shell's "\ " for spaces.
static func path_in(text: String, home := "") -> String:
	var t := text.strip_edges()
	if t == "" or "\n" in t:
		return ""
	if t.length() >= 2 and t[0] == t[t.length() - 1] and t[0] in ["\"", "'"]:
		t = t.substr(1, t.length() - 2)
	if t.begins_with("file://"):
		t = t.substr(7).uri_decode()
	t = t.replace("\\ ", " ")
	if t == "~" or t.begins_with("~/") or t.begins_with("~\\"):
		if home == "":
			home = OS.get_environment("HOME") if OS.get_environment("HOME") != "" else OS.get_environment("USERPROFILE")
		t = home.path_join(t.substr(2)) if t.length() > 1 else home
	var win_drive := t.length() > 2 and t[1] == ":" and t[2] in ["\\", "/"]
	if not (t.begins_with("/") or win_drive):
		return ""
	if ": " in t or t.begins_with("apiVersion"):
		return ""   # a line of YAML, not a path
	return t


## Reads a kubeconfig file. {text} or {error} (already in words, translated).
static func read(path: String) -> Dictionary:
	if DirAccess.dir_exists_absolute(path):
		return {"error": I18n.t("%s is a folder: pick the kubeconfig file inside it (usually config).") % path}
	if not FileAccess.file_exists(path):
		return {"error": I18n.t("There is no file at %s.") % path}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		var why := FileAccess.get_open_error()
		if OS.get_name() == "macOS" and why in [ERR_FILE_NO_PERMISSION, ERR_FILE_CANT_OPEN, ERR_FILE_CANT_READ]:
			return {"error": I18n.t("macOS didn't let Kubiverse read %s. Allow it in System Settings > Privacy & Security > Files and Folders (or Full Disk Access), or paste the file's content here.") % path}
		return {"error": I18n.t("Could not read %s (%s). Paste the file's content here instead.") % [path, error_string(why)]}
	var text := f.get_as_text()
	if text.strip_edges() == "":
		return {"error": I18n.t("%s is empty.") % path}
	return {"text": text}


## A name for the cluster from its file ("prod eu.yaml" -> "prod-eu"),
## with only what the bridge takes in a file name (letters, digits, . _ -).
static func name_for(path: String) -> String:
	var n := ""
	for ch in path.get_file().get_basename():
		n += ch if (ch >= "a" and ch <= "z") or (ch >= "A" and ch <= "Z") or (ch >= "0" and ch <= "9") or ch in [".", "_", "-"] else "-"
	n = n.lstrip("._-").left(63)
	return n if n != "" else "kubeconfig"
