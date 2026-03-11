@tool
extends Node

const RenderContextScript = preload("res://addons/gaussian-splatting/render_context.gd")

const TILE_SIZE := 16
const WORKGROUP_SIZE := 512
const RADIX := 256
const PARTITION_DIVISION := 8
const PARTITION_SIZE := PARTITION_DIVISION * WORKGROUP_SIZE

## Public properties
var render_scale := 1
var discard_alpha := 0.6
var enable_heatmap := false

## Internal state
var _instances: Array = []
var _instance_gpu_data: Array = [] # Array of Dictionaries
var _context # RenderingContext
var _shaders: Dictionary = {}
var _pipelines: Dictionary = {}
var _descriptors: Dictionary = {}
var _total_splats: int = 0

var _render_texture: Texture2DRD
var _depth_texture: Texture2DRD
var _display_quad: MeshInstance3D
var _display_material: ShaderMaterial

var _needs_rebuild := false
var _needs_resize := false
var _texture_size := Vector2i.ONE
var _tile_dims := Vector2i.ZERO
var _prev_viewport_size := Vector2i.ZERO

# Cached debug info
var cached_num_rendered_splats: int = 0
var cached_vram_bytes: int = 0
var cached_timings: Array = []

# Async splat position query
var _pending_splat_query := Vector2i(-1, -1)
var last_splat_position := Vector3.INF

# Dirty tracking
var _prev_camera_transform := Transform3D()
var _prev_camera_projection := Projection()
var _prev_instance_transforms: Array = []

# Cleanup flag
var _pending_cleanup := false

func _ready() -> void:
	# Create display quad
	_display_quad = MeshInstance3D.new()
	var quad_mesh := QuadMesh.new()
	quad_mesh.flip_faces = true
	quad_mesh.size = Vector2(2, 2)
	_display_quad.mesh = quad_mesh
	_display_quad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_display_quad.extra_cull_margin = 16384.0
	_display_quad.gi_mode = GeometryInstance3D.GI_MODE_DISABLED

	var shader = load("res://addons/gaussian-splatting/shaders/spatial/gs_display.gdshader")
	_display_material = ShaderMaterial.new()
	_display_material.shader = shader

	_render_texture = Texture2DRD.new()
	_depth_texture = Texture2DRD.new()
	_display_material.set_shader_parameter('render_texture', _render_texture)
	_display_material.set_shader_parameter('depth_texture', _depth_texture)
	_display_material.set_shader_parameter('FRAG_DISCARD_THRESHOLD', discard_alpha)

	_display_quad.set_surface_override_material(0, _display_material)
	add_child(_display_quad)

func register_instance(inst) -> void:
	if inst in _instances: return
	_instances.append(inst)
	_needs_rebuild = true

func unregister_instance(inst) -> void:
	_instances.erase(inst)
	_needs_rebuild = true

func request_splat_position(screen_position: Vector2i) -> void:
	_pending_splat_query = screen_position

func _get_viewport():
	if Engine.is_editor_hint():
		return Engine.get_singleton('EditorInterface').get_editor_viewport_3d(0)
	return get_viewport()

func _process(_delta: float) -> void:
	var viewport = _get_viewport()
	if not viewport: return
	var camera = viewport.get_camera_3d()
	if not camera: return

	# Check viewport size change
	var vp_size = viewport.size
	if vp_size != _prev_viewport_size:
		_prev_viewport_size = vp_size
		_texture_size = Vector2i((Vector2(vp_size) * render_scale).max(Vector2.ONE))
		_tile_dims = (_texture_size + Vector2i.ONE * (TILE_SIZE - 1)) / TILE_SIZE
		_needs_resize = true

	# Update discard alpha
	_display_material.set_shader_parameter('FRAG_DISCARD_THRESHOLD', discard_alpha)

	# Check if any instance is still loading or has new data
	var any_loading := false
	for inst in _instances:
		if inst.point_cloud and not inst.is_loaded:
			any_loading = true
			break

	# Check dirty state
	var is_dirty := false
	var cam_transform = camera.global_transform
	var cam_projection = camera.get_camera_projection()
	if cam_transform != _prev_camera_transform or cam_projection != _prev_camera_projection:
		_prev_camera_transform = cam_transform
		_prev_camera_projection = cam_projection
		is_dirty = true

	# Check instance transform changes
	var current_transforms: Array = []
	for inst in _instances:
		current_transforms.append(inst.global_transform)
	if current_transforms != _prev_instance_transforms:
		_prev_instance_transforms = current_transforms
		is_dirty = true

	if is_dirty or any_loading or _needs_rebuild or _needs_resize or _pending_cleanup:
		RenderingServer.call_on_render_thread(_rasterize)

func _rasterize() -> void:
	# Handle deferred cleanup on render thread
	if _pending_cleanup:
		_pending_cleanup = false
		if _context:
			_context.deletion_queue.flush(_context.device)
			_context.shader_cache.clear()
		if _render_texture: _render_texture.texture_rd_rid = RID()
		if _depth_texture: _depth_texture.texture_rd_rid = RID()
		return

	if not _context:
		_init_gpu()
	if _needs_rebuild:
		_rebuild_gpu()
	if _needs_resize:
		_resize_gpu()

	if _total_splats == 0: return

	var viewport = _get_viewport()
	if not viewport: return
	var camera = viewport.get_camera_3d()
	if not camera: return

	# Upload ready splat data
	for data in _instance_gpu_data:
		var inst = data.instance
		if inst._splat_data_ready and not data.uploaded:
			_context.device.buffer_update(data.splat_buffer_rid, 0, inst._splat_cpu_data.size() * 4, inst._splat_cpu_data.to_byte_array())
			data.uploaded = true
			inst._splat_data_ready = false
			inst.is_loaded = true
			inst.loaded.emit.call_deferred()

	# Clear histogram + tile_bounds
	_context.device.buffer_clear(_descriptors['histogram'].rid, 0, 4 + 4 * RADIX * 4)
	_context.device.buffer_clear(_descriptors['tile_bounds'].rid, 0, _tile_dims.x * _tile_dims.y * 2 * 4)

	var cam_proj = camera.get_camera_projection()

	# === PROJECTION (per-instance) ===
	_context.device.capture_timestamp('Start')
	for data in _instance_gpu_data:
		var inst = data.instance

		# Compute per-instance model-view matrix
		var inst_basis = inst.global_basis.orthonormalized()
		var inst_transform = Transform3D(inst_basis, inst.global_position)
		var T_inv = inst_transform.affine_inverse()
		var view = Projection(T_inv * camera.get_camera_transform())

		# Build push constants (view + projection)
		var push_constants = _build_camera_push_constants(view, cam_proj)

		# Compute camera position in model space
		var camera_pos_model = T_inv * camera.global_position
		var model_scale_val: float = inst.global_basis.get_scale().x

		# Update uniform buffer (camera_pos, model_scale, texture_size, time, splat_offset)
		_context.device.buffer_update(data.uniform_rid, 0, 8 * 4, RenderContextScript.create_push_constant([
			-camera_pos_model.x, -camera_pos_model.y, camera_pos_model.z,
			model_scale_val,
			_texture_size.x, _texture_size.y,
			Time.get_ticks_msec() * 1e-3,
			data.splat_offset
		]))

		# Dispatch projection
		var compute_list = _context.compute_list_begin()
		data.projection_pipeline.call(_context, compute_list, push_constants)
		_context.compute_list_end()
	_context.device.capture_timestamp('Projection')

	# === SORT (shared) ===
	var compute_list = _context.compute_list_begin()
	var num_sort_max := _total_splats * 10
	for radix_shift_pass in range(4):
		var push_constant := RenderContextScript.create_push_constant([radix_shift_pass, num_sort_max * (radix_shift_pass % 2), num_sort_max * (1 - (radix_shift_pass % 2))])
		_pipelines['radix_sort_upsweep'].call(_context, compute_list, push_constant, [], _descriptors['grid_dimensions'].rid, 0)
		_pipelines['radix_sort_spine'].call(_context, compute_list, push_constant)
		_pipelines['radix_sort_downsweep'].call(_context, compute_list, push_constant, [], _descriptors['grid_dimensions'].rid, 0)
	_context.compute_list_end()
	_context.device.capture_timestamp('Sort')

	# === BOUNDARIES ===
	compute_list = _context.compute_list_begin()
	_pipelines['gsplat_boundaries'].call(_context, compute_list, [], [], _descriptors['grid_dimensions'].rid, 3 * 4)
	_context.compute_list_end()
	_context.device.capture_timestamp('Boundaries')

	# === RENDER ===
	compute_list = _context.compute_list_begin()
	_pipelines['gsplat_render'].call(_context, compute_list, RenderContextScript.create_push_constant([float(enable_heatmap), -1]))
	_context.compute_list_end()
	_context.device.capture_timestamp('Render')

	# Process pending splat position query
	if _pending_splat_query.x >= 0:
		var tile: Vector2i = Vector2i(Vector2(_pending_splat_query) * render_scale) / TILE_SIZE
		var tile_id := tile.y * _tile_dims.x + tile.x
		compute_list = _context.compute_list_begin()
		_pipelines['gsplat_render'].call(_context, compute_list, RenderContextScript.create_push_constant([float(enable_heatmap), tile_id]))
		_context.compute_list_end()
		var splat_data = _context.device.buffer_get_data(_descriptors['tile_splat_pos'].rid, 0, 4 * 4).to_float32_array()
		last_splat_position = Vector3.INF if splat_data[3] == 0 else Vector3(-splat_data[0], -splat_data[1], splat_data[2])
		_pending_splat_query = Vector2i(-1, -1)

	_collect_debug_info()

func _build_camera_push_constants(view: Projection, proj: Projection) -> PackedByteArray:
	return RenderContextScript.create_push_constant([
		# --- View Matrix ---
		-view.x[0],  view.y[0], -view.z[0], 0.0,
		-view.x[1],  view.y[1], -view.z[1], 0.0,
		 view.x[2], -view.y[2],  view.z[2], 0.0,
		-view.w.dot(view.x), -view.w.dot(-view.y), -view.w.dot(view.z), 1.0,
		# --- Projection Matrix ---
		proj.x[0], proj.x[1], proj.x[2], 0.0,
		proj.y[0], proj.y[1], proj.y[2], 0.0,
		proj.z[0], proj.z[1], proj.z[2], -1.0,
		proj.w[0], proj.w[1], proj.w[2], 0.0])

func _init_gpu() -> void:
	_context = RenderContextScript.create(RenderingServer.get_rendering_device())

	_shaders['projection'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/gsplat_projection.glsl')
	_shaders['upsweep'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/radix_sort_upsweep.glsl')
	_shaders['spine'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/radix_sort_spine.glsl')
	_shaders['downsweep'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/radix_sort_downsweep.glsl')
	_shaders['boundaries'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/gsplat_boundaries.glsl')
	_shaders['render'] = _context.load_shader('res://addons/gaussian-splatting/shaders/compute/gsplat_render.glsl')

func _rebuild_gpu() -> void:
	_needs_rebuild = false

	# Clean up old per-instance and shared resources
	if _descriptors.size() > 0:
		_context.deletion_queue.flush(_context.device)
		_context.shader_cache.clear()
		_shaders.clear()
		_pipelines.clear()
		_descriptors.clear()
		_instance_gpu_data.clear()
		# Reload shaders after flush
		_init_gpu()

	# Calculate total splats
	_total_splats = 0
	var valid_instances: Array = []
	for inst in _instances:
		if inst.point_cloud and inst.point_cloud.size > 0:
			valid_instances.append(inst)
			_total_splats += inst.point_cloud.size

	if _total_splats == 0:
		_render_texture.texture_rd_rid = RID()
		_depth_texture.texture_rd_rid = RID()
		return

	# Allocate shared buffers (sized by _total_splats)
	var num_sort_elements_max := _total_splats * 10
	var num_partitions := (num_sort_elements_max + PARTITION_SIZE - 1) / PARTITION_SIZE
	var block_dims: PackedInt32Array; block_dims.resize(2 * 3); block_dims.fill(1)

	_descriptors['culled_splats'] = _context.create_storage_buffer(_total_splats * 12 * 4)
	_descriptors['grid_dimensions'] = _context.create_storage_buffer(2 * 3 * 4, block_dims.to_byte_array(), RenderingDevice.STORAGE_BUFFER_USAGE_DISPATCH_INDIRECT)
	_descriptors['histogram'] = _context.create_storage_buffer(4 + (1 + 4 * RADIX + num_partitions * RADIX) * 4)
	_descriptors['sort_keys'] = _context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	_descriptors['sort_values'] = _context.create_storage_buffer(num_sort_elements_max * 4 * 2)
	_descriptors['tile_bounds'] = _context.create_storage_buffer(_tile_dims.x * _tile_dims.y * 2 * 4)
	_descriptors['tile_splat_pos'] = _context.create_storage_buffer(4 * 4)
	_descriptors['render_texture'] = _context.create_texture(_texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_descriptors['splat_depths'] = _context.create_storage_buffer(_total_splats * 4)
	_descriptors['render_depth'] = _context.create_texture(_texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

	# Per-instance: create splat buffers + projection descriptor sets + pipelines
	var splat_offset := 0
	for inst in valid_instances:
		var inst_size: int = inst.point_cloud.size
		var splat_buffer = _context.create_storage_buffer(inst_size * 60 * 4)
		var uniform_buffer = _context.create_uniform_buffer(8 * 4)

		var projection_set = _context.create_descriptor_set([
			splat_buffer,
			_descriptors['culled_splats'],
			_descriptors['histogram'],
			_descriptors['sort_keys'],
			_descriptors['sort_values'],
			_descriptors['grid_dimensions'],
			uniform_buffer,
			_descriptors['splat_depths']
		], _shaders['projection'], 0)

		var projection_pipeline = _context.create_pipeline(
			[ceili(inst_size / 256.0), 1, 1],
			[projection_set],
			_shaders['projection']
		)

		# If this instance was already loaded, mark it for re-upload
		var already_uploaded = inst.is_loaded and inst._splat_cpu_data.size() > 0
		if already_uploaded:
			inst._splat_data_ready = true

		_instance_gpu_data.append({
			"instance": inst,
			"splat_buffer_rid": splat_buffer.rid,
			"uniform_rid": uniform_buffer.rid,
			"projection_pipeline": projection_pipeline,
			"splat_offset": splat_offset,
			"size": inst_size,
			"uploaded": false
		})
		splat_offset += inst_size

	# Create shared sort/boundaries/render descriptor sets + pipelines
	var upsweep_set = _context.create_descriptor_set([_descriptors['histogram'], _descriptors['sort_keys']], _shaders['upsweep'], 0)
	var spine_set = _context.create_descriptor_set([_descriptors['histogram']], _shaders['spine'], 0)
	var downsweep_set = _context.create_descriptor_set([_descriptors['histogram'], _descriptors['sort_keys'], _descriptors['sort_values']], _shaders['downsweep'], 0)
	var boundaries_set = _context.create_descriptor_set([_descriptors['histogram'], _descriptors['sort_keys'], _descriptors['tile_bounds']], _shaders['boundaries'], 0)
	var render_set = _context.create_descriptor_set([
		_descriptors['culled_splats'],
		_descriptors['sort_values'],
		_descriptors['tile_bounds'],
		_descriptors['tile_splat_pos'],
		_descriptors['render_texture'],
		_descriptors['splat_depths'],
		_descriptors['render_depth']
	], _shaders['render'], 0)

	_pipelines['radix_sort_upsweep'] = _context.create_pipeline([], [upsweep_set], _shaders['upsweep'])
	_pipelines['radix_sort_spine'] = _context.create_pipeline([RADIX, 1, 1], [spine_set], _shaders['spine'])
	_pipelines['radix_sort_downsweep'] = _context.create_pipeline([], [downsweep_set], _shaders['downsweep'])
	_pipelines['gsplat_boundaries'] = _context.create_pipeline([], [boundaries_set], _shaders['boundaries'])
	_pipelines['gsplat_render'] = _context.create_pipeline([_tile_dims.x, _tile_dims.y, 1], [render_set], _shaders['render'])

	_render_texture.texture_rd_rid = _descriptors['render_texture'].rid
	_depth_texture.texture_rd_rid = _descriptors['render_depth'].rid

func _resize_gpu() -> void:
	_needs_resize = false

	if not _descriptors.has('tile_bounds') or not _context: return

	# Update texture size from current viewport
	_texture_size = Vector2i((Vector2(_prev_viewport_size) * render_scale).max(Vector2.ONE))
	_tile_dims = (_texture_size + Vector2i.ONE * (TILE_SIZE - 1)) / TILE_SIZE

	if _total_splats == 0: return

	# Need to create new Texture2DRD instances (Godot quirk)
	_render_texture = Texture2DRD.new()
	_depth_texture = Texture2DRD.new()
	_display_material.set_shader_parameter('render_texture', _render_texture)
	_display_material.set_shader_parameter('depth_texture', _depth_texture)

	_context.deletion_queue.free_rid(_context.device, _descriptors['tile_bounds'].rid)
	_context.deletion_queue.free_rid(_context.device, _descriptors['render_texture'].rid)
	_context.deletion_queue.free_rid(_context.device, _descriptors['render_depth'].rid)

	_descriptors['tile_bounds'] = _context.create_storage_buffer(_tile_dims.x * _tile_dims.y * 2 * 4)
	_descriptors['render_texture'] = _context.create_texture(_texture_size, RenderingDevice.DATA_FORMAT_R32G32B32A32_SFLOAT)
	_descriptors['render_depth'] = _context.create_texture(_texture_size, RenderingDevice.DATA_FORMAT_R32_SFLOAT)

	var boundaries_set = _context.create_descriptor_set([_descriptors['histogram'], _descriptors['sort_keys'], _descriptors['tile_bounds']], _shaders['boundaries'], 0)
	var render_set = _context.create_descriptor_set([
		_descriptors['culled_splats'],
		_descriptors['sort_values'],
		_descriptors['tile_bounds'],
		_descriptors['tile_splat_pos'],
		_descriptors['render_texture'],
		_descriptors['splat_depths'],
		_descriptors['render_depth']
	], _shaders['render'], 0)

	_pipelines['gsplat_boundaries'] = _context.create_pipeline([], [boundaries_set], _shaders['boundaries'])
	_pipelines['gsplat_render'] = _context.create_pipeline([_tile_dims.x, _tile_dims.y, 1], [render_set], _shaders['render'])

	_render_texture.texture_rd_rid = _descriptors['render_texture'].rid
	_depth_texture.texture_rd_rid = _descriptors['render_depth'].rid

func _collect_debug_info() -> void:
	if _descriptors.has('histogram'):
		cached_num_rendered_splats = _context.device.buffer_get_data(_descriptors['histogram'].rid, 0, 4).decode_u32(0)
	cached_vram_bytes = _context.device.get_memory_usage(RenderingDevice.MEMORY_TOTAL)
	var timestamp_count = _context.device.get_captured_timestamps_count()
	if timestamp_count > 0:
		cached_timings.clear()
		var previous_time = _context.device.get_captured_timestamp_gpu_time(0)
		for i in range(1, timestamp_count):
			var timestamp_time = _context.device.get_captured_timestamp_gpu_time(i)
			cached_timings.append({
				"name": _context.device.get_captured_timestamp_name(i),
				"time_ms": (timestamp_time - previous_time) * 1e-6
			})
			previous_time = timestamp_time

func _notification(what) -> void:
	if what == NOTIFICATION_PREDELETE:
		# Defer GPU cleanup to render thread to avoid freeing RIDs from wrong thread
		if _context:
			_pending_cleanup = true
			RenderingServer.call_on_render_thread(_cleanup_gpu)
		if _render_texture: _render_texture.texture_rd_rid = RID()
		if _depth_texture: _depth_texture.texture_rd_rid = RID()

func _cleanup_gpu() -> void:
	if _context:
		_context.deletion_queue.flush(_context.device)
		_context.shader_cache.clear()
