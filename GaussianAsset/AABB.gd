extends MeshInstance3D

@onready var multi_mesh_instance: MultiMeshInstance3D = get_parent().get_node("MultiMeshInstance3D")

func _process(_delta):
	var aabb = multi_mesh_instance.custom_aabb
	transform = Transform3D()
	transform = transform.scaled(aabb.size)
	transform = transform.translated(aabb.get_center())
