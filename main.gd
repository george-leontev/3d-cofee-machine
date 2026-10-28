extends Node3D
# Кофейный автомат в 3D. Всё строится кодом: корпус, панель, кнопки, отсек с чашкой, свет и камера.
# Мышь: навёл на кнопку - она подсвечивается, клик - нажатие. Движение мыши слегка поворачивает камеру,
# колесо мыши приближает и отдаляет автомат.

enum State { IDLE, BREWING, DONE, TAKING }

# price - цена, time - секунд на приготовление,
# coffee/milk - доли кофе и молока в чашке, color - цвет кофе, btn - цвет кнопки
const DRINKS := {
	"Эспрессо": {"price": 50, "time": 3.0, "coffee": 1.0, "milk": 0.0, "color": Color(0.20, 0.10, 0.04), "btn": Color(0.36, 0.20, 0.10)},
	"Американо": {"price": 60, "time": 3.5, "coffee": 1.0, "milk": 0.0, "color": Color(0.35, 0.20, 0.09), "btn": Color(0.46, 0.28, 0.14)},
	"Капучино": {"price": 90, "time": 4.5, "coffee": 0.5, "milk": 0.5, "color": Color(0.30, 0.16, 0.07), "btn": Color(0.58, 0.38, 0.20)},
	"Латте": {"price": 100, "time": 5.0, "coffee": 0.3, "milk": 0.7, "color": Color(0.30, 0.16, 0.07), "btn": Color(0.68, 0.48, 0.28)},
}
const MILK_COLOR := Color(0.80, 0.70, 0.56)
const FOAM_COLOR := Color(0.90, 0.82, 0.70)
const SCREEN_GREEN := Color(0.45, 1.0, 0.55)
const SCREEN_RED := Color(1.0, 0.40, 0.35)
const LED_IDLE := Color(0.30, 1.0, 0.45)
const LED_BREW := Color(1.0, 0.65, 0.20)
const LED_DONE := Color(0.40, 0.80, 1.0)

const SCREEN_LABEL_POS := Vector3(0.0, 1.885, 0.428)
const CUP_BASE := Vector3(0.0, 0.553, 0.05)   # низ чашки
const CUP_H := 0.24
const CUP_R := 0.095
const LIQ_R := 0.087
const LIQ_Y0 := 0.012
const LIQ_H := 0.215
const NOZZLE_TIP_Y := 1.02
const DOOR_CLOSED_Y := 0.85
const DOOR_OPEN_Y := 1.75
const CAM_TARGET := Vector3(0.0, 1.15, 0.0)

var state: State = State.IDLE
var balance := 0
var shown_balance := 0.0
var last_shown := -1
var current := ""
var progress := 0.0
var brew_time := 1.0

var machine: Node3D
var camera: Camera3D
var cam_dist := 3.7
var cam_intro_yaw := 0.0
var cam_yaw := 0.0
var cam_pitch := 0.0
var zoom := 1.0
var zoom_target := 1.0

var buttons: Array[Dictionary] = []
var hover_idx := -1

var screen_label: Label3D
var balance_label: Label3D
var bar_pivot: Node3D
var led_mat: StandardMaterial3D
var sign_mat: StandardMaterial3D
var head_mat: StandardMaterial3D
var coin_mat: StandardMaterial3D
var niche_light: OmniLight3D
var door: Node3D
var door_tween: Tween
var cup: Node3D
var coffee_node: MeshInstance3D
var milk_node: MeshInstance3D
var foam_node: MeshInstance3D
var coffee_mat: StandardMaterial3D
var stream: MeshInstance3D
var stream_mat: StandardMaterial3D
var splash: CPUParticles3D
var splash_mat: StandardMaterial3D
var steam: CPUParticles3D


func _ready() -> void:
	_build_environment()
	_build_room()
	machine = Node3D.new()
	add_child(machine)
	_build_machine()
	_build_camera()
	_set_screen("Внесите деньги")
	_refresh()
	_update_cup()
	# вступление: камера плавно подъезжает и разворачивается
	cam_dist = 8.0
	cam_intro_yaw = 0.7
	var tw := create_tween().set_parallel(true)
	tw.tween_property(self, "cam_dist", 3.7, 1.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(self, "cam_intro_yaw", 0.0, 1.8).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _process(delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if state == State.BREWING:
		progress = minf(progress + delta / brew_time, 1.0)
		bar_pivot.scale.x = maxf(0.84 * progress, 0.0001)
		bar_pivot.visible = progress > 0.002
		_update_cup()
		if progress >= 1.0:
			_finish_brewing()
	_animate(t, delta)
	_update_balance(delta)
	_update_camera(delta)


func _physics_process(_delta: float) -> void:
	_update_hover()


func _unhandled_input(event: InputEvent) -> void:
	var mb := event as InputEventMouseButton
	if mb == null or not mb.pressed:
		return
	if mb.button_index == MOUSE_BUTTON_LEFT:
		var idx := _pick(mb.position)
		if idx >= 0:
			_activate(idx)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_UP:
		zoom_target = clampf(zoom_target - 0.08, 0.6, 1.5)
	elif mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		zoom_target = clampf(zoom_target + 0.08, 0.6, 1.5)


# ---------- Логика ----------

func _activate(idx: int) -> void:
	var b: Dictionary = buttons[idx]
	if not b["enabled"]:
		_shake(b)
		return
	_press_anim(b)
	match b["action"]:
		"drink":
			if not _on_drink(b["arg"]):
				_shake(b)
		"coin":
			_add_money(b["arg"])
			_drop_coin(b)
		"refund":
			_on_refund()
		"take":
			_on_take()


func _add_money(amount: int) -> void:
	if state != State.IDLE:
		return
	balance += amount
	_set_screen("Выберите напиток")
	_refresh()


func _on_drink(drink_name: String) -> bool:
	if state != State.IDLE:
		return false
	var d: Dictionary = DRINKS[drink_name]
	if balance < d["price"]:
		_set_screen("Не хватает денег: нужно %d ₽" % d["price"], SCREEN_RED)
		return false
	balance -= d["price"]
	current = drink_name
	brew_time = d["time"]
	progress = 0.0
	state = State.BREWING
	coffee_mat.albedo_color = d["color"]
	bar_pivot.scale.x = 0.0001
	_set_screen("Готовим: %s..." % drink_name)
	_refresh()
	_update_cup()
	return true


func _finish_brewing() -> void:
	state = State.DONE
	steam.emitting = true
	_move_door(true)
	_set_screen("%s готов! Заберите чашку" % current)
	_refresh()
	_update_cup()


func _on_take() -> void:
	if state != State.DONE:
		return
	state = State.TAKING
	steam.emitting = false
	_set_screen("Приятного аппетита!")
	_refresh()
	# чашка выезжает к нам, уменьшается и исчезает
	var tw := create_tween()
	tw.tween_property(cup, "position", CUP_BASE + Vector3(0.0, 0.22, 0.55), 0.5) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(cup, "scale", Vector3.ONE * 0.02, 0.2).set_ease(Tween.EASE_IN)
	tw.tween_callback(_cup_taken)


func _cup_taken() -> void:
	cup.visible = false
	progress = 0.0
	current = ""
	bar_pivot.visible = false
	_update_cup()
	# новая пустая чашка выезжает из задней стенки, дверца закрывается
	cup.scale = Vector3.ONE
	cup.position = CUP_BASE + Vector3(0.0, 0.0, -0.45)
	cup.visible = true
	_move_door(false)
	var tw := create_tween()
	tw.tween_property(cup, "position", CUP_BASE, 0.55).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_interval(0.3)
	tw.tween_callback(_take_finished)


func _take_finished() -> void:
	state = State.IDLE
	_set_screen("Спасибо! Внесите деньги" if balance == 0 else "Выберите напиток")
	_refresh()


func _on_refund() -> void:
	if state != State.IDLE or balance == 0:
		return
	_set_screen("Выдана сдача: %d ₽" % balance)
	balance = 0
	_refresh()


# ---------- Обновление вида ----------

func _set_screen(text: String, col: Color = SCREEN_GREEN) -> void:
	screen_label.text = text
	screen_label.modulate = Color(col, 0.0)
	screen_label.position = SCREEN_LABEL_POS + Vector3(0.0, -0.012, 0.0)
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(screen_label, "modulate", col, 0.28)
	tw.tween_property(screen_label, "position", SCREEN_LABEL_POS, 0.28)


func _refresh() -> void:
	for b in buttons:
		var en := false
		match b["action"]:
			"drink", "coin":
				en = state == State.IDLE
			"refund":
				en = state == State.IDLE and balance > 0
			"take":
				en = state == State.DONE
		_set_enabled(b, en)
	var c := LED_IDLE
	match state:
		State.BREWING:
			c = LED_BREW
		State.DONE:
			c = LED_DONE
		State.TAKING:
			c = LED_BREW
	var tw := create_tween().set_parallel(true)
	tw.tween_property(led_mat, "albedo_color", c, 0.3)
	tw.tween_property(led_mat, "emission", c, 0.3)
	_update_cursor()


func _update_balance(delta: float) -> void:
	shown_balance = lerpf(shown_balance, float(balance), 1.0 - exp(-9.0 * delta))
	if absf(shown_balance - float(balance)) < 0.5:
		shown_balance = float(balance)
	var v := roundi(shown_balance)
	if v != last_shown:
		last_shown = v
		balance_label.text = "Баланс: %d ₽" % v


func _update_camera(delta: float) -> void:
	var vp := get_viewport()
	var vs := vp.get_visible_rect().size
	var mp := vp.get_mouse_position()
	var nx := clampf(mp.x / maxf(vs.x, 1.0) - 0.5, -0.5, 0.5)
	var ny := clampf(mp.y / maxf(vs.y, 1.0) - 0.5, -0.5, 0.5)
	var k := 1.0 - exp(-4.0 * delta)
	cam_yaw = lerpf(cam_yaw, nx * 0.7, k)
	cam_pitch = lerpf(cam_pitch, 0.12 - ny * 0.22, k)
	zoom = lerpf(zoom, zoom_target, 1.0 - exp(-8.0 * delta))
	var rot := Basis(Vector3.UP, cam_yaw + cam_intro_yaw) * Basis(Vector3.RIGHT, -cam_pitch)
	camera.position = CAM_TARGET + rot * Vector3(0.0, 0.0, cam_dist * zoom)
	camera.look_at(CAM_TARGET, Vector3.UP)


func _animate(t: float, delta: float) -> void:
	var brewing := state == State.BREWING
	# лампочка и вывеска
	var pulse := 1.0
	if brewing:
		pulse = 0.6 + 0.4 * sin(t * 9.0)
	led_mat.emission_energy_multiplier = 1.6 * pulse
	sign_mat.emission_energy_multiplier = 0.45 + 0.05 * sin(t * 1.7)
	# индикатор на дозаторе
	head_mat.emission_energy_multiplier = (1.0 + 0.8 * sin(t * 10.0)) if brewing else 0.2
	# автомат слегка вибрирует, пока готовит
	machine.position.x = sin(t * 55.0) * 0.0007 if brewing else 0.0
	# свет в отсеке становится ярче при приготовлении
	var target_energy := 1.5 if brewing else 0.8
	niche_light.light_energy = lerpf(niche_light.light_energy, target_energy, 1.0 - exp(-5.0 * delta))


func _set_layer(node: MeshInstance3D, y0: float, h: float) -> void:
	if h < 0.0005:
		node.visible = false
		return
	node.visible = true
	node.scale = Vector3(1.0, h, 1.0)
	node.position = Vector3(0.0, y0 + h / 2.0, 0.0)


func _update_cup() -> void:
	var coffee_share := 1.0
	var milk_share := 0.0
	if current != "":
		coffee_share = DRINKS[current]["coffee"]
		milk_share = DRINKS[current]["milk"]
	# сначала наливается кофе, потом молоко сверху
	var total_h := LIQ_H * progress * (coffee_share + milk_share)
	var coffee_h := minf(total_h, LIQ_H * coffee_share)
	var milk_h := maxf(total_h - coffee_h, 0.0)
	_set_layer(coffee_node, LIQ_Y0, coffee_h)
	_set_layer(milk_node, LIQ_Y0 + coffee_h, milk_h)
	if milk_h > 0.001:
		foam_node.visible = true
		foam_node.position = Vector3(0.0, LIQ_Y0 + total_h, 0.0)
	else:
		foam_node.visible = false
	# струя тянется от носика до поверхности жидкости
	var surface_y := cup.position.y + LIQ_Y0 + total_h
	var slen := maxf(NOZZLE_TIP_Y - surface_y, 0.01)
	var wob := 1.0 + 0.2 * sin(Time.get_ticks_msec() / 1000.0 * 28.0)
	stream.scale = Vector3(wob, slen, wob)
	stream.position = Vector3(0.0, NOZZLE_TIP_Y - slen / 2.0, CUP_BASE.z)
	var col: Color = MILK_COLOR if milk_h > 0.0 else coffee_mat.albedo_color
	stream_mat.albedo_color = col
	splash_mat.albedo_color = col
	var brewing := state == State.BREWING
	stream.visible = brewing
	splash.position = Vector3(0.0, surface_y + 0.003, CUP_BASE.z)
	splash.emitting = brewing


# ---------- Мышь, кнопки, анимации кнопок ----------

func _pick(pos: Vector2) -> int:
	if camera == null:
		return -1
	var from := camera.project_ray_origin(pos)
	var to := from + camera.project_ray_normal(pos) * 30.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	var hit := get_world_3d().direct_space_state.intersect_ray(query)
	if hit.is_empty():
		return -1
	var col: Object = hit["collider"]
	if col != null and col.has_meta("btn"):
		return int(col.get_meta("btn"))
	return -1


func _update_hover() -> void:
	var idx := _pick(get_viewport().get_mouse_position())
	if idx == hover_idx:
		return
	if hover_idx >= 0:
		buttons[hover_idx]["hover"] = false
		_apply_hover(buttons[hover_idx])
	hover_idx = idx
	if hover_idx >= 0:
		buttons[hover_idx]["hover"] = true
		_apply_hover(buttons[hover_idx])
	_update_cursor()


func _update_cursor() -> void:
	var can := hover_idx >= 0 and bool(buttons[hover_idx]["enabled"])
	Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if can else Input.CURSOR_ARROW)


func _apply_hover(b: Dictionary) -> void:
	var root: Node3D = b["root"]
	if root == null:
		return
	var on: bool = b["hover"] and b["enabled"]
	if b["htween"] != null and (b["htween"] as Tween).is_valid():
		(b["htween"] as Tween).kill()
	var tw := create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(root, "scale", Vector3.ONE * (1.07 if on else 1.0), 0.16)
	tw.tween_property(b["mat"], "emission_energy_multiplier", 0.55 if on else 0.0, 0.16)
	b["htween"] = tw


func _set_enabled(b: Dictionary, en: bool) -> void:
	if b["enabled"] == en:
		return
	b["enabled"] = en
	if b["mat"] != null:
		var base: Color = b["base_col"]
		var tcol: Color = b["text_col"]
		if b["ctween"] != null and (b["ctween"] as Tween).is_valid():
			(b["ctween"] as Tween).kill()
		var tw := create_tween().set_parallel(true)
		tw.tween_property(b["mat"], "albedo_color", base if en else base.darkened(0.6), 0.25)
		tw.tween_property(b["label"], "modulate", tcol if en else tcol.darkened(0.55), 0.25)
		b["ctween"] = tw
	_apply_hover(b)


func _press_anim(b: Dictionary) -> void:
	var root: Node3D = b["root"]
	if root == null:
		return
	var z0: float = b["base_z"]
	var tw := create_tween()
	tw.tween_property(root, "position:z", z0 - 0.014, 0.05).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(root, "position:z", z0, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _shake(b: Dictionary) -> void:
	var root: Node3D = b["root"]
	if root == null:
		return
	var x0: float = b["base_x"]
	var tw := create_tween()
	for dx in [0.012, -0.012, 0.008, -0.008, 0.0]:
		tw.tween_property(root, "position:x", x0 + dx, 0.04)


func _drop_coin(b: Dictionary) -> void:
	var root: Node3D = b["root"]
	var coin := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.028
	cm.bottom_radius = 0.028
	cm.height = 0.006
	coin.mesh = cm
	coin.material_override = coin_mat
	coin.rotation.x = PI / 2.0
	coin.position = root.position + Vector3(0.0, 0.07, 0.06)
	machine.add_child(coin)
	# монетка летит к щели и исчезает в ней
	var tw := create_tween()
	tw.tween_property(coin, "position", Vector3(0.34, 1.70, 0.43), 0.32) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(coin, "scale", Vector3.ONE * 0.1, 0.1)
	tw.tween_callback(coin.queue_free)
	var spin := create_tween()
	spin.tween_property(coin, "rotation:y", TAU * 1.5, 0.4)


func _move_door(open: bool) -> void:
	if door_tween != null and door_tween.is_valid():
		door_tween.kill()
	door_tween = create_tween()
	door_tween.tween_property(door, "position:y", DOOR_OPEN_Y if open else DOOR_CLOSED_Y, 0.75) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)


# ---------- Помощники построения ----------

func _mat(col: Color, metallic: float = 0.0, rough: float = 0.5) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = col
	m.metallic = metallic
	m.roughness = rough
	return m


func _emissive(m: StandardMaterial3D, col: Color, energy: float) -> StandardMaterial3D:
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = energy
	return m


func _glass(alpha: float) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.85, 0.92, 1.0, alpha)
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.roughness = 0.05
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _box(parent: Node3D, pos: Vector3, size: Vector3, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := BoxMesh.new()
	m.size = size
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, pos: Vector3, radius: float, height: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = radius
	m.bottom_radius = radius
	m.height = height
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _sphere(parent: Node3D, pos: Vector3, radius: float, mat: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	mi.mesh = m
	mi.material_override = mat
	mi.position = pos
	parent.add_child(mi)
	return mi


func _label3d(parent: Node3D, text: String, pos: Vector3, font_size: int, px: float, col: Color) -> Label3D:
	var l := Label3D.new()
	l.text = text
	l.position = pos
	l.font_size = font_size
	l.pixel_size = px
	l.modulate = col
	l.outline_size = 0
	l.shaded = false
	l.double_sided = false
	parent.add_child(l)
	return l


func _gradient_tex(c0: Color, c1: Color) -> GradientTexture2D:
	var g := Gradient.new()
	g.set_color(0, c0)
	g.set_color(1, c1)
	var t := GradientTexture2D.new()
	t.gradient = g
	t.width = 128
	t.height = 128
	t.fill = GradientTexture2D.FILL_RADIAL
	t.fill_from = Vector2(0.5, 0.5)
	t.fill_to = Vector2(1.0, 0.5)
	return t


func _new_entry(action: String, arg: Variant) -> Dictionary:
	return {
		"root": null, "mat": null, "label": null, "action": action, "arg": arg,
		"enabled": true, "hover": false, "htween": null, "ctween": null,
		"base_x": 0.0, "base_z": 0.0, "base_col": Color.WHITE, "text_col": Color.WHITE,
	}


func _make_button(parent: Node3D, pos: Vector3, size: Vector3, col: Color, text: String,
		font_size: int, text_col: Color, action: String, arg: Variant = null,
		is_round: bool = false) -> void:
	var b := _new_entry(action, arg)
	var root := Node3D.new()
	root.position = pos
	parent.add_child(root)
	var mat := _emissive(_mat(col, 0.15, 0.35), col, 0.0)
	var mi := MeshInstance3D.new()
	if is_round:
		var cm := CylinderMesh.new()
		cm.top_radius = size.x / 2.0
		cm.bottom_radius = size.x / 2.0
		cm.height = size.z
		mi.mesh = cm
		mi.rotation.x = PI / 2.0
	else:
		var bm := BoxMesh.new()
		bm.size = size
		mi.mesh = bm
	mi.material_override = mat
	root.add_child(mi)
	var lab := _label3d(root, text, Vector3(0.0, 0.0, size.z / 2.0 + 0.002), font_size, 0.0012, text_col)
	var body := StaticBody3D.new()
	var cs := CollisionShape3D.new()
	var bs := BoxShape3D.new()
	bs.size = Vector3(size.x, size.x if is_round else size.y, size.z)
	cs.shape = bs
	body.add_child(cs)
	root.add_child(body)
	buttons.append(b)
	body.set_meta("btn", buttons.size() - 1)
	b["root"] = root
	b["mat"] = mat
	b["label"] = lab
	b["base_x"] = pos.x
	b["base_z"] = pos.z
	b["base_col"] = col
	b["text_col"] = text_col


# ---------- Построение сцены ----------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.06, 0.07, 0.10)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.45, 0.50, 0.65)
	env.ambient_light_energy = 0.6
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.glow_enabled = true
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	var sun := DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38.0, 28.0, 0.0)
	sun.light_color = Color(1.0, 0.96, 0.90)
	sun.light_energy = 0.9
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 12.0
	add_child(sun)

	# холодная подсветка сзади и тёплая заполняющая спереди
	var rim := OmniLight3D.new()
	rim.position = Vector3(0.0, 2.6, -1.0)
	rim.light_color = Color(0.50, 0.60, 1.0)
	rim.light_energy = 1.2
	rim.omni_range = 6.0
	add_child(rim)
	var fill := OmniLight3D.new()
	fill.position = Vector3(-1.6, 1.8, 2.5)
	fill.light_color = Color(1.0, 0.85, 0.70)
	fill.light_energy = 0.5
	fill.omni_range = 8.0
	add_child(fill)


func _build_room() -> void:
	var floor_mi := MeshInstance3D.new()
	var pm := PlaneMesh.new()
	pm.size = Vector2(16.0, 16.0)
	floor_mi.mesh = pm
	floor_mi.material_override = _mat(Color(0.10, 0.10, 0.12), 0.2, 0.55)
	add_child(floor_mi)

	var wall := MeshInstance3D.new()
	var qm := QuadMesh.new()
	qm.size = Vector2(16.0, 8.0)
	wall.mesh = qm
	wall.material_override = _mat(Color(0.17, 0.18, 0.23), 0.0, 0.9)
	wall.position = Vector3(0.0, 4.0, -1.5)
	add_child(wall)


func _build_camera() -> void:
	camera = Camera3D.new()
	camera.fov = 40.0
	camera.near = 0.05
	camera.far = 60.0
	add_child(camera)
	camera.make_current()


func _build_machine() -> void:
	var body_mat := _mat(Color(0.19, 0.20, 0.23), 0.55, 0.38)
	var dark_mat := _mat(Color(0.06, 0.06, 0.07), 0.3, 0.5)
	var steel_mat := _mat(Color(0.62, 0.63, 0.68), 0.9, 0.3)
	var interior_mat := _emissive(_mat(Color(0.22, 0.16, 0.12), 0.0, 0.85), Color(0.35, 0.20, 0.08), 0.25)
	coin_mat = _mat(Color(0.95, 0.75, 0.25), 0.9, 0.25)

	# --- корпус: верх, две стойки, низ и задняя стенка отсека ---
	_box(machine, Vector3(0.0, 1.75, 0.0), Vector3(1.2, 0.9, 0.8), body_mat)
	_box(machine, Vector3(-0.525, 0.85, 0.0), Vector3(0.15, 0.9, 0.8), body_mat)
	_box(machine, Vector3(0.525, 0.85, 0.0), Vector3(0.15, 0.9, 0.8), body_mat)
	_box(machine, Vector3(0.0, 0.25, 0.0), Vector3(1.2, 0.3, 0.8), body_mat)
	_box(machine, Vector3(0.0, 0.85, -0.36), Vector3(0.9, 0.9, 0.04), interior_mat)
	_box(machine, Vector3(0.0, 0.402, 0.0), Vector3(0.9, 0.004, 0.74), dark_mat)
	for fx in [-0.5, 0.5]:
		for fz in [-0.3, 0.3]:
			_cyl(machine, Vector3(fx, 0.05, fz), 0.04, 0.1, dark_mat)

	# --- вывеска и лампочка ---
	sign_mat = _emissive(_mat(Color(0.62, 0.12, 0.10), 0.2, 0.4), Color(0.8, 0.1, 0.08), 0.45)
	_box(machine, Vector3(0.0, 2.12, 0.405), Vector3(1.0, 0.16, 0.02), sign_mat)
	_label3d(machine, "COFFEE POINT", Vector3(0.0, 2.12, 0.418), 64, 0.0016, Color(1.0, 0.93, 0.80))
	led_mat = _emissive(_mat(LED_IDLE, 0.0, 0.3), LED_IDLE, 1.6)
	_sphere(machine, Vector3(-0.42, 2.12, 0.42), 0.018, led_mat)

	# --- панель и экран ---
	_box(machine, Vector3(0.0, 1.69, 0.405), Vector3(1.04, 0.62, 0.02), dark_mat)
	_box(machine, Vector3(0.0, 1.84, 0.41), Vector3(0.96, 0.24, 0.02), _mat(Color(0.02, 0.02, 0.02), 0.5, 0.3))
	var screen_mat := _emissive(_mat(Color(0.02, 0.07, 0.04), 0.0, 0.2), Color(0.0, 0.30, 0.10), 0.35)
	_box(machine, Vector3(0.0, 1.84, 0.42), Vector3(0.92, 0.20, 0.01), screen_mat)
	screen_label = _label3d(machine, "", SCREEN_LABEL_POS, 36, 0.0013, SCREEN_GREEN)
	balance_label = _label3d(machine, "", Vector3(0.0, 1.815, 0.427), 28, 0.0013, Color(0.30, 0.75, 0.40))
	_box(machine, Vector3(0.0, 1.765, 0.426), Vector3(0.84, 0.012, 0.003), _mat(Color(0, 0, 0), 0.0, 0.5))
	bar_pivot = Node3D.new()
	bar_pivot.position = Vector3(-0.42, 1.765, 0.428)
	machine.add_child(bar_pivot)
	_box(bar_pivot, Vector3(0.5, 0.0, 0.0), Vector3(1.0, 0.012, 0.004),
		_emissive(_mat(SCREEN_GREEN, 0.0, 0.3), SCREEN_GREEN, 0.8))
	bar_pivot.visible = false

	# --- кнопки напитков ---
	var i := 0
	for n in DRINKS:
		var d: Dictionary = DRINKS[n]
		var pos := Vector3(-0.32 + (i % 2) * 0.28, 1.62 - floori(i / 2.0) * 0.12, 0.435)
		_make_button(machine, pos, Vector3(0.25, 0.10, 0.04), d["btn"],
			"%s\n%d ₽" % [n, d["price"]], 30, Color(1.0, 0.95, 0.85), "drink", n)
		i += 1

	# --- монеты, щель и сдача ---
	var k := 0
	for amount in [10, 50, 100]:
		_make_button(machine, Vector3(0.22 + k * 0.12, 1.62, 0.435), Vector3(0.09, 0.09, 0.04),
			Color(0.85, 0.68, 0.22), "%d ₽" % amount, 28, Color(0.22, 0.13, 0.0), "coin", amount, true)
		k += 1
	_make_button(machine, Vector3(0.34, 1.50, 0.435), Vector3(0.30, 0.09, 0.04),
		Color(0.42, 0.44, 0.50), "СДАЧА", 30, Color.WHITE, "refund")
	_box(machine, Vector3(0.34, 1.695, 0.416), Vector3(0.16, 0.014, 0.01), _mat(Color(0, 0, 0), 0.0, 0.8))

	# --- кнопка выдачи внизу и лоток ---
	_make_button(machine, Vector3(0.0, 0.25, 0.42), Vector3(0.56, 0.10, 0.04),
		Color(0.20, 0.55, 0.32), "ЗАБРАТЬ НАПИТОК", 30, Color.WHITE, "take")
	_box(machine, Vector3(0.0, 0.14, 0.415), Vector3(0.62, 0.03, 0.03), dark_mat)

	# --- отсек выдачи: полка с решёткой ---
	_box(machine, Vector3(0.0, 0.53, 0.0), Vector3(0.9, 0.04, 0.74), steel_mat)
	for s in 9:
		_box(machine, Vector3(-0.36 + s * 0.09, 0.5515, 0.05), Vector3(0.04, 0.003, 0.5), dark_mat)

	# --- дозатор с носиком ---
	_box(machine, Vector3(0.0, 1.19, 0.05), Vector3(0.34, 0.22, 0.30), steel_mat)
	head_mat = _emissive(_mat(Color(1.0, 0.65, 0.2), 0.0, 0.3), Color(1.0, 0.65, 0.2), 0.2)
	_box(machine, Vector3(0.0, 1.20, 0.2015), Vector3(0.2, 0.012, 0.003), head_mat)
	_cyl(machine, Vector3(0.0, 1.05, 0.05), 0.03, 0.06, dark_mat)

	# --- струя и брызги ---
	stream_mat = _mat(Color(0.2, 0.1, 0.04), 0.0, 0.15)
	stream = MeshInstance3D.new()
	var stm := CylinderMesh.new()
	stm.top_radius = 0.006
	stm.bottom_radius = 0.006
	stm.height = 1.0
	stm.radial_segments = 8
	stm.rings = 1
	stream.mesh = stm
	stream.material_override = stream_mat
	stream.visible = false
	machine.add_child(stream)

	splash_mat = _mat(Color(0.2, 0.1, 0.04), 0.0, 0.2)
	splash = CPUParticles3D.new()
	splash.amount = 24
	splash.lifetime = 0.45
	splash.direction = Vector3.UP
	splash.spread = 55.0
	splash.initial_velocity_min = 0.12
	splash.initial_velocity_max = 0.28
	splash.gravity = Vector3(0.0, -1.6, 0.0)
	splash.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	splash.emission_sphere_radius = 0.01
	var spm := SphereMesh.new()
	spm.radius = 0.004
	spm.height = 0.008
	spm.radial_segments = 6
	spm.rings = 3
	spm.material = splash_mat
	splash.mesh = spm
	splash.emitting = false
	machine.add_child(splash)

	# --- чашка: стекло, ободок, ручка, слои жидкости ---
	cup = Node3D.new()
	cup.position = CUP_BASE
	machine.add_child(cup)
	var glass := MeshInstance3D.new()
	var gm := CylinderMesh.new()
	gm.top_radius = CUP_R
	gm.bottom_radius = CUP_R
	gm.height = CUP_H
	gm.radial_segments = 32
	gm.rings = 1
	gm.cap_top = false
	glass.mesh = gm
	glass.material_override = _glass(0.22)
	glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	glass.position = Vector3(0.0, CUP_H / 2.0, 0.0)
	cup.add_child(glass)

	var white_mat := _mat(Color(0.96, 0.96, 0.94), 0.0, 0.25)
	var rim := MeshInstance3D.new()
	var rm := TorusMesh.new()
	rm.inner_radius = CUP_R - 0.003
	rm.outer_radius = CUP_R + 0.003
	rim.mesh = rm
	rim.material_override = white_mat
	rim.position = Vector3(0.0, CUP_H, 0.0)
	cup.add_child(rim)

	var handle := MeshInstance3D.new()
	var hm := TorusMesh.new()
	hm.inner_radius = 0.02
	hm.outer_radius = 0.04
	handle.mesh = hm
	handle.material_override = white_mat
	handle.rotation.x = PI / 2.0
	handle.position = Vector3(CUP_R + 0.02, CUP_H * 0.55, 0.0)
	cup.add_child(handle)

	coffee_mat = _mat(Color(0.2, 0.1, 0.04), 0.0, 0.12)
	coffee_node = _liquid_layer(coffee_mat, LIQ_H)
	milk_node = _liquid_layer(_mat(MILK_COLOR, 0.0, 0.3), LIQ_H)
	foam_node = _liquid_layer(_mat(FOAM_COLOR, 0.0, 0.6), 0.008)
	foam_node.scale = Vector3.ONE
	foam_node.visible = false

	# по чашке тоже можно кликнуть, когда напиток готов
	buttons.append(_new_entry("take", null))
	var cbody := StaticBody3D.new()
	var ccs := CollisionShape3D.new()
	var cshape := CylinderShape3D.new()
	cshape.radius = CUP_R
	cshape.height = CUP_H
	ccs.shape = cshape
	ccs.position = Vector3(0.0, CUP_H / 2.0, 0.0)
	cbody.add_child(ccs)
	cbody.set_meta("btn", buttons.size() - 1)
	cup.add_child(cbody)

	# --- пар над чашкой ---
	steam = CPUParticles3D.new()
	steam.amount = 16
	steam.lifetime = 1.8
	steam.direction = Vector3.UP
	steam.spread = 15.0
	steam.initial_velocity_min = 0.06
	steam.initial_velocity_max = 0.12
	steam.gravity = Vector3.ZERO
	steam.scale_amount_min = 0.6
	steam.scale_amount_max = 1.2
	steam.emission_shape = CPUParticles3D.EMISSION_SHAPE_SPHERE
	steam.emission_sphere_radius = 0.03
	var ramp := Gradient.new()
	ramp.set_color(0, Color(1, 1, 1, 0.0))
	ramp.set_color(1, Color(1, 1, 1, 0.0))
	ramp.add_point(0.25, Color(1, 1, 1, 0.30))
	steam.color_ramp = ramp
	var qm := QuadMesh.new()
	qm.size = Vector2(0.09, 0.09)
	var sm := StandardMaterial3D.new()
	sm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	sm.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	sm.vertex_color_use_as_albedo = true
	sm.albedo_texture = _gradient_tex(Color(1, 1, 1, 1), Color(1, 1, 1, 0))
	sm.cull_mode = BaseMaterial3D.CULL_DISABLED
	qm.material = sm
	steam.mesh = qm
	steam.position = Vector3(0.0, CUP_H + 0.01, 0.0)
	steam.emitting = false
	cup.add_child(steam)

	# --- стеклянная дверца отсека (въезжает вверх в корпус) ---
	door = Node3D.new()
	door.position = Vector3(0.0, DOOR_CLOSED_Y, 0.385)
	machine.add_child(door)
	var dglass := _box(door, Vector3.ZERO, Vector3(0.88, 0.88, 0.01), _glass(0.10))
	dglass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_box(door, Vector3(0.0, 0.425, 0.0), Vector3(0.9, 0.03, 0.014), steel_mat)
	_box(door, Vector3(0.0, -0.425, 0.0), Vector3(0.9, 0.03, 0.014), steel_mat)
	_box(door, Vector3(-0.44, 0.0, 0.0), Vector3(0.03, 0.88, 0.014), steel_mat)
	_box(door, Vector3(0.44, 0.0, 0.0), Vector3(0.03, 0.88, 0.014), steel_mat)

	# --- тёплый свет внутри отсека ---
	niche_light = OmniLight3D.new()
	niche_light.position = Vector3(0.0, 1.0, 0.2)
	niche_light.light_color = Color(1.0, 0.78, 0.50)
	niche_light.light_energy = 0.8
	niche_light.omni_range = 1.3
	machine.add_child(niche_light)


func _liquid_layer(mat: StandardMaterial3D, height: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var m := CylinderMesh.new()
	m.top_radius = LIQ_R
	m.bottom_radius = LIQ_R
	m.height = 1.0 if height > 0.01 else height
	m.radial_segments = 32
	m.rings = 1
	mi.mesh = m
	mi.material_override = mat
	mi.visible = false
	cup.add_child(mi)
	return mi
