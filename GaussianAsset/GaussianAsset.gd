extends Node3D

@export var ply_path: String

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
var depth_index: Array[int] = []
var depths: Array[float] = []
var vertices_float: PackedFloat32Array
var sh_degree: int
var sort_thread: Thread

func _ready():
	if ply_path != null:
		load_header(ply_path)
		load_gaussians(ply_path)
		

func _process(delta):
	var direction = (main_camera.global_transform.origin - global_transform.origin).normalized()
	var angle = last_direction.dot(direction)
	
	# Only re-sort if camera has changed enough
	if angle < 0.8:
		if sort_thread != null and sort_thread.is_alive():
			sort_thread.wait_to_finish()
		sort_thread = Thread.new()
		sort_thread.start(sort_splats_by_depth)
		last_direction = direction

# Thread must be disposed (or "joined"), for portability.
func _exit_tree():
	sort_thread.wait_to_finish()

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
	sh_degree = ((properties.size() - 14)  / 3) ** 0.5

func load_gaussians(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("end_header"):
			break
		current_line = ply_file.get_line()
	
	vertices_float = ply_file.get_buffer(n_splats * len(property_indices) * 4).to_float32_array()

	var multi_mesh = multi_mesh_instance.multimesh
	multi_mesh.instance_count = n_splats
	
	for i in range(n_splats):
		var idx = i * len(property_indices)
		
		var color = Color(
			clamp(vertices_float[idx + property_indices["f_dc_0"]], 0.0, 1.0),
			clamp(vertices_float[idx + property_indices["f_dc_1"]], 0.0, 1.0),
			clamp(vertices_float[idx + property_indices["f_dc_2"]], 0.0, 1.0),
			vertices_float[idx + property_indices["opacity"]],
		)
		depth_index.append(i)
		depths.append(0)
		
		multi_mesh.set_instance_transform(i, Transform3D())
		multi_mesh.set_instance_color(i, color)
		multi_mesh.set_instance_custom_data(i, color)
		
	multi_mesh.visible_instance_count = n_splats
	ply_file.close()
	
	create_data_textures(vertices_float)
	sort_splats_by_depth()
	multi_mesh.mesh.material.set_shader_parameter("means_opa_sampler", means_opa_texture)
	multi_mesh.mesh.material.set_shader_parameter("scales_sampler", scales_texture)
	multi_mesh.mesh.material.set_shader_parameter("rot_sampler", rot_texture)
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
	

func create_data_textures(vertices_float: PackedFloat32Array):
	var means_opa_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	var scales_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	var rot_image = Image.create(n_splats, 1, false, Image.FORMAT_RGBAF)
	var sh_image = Image.create(n_splats, sh_degree ** 2, false, Image.FORMAT_RGBAF)
	
	for i in range(n_splats):
		var idx = i * len(property_indices)
		means_opa_image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["x"]],
			vertices_float[idx + property_indices["y"]],
			vertices_float[idx + property_indices["z"]],
			vertices_float[idx + property_indices["opacity"]]
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
		
		# spherical harmonics		
		sh_image.set_pixel(i, 0, Color(
			vertices_float[idx + property_indices["f_dc_0"]],
			vertices_float[idx + property_indices["f_dc_1"]],
			vertices_float[idx + property_indices["f_dc_2"]]
		))
		var n_rest = (sh_degree ** 2) * 3 - 3
		var tex_index = 1
		for sh_index in range(3, n_rest, 3):
			sh_image.set_pixel(i, tex_index, Color(
				vertices_float[idx + property_indices["f_rest_" + str(sh_index)]],
				vertices_float[idx + property_indices["f_rest_" + str(sh_index + 1)]],
				vertices_float[idx + property_indices["f_rest_" + str(sh_index + 2)]]
			))
			tex_index += 1
	
	means_opa_texture = ImageTexture.create_from_image(means_opa_image)
	scales_texture = ImageTexture.create_from_image(scales_image) 
	rot_texture = ImageTexture.create_from_image(rot_image)
	sh_texture = ImageTexture.create_from_image(sh_image)

func depth_to_cam(mu: Vector3) -> float:
	# Get the object's model matrix (global transform)
	var model_matrix = self.global_transform
	
	# Get the camera's view matrix (inverse of the camera's global transform)
	var view_matrix = main_camera.get_camera_transform().affine_inverse()
	
	var rot = Basis(
		Vector3(0, -1, 0),
		Vector3(1, 0, 0),
		Vector3(0, 0, -1),
	)
	
	# Transform the point from object space to world space
	var view_space = (view_matrix * (model_matrix * (rot * mu)))
	var world_position = main_camera.get_camera_projection() * Vector4(view_space.x, view_space.y, view_space.z, 1.0)
	
	return world_position.z / world_position.w
	
func compute_all_depths():
	for i in range(n_splats):
		var idx = i * len(property_indices)
		depths[i] = depth_to_cam(
				Vector3(
					vertices_float[idx + property_indices["x"]],
					vertices_float[idx + property_indices["y"]],
					vertices_float[idx + property_indices["z"]]
				)
			)

func reindex_by_depth():
	depth_index.sort_custom(func(idx1, idx2): return depths[idx1] < depths[idx2])
	
func sort_splats_by_depth():
	compute_all_depths()
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
