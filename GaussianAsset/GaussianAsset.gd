# Adapted from: https://github.com/LightningStorm0/Godot-Gaussian-Splatting/blob/main/GaussianLoader.gd
extends Node3D

@export var ply_path: String = "res://ply_files/lego.ply"
@export var max_vertices: int = 16384 ** 2
@export var near_cull_distance: float = 0.1

@onready var multi_mesh_instance = $MultiMeshInstance3D
@onready var main_camera = get_viewport().get_camera_3d()
var last_direction
@onready var rd = RenderingServer.get_rendering_device()

var n_splats: int = 0
var property_indices = Dictionary()
var means_opa_texture: ImageTexture 
var scales_texture: ImageTexture 
var rot_texture: ImageTexture
var sh_texture: ImageTexture
var depth_index: Array[float]
var texture_size: int

var means_byte_array: PackedByteArray

var depth_index_texture_rid: RID
var depth_index_texture: Texture2DRD
var depth_index_in_buffer: RID
var depth_index_out_buffer: RID
var model_view_buffer: RID
var projection_buffer: RID
var depth_buffer: RID
var projection_uniform_set: RID
var projection_pipeline: RID
var means_buffer: RID
var sort_uniform_set: RID
var sort_pipeline: RID
var texture_projection_uniform_set: RID
var texture_projection_pipeline: RID

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

var vertices_float: PackedFloat32Array
var sh_degree: int
var data_image: Image
var vertices_bytes

func _ready():
	if ply_path != null:
		load_header(ply_path)
		load_gaussians(ply_path)
		RenderingServer.call_on_render_thread(setup_sort_pipeline)

func setup_sort_pipeline():
	# projection
	var projection_shader_file = load("res://Sort/depth_projection.glsl")
	var projection_shader_spirv = projection_shader_file.get_spirv()
	var projection_shader := rd.shader_create_from_spirv(projection_shader_spirv)
	
	# uniforms
	# model view matrix
	var model_view_bytes = _matrix_to_bytes(Projection(get_model_view_matrix()))
	model_view_buffer = rd.storage_buffer_create(model_view_bytes.size(), model_view_bytes)
	var model_view_uniform := RDUniform.new()
	model_view_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	model_view_uniform.binding = 0
	model_view_uniform.add_id(model_view_buffer)
	
	# projection matrix
	var projection_bytes = _matrix_to_bytes(main_camera.get_camera_projection())
	projection_buffer = rd.storage_buffer_create(projection_bytes.size(), projection_bytes)
	var projection_uniform := RDUniform.new()
	projection_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	projection_uniform.binding = 3
	projection_uniform.add_id(projection_buffer)
	
	# depth buffer
	var depth_bytes = PackedByteArray()
	depth_bytes.resize(n_splats * 4)
	depth_buffer = rd.storage_buffer_create(depth_bytes.size(), depth_bytes)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_uniform.binding = 2
	depth_uniform.add_id(depth_buffer)
	
	# vertex buffer
	assert(means_byte_array.size() == n_splats * 12)
	means_buffer = rd.storage_buffer_create(means_byte_array.size(), means_byte_array)
	var means_uniform := RDUniform.new()
	means_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	means_uniform.binding = 1
	means_uniform.add_id(means_buffer)
	
	var projection_bindings = [
		model_view_uniform,
		projection_uniform,
		depth_uniform,
		means_uniform
	]
	projection_uniform_set = rd.uniform_set_create(projection_bindings, projection_shader, 0)
	projection_pipeline = rd.compute_pipeline_create(projection_shader)
	
	print("projection pipeline valid: ", rd.compute_pipeline_is_valid(projection_pipeline))
	
	# sort
	var sort_shader_file = load("res://Sort/single_radix_sort.glsl")
	var sort_shader_spirv = sort_shader_file.get_spirv()
	var sort_shader := rd.shader_create_from_spirv(sort_shader_spirv)
	
	# uniforms
	# depth index in
	var depth_index_in_bytes = PackedInt32Array(depth_index).to_byte_array()
	depth_index_in_bytes.resize(n_splats * 4)
	depth_index_in_buffer = rd.storage_buffer_create(depth_index_in_bytes.size(), depth_index_in_bytes)
	var depth_index_in_uniform := RDUniform.new()
	depth_index_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_index_in_uniform.binding = 0
	depth_index_in_uniform.add_id(depth_index_in_buffer)
	
	# depth index out
	var depth_index_out_bytes = PackedInt32Array(depth_index).to_byte_array()
	depth_index_out_bytes.resize(n_splats * 4)
	depth_index_out_buffer = rd.storage_buffer_create(depth_index_out_bytes.size(), depth_index_out_bytes)
	var depth_index_out_uniform := RDUniform.new()
	depth_index_out_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_index_out_uniform.binding = 1
	depth_index_out_uniform.add_id(depth_index_out_buffer)
	
	var sort_bindings = [
		depth_index_in_uniform,
		depth_index_out_uniform,
		depth_uniform
	]
	sort_uniform_set = rd.uniform_set_create(sort_bindings, sort_shader, 0)
	sort_pipeline = rd.compute_pipeline_create(sort_shader)
	
	print("sort pipeline valid: ", rd.compute_pipeline_is_valid(sort_pipeline))
	
	# project to texture
	var project_to_texture_shader_file = load("res://Sort/project_to_texture.glsl")
	var project_to_texture_shader_spirv = project_to_texture_shader_file.get_spirv()
	var project_to_texture_shader := rd.shader_create_from_spirv(project_to_texture_shader_spirv)
	
	# depth index texture
	var depth_index_bytes = PackedFloat32Array(depth_index).to_byte_array()
	fill_byte_array(depth_index_bytes, (texture_size ** 2 - n_splats) * 4)
	var tf : RDTextureFormat = RDTextureFormat.new()
	tf.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	tf.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tf.width = texture_size
	tf.height = texture_size
	tf.depth = 0
	tf.array_layers = 1
	tf.mipmaps = 1
	tf.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT + 
					RenderingDevice.TEXTURE_USAGE_STORAGE_BIT + 
					RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT + 
					RenderingDevice.TEXTURE_USAGE_CAN_COPY_TO_BIT)
	depth_index_texture_rid = rd.texture_create(tf, RDTextureView.new(), [depth_index_bytes])
	assert(rd.texture_is_valid(depth_index_texture_rid))
	depth_index_texture = Texture2DRD.new()
	depth_index_texture.texture_rd_rid = depth_index_texture_rid
	
	multi_mesh_instance.multimesh.mesh.material.set_shader_parameter("depth_index_sampler", depth_index_texture)
	
	var depth_index_uniform := RDUniform.new()
	depth_index_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_IMAGE
	depth_index_uniform.binding = 1
	depth_index_uniform.add_id(depth_index_texture_rid)
	
	var texture_projection_bindings = [
		depth_index_in_uniform,
		depth_index_uniform,
	]
	texture_projection_uniform_set = rd.uniform_set_create(texture_projection_bindings, project_to_texture_shader, 0)
	texture_projection_pipeline = rd.compute_pipeline_create(project_to_texture_shader)
	
	print("texture projection pipeline valid: ", rd.compute_pipeline_is_valid(sort_pipeline))


func _matrix_to_bytes(p : Projection) -> PackedByteArray:
	var bytes : PackedByteArray = PackedFloat32Array([
		p.x.x, p.x.y, p.x.z, p.x.w,
		p.y.x, p.y.y, p.y.z, p.y.w,
		p.z.x, p.z.y, p.z.z, p.z.w,
		p.w.x, p.w.y, p.w.z, p.w.w,
	]).to_byte_array()
	return bytes

func _process(_delta):
	var direction = (main_camera.global_transform.origin - global_transform.origin).normalized()
	var angle = last_direction.dot(direction) if last_direction != null else 0.0
	
	# Only re-sort if camera has changed enough
	if angle < 0.8 and multi_mesh_instance.is_visible_in_tree():
		call_sort()
		last_direction = direction

func call_sort():
	print("Sorting")
	RenderingServer.call_on_render_thread(sort_splats_by_depth.bind(get_model_view_matrix(), main_camera.get_camera_projection()))

func _exit_tree():
	if depth_index_texture_rid != null:
		RenderingServer.free_rid(depth_index_texture_rid)
	if depth_index_in_buffer != null:
		RenderingServer.free_rid(depth_index_in_buffer)
	if depth_index_out_buffer != null:
		RenderingServer.free_rid(depth_index_out_buffer)
	if model_view_buffer != null:
		RenderingServer.free_rid(model_view_buffer)
	if projection_buffer != null:
		RenderingServer.free_rid(projection_buffer)
	if depth_buffer != null:
		RenderingServer.free_rid(depth_buffer)
	if projection_uniform_set != null:
		RenderingServer.free_rid(projection_uniform_set)
	if projection_pipeline != null:
		RenderingServer.free_rid(projection_pipeline)
	if means_buffer != null:
		RenderingServer.free_rid(means_buffer)
	if sort_uniform_set != null:
		RenderingServer.free_rid(sort_uniform_set)
	if sort_pipeline != null:
		RenderingServer.free_rid(sort_pipeline)
	if texture_projection_uniform_set != null:
		RenderingServer.free_rid(texture_projection_uniform_set)
	if texture_projection_pipeline != null:
		RenderingServer.free_rid(texture_projection_pipeline)

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

func fill_byte_array(byte_data: PackedByteArray, to_size: int):
	var fill_data = PackedByteArray()
	fill_data.resize(to_size)
	byte_data.append_array(fill_data)
	return byte_data

func create_extended_image_texture(
	image_format: Image.Format,
	n_components: int,
	byte_data: PackedByteArray,
	extended_image_size: int,
	byte_size: int = 4
) -> ImageTexture:
	fill_byte_array(byte_data, (extended_image_size ** 2 - n_splats) * byte_size * n_components)
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
	
	means_byte_array = PackedByteArray()
	
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
	
	texture_size = ceil(n_splats ** 0.5)
	
	means_image_texture = create_extended_image_texture(Image.FORMAT_RGBF, 3, means_byte_array.duplicate(), texture_size)
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
	depth_index = []
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
		depth_index.append(float(i))
		multi_mesh.set_instance_transform(i, Transform3D())
	
	multi_mesh_instance.custom_aabb = AABB(aabb_position, abs(aabb_position) + aabb_size)
	print("AABB: " + str(multi_mesh_instance.custom_aabb))
	
	multi_mesh.visible_instance_count = n_splats
	ply_file.close()
	
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
	multi_mesh.mesh.material.set_shader_parameter("near_cull_distance", near_cull_distance)
	
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

func sort_splats_by_depth(model_view_matrix: Transform3D, main_camera_projection: Projection):
	# update buffers
	var model_view_bytes = _matrix_to_bytes(Projection(model_view_matrix))
	rd.buffer_update(model_view_buffer, 0, model_view_bytes.size(), model_view_bytes)
	var projection_bytes = _matrix_to_bytes(main_camera_projection)
	rd.buffer_update(projection_buffer, 0, projection_bytes.size(), projection_bytes)

	var projection_threads_per_workgroup = max(1, n_splats / 256 + 1)
	var compute_list := rd.compute_list_begin()
	rd.compute_list_bind_compute_pipeline(compute_list, projection_pipeline)
	var push_constants_depth = PackedInt32Array([n_splats, 0])
	rd.compute_list_set_push_constant(compute_list, push_constants_depth.to_byte_array(), push_constants_depth.size() * 8)
	rd.compute_list_bind_uniform_set(compute_list, projection_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, projection_threads_per_workgroup, 1, 1)
	
	rd.compute_list_add_barrier(compute_list)
	
	rd.compute_list_bind_compute_pipeline(compute_list, sort_pipeline)
	var push_constants_sort = PackedInt32Array([n_splats, 0])
	rd.compute_list_set_push_constant(compute_list, push_constants_sort.to_byte_array(), push_constants_sort.size() * 8)
	rd.compute_list_bind_uniform_set(compute_list, sort_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, 1, 1, 1)
	rd.compute_list_add_barrier(compute_list)

	rd.compute_list_bind_compute_pipeline(compute_list, texture_projection_pipeline)
	var push_constants_projection = PackedInt32Array([n_splats, 0])
	rd.compute_list_set_push_constant(compute_list, push_constants_projection.to_byte_array(), push_constants_projection.size() * 8)
	rd.compute_list_bind_uniform_set(compute_list, texture_projection_uniform_set, 0)
	rd.compute_list_dispatch(compute_list, n_splats / 1024 + 1, 1, 1)
	
	rd.compute_list_end()
