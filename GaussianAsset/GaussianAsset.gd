# Adapted from: https://github.com/LightningStorm0/Godot-Gaussian-Splatting/blob/main/GaussianLoader.gd
extends Node3D

@export var ply_path: String = "res://ply_files/lego.ply"
@export var max_vertices: int = 16384 ** 2

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

var means_image_texture: ImageTexture
var dc_image_texture: ImageTexture
var sh1_1_image_texture: ImageTexture
var sh1_2_image_texture: ImageTexture
var sh1_3_image_texture: ImageTexture
var sh2_1_image_texture: ImageTexture
var sh2_2_image_texture: ImageTexture
var sh2_3_image_texture: ImageTexture
var sh2_4_image_texture: ImageTexture
var sh2_5_image_texture: ImageTexture
var sh3_1_image_texture: ImageTexture
var sh3_2_image_texture: ImageTexture
var sh3_3_image_texture: ImageTexture
var sh3_4_image_texture: ImageTexture
var sh3_5_image_texture: ImageTexture
var sh3_6_image_texture: ImageTexture
var sh3_7_image_texture: ImageTexture
var opa_scale_image_texture: ImageTexture
var rot_image_texture: ImageTexture

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
		if sort_thread != null and sort_thread.is_started():
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

func create_extended_image_texture(
	image_format: Image.Format,
	n_components: int,
	byte_data: PackedByteArray,
	extended_image_size: int,
) -> ImageTexture:
	var fill_data = PackedByteArray()
	fill_data.resize((extended_image_size ** 2 - n_splats) * 4 * n_components)
	byte_data.append_array(fill_data)
	var image = Image.create_from_data(
		extended_image_size,
		extended_image_size,
		false,
		image_format,
		byte_data
	)
	return ImageTexture.create_from_image(image)

func load_gaussians(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("end_header"):
			break
		current_line = ply_file.get_line()
	
	print("Loading vertices")
	
	var means_byte_array: PackedByteArray = PackedByteArray()
	
	var dc_byte_array: PackedByteArray = PackedByteArray()
	
	var sh1_1_byte_array: PackedByteArray = PackedByteArray()
	var sh1_2_byte_array: PackedByteArray = PackedByteArray()
	var sh1_3_byte_array: PackedByteArray = PackedByteArray()
	
	var sh2_1_byte_array: PackedByteArray = PackedByteArray()
	var sh2_2_byte_array: PackedByteArray = PackedByteArray()
	var sh2_3_byte_array: PackedByteArray = PackedByteArray()
	var sh2_4_byte_array: PackedByteArray = PackedByteArray()
	var sh2_5_byte_array: PackedByteArray = PackedByteArray()
	
	var sh3_1_byte_array: PackedByteArray = PackedByteArray()
	var sh3_2_byte_array: PackedByteArray = PackedByteArray()
	var sh3_3_byte_array: PackedByteArray = PackedByteArray()
	var sh3_4_byte_array: PackedByteArray = PackedByteArray()
	var sh3_5_byte_array: PackedByteArray = PackedByteArray()
	var sh3_6_byte_array: PackedByteArray = PackedByteArray()
	var sh3_7_byte_array: PackedByteArray = PackedByteArray()
	
	var opa_scale_byte_array: PackedByteArray = PackedByteArray()
	var rot_byte_array: PackedByteArray = PackedByteArray()
	
	for i in n_splats:
		means_byte_array.append_array(ply_file.get_buffer(3 * 4))
		# skip normals
		ply_file.get_buffer(3 * 4)
		
		# spherical harmonics
		dc_byte_array.append_array(ply_file.get_buffer(3 * 4))
		
		if sh_degree > 0:
			sh1_1_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh1_2_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh1_3_byte_array.append_array(ply_file.get_buffer(3 * 4))
		
		if sh_degree > 1:
			sh2_1_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh2_2_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh2_3_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh2_4_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh2_5_byte_array.append_array(ply_file.get_buffer(3 * 4))
			
		if sh_degree > 2:
			sh3_1_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_2_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_3_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_4_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_5_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_6_byte_array.append_array(ply_file.get_buffer(3 * 4))
			sh3_7_byte_array.append_array(ply_file.get_buffer(3 * 4))
		
		opa_scale_byte_array.append_array(ply_file.get_buffer(4 * 4))
		rot_byte_array.append_array(ply_file.get_buffer(4 * 4))
	
	vertices_float = means_byte_array.to_float32_array()
	
	var texture_size = ceil(n_splats ** 0.5)
	
	means_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, means_byte_array, texture_size)
	dc_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, dc_byte_array, texture_size)
	sh1_1_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh1_1_byte_array, texture_size)
	sh1_2_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh1_2_byte_array, texture_size)
	sh1_3_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh1_3_byte_array, texture_size)
	sh2_1_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh2_1_byte_array, texture_size)
	sh2_2_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh2_2_byte_array, texture_size)
	sh2_3_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh2_3_byte_array, texture_size)
	sh2_4_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh2_4_byte_array, texture_size)
	sh2_5_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh2_5_byte_array, texture_size)
	sh3_1_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_1_byte_array, texture_size)
	sh3_2_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_2_byte_array, texture_size)
	sh3_3_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_3_byte_array, texture_size)
	sh3_4_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_4_byte_array, texture_size)
	sh3_5_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_5_byte_array, texture_size)
	sh3_6_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_6_byte_array, texture_size)
	sh3_7_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, sh3_7_byte_array, texture_size)
	opa_scale_image_texture = create_extended_image_texture(Image.FORMAT_RGBAF, 4, opa_scale_byte_array, texture_size)
	rot_image_texture = create_extended_image_texture(Image.FORMAT_RGBAF, 4, rot_byte_array, texture_size)
	
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
		var idx = i * 3
		var mu = Vector3(
			vertices_float[idx],
			vertices_float[idx + 1],
			vertices_float[idx + 2]
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
	multi_mesh.mesh.material.set_shader_parameter("means_sampler", means_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("dc_sampler", dc_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh1_1_sampler", sh1_1_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh1_2_sampler", sh1_2_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh1_3_sampler", sh1_3_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh2_1_sampler", sh2_1_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh2_2_sampler", sh2_2_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh2_3_sampler", sh2_3_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh2_4_sampler", sh2_4_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh2_5_sampler", sh2_5_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_1_sampler", sh3_1_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_2_sampler", sh3_2_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_3_sampler", sh3_3_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_4_sampler", sh3_4_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_5_sampler", sh3_5_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_6_sampler", sh3_6_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh3_7_sampler", sh3_7_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("opa_scale_sampler", opa_scale_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("rot_sampler", rot_image_texture)
	multi_mesh.mesh.material.set_shader_parameter("sh_sampler", sh_texture)
	multi_mesh.mesh.material.set_shader_parameter("n_splats", n_splats)
	multi_mesh.mesh.material.set_shader_parameter("texture_size", texture_size)
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
		var idx = i * 3
		var mu = Vector3(
			vertices_float[idx],
			vertices_float[idx + 1],
			vertices_float[idx + 2]
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
	var texture_size = ceil(n_splats ** 0.5)
	if depth_index_image == null:
		depth_index_image = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	for i in range(n_splats):
		var integer_value = depth_index[i]
		var r = (integer_value >> 24) & 0xFF
		var g = (integer_value >> 16) & 0xFF
		var b = (integer_value >> 8) & 0xFF
		var a = integer_value & 0xFF
		
		depth_index_image.set_pixel(
			int(int(i) % int(texture_size)), int(i / texture_size), 
			Color(r / 255.0, g / 255.0, b / 255.0, a / 255.0))
	depth_index_texture = ImageTexture.create_from_image(depth_index_image)
