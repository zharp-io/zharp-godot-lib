## Picks the scenario from `-- --mode=<name>` and moves on to the checkout scene.
extends Node


func _ready() -> void:
	Zharp.set_user("player-42", "ada@example.com", "Ada")
	get_tree().change_scene_to_file.call_deferred("res://level.tscn")
