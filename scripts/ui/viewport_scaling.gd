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

## The matching rule for a 3D camera, which has the same problem and does not get
## the fix for free. `Camera3D` defaults to `KEEP_HEIGHT`: the vertical FOV is
## held and the horizontal one shrinks with the viewport. On a 9:16 phone that
## leaves about a third of the horizontal view a landscape window gets — the car
## fills the screen, the road ahead is gone, and the game is unplayable held
## upright. Portrait therefore keeps the *width*, exactly as the canvas does, so
## the same amount of track is visible either way up and the extra room becomes
## more sky and more road rather than a crop.
static func camera_aspect(size: Vector2i) -> int:
	return Camera3D.KEEP_WIDTH if is_portrait(size) else Camera3D.KEEP_HEIGHT

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
	# Parented to the window, not to the scene, so it outlives every scene change
	# the way the connection above does. Deferred because `attach` is called from
	# a scene's `_ready`, and the tree will not take a new child mid-build.
	var watch := SizeWatch.new()
	watch.name = "ViewportScalingWatch"
	watch.window = window
	watch.seen = window.size
	window.add_child.call_deferred(watch)

static func _on_size_changed(window: Window) -> void:
	apply(window)

## Re-checks the window's size every frame and announces a change the signal did
## not usefully report.
##
## `size_changed` is not enough on a phone. A browser fires its resize on
## rotation *before* it has finished reshaping the canvas, so the handler reads
## the size the window is about to stop being. Every orientation decision in the
## game is made from that one read — the canvas rule here, the camera's aspect,
## the HUD's layout, the editor's — and none of them is ever revisited, so a
## single stale read latches: landscape gets drawn to the portrait rule, and
## turning back applies the landscape rule to a portrait screen. It is
## permanently one rotation behind and there is no event left to fix it.
##
## Polling catches it because the size is only wrong for a moment: whatever the
## browser said at signal time, `window.size` is right a frame or two later. The
## same tick also covers a resize that reports no signal at all.
##
## It re-emits `size_changed` rather than calling [method apply] itself. The
## signal is the one wire every listener is already on, and what the watch has
## observed is exactly what the signal means — the window's size has changed. Any
## other route would leave the camera and the editor still reading the stale
## value while only the canvas recovered.
class SizeWatch extends Node:
	var window: Window
	var seen := Vector2i.ZERO

	func _process(_delta: float) -> void:
		if window == null or not is_instance_valid(window) or window.size == seen:
			return
		seen = window.size
		window.size_changed.emit()
