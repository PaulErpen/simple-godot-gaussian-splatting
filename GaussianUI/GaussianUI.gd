extends Control

var show_depth: bool = false
var show_aabb: bool = false
@export var targets: Array[Node3D]

@onready var aabb_checkbox = $PanelContainer/VBoxContainer/AABB
@onready var depth_checkbox = $PanelContainer/VBoxContainer/Depth

func _on_aabb_toggled(toggled_on):
	if targets != null:
		for target in targets:
			target.volume.mesh.material.set_shader_parameter("show_aabb", toggled_on)
	aabb_checkbox.release_focus()

func _on_depth_toggled(toggled_on):
	if targets != null:
		for target in targets:
			target.shade_depth_texture = toggled_on
	depth_checkbox.release_focus()

func _on_trigger_sort_button_pressed():
	if targets != null:
		for target in targets:
			target.sort()
