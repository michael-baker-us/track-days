class_name UiTheme
extends RefCounted

## The one definition of what the interface looks like.
##
## Two things consume this file. `tools/build_theme.gd` calls [method build] and
## saves the result as `resources/ui_theme.tres`, which `project.godot` sets as
## the project-wide theme — so every Control in every scene is styled without a
## single node opting in. Runtime code that *draws* rather than lays out (the
## editor canvas, the coloured bits of the menu rows) reads the colour constants
## below directly, so the painted canvas and the widgets around it can never
## drift apart.
##
## Colours are deliberately shared with `track_grid.gd`'s canvas palette:
## [constant GREEN] is the valid racing line, [constant ACCENT] is height, and
## [constant DANGER] is a circuit that will not compile. Those meanings carry
## over into the widgets — a primary action is accent, a destructive one is
## danger — so the two halves of the editor read as one tool.

# --- palette ---

const BG := Color(0.043, 0.055, 0.075)          ## Page behind everything.
const SURFACE := Color(0.078, 0.098, 0.129)     ## Panels sitting on the page.
const SURFACE_HI := Color(0.110, 0.137, 0.180)  ## Controls sitting on a panel.
const LINE := Color(0.165, 0.204, 0.255)        ## Hairline borders and rules.
const TEXT := Color(0.894, 0.914, 0.945)
const MUTED := Color(0.541, 0.580, 0.651)       ## Secondary and explanatory text.
const ACCENT := Color(0.95, 0.72, 0.30)         ## Primary action; height, on the canvas.
const GREEN := Color(0.55, 0.80, 0.45)          ## A good result; the racing line.
const DANGER := Color(0.85, 0.30, 0.30)         ## Destructive action; a broken circuit.
const ON_ACCENT := Color(0.055, 0.071, 0.094)   ## Text on top of a filled accent button.

# --- metrics ---

const RADIUS := 6
const FONT_M := 16
const FONT_S := 14
const FONT_XS := 12

## Type variations. Named here rather than typed as strings at each call site,
## because a typo in a variation name fails silently — the control just renders
## with the base style and nothing says why.
const V_WORDMARK := &"Wordmark"      ## The game's name, once, on the title screen.
const V_HEADING := &"Heading"        ## A screen's title.
const V_SECTION := &"SectionLabel"   ## Small caps label above a group.
const V_MUTED := &"Muted"            ## Explanatory text.
const V_FINE := &"FineText"          ## Fine print: shortcuts, transient status.
const V_BODY := &"PanelBody"         ## A paragraph inside a panel card.
const V_CARD_META := &"CardMeta"     ## The right-hand detail on a list row.
const V_PRIMARY := &"PrimaryButton"  ## The one action the screen is for.
const V_DANGER := &"DangerButton"
const V_GHOST := &"GhostButton"      ## Secondary; reads as a link until hovered.
const V_DISCLOSURE := &"Disclosure"  ## Shows and hides the section under it.
const V_CARD := &"CardButton"        ## A whole list row that happens to be pressable.
const V_CARD_PANEL := &"CardPanel"   ## A framed block inside a panel.
const V_SIDEBAR := &"Sidebar"        ## A panel docked to a screen edge.
const V_HUD := &"HudPanel"           ## A readout floating over the 3D view.

## Builds the project theme. Pure — no file access — so the test suite can build
## a copy and assert on it without depending on the saved resource being current.
static func build() -> Theme:
	var theme := Theme.new()
	theme.default_font_size = FONT_M

	_labels(theme)
	_buttons(theme)
	_inputs(theme)
	_panels(theme)
	_scrollbars(theme)
	_misc(theme)
	return theme

# --- text ---

static func _labels(theme: Theme) -> void:
	theme.set_color("font_color", "Label", TEXT)
	theme.set_font_size("font_size", "Label", FONT_M)

	# The wordmark is letterspaced by hand — see `title_screen.gd`. Godot only
	# offers glyph spacing through a FontVariation, which would mean shipping a
	# font resource wrapping the built-in one purely to move letters apart.
	_label_variation(theme, V_WORDMARK, 54, TEXT)
	_label_variation(theme, V_HEADING, 23, TEXT)
	_label_variation(theme, V_SECTION, FONT_XS, MUTED)
	_label_variation(theme, V_MUTED, FONT_S, MUTED)
	_label_variation(theme, V_FINE, FONT_XS, MUTED)
	# Smaller than the widget default on purpose: these are paragraphs, and at
	# 16pt three sentences of guidance cost more of a 720-unit column than the
	# controls they explain.
	_label_variation(theme, V_BODY, FONT_S, TEXT)
	_label_variation(theme, V_CARD_META, 20, ACCENT)

static func _label_variation(theme: Theme, name: StringName, size: int,
		colour: Color) -> void:
	theme.set_type_variation(name, "Label")
	theme.set_color("font_color", name, colour)
	theme.set_font_size("font_size", name, size)

# --- buttons ---

static func _buttons(theme: Theme) -> void:
	_button_styles(theme, "Button", {
		"normal": _flat(SURFACE_HI, LINE),
		"hover": _flat(SURFACE_HI.lightened(0.06), _mix(LINE, ACCENT, 0.45)),
		"pressed": _flat(_mix(SURFACE_HI, ACCENT, 0.18), _fade(ACCENT, 0.7)),
		"disabled": _flat(_fade(SURFACE_HI, 0.45), _fade(LINE, 0.5)),
		"focus": _outline(_fade(ACCENT, 0.85)),
	})
	_button_colours(theme, "Button", TEXT, TEXT, ACCENT, _fade(MUTED, 0.45))

	# The screen's one real action: filled, so it is findable without reading.
	theme.set_type_variation(V_PRIMARY, "Button")
	_button_styles(theme, V_PRIMARY, {
		"normal": _flat(ACCENT, _fade(Color.WHITE, 0.0)),
		"hover": _flat(ACCENT.lightened(0.12), _fade(Color.WHITE, 0.0)),
		"pressed": _flat(ACCENT.darkened(0.12), _fade(Color.WHITE, 0.0)),
		"disabled": _flat(_fade(ACCENT, 0.18), _fade(ACCENT, 0.25)),
		"focus": _outline(Color.WHITE),
	})
	_button_colours(theme, V_PRIMARY, ON_ACCENT, ON_ACCENT, ON_ACCENT,
		_fade(ACCENT, 0.55))

	# Outlined rather than filled: Delete should be reachable without being the
	# brightest thing in the panel.
	theme.set_type_variation(V_DANGER, "Button")
	_button_styles(theme, V_DANGER, {
		"normal": _flat(_fade(DANGER, 0.10), _fade(DANGER, 0.55)),
		"hover": _flat(_fade(DANGER, 0.22), DANGER),
		"pressed": _flat(_fade(DANGER, 0.34), DANGER),
		"disabled": _flat(_fade(SURFACE_HI, 0.45), _fade(LINE, 0.5)),
		"focus": _outline(DANGER),
	})
	_button_colours(theme, V_DANGER, DANGER.lightened(0.25), Color.WHITE,
		Color.WHITE, _fade(MUTED, 0.45))

	theme.set_type_variation(V_GHOST, "Button")
	var invisible := StyleBoxEmpty.new()
	invisible.content_margin_left = 10.0
	invisible.content_margin_right = 10.0
	invisible.content_margin_top = 6.0
	invisible.content_margin_bottom = 6.0
	_button_styles(theme, V_GHOST, {
		"normal": invisible,
		"hover": _flat(_fade(Color.WHITE, 0.06), _fade(Color.WHITE, 0.0)),
		"pressed": _flat(_fade(Color.WHITE, 0.10), _fade(Color.WHITE, 0.0)),
		"disabled": invisible,
		"focus": _outline(_fade(ACCENT, 0.85)),
	})
	_button_colours(theme, V_GHOST, MUTED, TEXT, TEXT, _fade(MUTED, 0.4))

	# A list row. The name sits in the top-left rather than dead centre, which is
	# what the lopsided vertical content margins buy: the button draws its text
	# centred in whatever the stylebox leaves it, so a deep bottom margin lifts
	# the text and frees the space underneath for the overlaid detail lines.
	theme.set_type_variation(V_CARD, "Button")
	var card_pad := {"left": 18.0, "right": 18.0, "top": 14.0, "bottom": 40.0}
	_button_styles(theme, V_CARD, {
		"normal": _flat(SURFACE, LINE, card_pad, 4),
		"hover": _flat(SURFACE_HI, _fade(ACCENT, 0.6), card_pad, 4),
		"pressed": _flat(_mix(SURFACE_HI, ACCENT, 0.14), _fade(ACCENT, 0.9),
			card_pad, 4),
		"disabled": _flat(_fade(SURFACE, 0.55), _fade(LINE, 0.6), card_pad, 4),
		"focus": _flat(SURFACE_HI, ACCENT, card_pad, 4),
	})
	_button_colours(theme, V_CARD, TEXT, Color.WHITE, Color.WHITE,
		_fade(MUTED, 0.5))
	theme.set_font_size("font_size", V_CARD, 21)

	# A section header that happens to be pressable. Styled as the caption it
	# replaces, not as a button, because it labels the block below it.
	theme.set_type_variation(V_DISCLOSURE, V_GHOST)
	theme.set_font_size("font_size", V_DISCLOSURE, FONT_XS)
	theme.set_color("font_color", V_DISCLOSURE, MUTED)
	theme.set_color("font_pressed_color", V_DISCLOSURE, MUTED)
	theme.set_color("font_hover_color", V_DISCLOSURE, TEXT)

static func _button_styles(theme: Theme, type: StringName,
		styles: Dictionary) -> void:
	for state: String in styles:
		theme.set_stylebox(state, type, styles[state])

static func _button_colours(theme: Theme, type: StringName, normal: Color,
		hover: Color, pressed: Color, disabled: Color) -> void:
	theme.set_color("font_color", type, normal)
	theme.set_color("font_hover_color", type, hover)
	theme.set_color("font_pressed_color", type, pressed)
	theme.set_color("font_focus_color", type, hover)
	theme.set_color("font_disabled_color", type, disabled)

# --- inputs ---

static func _inputs(theme: Theme) -> void:
	var pad := {"left": 12.0, "right": 12.0, "top": 8.0, "bottom": 8.0}
	theme.set_stylebox("normal", "LineEdit", _flat(BG, LINE, pad))
	theme.set_stylebox("focus", "LineEdit", _flat(BG, _fade(ACCENT, 0.8), pad))
	theme.set_stylebox("read_only", "LineEdit",
		_flat(_fade(BG, 0.5), _fade(LINE, 0.6), pad))
	theme.set_color("font_color", "LineEdit", TEXT)
	theme.set_color("font_placeholder_color", "LineEdit", _fade(MUTED, 0.7))
	theme.set_color("caret_color", "LineEdit", ACCENT)
	theme.set_color("selection_color", "LineEdit", _fade(ACCENT, 0.3))

	# OptionButton has its own stylebox set: styling Button alone leaves the
	# circuit picker looking like stock Godot next to everything else.
	_button_styles(theme, "OptionButton", {
		"normal": _flat(SURFACE_HI, LINE, pad),
		"hover": _flat(SURFACE_HI.lightened(0.06), _mix(LINE, ACCENT, 0.45), pad),
		"pressed": _flat(_mix(SURFACE_HI, ACCENT, 0.18), _fade(ACCENT, 0.7), pad),
		"disabled": _flat(_fade(SURFACE_HI, 0.45), _fade(LINE, 0.5), pad),
		"focus": _outline(_fade(ACCENT, 0.85)),
	})
	_button_colours(theme, "OptionButton", TEXT, TEXT, ACCENT, _fade(MUTED, 0.45))

	theme.set_stylebox("panel", "PopupMenu", _flat(SURFACE, LINE,
		{"left": 6.0, "right": 6.0, "top": 6.0, "bottom": 6.0}))
	theme.set_stylebox("hover", "PopupMenu", _flat(_fade(ACCENT, 0.18),
		_fade(Color.WHITE, 0.0)))
	theme.set_color("font_color", "PopupMenu", TEXT)
	theme.set_color("font_hover_color", "PopupMenu", Color.WHITE)
	theme.set_constant("v_separation", "PopupMenu", 6)

# --- containers ---

static func _panels(theme: Theme) -> void:
	var panel := _flat(SURFACE, LINE, {
		"left": 18.0, "right": 18.0, "top": 16.0, "bottom": 16.0
	})
	theme.set_stylebox("panel", "Panel", panel)
	theme.set_stylebox("panel", "PanelContainer", panel)

	# A block inside a panel: no border, just a slightly different surface, so
	# nesting does not produce a box inside a box inside a box.
	theme.set_type_variation(V_CARD_PANEL, "PanelContainer")
	theme.set_stylebox("panel", V_CARD_PANEL, _flat(BG, _fade(LINE, 0.7), {
		"left": 12.0, "right": 12.0, "top": 8.0, "bottom": 8.0
	}))

	# Docked to a screen edge, so no rounded corners and no border except on the
	# side that faces the content it sits next to.
	theme.set_type_variation(V_SIDEBAR, "PanelContainer")
	var sidebar := StyleBoxFlat.new()
	sidebar.bg_color = SURFACE
	sidebar.set_corner_radius_all(0)
	sidebar.set_border_width_all(0)
	sidebar.border_width_left = 1
	sidebar.border_color = LINE
	sidebar.content_margin_left = 18.0
	sidebar.content_margin_right = 18.0
	sidebar.content_margin_top = 16.0
	sidebar.content_margin_bottom = 14.0
	theme.set_stylebox("panel", V_SIDEBAR, sidebar)

	# Over the 3D view, so it is translucent — a solid block would punch a hole in
	# the road. It carries no padding of its own: the HUD spaces its own contents
	# with margin containers, and a panel style that also padded would move every
	# readout away from the screen edge it is anchored to. The speed panel ran off
	# the right of the screen exactly that way.
	theme.set_type_variation(V_HUD, "PanelContainer")
	var hud := _flat(_fade(SURFACE, 0.72), _fade(LINE, 0.6),
		{"left": 0.0, "right": 0.0, "top": 0.0, "bottom": 0.0})
	theme.set_stylebox("panel", V_HUD, hud)

	theme.set_stylebox("panel", "ScrollContainer", StyleBoxEmpty.new())

static func _scrollbars(theme: Theme) -> void:
	for axis in ["VScrollBar", "HScrollBar"]:
		theme.set_stylebox("scroll", axis, _bar(_fade(Color.WHITE, 0.04)))
		theme.set_stylebox("grabber", axis, _bar(_fade(Color.WHITE, 0.16)))
		theme.set_stylebox("grabber_highlight", axis, _bar(_fade(Color.WHITE, 0.28)))
		theme.set_stylebox("grabber_pressed", axis, _bar(_fade(ACCENT, 0.7)))

static func _misc(theme: Theme) -> void:
	theme.set_stylebox("panel", "TooltipPanel", _flat(SURFACE_HI, LINE, {
		"left": 10.0, "right": 10.0, "top": 6.0, "bottom": 6.0
	}))
	theme.set_color("font_color", "TooltipLabel", TEXT)
	theme.set_font_size("font_size", "TooltipLabel", FONT_S)
	theme.set_stylebox("separator", "HSeparator", _bar(_fade(Color.WHITE, 0.10)))
	theme.set_constant("separation", "HSeparator", 12)

# --- helpers ---

## A rounded panel. `left_edge` thickens the left border only — a marker bar for
## the row the pointer or the keyboard is on. It is a width rather than a second
## colour because `StyleBoxFlat` has exactly one `border_color`, so the bar takes
## the colour already passed as `border`; the states that want a visible bar pass
## an accent border to go with it. Widening the border does not move the content,
## because the content margins are absolute, so the list never jitters between
## states.
static func _flat(bg: Color, border: Color, pad: Dictionary = {},
		left_edge: int = 0) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = bg
	box.set_border_width_all(1)
	box.border_width_left = maxi(1, left_edge)
	box.border_color = border
	box.set_corner_radius_all(RADIUS)
	box.content_margin_left = pad.get("left", 14.0)
	box.content_margin_right = pad.get("right", 14.0)
	box.content_margin_top = pad.get("top", 8.0)
	box.content_margin_bottom = pad.get("bottom", 8.0)
	return box

static func _outline(colour: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.draw_center = false
	box.set_border_width_all(2)
	box.border_color = colour
	box.set_corner_radius_all(RADIUS)
	return box

static func _bar(colour: Color) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = colour
	box.set_corner_radius_all(4)
	box.content_margin_left = 3.0
	box.content_margin_right = 3.0
	return box

static func _fade(colour: Color, alpha: float) -> Color:
	return Color(colour.r, colour.g, colour.b, alpha)

static func _mix(a: Color, b: Color, amount: float) -> Color:
	return a.lerp(b, amount)
