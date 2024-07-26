extends Node3D

@export var ply_path: String

@onready var multi_mesh_instance = $MultiMeshInstance3D
@onready var main_camera = get_viewport().get_camera_3d()

var n_splats: int = 0
var property_indices = Dictionary()
var means_texture: ImageTexture 
var scales_texture: ImageTexture 
var rot_texture: ImageTexture 

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
			vertices_float[idx + property_indices["opacity"]],
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
		
	#multi_mesh.visible_instance_count = n_splats
	multi_mesh.visible_instance_count = n_splats
	ply_file.close()
	
	create_data_textures(vertices_float)
	multi_mesh.mesh.material.set_shader_parameter("means_sampler", means_texture)
	multi_mesh.mesh.material.set_shader_parameter("scales_sampler", scales_texture)
	multi_mesh.mesh.material.set_shader_parameter("rot_sampler", rot_texture)
	#multi_mesh.mesh.material.set_shader_parameter("n_splats", n_splats)
	multi_mesh.mesh.material.set_shader_parameter("n_splats", n_splats)
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
	

func create_data_textures(vertices_float: PackedFloat32Array):
	var means_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	var scales_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	var rot_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	
	for i in range(n_splats):
		var idx = i * len(property_indices)
		means_image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]]
		))
		scales_image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["scale_0"]],
			vertices_float[idx + property_indices["scale_1"]],
			vertices_float[idx + property_indices["scale_2"]]
		))
		rot_image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["rot_0"]],
			vertices_float[idx + property_indices["rot_1"]],
			vertices_float[idx + property_indices["rot_2"]],
			vertices_float[idx + property_indices["rot_3"]]
		))
	
	means_texture = ImageTexture.create_from_image(means_image)
	scales_texture = ImageTexture.create_from_image(scales_image) 
	rot_texture = ImageTexture.create_from_image(rot_image) 
