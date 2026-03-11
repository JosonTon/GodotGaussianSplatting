@tool
extends EditorPlugin

const GaussianSplattingScript = preload("res://addons/gaussian-splatting/gaussian_splatting.gd")
const SettingsOverrideScript = preload("res://addons/gaussian-splatting/gaussian_splatting_settings_override.gd")

func _enter_tree() -> void:
	add_autoload_singleton("GaussianSplattingServer", "res://addons/gaussian-splatting/gaussian_splatting_server.gd")
	add_custom_type("GaussianSplatting", "Node3D", GaussianSplattingScript, null)
	add_custom_type("GaussianSplattingServerSettingsOverride", "Node", SettingsOverrideScript, null)

func _exit_tree() -> void:
	remove_autoload_singleton("GaussianSplattingServer")
	remove_custom_type("GaussianSplatting")
	remove_custom_type("GaussianSplattingServerSettingsOverride")
