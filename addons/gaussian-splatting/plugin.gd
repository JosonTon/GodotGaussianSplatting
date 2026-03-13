@tool
extends EditorPlugin

const GaussianSplattingScript = preload("res://addons/gaussian-splatting/gaussian_splatting.gd")
const SettingsOverrideScript = preload("res://addons/gaussian-splatting/gaussian_splatting_settings_override.gd")
const GaussianSplattingIcon = preload("res://addons/gaussian-splatting/icons/gaussian_splatting.svg")
const SettingsOverrideIcon = preload("res://addons/gaussian-splatting/icons/settings_override.svg")

func _enter_tree() -> void:
	add_autoload_singleton("GaussianSplattingServer", "res://addons/gaussian-splatting/gaussian_splatting_server.gd")
	add_custom_type("GaussianSplatting", "Node3D", GaussianSplattingScript, GaussianSplattingIcon)
	add_custom_type("GaussianSplattingServerSettingsOverride", "Node", SettingsOverrideScript, SettingsOverrideIcon)

func _exit_tree() -> void:
	remove_autoload_singleton("GaussianSplattingServer")
	remove_custom_type("GaussianSplatting")
	remove_custom_type("GaussianSplattingServerSettingsOverride")
