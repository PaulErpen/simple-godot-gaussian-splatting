extends Node3D

@export var color: Color = Color(0, 0, 0)
@onready var mesh = $MeshInstance3D

# Called when the node enters the scene tree for the first time.
func _ready():
	mesh.mesh.material.set_shader_parameter("color", color)

# Called every frame. 'delta' is the elapsed time since the previous frame.
func _process(delta):
	mesh.mesh.material.set_shader_parameter("color", color)
