# Adapted from: https://github.com/LightningStorm0/Godot-Gaussian-Splatting/blob/main/GaussianLoader.gd
extends Node3D

@export var ply_path: String = "res://ply_files/lego.ply"
@export var max_vertices: int = 16384 ** 2
@onready var main_camera = get_viewport().get_camera_3d()
var last_direction
@onready var rd = RenderingServer.create_local_rendering_device()
@onready var volume = $Volume

var n_splats: int = 0
var means: Array[Vector3]
var vertices: PackedFloat32Array
var n_properties: int
var sh_degree: int
var shade_depth_texture: bool = false
var modifier = 1.0

# Pipeline
# Depth Projection
var projection_uniform_set: RID
var projection_pipeline: RID

# Sort
var sort_uniform_set: RID
var sort_pipeline: RID

# Render
var render_splats_shader: RID
var render_splats_uniform_set: RID
var render_splats_pipeline: RID
var output_texture: RID
var params_buffer: RID
var model_view_buffer: RID
var projection_buffer: RID
var blend := RDPipelineColorBlendState.new()
var vertex_format: int
var framebuffer: RID
var vertex_array: RID
var index_array: RID
var clear_color_values := PackedColorArray([Color(0,0,0,0)])
var rendered_image_texture: ImageTexture

func _ready():
	if ply_path != null:
		load_header(ply_path)
		load_gaussians(ply_path)
		setup_image_texture()
		setup_render_pipeline()

func _process(_delta):
	var direction = (main_camera.global_transform.origin - global_transform.origin).normalized()
	var angle = last_direction.dot(direction) if last_direction != null else 0.0
	
	# Only re-sort if camera has changed enough
	if angle < 0.8:
		sort()
		last_direction = direction
	
	render()

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

	n_properties = properties.size()
	sh_degree = int(((n_properties - 14)  / 3.0) ** 0.5)

func load_gaussians(path: String):
	var ply_file = FileAccess.open(path, FileAccess.READ)
	var current_line = ply_file.get_line()
	while true:
		if current_line.begins_with("end_header"):
			break
		current_line = ply_file.get_line()
	
	print("Loading vertices")

	vertices = ply_file.get_buffer(n_splats * n_properties * 4).to_float32_array()
	
	var aabb_position = Vector3.ZERO
	var aabb_size = Vector3.ZERO
	for i in n_splats:
		var idx = i * n_properties
		var mean = Vector3(
			vertices[idx],
			vertices[idx + 1],
			vertices[idx + 2],
		)
		means.append(mean)
		aabb_size = Vector3(
			max(mean.x, aabb_size.x),
			max(mean.y, aabb_size.y),
			max(mean.z, aabb_size.z),
		)
		aabb_position = Vector3(
			min(mean.x, aabb_position.x),
			min(mean.y, aabb_position.y),
			min(mean.z, aabb_position.z),
		)
	
	
	var aabb = AABB(aabb_position, abs(aabb_position) + aabb_size)
	print("AABB: " + str(aabb))

	var volumne_transform = Transform3D()
	volumne_transform = volumne_transform.scaled(aabb.size)
	volumne_transform = volumne_transform.translated(aabb.get_center())
	volume.transform = volumne_transform
	
	ply_file.close()
	print("Finished Loading Gaussian Asset")

func setup_render_pipeline():
	# projection
	var projection_shader_file = load("res://Shaders/depth_projection.glsl")
	var projection_shader_spirv = projection_shader_file.get_spirv()
	var projection_shader := rd.shader_create_from_spirv(projection_shader_spirv)
	
	# uniforms
	# model view matrix
	var model_view_bytes = _matrix_to_bytes(Projection(get_model_view_matrix()))
	model_view_buffer = rd.storage_buffer_create(model_view_bytes.size(), model_view_bytes)
	var model_view_uniform := RDUniform.new()
	model_view_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	model_view_uniform.binding = 4
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
	var depth_buffer = rd.storage_buffer_create(depth_bytes.size(), depth_bytes)
	var depth_uniform := RDUniform.new()
	depth_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_uniform.binding = 2
	depth_uniform.add_id(depth_buffer)
	
	# vertex buffer
	var vertices_buffer = rd.storage_buffer_create(vertices.size() * 4, vertices.to_byte_array())
	var vertices_uniform := RDUniform.new()
	vertices_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	vertices_uniform.binding = 1
	vertices_uniform.add_id(vertices_buffer)
	
	var projection_bindings = [
		model_view_uniform,
		projection_uniform,
		depth_uniform,
		vertices_uniform
	]
	projection_uniform_set = rd.uniform_set_create(projection_bindings, projection_shader, 0)
	projection_pipeline = rd.compute_pipeline_create(projection_shader)
	
	print("projection pipeline valid: ", rd.compute_pipeline_is_valid(projection_pipeline))
	
	# sort
	var sort_shader_file = load("res://Shaders/single_radix_sort.glsl")
	var sort_shader_spirv = sort_shader_file.get_spirv()
	var sort_shader := rd.shader_create_from_spirv(sort_shader_spirv)

	var points := PackedFloat32Array([
		-1,-1,0,
		1,-1,0,
		-1,1,0,
		1,1,0,
	])
	var points_bytes := points.to_byte_array()
	
	var indices := PackedByteArray()
	indices.resize(12)
	var pos = 0
	
	for i in [0,2,1,0,2,3]:
		indices.encode_u16(pos,i)
		pos += 2
		
	var index_buffer = rd.index_buffer_create(6,RenderingDevice.INDEX_BUFFER_FORMAT_UINT16,indices)
	index_array = rd.index_array_create(index_buffer,0,6)
	
	var vertex_buffers := [
		rd.vertex_buffer_create(points_bytes.size(), points_bytes),
	]
	
	var vertex_attrs = [ RDVertexAttribute.new()]
	vertex_attrs[0].format = RenderingDevice.DATA_FORMAT_R32G32B32_SFLOAT
	vertex_attrs[0].location = 0
	vertex_attrs[0].stride = 4 * 3
	vertex_format = rd.vertex_format_create(vertex_attrs)
	vertex_array = rd.vertex_array_create(4, vertex_format, vertex_buffers)
	
	# uniforms
	# depth index in
	var depth_index: Array[float] = []
	for i in n_splats:
		depth_index.append(i)

	var depth_index_in_bytes = PackedInt32Array(depth_index).to_byte_array()
	depth_index_in_bytes.resize(n_splats * 4)
	var depth_index_in_buffer = rd.storage_buffer_create(depth_index_in_bytes.size(), depth_index_in_bytes)
	var depth_index_in_uniform := RDUniform.new()
	depth_index_in_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	depth_index_in_uniform.binding = 0
	depth_index_in_uniform.add_id(depth_index_in_buffer)
	
	# depth index out
	var depth_index_out_bytes = PackedInt32Array(depth_index).to_byte_array()
	depth_index_out_bytes.resize(n_splats * 4)
	var depth_index_out_buffer = rd.storage_buffer_create(depth_index_out_bytes.size(), depth_index_out_bytes)
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
	
	# render splats
	var render_splats_shader_file = load("res://Shaders/render_splats.glsl")
	var render_splats_shader_spirv = render_splats_shader_file.get_spirv()
	render_splats_shader = rd.shader_create_from_spirv(render_splats_shader_spirv)
	
	# params uniform
	var tan_fovy = tan(deg_to_rad(main_camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)
	var params : PackedByteArray = PackedFloat32Array([
		get_viewport().size.x,
		get_viewport().size.y,
		tan_fovx,
		tan_fovy,
		focal_x,
		focal_y,
		sh_degree,
		modifier
	]).to_byte_array()
	params_buffer = rd.storage_buffer_create(params.size(), params)
	var params_uniform := RDUniform.new()
	params_uniform.uniform_type = RenderingDevice.UNIFORM_TYPE_STORAGE_BUFFER
	params_uniform.binding = 2
	params_uniform.add_id(params_buffer)

	# Configure blend mode
	var blend_attachment = RDPipelineColorBlendStateAttachment.new()	
	blend_attachment.enable_blend = true
	blend_attachment.src_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_color_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
	blend_attachment.color_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.src_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE
	blend_attachment.dst_alpha_blend_factor = RenderingDevice.BLEND_FACTOR_ONE_MINUS_SRC_ALPHA
	blend_attachment.alpha_blend_op = RenderingDevice.BLEND_OP_ADD
	blend_attachment.write_r = true
	blend_attachment.write_g = true
	blend_attachment.write_b = true
	blend_attachment.write_a = true 
	blend.attachments.push_back(blend_attachment)	

	var framebuffer_format = _initialise_framebuffer_format()
	framebuffer = rd.framebuffer_create([output_texture], framebuffer_format)
	print("framebuffer valid: ",rd.framebuffer_is_valid(framebuffer))
	
	var render_splats_bindings = [
		model_view_uniform,
		projection_uniform,
		vertices_uniform,
		params_uniform,
		depth_index_in_uniform
	]
	render_splats_uniform_set = rd.uniform_set_create(render_splats_bindings, render_splats_shader, 0)
	render_splats_pipeline = rd.render_pipeline_create(
		render_splats_shader,
		framebuffer_format,
		vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLE_STRIPS,
		RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(),
		blend
	)
	
	print("render splats pipeline valid: ", rd.render_pipeline_is_valid(render_splats_pipeline))

func setup_image_texture():
	var byte_data = PackedByteArray()
	var image_size = get_viewport().size	
	byte_data.resize(image_size.x * image_size.y * 4 * 4)
	rendered_image_texture = ImageTexture.create_from_image(Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_RGBAF, byte_data))

func _initialise_framebuffer_format():
	var tex_format := RDTextureFormat.new()
	var tex_view := RDTextureView.new()
	tex_format.texture_type = RenderingDevice.TEXTURE_TYPE_2D
	tex_format.height = get_viewport().size.y
	tex_format.width = get_viewport().size.x
	tex_format.format = RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT
	tex_format.usage_bits = (RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT) 
	output_texture = rd.texture_create(tex_format,tex_view)

	var attachments = []
	var attachment_format := RDAttachmentFormat.new()
	attachment_format.set_format(tex_format.format)
	attachment_format.set_samples(RenderingDevice.TEXTURE_SAMPLES_1)
	attachment_format.usage_flags = RenderingDevice.TEXTURE_USAGE_COLOR_ATTACHMENT_BIT | RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT
	attachments.push_back(attachment_format)
	var framebuf_format = rd.framebuffer_format_create(attachments)
	return framebuf_format

func _on_viewport_size_changed():
	var framebuf_format = _initialise_framebuffer_format()
	framebuffer = rd.framebuffer_create([output_texture], framebuf_format)
	
	render_splats_pipeline = rd.render_pipeline_create(
		render_splats_shader,
		framebuf_format,
		vertex_format,
		RenderingDevice.RENDER_PRIMITIVE_TRIANGLE_STRIPS,
		RDPipelineRasterizationState.new(),
		RDPipelineMultisampleState.new(),
		RDPipelineDepthStencilState.new(),
		blend
	)

	update_params_buffer()

func _matrix_to_bytes(p : Projection) -> PackedByteArray:
	var bytes : PackedByteArray = PackedFloat32Array([
		p.x.x, p.x.y, p.x.z, p.x.w,
		p.y.x, p.y.y, p.y.z, p.y.w,
		p.z.x, p.z.y, p.z.z, p.z.w,
		p.w.x, p.w.y, p.w.z, p.w.w,
	]).to_byte_array()
	return bytes

func _exit_tree():
	pass
	# TODO: Dispose of all rendering ids

func get_model_view_matrix() -> Transform3D:
	var model_matrix = self.global_transform
	
	# Get the camera's view matrix (inverse of the camera's global transform)
	var view_matrix = main_camera.get_camera_transform().affine_inverse()
	
	return view_matrix * model_matrix

func update_params_buffer():
	var tan_fovy = tan(deg_to_rad($Camera.fov) * 0.5)
	var tan_fovx = tan_fovy * get_viewport().size.x / get_viewport().size.y
	var focal_y = get_viewport().size.y / (2 * tan_fovy)
	var focal_x = get_viewport().size.x / (2 * tan_fovx)

	# Viewport size buffer
	var params : PackedByteArray = PackedFloat32Array([
		get_viewport().size.x,
		get_viewport().size.y,
		tan_fovx,
		tan_fovy,
		focal_x,
		focal_y,
		sh_degree,
		modifier
	]).to_byte_array()
	rd.buffer_update(params_buffer, 0, params.size(), params)

func update_camera_buffers():
	var model_view_bytes = _matrix_to_bytes(Projection(get_model_view_matrix()))
	rd.buffer_update(model_view_buffer, 0, model_view_bytes.size(), model_view_bytes)
	var projection_bytes = _matrix_to_bytes(main_camera.get_camera_projection())
	rd.buffer_update(projection_buffer, 0, projection_bytes.size(), projection_bytes)

func sort():
	update_camera_buffers()

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
	
	rd.compute_list_end()
	rd.submit()
	rd.sync()

func render():
	update_camera_buffers()
	
	var draw_list := rd.draw_list_begin(framebuffer, 
		RenderingDevice.INITIAL_ACTION_CLEAR, 
		RenderingDevice.FINAL_ACTION_READ, 
		RenderingDevice.INITIAL_ACTION_CLEAR, 
		RenderingDevice.FINAL_ACTION_READ, 
		clear_color_values)
	rd.draw_list_bind_render_pipeline(draw_list, render_splats_pipeline)
	rd.draw_list_bind_uniform_set(draw_list, render_splats_uniform_set, 0)
	rd.draw_list_bind_vertex_array(draw_list, vertex_array)
	var push_constants = PackedInt32Array([n_splats, 1 if shade_depth_texture else 0])
	rd.draw_list_set_push_constant(draw_list, push_constants.to_byte_array(), push_constants.size() * 8)
	rd.draw_list_draw(draw_list, false, n_splats)
	rd.draw_list_end(RenderingDevice.BARRIER_MASK_VERTEX)
	
	var byte_data := rd.texture_get_data(output_texture, 0)
	var image_size = get_viewport().size
	var image := Image.create_from_data(image_size.x, image_size.y, false, Image.FORMAT_RGBAF, byte_data)
	rendered_image_texture.update(image)
	volume.mesh.material.set_shader_parameter("rendered_image_texture", rendered_image_texture)
