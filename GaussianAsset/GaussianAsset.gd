# Adapted from: https://github.com/LightningStorm0/Godot-Gaussian-Splatting/blob/main/GaussianLoader.gd
extends Node3D

@export var ply_path: String = "res://lego.ply"
@export var max_vertices: int = 500000

@onready var multi_mesh_instance = $MultiMeshInstance3D
@onready var main_camera = get_viewport().get_camera_3d()
@onready var last_direction = (main_camera.global_transform.origin - global_transform.origin).normalized()

var n_splats: int = 0
var property_indices = Dictionary()
var means_opa_texture: ImageTexture 
var scales_texture: ImageTexture 
var rot_texture: ImageTexture
var sh_texture: ImageTexture
var depth_index_image: Image
var depth_index_texture: ImageTexture
var data_texture: ImageTexture
var depth_index: Array[int] = []
var depths: Array[float] = []
var vertices_float: PackedFloat32Array
var sh_degree: int
var sort_thread: Thread
var data_image: Image
var vertices_bytes

func _ready():
	if ply_path != null:
		load_header(ply_path)
		load_gaussians(ply_path)
		

func _process(_delta):
	var direction = (main_camera.global_transform.origin - global_transform.origin).normalized()
	var angle = last_direction.dot(direction)
	
	# Only re-sort if camera has changed enough
	if angle < 0.8:
		if sort_thread != null and sort_thread.is_started() and sort_thread.is_alive() == false:
			sort_thread.wait_to_finish()
		sort_thread = Thread.new()
		sort_thread.start(sort_splats_by_depth.bind(get_model_view_matrix(), main_camera.get_camera_projection()))
		last_direction = direction

# Thread must be disposed (or "joined"), for portability.
func _exit_tree():
	if sort_thread != null:
		sort_thread.wait_to_finish()

func load_header(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var properties = []
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("element vertex"):
			n_splats = min(int(current_line.split(" ")[2]), max_vertices)
			print("Number of splats: ", n_splats)
		if current_line.begins_with("property float"):
			properties.append(current_line.split(" ")[2])
		if current_line.begins_with("end_header"):
			break

		current_line = ply_file.get_line()
		
	ply_file.close()

	for i in range(properties.size()):
		property_indices[properties[i]] = i
	sh_degree = int(((properties.size() - 14)  / 3.0) ** 0.5)

func load_gaussians(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("end_header"):
			break
		current_line = ply_file.get_line()
	
	print("Loading vertices")
	var data_size = n_splats * len(property_indices) * 4
	vertices_bytes = ply_file.get_buffer(data_size)
	vertices_float = vertices_bytes.to_float32_array()
	data_image = Image.create_from_data(
		len(property_indices),
		n_splats,
		false,
		Image.FORMAT_RF,
		vertices_bytes
	)
	data_texture = ImageTexture.create_from_image(data_image)

	var multi_mesh = MultiMesh.new()
	multi_mesh.transform_format = MultiMesh.TRANSFORM_3D
	multi_mesh.instance_count = n_splats
	var plane_mesh = PlaneMesh.new()
	plane_mesh.material = load("res://GaussianAsset/gaussian_shader.tres").duplicate()
	multi_mesh.mesh = plane_mesh
	
	multi_mesh_instance.multimesh = multi_mesh
	
	var aabb_position = Vector3.ZERO
	var aabb_size = Vector3.ZERO
	for i in range(n_splats):
		var idx = i * len(property_indices)
		var mu = Vector3(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]]
		)
		aabb_size = Vector3(
			max(mu.x, aabb_size.x),
			max(mu.y, aabb_size.y),
			max(mu.z, aabb_size.z),
		)
		aabb_position = Vector3(
			min(mu.x, aabb_position.x),
			min(mu.y, aabb_position.y),
			min(mu.z, aabb_position.z),
		)
		depth_index.append(i)
		depths.append(0)
		multi_mesh.set_instance_transform(i, Transform3D())
	
	multi_mesh_instance.custom_aabb = AABB(aabb_position, abs(aabb_position) + aabb_size)
	print("AABB: " + str(multi_mesh_instance.custom_aabb))
	
	for property in property_indices.keys():
		multi_mesh.mesh.material.set_shader_parameter("idx_" + property, property_indices[property])
		
	multi_mesh.visible_instance_count = n_splats
	ply_file.close()
	
	print("Sorting")
	sort_splats_by_depth(get_model_view_matrix(), main_camera.get_camera_projection())
	multi_mesh.mesh.material.set_shader_parameter("data_sampler", data_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh_sampler", sh_texture)
	multi_mesh.mesh.material.set_shader_parameter("n_splats", n_splats)
	multi_mesh.mesh.material.set_shader_parameter("modifier", 1.0)
	multi_mesh.mesh.material.set_shader_parameter("shade_depth_texture", false)
	
	var tan_fovy = tan(deg_to_rad(main_camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)
	multi_mesh.mesh.material.set_shader_parameter("tan_fovx", tan_fovx)
	multi_mesh.mesh.material.set_shader_parameter("tan_fovy", tan_fovy)
	multi_mesh.mesh.material.set_shader_parameter("focal_x", focal_y)
	multi_mesh.mesh.material.set_shader_parameter("focal_y", focal_x)
	multi_mesh.mesh.material.set_shader_parameter("viewport_size", get_viewport().size)
	print("Finished Loading Gaussian Asset")

func get_model_view_matrix() -> Transform3D:
	var model_matrix = self.global_transform
	
	# Get the camera's view matrix (inverse of the camera's global transform)
	var view_matrix = main_camera.get_camera_transform().affine_inverse()
	
	return view_matrix * model_matrix

func transform_to_godot_convention(vec: Vector3) -> Vector3:
	var rot = Basis(
		Vector3(0, -1, 0),
		Vector3(1, 0, 0),
		Vector3(0, 0, -1),
	)
	return rot * vec

func compute_all_depths(model_view_matrix: Transform3D, projection_matrix: Projection):
	for i in range(n_splats):
		var idx = i * len(property_indices)
		var mu = Vector3(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]]
		)
		var view_space = (model_view_matrix * (mu))
		var world_position = projection_matrix * Vector4(view_space.x, view_space.y, view_space.z, 1.0)
		
		depths[i] = world_position.z / world_position.w

func reindex_by_depth():
	depth_index.sort_custom(func(idx1, idx2): return depths[idx1] > depths[idx2])
	
func sort_splats_by_depth(model_view_matrix: Transform3D, projection_matrix: Projection):
	compute_all_depths(model_view_matrix, projection_matrix)
	reindex_by_depth()
	compute_depth_index_texture()
	multi_mesh_instance.multimesh.mesh.material.set_shader_parameter("depth_index_sampler", depth_index_texture)

func compute_depth_index_texture():
	if depth_index_image == null:
		depth_index_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBA8)
	for i in range(n_splats):
		var integer_value = depth_index[i]
		var r = (integer_value >> 24) & 0xFF
		var g = (integer_value >> 16) & 0xFF
		var b = (integer_value >> 8) & 0xFF
		var a = integer_value & 0xFF
		
		depth_index_image.set_pixel(i, 0, Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0))
	depth_index_texture = ImageTexture.create_from_image(depth_index_image)
