class_name Entity
extends Node3D
## Base for every cluster object that lives in the world.

var kind := ""        # node | pod | service | workload
var key := ""         # unique id, e.g. "ns/name"
var data: Dictionary = {}
var target := Vector3.ZERO
var world: Node       # World, for fx


func label_text() -> String:
	return data.get("name", key)


## Second, smaller line under the label (what the thing *is* / its state).
func label_sub() -> String:
	return ""


func label_color() -> Color:
	return Vox.WHITE


## World-space point used for screen picking and labels.
func anchor() -> Vector3:
	return global_position + Vector3(0, 1.2, 0)


## Big objects (islands, buildings) are picked by the ground under the mouse.
func is_area() -> bool:
	return false


func contains_xz(_p: Vector3) -> bool:
	return false


func pick_radius() -> float:
	return 22.0
