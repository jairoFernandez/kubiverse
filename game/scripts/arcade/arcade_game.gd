class_name ArcadeGame
extends RefCounted
## One minigame of the Underground arcade. It draws on the 320×180 pixel
## screen (the Underground sets the transform) and ends with ug.game_over().

var ug: Underground
var score := 0
var t := 0.0


func start() -> void:
	pass


func tick(_delta: float) -> void:
	pass


## A key was pressed (held keys: read them with held()).
func key(_k: int) -> void:
	pass


## A click, in screen pixels of the 320×180 screen.
func click(_p: Vector2) -> void:
	pass


func paint(_v: Control) -> void:
	pass


## The controls, shown at the bottom.
func help() -> String:
	return ""


static func held(keys: Array) -> bool:
	for k in keys:
		if Input.is_physical_key_pressed(k):
			return true
	return false
