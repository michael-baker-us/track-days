class_name ViewportScaling
extends RefCounted

## Picks the content-scale design size and aspect rule for the window's current
## orientation, and keeps them up to date as it resizes.
##
## The project setting is `keep_height` against a 1280x720 design, which is right
## for every landscape shape (measured at 16:9, 16:10 and ultrawide) but crops a
## portrait phone horizontally: `keep_height` pins the canvas to 720 units tall,
## so a 9:16 screen gets 720 * 9/16 = 405 units of width and the UI runs off both
## sides. Portrait therefore needs the other rule — keep the *width* and let the
## canvas grow tall — against a design size that is itself portrait.
##
## Only the runtime window is touched. The project setting stays `keep_height` so
## the landscape default is what a fresh window and the headless suite both get.

## Design sizes per orientation. Same 720 short edge either way, so a control
## sized in canvas units is the same fraction of the short edge in both.
const LANDSCAPE := Vector2i(1280, 720)
const PORTRAIT := Vector2i(720, 1280)

## True when the window is taller than it is wide. Square counts as landscape,
## which keeps the common 1:1 case on the already-measured path.
static func is_portrait(size: Vector2i) -> bool:
	return size.y > size.x

static func design_size(size: Vector2i) -> Vector2i:
	return PORTRAIT if is_portrait(size) else LANDSCAPE

## `keep_width` grows the canvas downwards in portrait; `keep_height` grows it
## sideways in landscape. Both keep the 3D view filling the screen with no bars,
## which `keep` (letterbox) would not.
static func aspect_mode(size: Vector2i) -> Window.ContentScaleAspect:
	return (
		Window.CONTENT_SCALE_ASPECT_KEEP_WIDTH if is_portrait(size)
		else Window.CONTENT_SCALE_ASPECT_KEEP_HEIGHT
	)

static func apply(window: Window) -> void:
	if window == null:
		return
	var size := window.size
	window.content_scale_size = design_size(size)
	window.content_scale_aspect = aspect_mode(size)

## Marks a window whose `size_changed` is already wired up. A bound Callable is
## not reliably equal to another built the same way, so `is_connected` cannot be
## trusted to keep this idempotent — and every scene calls `attach` in `_ready`,
## so without a guard the signal would gain a connection per scene change.
const ATTACHED_META := "viewport_scaling_attached"

## Apply now and on every resize. Safe to call from every scene: the window
## outlives them all, so the connection is made once and the scenes come and go
## under it.
static func attach(window: Window) -> void:
	if window == null:
		return
	apply(window)
	if window.has_meta(ATTACHED_META):
		return
	window.set_meta(ATTACHED_META, true)
	window.size_changed.connect(_on_size_changed.bind(window))

static func _on_size_changed(window: Window) -> void:
	apply(window)
