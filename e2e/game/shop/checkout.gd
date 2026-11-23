extends Node

var cart = null


func _ready() -> void:
	var mode := mode()
	print("mode: ", mode)
	match mode:
		"error":
			push_warning("Coupon SPRING expired")
			add_to_cart("sword")
			push_error("Payment provider slow")
			Zharp.capture_error("Save failed: disk full", {"slot": 2})
			get_node("Missing")
			Zharp.log_info("Checkout opened", {"items": 3})
			var span := Zharp.start_span("load_inventory", {"items": 3})
			Zharp.request($HTTPRequest, "http://localhost:4318/scores.json?api_key=secret", PackedStringArray(["Authorization: Bearer abc", "Accept: application/json"]))
			await $HTTPRequest.request_completed
			span.end()
		"logs":
			print("Player bought a sword")
			printerr("Low on gold")
		"hang":
			await get_tree().process_frame
			OS.delay_msec(7000)
		"crash":
			await get_tree().process_frame
			explode()
		"offline", "after":
			pass
	await finish()


func add_to_cart(item: String) -> void:
	cart.append(item)


func explode() -> void:
	OS.crash("Inventory corrupted")


static func mode() -> String:
	if OS.has_feature("web"):
		return "error"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--mode="):
			return arg.trim_prefix("--mode=")
	return "after"


func finish() -> void:
	Zharp.flush()
	var deadline := Time.get_ticks_msec() + 8000
	while Time.get_ticks_msec() < deadline:
		await get_tree().create_timer(0.2).timeout
		if Zharp._transport == null or Zharp._transport.pending() == 0:
			break
		Zharp.flush()
	print("done; waiting: ", Zharp._transport.pending() if Zharp._transport != null else -1)
	get_tree().quit()
