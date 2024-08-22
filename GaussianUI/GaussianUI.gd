extends Control

var show_depth: bool = false
var show_aabb: bool = false
var scale_modifier = 1.0
@export var targets: Array[Node3D]

@onready var aabb_checkbox = $PanelContainer/VBoxContainer/AABB
@onready var depth_checkbox = $PanelContainer/VBoxContainer/Depth
@onready var fps_label = $PanelContainer/VBoxContainer/FPSLabel
@onready var modifier_label = $PanelContainer/VBoxContainer/ModifierLabel

func _process(delta):
	fps_label.text = "FPS: %d" % Engine.get_frames_per_second()
	modifier_label.text = "Scale modifier: %4.2f" % scale_modifier
	
func _input(event):
	if targets != null and event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			scale_modifier -= 0.025
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			scale_modifier += 0.025
		if event.button_index == MOUSE_BUTTON_WHEEL_DOWN or event.button_index == MOUSE_BUTTON_WHEEL_UP:
			for target in targets:
				target.get_node("MultiMeshInstance3D").multimesh.mesh.material.set_shader_parameter("modifier", scale_modifier)

func _on_aabb_toggled(toggled_on):
	if targets != null:
		for target in targets:
			target.get_node("AABB").set_visible(toggled_on)
	aabb_checkbox.release_focus()

func _on_depth_toggled(toggled_on):
	if targets != null:
		for target in targets:
			target.get_node("MultiMeshInstance3D").multimesh.mesh.material.set_shader_parameter("shade_depth_texture", toggled_on)
	depth_checkbox.release_focus()

func _on_trigger_sort_button_pressed():
	if targets != null:
		for target in targets:
			target.call_sort()
