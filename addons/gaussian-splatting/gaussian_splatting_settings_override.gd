@tool
extends Node

@export_range(0.0, 1.0, 0.01) var render_scale: float = 1.0:
	set(v):
		render_scale = v
		_apply()

@export_range(0.0, 1.0, 0.01) var discard_alpha: float = 0.6:
	set(v):
		discard_alpha = v
		_apply()

@export var enable_heatmap: bool = false:
	set(v):
		enable_heatmap = v
		_apply()

func _enter_tree() -> void:
	_apply()

func _apply() -> void:
	if not is_inside_tree(): return
	var server = get_node_or_null("/root/GaussianSplattingServer")
	if not server: return
	server.render_scale = render_scale
	server.discard_alpha = discard_alpha
	server.enable_heatmap = enable_heatmap
