extends Node3D

var xr_interface: XRInterface


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR")
	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		
		# The viewport now uses the XR frame clock
		get_viewport().use_xr = true
	else:
		push_error("Open XR not initialized - is the headset connected?")
