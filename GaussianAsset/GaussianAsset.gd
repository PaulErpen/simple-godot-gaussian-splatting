extends Node3D

@export var ply_path: String

@onready var multi_mesh_instance = $MultiMeshInstance3D
@onready var main_camera = get_viewport().get_camera_3d()

var n_splats: int = 0
var property_indices = Dictionary()
var data_texture: ImageTexture 
var n_texture_properties: int = 3

func _ready():
	if ply_path != null:
		load_header(ply_path)
		load_gaussians(ply_path)

func load_header(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var properties = []
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("element vertex"):
			n_splats = int(current_line.split(" ")[2])
			print("Number of splats: ", n_splats)
		if current_line.begins_with("property float"):
			properties.append(current_line.split(" ")[2])
		if current_line.begins_with("end_header"):
			break

		current_line = ply_file.get_line()
		
	ply_file.close()

	for i in range(properties.size()):
		property_indices[properties[i]] = i

func load_gaussians(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("end_header"):
			break
		current_line = ply_file.get_line()
	
	var vertices_float: PackedFloat32Array =  ply_file.get_buffer(n_splats * len(property_indices) * 4).to_float32_array()

	var multi_mesh = multi_mesh_instance.multimesh
	multi_mesh.instance_count = n_splats
	
	for i in range(n_splats):
		var idx = i * len(property_indices)
		var mu = Vector3(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]]
		)
		var color = Color(
			clamp(vertices_float[idx + property_indices["f_dc_0"]], 0.0, 1.0),
			clamp(vertices_float[idx + property_indices["f_dc_1"]], 0.0, 1.0),
			clamp(vertices_float[idx + property_indices["f_dc_2"]], 0.0, 1.0),
			clamp(vertices_float[idx + property_indices["opacity"]], 0.0, 1.0),
		)
		var scale = Vector3(
			vertices_float[idx + property_indices["scale_0"]],
			vertices_float[idx + property_indices["scale_1"]],
			vertices_float[idx + property_indices["scale_2"]]
		)
		
		var gaussianTransform = Transform3D()
		
		gaussianTransform.basis = gaussianTransform.basis.scaled(scale * 0.001)
		
		gaussianTransform.basis = gaussianTransform.basis.rotated(
			Vector3(
				vertices_float[idx + property_indices["rot_0"]],
				vertices_float[idx + property_indices["rot_1"]],
				vertices_float[idx + property_indices["rot_2"]]
			).normalized(),
			vertices_float[idx + property_indices["rot_3"]]
		)
		
		gaussianTransform.origin = mu
		
		multi_mesh.set_instance_transform(i, gaussianTransform)
		multi_mesh.set_instance_color(i, color)
		multi_mesh.set_instance_custom_data(i, color)
		
		if i > 30:
			break
		
	#multi_mesh.visible_instance_count = n_splats
	multi_mesh.visible_instance_count = 30
	ply_file.close()
	
	data_texture = create_data_texture(vertices_float)
	multi_mesh.mesh.material.set_shader_parameter("data", data_texture)
	#multi_mesh.mesh.material.set_shader_parameter("n_splats", n_splats)
	multi_mesh.mesh.material.set_shader_parameter("n_splats", 30)
	multi_mesh.mesh.material.set_shader_parameter("n_properties", n_texture_properties)
	multi_mesh.mesh.material.set_shader_parameter("modifier", 1.0)
	
	var tan_fovy = tan(deg_to_rad(main_camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)
	multi_mesh.mesh.material.set_shader_parameter("tan_fovx", tan_fovx)
	multi_mesh.mesh.material.set_shader_parameter("tan_fovy", tan_fovy)
	multi_mesh.mesh.material.set_shader_parameter("focal_x", focal_y)
	multi_mesh.mesh.material.set_shader_parameter("focal_y", focal_x)
	multi_mesh.mesh.material.set_shader_parameter("viewport_size", get_viewport().size)
	

func create_data_texture(vertices_float: PackedFloat32Array) -> ImageTexture:
	var image = Image.create(30, n_texture_properties, false, Image.FORMAT_RGBAF)
	
	for i in range(30):
		var idx = i * len(property_indices)
		# mu/mean - 0
		image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]]
		))
		# scale - 1
		image.set_pixel(i, 1, Color(
			vertices_float[idx + property_indices["scale_0"]],
			vertices_float[idx + property_indices["scale_1"]],
			vertices_float[idx + property_indices["scale_2"]]
		))
		# rot - 2
		image.set_pixel(i, 2, Color(
			vertices_float[idx + property_indices["rot_0"]],
			vertices_float[idx + property_indices["rot_1"]],
			vertices_float[idx + property_indices["rot_2"]],
			vertices_float[idx + property_indices["rot_3"]]
		))
	
	return ImageTexture.create_from_image(image)
