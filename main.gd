@tool
extends Node

const DEFAULT_SPLAT_PLY_FILE := 'res://resources/demo.ply'

@onready var viewport : Variant = Engine.get_singleton('EditorInterface').get_editor_viewport_3d(0) if Engine.is_editor_hint() else get_viewport()
@onready var camera : Variant = viewport.get_camera_3d()
@onready var camera_fov := [camera.fov]

var gs_node: Node3D
var loaded_file : String
var num_rendered_splats := '0'
var video_memory_used := '0.00MB'
var timings : PackedStringArray
var should_render_imgui := true
var should_allow_render_pause := [true]
var frag_discard_threshold := [0.6]
var render_scale_arr := [1.0]
var model_scale_arr := [1.0]
var enable_heatmap_arr := [false]

func _init() -> void:
	DisplayServer.window_set_size(DisplayServer.screen_get_size() * 0.75)
	DisplayServer.window_set_position(DisplayServer.screen_get_size() * 0.25 / 2.0)

func _ready() -> void:
	gs_node = get_node_or_null("GaussianSplatting")
	if gs_node:
		loaded_file = gs_node.ply_path.get_file()

	viewport.size_changed.connect(_on_viewport_resized)
	if Engine.is_editor_hint(): return
	viewport.files_dropped.connect(func(files : PackedStringArray):
		if files[0].ends_with('.ply') and gs_node:
			gs_node.ply_path = files[0]
			loaded_file = files[0].get_file()
			camera.reset()
			$LoadingBar.set_visibility(true)
			gs_node.loaded.connect($LoadingBar.set_visibility.bind(false), CONNECT_ONE_SHOT))
	$UpdateDebugTimer.timeout.connect(update_debug_info)
	$PauseTimer.timeout.connect(update_debug_info)

	if gs_node and not gs_node.is_loaded:
		$LoadingBar.set_visibility(true)
		gs_node.loaded.connect($LoadingBar.set_visibility.bind(false), CONNECT_ONE_SHOT)

func _render_imgui() -> void:
	var server = get_node_or_null("/root/GaussianSplattingServer")
	if not server: return

	var fps := Engine.get_frames_per_second()
	var is_paused : bool = $PauseTimer.is_stopped() and should_allow_render_pause[0]

	ImGui.Begin(' ', [], ImGui.WindowFlags_AlwaysAutoResize | ImGui.WindowFlags_NoMove)
	ImGui.SetWindowPos(Vector2(20, 20))
	ImGui.PushItemWidth(ImGui.GetWindowWidth() * 0.6);
	ImGui.Text('Drag and drop .ply files on the window to load!')

	ImGui.SeparatorText('GaussianSplatting')
	ImGui.Text('FPS:             %d (%s)' % [fps, '%.2fms' % (1e3 / fps) if not is_paused else 'paused'])
	ImGui.Text('Loaded File:     %s' % ['(loading...)' if gs_node and not gs_node.is_loaded else loaded_file])
	ImGui.Text('VRAM Used:       %s' % video_memory_used)
	ImGui.Text('Rendered Splats: %s' % num_rendered_splats)
	ImGui.Text('Rendered Size:   %.0v' % Vector2(_get_texture_size()))
	ImGui.Text('Allow Pause:    '); ImGui.SameLine(); ImGui.Checkbox('##pause_bool', should_allow_render_pause)
	ImGui.Text('Enable Heatmap: '); ImGui.SameLine()
	if ImGui.Checkbox('##heatmap_bool', enable_heatmap_arr):
		server.enable_heatmap = enable_heatmap_arr[0]
	ImGui.Text('Render Scale:   '); ImGui.SameLine()
	if ImGui.SliderFloat('##render_scale_float', render_scale_arr, 0.05, 1.5):
		server.render_scale = render_scale_arr[0]
		_on_viewport_resized()
	ImGui.Text('Model Scale:    '); ImGui.SameLine()
	if ImGui.SliderFloat('##model_scale_float', model_scale_arr, 0.25, 5.0):
		if gs_node: gs_node.scale = Vector3.ONE * model_scale_arr[0]
	ImGui.Text('Discard Alpha:  '); ImGui.SameLine()
	if ImGui.SliderFloat('##discard_float', frag_discard_threshold, 0.0, 1.0):
		server.discard_alpha = frag_discard_threshold[0]

	ImGui.SeparatorText('Stage Timings')
	for i in len(timings):
		ImGui.Text(timings[i])

	ImGui.SeparatorText('Camera')
	ImGui.Text('Cursor Position: %+.2v' % $Camera/Cursor.global_position)
	ImGui.Text('Camera Position: %+.2v' % camera.global_position)
	ImGui.Text('Camera Mode:     %s' % FreeLookCamera.RotationMode.keys()[camera.rotation_mode].capitalize())
	ImGui.Text('Camera FOV:     '); ImGui.SameLine(); if ImGui.SliderFloat('##fov_float', camera_fov, 20, 170): camera.fov = camera_fov[0]

	ImGui.Dummy(Vector2(0,0)); ImGui.Separator(); ImGui.Dummy(Vector2(0,0))
	ImGui.PushStyleColor(ImGui.Col_Text, Color.WEB_GRAY);
	ImGui.Text('Press %s-H to toggle GUI visibility!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']);
	ImGui.Text('Press %s-F to toggle fullscreen!' % ['Cmd' if OS.get_name() == 'macOS' else 'Ctrl']);
	ImGui.PopStyleColor()
	ImGui.End()

func _input(event: InputEvent) -> void:
	if event.is_action_pressed('toggle_imgui'):
		should_render_imgui = not should_render_imgui
		$Camera/Cursor.visible = should_render_imgui
		$LoadingBar.visible = should_render_imgui
	elif event.is_action_pressed('toggle_fullscreen'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN if DisplayServer.window_get_mode() == DisplayServer.WINDOW_MODE_WINDOWED else DisplayServer.WINDOW_MODE_WINDOWED)
	elif event.is_action_pressed('ui_cancel'):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
	elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed and camera.rotation_mode == FreeLookCamera.RotationMode.NONE:
			var server = get_node_or_null("/root/GaussianSplattingServer")
			if server: server.request_splat_position(event.position)

func update_debug_info() -> void:
	var server = get_node_or_null("/root/GaussianSplattingServer")
	if not server or not server._context: return

	### Update Total Duplicated Splats ###
	var num_splats = server.cached_num_rendered_splats
	var total_splats = server._total_splats
	num_rendered_splats = add_number_separator(num_splats) + (' (buffer overflow!)' if total_splats > 0 and num_splats > total_splats * 10 else '')

	### Update VRAM Used ###
	var vram_bytes = server.cached_vram_bytes
	video_memory_used = '%.2f%s' % [vram_bytes * (1e-6 if vram_bytes < 1e9 else 1e-9), 'MB' if vram_bytes < 1e9 else 'GB']

	### Update Pipeline Timestamps ###
	var is_paused : bool = $PauseTimer.is_stopped() and should_allow_render_pause[0]
	var cached = server.cached_timings
	if cached.size() > 0:
		timings = PackedStringArray(); timings.resize(cached.size() + 1)
		var total_time_ms := 0.0
		for i in cached.size():
			total_time_ms += cached[i]["time_ms"]
		for i in cached.size():
			var stage_time_ms : float = cached[i]["time_ms"]
			var gpu_time_percentage_text := ('%5.2f%%' % (stage_time_ms/total_time_ms*1e2)) if not is_paused else 'paused'
			timings[i] = '%-16s %.2fms (%s)' % [str(cached[i]["name"]) + ':', stage_time_ms, gpu_time_percentage_text]
		timings[-1] = 'Total GPU Time:  %.2fms' % total_time_ms

func _on_viewport_resized() -> void:
	# Server handles resize internally
	pass

func _get_texture_size() -> Vector2i:
	var server = get_node_or_null("/root/GaussianSplattingServer")
	if server: return server._texture_size
	return viewport.size

func _process(delta: float) -> void:
	var server = get_node_or_null("/root/GaussianSplattingServer")

	if not Engine.is_editor_hint():
		if should_render_imgui:
			_render_imgui()
		camera.enable_camera_movement = not (ImGui.IsWindowHovered(ImGui.HoveredFlags_AnyWindow) or ImGui.IsAnyItemActive())
		if gs_node and gs_node.point_cloud:
			$LoadingBar.update_progress(float(gs_node.num_splats_loaded[0]) / float(gs_node.point_cloud.size))

		# Check for async splat position query result
		if server and server.last_splat_position != Vector3.INF and server._pending_splat_query == Vector2i(-1, -1):
			var pos = server.last_splat_position
			server.last_splat_position = Vector3.INF
			camera.set_focused_position(pos)

	# Pause timer logic
	var any_loading = gs_node and gs_node.point_cloud and not gs_node.is_loaded
	var has_camera_moved = camera.global_transform != _prev_cam_transform or camera.get_camera_projection() != _prev_cam_proj
	_prev_cam_transform = camera.global_transform
	_prev_cam_proj = camera.get_camera_projection()

	if not any_loading and not has_camera_moved:
		pass # Let pause timer run
	else:
		$PauseTimer.start()

	var is_paused : bool = $PauseTimer.is_stopped() and should_allow_render_pause[0]
	Engine.max_fps = 30 if is_paused else 144

var _prev_cam_transform := Transform3D()
var _prev_cam_proj := Projection()

## Source: https://reddit.com/r/godot/comments/yljjmd/comment/iuz0x43/
static func add_number_separator(number : int, separator : String = ',') -> String:
	var in_str := str(number)
	var out_chars := PackedStringArray()
	var length := in_str.length()
	for i in range(1, length + 1):
		out_chars.append(in_str[length - i])
		if i < length and i % 3 == 0:
			out_chars.append(separator)
	out_chars.reverse()
	return ''.join(out_chars)
