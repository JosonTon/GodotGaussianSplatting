@tool
extends Node3D

const PlyFileScript = preload("res://addons/gaussian-splatting/ply_file.gd")

signal loaded

@export_file("*.ply") var ply_path: String :
	set(value):
		if ply_path == value: return
		ply_path = value
		if is_inside_tree() and not ply_path.is_empty():
			_reload()

@export var center_at_origin := true

var point_cloud # PlyFile instance
var _splat_cpu_data := PackedFloat32Array()
var _splat_data_ready := false
var _load_thread := Thread.new()
var _should_terminate: Array[bool] = [false]
var num_splats_loaded: Array[int] = [0]
var is_loaded := false

func _enter_tree() -> void:
	if not ply_path.is_empty():
		_reload()

func _exit_tree() -> void:
	_terminate_load_thread()
	if Engine.has_singleton("GaussianSplattingServer") or has_node("/root/GaussianSplattingServer"):
		var server = _get_server()
		if server: server.unregister_instance(self)

func _reload() -> void:
	_terminate_load_thread()

	var path := ply_path
	# Handle both res:// paths and absolute paths
	if not path.begins_with("res://") and not path.begins_with("user://"):
		# Absolute path from file drop
		pass

	point_cloud = PlyFileScript.new(path)
	if point_cloud.size == 0: return

	_should_terminate[0] = false
	num_splats_loaded[0] = 0
	_splat_data_ready = false
	is_loaded = false
	_splat_cpu_data.resize(point_cloud.size * 60)
	_splat_cpu_data.fill(0)

	_load_thread.start(PlyFileScript.load_gaussian_splats.bind(
		point_cloud,
		maxi(point_cloud.size / 1000, 1),
		_splat_cpu_data,
		_should_terminate,
		num_splats_loaded,
		center_at_origin,
		_on_splat_load_complete
	))

	var server = _get_server()
	if server: server.register_instance(self)

func _terminate_load_thread() -> void:
	_should_terminate[0] = true
	if _load_thread.is_started():
		_load_thread.wait_to_finish()

func _on_splat_load_complete() -> void:
	_splat_data_ready = true

func _get_server():
	if has_node("/root/GaussianSplattingServer"):
		return get_node("/root/GaussianSplattingServer")
	return null
