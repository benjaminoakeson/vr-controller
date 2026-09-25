extends Node3D

const BASELINE_REFRESH_RATE: float = 72.0

var xr_interface: OpenXRInterface


func _ready() -> void:
	xr_interface = XRServer.find_interface("OpenXR") as OpenXRInterface
	if xr_interface and xr_interface.is_initialized():
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		xr_interface.session_begun.connect(_on_session_begun)
		xr_interface.refresh_rate_changed.connect(_sync_physics_rate)

		# The viewport now uses the XR frame clock
		get_viewport().use_xr = true
		# The rig may be loaded after the runtime has already begun its session.
		var state := xr_interface.get_session_state()
		if state >= OpenXRInterface.SESSION_STATE_READY and state <= OpenXRInterface.SESSION_STATE_FOCUSED:
			_on_session_begun()
	else:
		push_error("Open XR not initialized - is the headset connected?")


func _on_session_begun() -> void:
	# Refresh-rate capabilities are only available once the session begins.
	_sync_physics_rate(xr_interface.get_display_refresh_rate())
	for rate in xr_interface.get_available_display_refresh_rates():
		if is_equal_approx(float(rate), BASELINE_REFRESH_RATE):
			xr_interface.set_display_refresh_rate(BASELINE_REFRESH_RATE)
			# A request can be asynchronous or rejected. Use the reported rate,
			# then follow refresh_rate_changed when the runtime confirms a change.
			_sync_physics_rate(xr_interface.get_display_refresh_rate())
			return
	push_warning("OpenXR: 72 Hz is unavailable; using the reported display rate for physics.")


func _sync_physics_rate(refresh_rate: float) -> void:
	if not is_finite(refresh_rate) or refresh_rate <= 0.0:
		Engine.physics_ticks_per_second = int(BASELINE_REFRESH_RATE)
		push_warning("OpenXR: Display rate unknown; keeping the 72 Hz physics baseline.")
		return
	Engine.physics_ticks_per_second = maxi(1, roundi(refresh_rate))
	print("OpenXR: Display %.2f Hz; physics %d ticks/s." % [refresh_rate, Engine.physics_ticks_per_second])
