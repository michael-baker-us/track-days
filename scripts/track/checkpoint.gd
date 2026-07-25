extends Area3D

## A gate across the track. Purely a trigger - it never blocks the car.
## Ordering is enforced by LapTracker, not here.

signal passed(index: int)

@export var index: int = 0

func _ready() -> void:
	add_to_group("checkpoint")
	body_entered.connect(_on_body_entered)

func _on_body_entered(body: Node3D) -> void:
	if body.is_in_group("player_car"):
		passed.emit(index)
