extends "res://tests/harness.gd"
## Headless checks of the kubeconfig box taking a file path, not only YAML:
##   godot --headless --path game --script res://tests/test_kubeconfig_input.gd

const DIR := "user://kubeconfig-input-test"


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame  # kubeconfig_input.gd uses autoloads: load it once they exist
	var KI: GDScript = load("res://scripts/kubeconfig_input.gd")
	_paths(KI)
	_reads(KI)
	_names(KI)
	finish("kubeconfig input tests")


## What counts as a path, and how it is expanded.
func _paths(KI: GDScript) -> void:
	check(KI.path_in("/Users/ana/.kube/config") == "/Users/ana/.kube/config", "an absolute path")
	check(KI.path_in("~/.kube/config", "/Users/ana") == "/Users/ana/.kube/config", "~ expands to the home folder")
	check(KI.path_in("'/Users/ana/My Clusters/prod.yaml'") == "/Users/ana/My Clusters/prod.yaml", "quotes around a path")
	check(KI.path_in("\"/Users/ana/x.yaml\"") == "/Users/ana/x.yaml", "double quotes too")
	check(KI.path_in("/Users/ana/My\\ Clusters/prod.yaml") == "/Users/ana/My Clusters/prod.yaml", "the shell's escaped spaces")
	check(KI.path_in("file:///Users/ana/My%20Clusters/prod.yaml") == "/Users/ana/My Clusters/prod.yaml", "a file:// URL")
	check(KI.path_in("C:\\Users\\ana\\.kube\\config") == "C:\\Users\\ana\\.kube\\config", "a Windows path")
	check(KI.path_in("apiVersion: v1\nkind: Config\nclusters: []") == "", "YAML is not a path")
	check(KI.path_in("apiVersion: v1") == "", "one line of YAML is not a path")
	check(KI.path_in("") == "" and KI.path_in("prod-eu") == "", "empty or a bare word is not a path")


## Reading the file, and saying in words why it can't be read.
func _reads(KI: GDScript) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(DIR))
	var file := ProjectSettings.globalize_path(DIR.path_join("prod.yaml"))
	var f := FileAccess.open(file, FileAccess.WRITE)
	f.store_string("apiVersion: v1\nkind: Config\n")
	f.close()
	var got: Dictionary = KI.read(file)
	check(got.get("text", "").begins_with("apiVersion: v1"), "an existing file is read")
	got = KI.read(file + ".missing")
	check(got.has("error") and str(got.error).contains("no file"), "a missing file is said so: %s" % got)
	got = KI.read(ProjectSettings.globalize_path(DIR))
	check(got.has("error") and str(got.error).contains("folder"), "a folder is said so")
	var empty := ProjectSettings.globalize_path(DIR.path_join("empty.yaml"))
	FileAccess.open(empty, FileAccess.WRITE).close()
	got = KI.read(empty)
	check(got.has("error") and str(got.error).contains("empty"), "an empty file is said so")
	DirAccess.remove_absolute(file)
	DirAccess.remove_absolute(empty)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(DIR))


## The cluster's name comes from the file, in what the bridge accepts.
func _names(KI: GDScript) -> void:
	check(KI.name_for("/a/prod-eu.yaml") == "prod-eu", "the file name without .yaml")
	check(KI.name_for("/a/My Cluster (old).yml") == "My-Cluster--old-", "spaces and brackets become -")
	check(KI.name_for("/a/.hidden.yaml") == "hidden", "no leading dot")
	check(KI.name_for("/Users/ana/.kube/config") == "config", "~/.kube/config is config")
	check(KI.name_for("/a/@@@.yaml") == "kubeconfig", "nothing usable left: kubeconfig")
