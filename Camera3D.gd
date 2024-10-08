extends Camera3D

@export var mouse_sensitivity : float = 0.2
@export var move_speed : float = 0.1

func _input(event):
	if event is InputEventMouseMotion and Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
		rotate_y(deg_to_rad(-event.relative.x * mouse_sensitivity))
		rotate_object_local(Vector3(1.0, 0.0, 0.0), deg_to_rad(-event.relative.y * mouse_sensitivity))
	if event.is_action_pressed("capture_mouse"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)
	

func _process(_delta):
	_move()

func _move():
	var input_vector := Vector3.ZERO
	input_vector.x = Input.get_action_strength("move_left") - Input.get_action_strength("move_right")
	input_vector.z = Input.get_action_strength("move_backward") - Input.get_action_strength("move_forward")
	input_vector.y = Input.get_action_strength("move_up") - Input.get_action_strength("move_down")
	if input_vector.length() > 1.0:
		input_vector = input_vector.normalized()
	
	var displacement := Vector3.ZERO
	displacement = Vector3(transform.basis.z.x, 0, transform.basis.z.z).normalized() * move_speed * input_vector.z
	displacement += move_speed * input_vector.y * Vector3.UP
	transform.origin += displacement
	
	displacement = transform.basis.x * move_speed * input_vector.x
	transform.origin -= displacement
