class_name TrackBuilder
extends RefCounted

## Turns a layout spec into a complete, drivable circuit node.
##
## This is the single implementation of track construction, used from two
## places: `tools/build_track.gd` bakes the shipped circuits into committed
## `.tscn` files with it, and `race.gd` calls it at runtime to build a
## player-authored track that has no scene file. Custom tracks are therefore
## made of exactly the same geometry as the shipped ones, and the test suite
## only has one builder to cover.
##
## Axis convention: -Z North, +Z South, -X West, +X East. Kenney road tiles are
## authored on a 1-unit grid with off-centre origins; every piece is normalised
## so its cell min corner sits at the origin, then placed by matching its entry
## connection point and edge normal to the walker's current position/heading.
##
## Height: each connection carries a y (in tile units). A piece's rise is
## conn_y[exit] - conn_y[entry], so the same ramp mesh climbs or descends purely
## by which way it is entered, and the walker carries the running height.
##
## Collision does NOT come from the road meshes. A ribbon of quads is generated
## along the centreline and used as a ConcavePolygonShape3D: smooth, seamless
## for the raycast wheels, and it follows elevation. The flat ground plane
## underneath is only the grass.
##
## Banking: the centreline carries a roll angle per point as well as a position,
## and the ribbon's lateral offsets are rolled about the track tangent by it, so
## corners lean into the turn. The tile meshes are deformed to match — see
## `_reshape_tiles`. Bank rolls about the centreline, so the racing line's *height*
## is untouched and elevation still closes exactly.

# 1 tile unit -> this many metres. Sets road width, corner radii and lap length
# together, since Kenney has no wider road tiles. The car does not scale, so
# raising this widens the track relative to the car and opens up the corners.
const SCALE := 14.0
# Vertical scale, applied on top of SCALE. Kenney's ramp is 0.5 units over 2,
# a 25% grade - very steep for a circuit, and with no barriers a fall off an
# elevated section hurts. Halving it gives ~12% and a 3.5 m high plateau.
const VERT := 0.5
const ROAD_HALF := 0.5 * SCALE
# Collision ribbon reaches slightly past the painted road edge, so the very edge
# of the tarmac is still drivable rather than a cliff.
const RIBBON_HALF := 0.6 * SCALE

## Tunnel shell: how far out the walls stand, how high the roof sits, and what
## colour it is. The walls clear `RIBBON_HALF` so the drivable edge of the road
## is still drivable, and the roof clears the chase camera, which rides 1.4 m up
## and 4.2 m back.
const TUNNEL_HALF := 0.68 * SCALE
const TUNNEL_HEIGHT := 6.5
const TUNNEL_COLOR := Color(0.30, 0.32, 0.35)

## The ring of distant land: how far out, and how tall its peaks are.
##
## 1.2 km sits inside the fog rather than beyond it, on purpose. Fog runs to
## 2.6 km, so at this range the silhouettes come through about a quarter hazed —
## present, and clearly far away. Put past the fog end they would be invisible;
## brought much closer they would read as scenery the car might reach.
## The pool of light under a trackside column: how wide, how bright, how far off
## the road, and what colour. Columns sit 70 m apart, so a 24 m radius leaves dark
## between them — which is the point. A continuous wash would be daylight.
## Roadside markers: how far off the tarmac they stand, how big they are, and how
## much room they need from another leg of the circuit.
const MARKER_GAP := 0.72
const MARKER_CLEARANCE := 0.7
const MARKER_SCALE := 3.2

## The trackside lamps. Height is where a `lightPostLarge` head sits at
## `POST_SCALE`; the cone is wide enough that consecutive lamps overlap at
## `POST_STEP` rather than leaving the road dark between them, which was most of
## what made night unreadable.
## Circuit floodlighting: high masts, wide cones, and **close enough together
## that their pools overlap**.
##
## Spacing is the number that matters and it was the one thing wrong after the
## lamps were aimed at the road. Lights hung off the visible columns inherited
## `POST_STEP`, which is 70 m — a cone 17 m across every 70 m leaves three
## quarters of the lap unlit, so the only continuously lit thing was whatever the
## car's own headlights were pointing at. That is what "the light follows the car"
## looks like, and no amount of energy fixes it.
##
## At 22 m a 44 degree half-angle reaches 21 m either side, so a mast lights a
## 42 m circle; at 28 m apart, consecutive circles overlap and the track is lit
## end to end. That is how a real circuit is lit and it is why the lights are no
## longer tied to the columns — a lamp post every 28 m would be a fence.
##
## The reach has to clear more than half the spacing, because the road is 17 m of
## drivable ribbon wide and the far corner of it is the worst case: a first
## attempt at 16 m and 26 m apart left points **17.4 m** from the nearest mast
## against a 14.4 m reach, all of them on the outside of corners, where the outer
## edge stretches between two masts placed by arc length along the centre.
## Floodlight masts: what a circuit is recognisably lit by.
##
## `MAST_LOOKAHEAD` is the one that makes the lighting continuous. A cone aimed
## straight down at its own feet stamps a *circle*, and circles tile badly — a
## spot goes to zero at its cone edge whatever its attenuation, so a row of them
## is a row of discs with dark rims. Aimed down the track instead, the cone
## strikes the road at a shallow angle and lays a long ellipse along it, and
## consecutive masts overlap end to end.
const MAST_STEP := 26.0
const MAST_GAP := 1.05
const MAST_HEIGHT := 21.0
## How many resampled steps ahead a mast aims: 2 x 26 m, so the cone strikes
## the road about 50 m down the track and lays a long ellipse along it.
const MAST_LOOKAHEAD := 2
const MAST_RANGE := 130.0
## **Godot's `spot_angle` is the half-angle**, measured from the cone axis to its
## edge — which is why it is capped at 89.9 rather than 180. Earlier code here
## treated it as the full angle and halved it, so cones set to "80 degrees" were
## in fact 80 degrees *from the axis*: a reach of 22 x tan(80) = 125 m from a 22 m
## mast, very nearly a hemisphere. That is a large part of why everything within
## sight of one blew out to white.
const MAST_ANGLE := 40.0
## The structure, in metres. Deliberately large: the silhouette of the masts is
## most of what says "floodlit circuit" before a single light is switched on.
const MAST_POLE := 0.7
const MAST_RIG_W := 9.0
const MAST_RIG_H := 0.7
const MAST_LAMPS := 6
const MAST_LAMP_W := 1.2
const MAST_LAMP_H := 0.9
const MAST_GLOW := 2.4
const MAST_COLOR := Color(0.30, 0.31, 0.34)

const LAMP_HEIGHT := 12.0
## **Far beyond where the light is needed, on purpose.** Godot's spot falloff is
## `pow(1 - distance/range, attenuation)`, so a range set to just clear the work
## puts the road near the bottom of the curve: at range 36 with attenuation 1.3,
## the point directly under a mast received 0.29 of full and the far edge of its
## cone received **0.09** — and the edge is exactly where two masts overlap, so
## the one place continuity depends on was the one place with no light. Bright
## discs under the masts, dark between them.
##
## At range 90 and attenuation 0.6 the same two points get 0.85 and 0.78 — flat
## across the whole pool, which is what a floodlit circuit looks like. The energy
## figures came down to match, because the light is no longer being thrown away.
const LAMP_RANGE := 90.0
const LAMP_FALLOFF := 0.6
## Flattens the cone across its width for the same reason: the default
## concentrates light at the centre, which puts the dark part back at the edges.
const LAMP_CONE_FALLOFF := 0.35
## Godot caps a spot at 89.9 degrees, so the cone cannot be widened much further
## than this — past here the only way to reach more road is to raise the mast.
## Also a half-angle: 40 degrees from 12 m up is a 10 m pool, which is an
## accent under a lamp post. Read as a full angle it was 76 from the axis,
## reaching 48 m — the whole width of the circuit and most of the field.
const LAMP_ANGLE := 40.0
## Past this a lamp switches off entirely, so the count that is live is the
## handful around the car rather than the whole circuit.
const LAMP_FADE_FROM := 140.0
const LAMP_FADE_OVER := 40.0


## The overlay laid on the tarmac: how many strips across the road, how far the
## rubber spreads either side of the racing line, and how dark it gets.
##
## Nine strips is enough for a smooth band across a 14 m road without doubling the
## triangle count of the circuit.
const OVERLAY_SHADER := "res://assets/shaders/road_overlay.gdshader"
const OVERLAY_STRIPS := 9
const OVERLAY_WIDTH := 2.6
const OVERLAY_LIFT := 0.02
const OVERLAY_STRENGTH := 0.5
const OVERLAY_COLOR := Color(0.05, 0.05, 0.06)

const HORIZON_RADIUS := 1200.0
const HORIZON_MIN := 40.0
const HORIZON_MAX := 170.0

## Solid walls at the edge of the road, and they are **on**.
##
## They were off for as long as grass gripped exactly like tarmac: with no penalty
## for leaving the road, a wall was the only thing that could have stopped a cut,
## and the ordered gates already did that job without putting an invisible box
## where the player can see open field. Off-road grip changes the trade. Running
## wide now costs you, and a surface with a real penalty needs something to stop
## the car sliding into four square kilometres of empty field — the two arrive
## together on purpose.
##
## Not to be confused with the *visual* barrier further down (`BARRIER_HEIGHT` and
## friends), which is scenery, is always built, and has no collision. This builds
## collision and no geometry; those rails are what you see it as.
const BARRIERS_ENABLED := true
const BARRIER_PIECE := "railDouble"
const BARRIER_LENGTH_AXIS := "z"
const BARRIER_SCALE := 10.0
const BARRIER_STEP := 1.0 * BARRIER_SCALE
const WALL_GAP := 0.7 * SCALE
const WALL_H := 2.8
const WALL_T := 0.6
const ARC_STEPS := 8

## Trackside dressing. All of it is decoration and none of it has collision,
## which is not an omission: `car_controller._surface_up` casts a ray straight
## down to decide which way is up, and a solid prop the car could get onto would
## be read as a piece of very steep banking.
##
## Repeated props go into one `MultiMeshInstance3D` each rather than a node
## apiece. A lap takes a few hundred rails and a hundred-odd trees, and the web
## export is a single-threaded compatibility-renderer build that cannot afford
## that many draw calls. The handful of buildings stay ordinary GLB instances,
## so the baked circuits reference the .glb files instead of inlining meshes.
const SCENERY_ENABLED := true

## Kenney's name for the drivable surface, on every road piece in the kit.
const ROAD_SURFACE := "road"

## Distance from the centreline, in tile units. The road is ROAD_HALF (0.5)
## either side of it, so anything under 0.5 is on the racing surface.
const RAIL_GAP := 0.62
const POST_GAP := 0.95
const PADDOCK_GAP := 1.55
const TREE_GAP_NEAR := 1.25
const TREE_GAP_FAR := 4.6

## How close a prop may come to *any* part of the centreline, in tile units.
##
## Placing everything at a fixed offset from the leg it was generated on is not
## enough. These circuits are laid on a grid and double back on themselves — two
## legs of Ardennes run a couple of tiles apart — so a grandstand set beside the
## pit straight lands squarely on the back straight, and trees grow out of the
## tarmac. Each candidate is therefore checked against the whole loop.
##
## Each clearance sits just inside the gap its prop is placed at, so a prop is
## only ever rejected by a *different* piece of road than the one it belongs to.
const RAIL_CLEARANCE := 0.55
## How far the railing will step in from the road edge, in metres, looking for
## somewhere it fits before giving up on that stretch entirely. See
## `_scenery_barrier`.
const RAIL_PULL_IN := [0.0, 0.8, 1.6, 2.4, 3.2, 4.0, 4.8, 5.6]
## How much of its own lap a railing point ignores when asking whether it is clear
## of the road. Comfortably more than the road is wide, so the leg it is lining
## never rejects it, and far less than the distance to any other leg.
const RAIL_OWN_SPAN := 30
const POST_CLEARANCE := 0.9
const TREE_CLEARANCE := 1.15
## Buildings are a tile square, so they need most of a tile of room; the banner
## towers are a third of that and sit much closer in. One clearance for both
## rejected every tower against the very straight it was meant to mark.
const PADDOCK_CLEARANCE := 1.35
const TOWER_CLEARANCE := 0.75

## The barrier is *generated*, not laid out of kit pieces, for the same reason
## the collision ribbon is: it has to follow a curve.
##
## Kenney's `rail` is a straight one-unit plank. Repeated round a corner it
## chords across the arc, so the barrier steps from facet to facet with a visible
## kink and a gap at every join — it reads as a line of fence panels rather than
## as armco. Swept along the centreline instead, it bends with the road, closes
## up, and rises with an elevated section for free.
##
## Height is set against the *car*, not against the kit. Kenney draws to its own
## proportions — a road tile is one unit and its cars about 0.55 of one — but
## this game stretches the tile to 14 m for a realistic road width while the car
## stays at the model's own 2.56 m, which leaves anything at tile scale roughly
## four times too big beside it. The kit rail came out 2.24 m tall next to a car
## 0.63 m high. A metre is both what real armco measures and what reads right
## here.
const BARRIER_HEIGHT := 1.0
const BARRIER_THICK := 0.24
const BARRIER_COLOR := Color(0.86, 0.87, 0.89)

## How far the swept barrier may depart from the centreline's own path before it
## needs another vertex, and the longest it may run without one regardless.
##
## The centreline carries a point every 2.8 m so that bank and ramp profiles stay
## smooth under the wheels. A barrier needs nothing like that on a straight, and
## following it point for point would bake tens of thousands of triangles of
## flat wall into every circuit file.
const BARRIER_MIN_TURN := 0.03
## The longest single length of railing between two stations.
##
## Was 6 tiles — **84 metres of rail as one flat quad**. A station is also kept
## wherever the road turns by more than `BARRIER_MIN_TURN` or changes height, so
## on paper a straight is the only place a span that long can happen; in practice
## it means any stretch the turn test reads as straight is drawn as a single chord
## between its ends, and a chord across even a gentle curve stands visibly off the
## road it is meant to be lining.
##
## One tile is short enough that the rail follows the road everywhere, at a few
## thousand more vertices per circuit — which is nothing against the tile meshes
## already in the scene.
const BARRIER_MAX_SPAN := 1.0 * SCALE

## Distant scenery keeps full tile scale on purpose: a grandstand or a tree is
## meant to tower, and shrinking those to match the car would make the whole
## circuit look like a model village. The lighting columns are the exception,
## being close enough to the road to loom.
const POST_SCALE := 7.0

## Metres of road between repeats.
const POST_STEP := 5.0 * SCALE
const TREE_STEP := 0.85 * SCALE

## Trees are the one prop not left at tile scale: at 1.5 units tall a full-size
## one stands 21 m over a 14 m road and closes the circuit in.

## The run of road the paddock occupies, in tile units relative to the start
## line, negative being before it.
##
## Weighted heavily forward on purpose. The grid sits about a tile and a half
## *behind* the line (see `GRID_POLE_ALONG`), so a paddock that stops at the line
## is a paddock the player is already parked past: from a standing start the
## whole thing is behind the car and the view down the road is empty grass. Most
## of it therefore lies ahead of the line, where it is actually looked at.
const PADDOCK_FROM := -4.0
const PADDOCK_TO := 8.0

## How far the road may have turned away from the start line's own heading before
## the paddock stops following it, in radians.
##
## A fixed length cannot serve three circuits and whatever a player paints. Run
## far enough forward to fill the view from the grid and, on a short pit straight,
## the last few buildings round the corner and strand themselves in a field with
## their backs to the racing line. Stopping at the corner instead gives every
## layout a terrace exactly as long as its pit straight.
const PADDOCK_MAX_TURN := 0.5

## How finely straights are sampled into the centreline, in tile units.
##
## Used to be one point per tile — 14 m, or 28 m for the long tile. That is
## plenty for a flat straight, where two points describe it exactly, but bank
## transitions and the eased ramp profile are *curves* laid along the straight,
## and a curve sampled every 14 m is a set of facets the wheels can feel. At
## 0.2 units the ribbon carries a sample every 2.8 m, which keeps the roll change
## from one sample to the next under 2.5 degrees.
const TRACE_STEP := 0.2

## Extra samples across a ramp tile, on top of `TRACE_STEP`. The eased profile
## does most of its climbing in the middle third, so it wants resolving finer
## than a flat straight does: at 16 the gradient never changes by more than about
## 4% between samples, against the 25% cliff the flat wedge had at each end.
const RAMP_STEPS := 16

## Bank angle by level, in degrees. Level 0 is a flat corner, and is always
## available — banking is a choice per corner, not something every bend gets.
##
## The ceiling is set by what happens when you run wide, not by taste.
##
## A banked corner is an embankment, so the outside of the road stands above the
## grass around it by twice `BANK_FULL_HALF * tan(angle)` — and all of that has to
## be shed again over the 2.1 m of verge between the tarmac and the edge of the
## tile. At 6 degrees that is a metre of road edge and a 26 degree apron: a car
## drifting a hand's width wide drops off it, which measured as the car being
## thrown and is exactly what banking should not do. At 4 it is 0.69 m and 18
## degrees, which the suspension can follow.
##
## Measured, not guessed: launched along the road at 30 m/s from points all round
## the lap, banked corners average 0.7 airborne frames against 23 for the hills
## and 13 for plain flat road. On the road, banking is the most planted part of
## the circuit; it was only ever the edge that threw anything.
##
## NASCAR's 24 to 33 is out of reach without wider tiles to land the apron on.
const BANK_DEGREES: Array[float] = [0.0, 1.5, 2.5, 4.0]
const MAX_BANK_LEVEL := 3
const MAX_BANK_DEG := 4.0

## The level a corner gets when nothing has asked for anything.
##
## Flat. A corner banks because someone said so and for no other reason — there
## is no radius-derived default anywhere, in the editor or in a hand-written
## layout. Banking changes how a circuit drives, and inheriting it silently is
## not something a track author should have to notice and undo.
##
## Suggested angles, when someone does ask, run *up* with radius: a sweeper is the
## corner taken fastest, so it is where leaning the road actually buys grip, and
## it is the only one with enough road either side to ease the roll in and out of.
## A hairpin banked hard is a skate bowl — the tilt arrives in a car length and
## reads as a glitch rather than as a corner.
const DEFAULT_BANK_LEVEL := 0

## Road spent easing bank in and out at each end of a corner, in tile units.
##
## 1.5 units is 21 m, about three quarters of a second at racing speed, which
## puts the peak roll rate near 25 degrees a second — quick enough to feel like
## the road is taking the car, slow enough that the chase camera never snaps.
## Shorter reads as a flick; much longer and a short straight between two bends
## never gets back to flat.
const BANK_TRANSITION := 1.5

## Below this the roll is not worth deforming a mesh for, in radians. Roughly a
## tenth of a degree.
const BANK_EPSILON := 0.002

## The same threshold for the ramp-chain correction, in metres. A centimetre is
## well under what a wheel can find, and keeping it non-zero means the tiles of a
## single-tile level change — where the chain profile and the mesh's own are the
## same curve — go on sharing one imported mesh instead of each baking a copy.
const LIFT_EPSILON := 0.01

## How far the bank is carried across the road before it grades back to ground
## level, in metres either side of the centreline.
##
## The world outside the road is one flat plane 4 km across, and it cannot be
## banked to meet a banked corner. Tilting a whole tile bodily therefore puts its
## outer edge into the air as a grass cliff and its inner edge *under* the ground
## plane, where the grass clips straight through the road.
##
## So the corner is built the way a real banked one is: as an embankment. The
## inside edge stays at ground level, the road climbs across its width, and the
## outside grades back down to ground by the edge of the tile. Nothing ever sits
## below the grass, so nothing can clip through it, whatever the angle.
##
## `BANK_FULL_HALF` must cover the whole painted road, and that is not a
## preference — it is the difference between banking and a bump.
##
## It was 0.25 units (3.5 m) first, chosen to leave a long, gentle verge to shed
## the height on. But the tarmac reaches 0.345 units (4.83 m), so the two places
## where the cross-section changes gradient — the apex of the climb on one side,
## the start of the flat apron on the other — both landed *on the driving
## surface*. The result was a ridge running along the road at 3.5 m out and a kink
## at 3.5 m in, and the car hopped every time a wheel crossed one. It measured as
## a perfect 10 degree bank the whole time, because along the racing line it was.
##
## At 0.35 units the banked strip is one unbroken plane across the entire road and
## every gradient change is on grass. The price is a steeper apron, since the same
## height is shed over less verge, which is what caps the angle below.
const BANK_FULL_HALF := 0.35 * SCALE
const BANK_FADE_HALF := 0.5 * SCALE

## How far either side of each break in the cross-section the corner is rounded
## off, in metres.
##
## Without this the road meets its apron at a sharp convex crest, and a sharp
## convex crest throws the car *however slowly it is crossed*: the vertical
## acceleration a surface demands is its curvature times the square of the speed
## across it, and at a corner the curvature is infinite. Drifting a wheel a
## hand's width off the tarmac was enough to launch the car, which is not what
## banking is supposed to do to anyone.
##
## Rounded over 0.7 m either side, the crest has a radius of a couple of metres.
## What crosses it is the car's *lateral* drift, not its speed down the road, so
## a couple of metres is enough: at 3 m/s sideways it asks for well under a g and
## the wheels stay down.
const BANK_FILLET := 0.05 * SCALE

# Lap checkpoints. Index 0 sits on the start line; a lap only counts if all of
# them are crossed in order.
const CHECKPOINT_COUNT := 16
const CHECKPOINT_W := 4.0 * SCALE
const CHECKPOINT_H := 12.0  # tall enough to still catch the car on a slope
const CHECKPOINT_T := 4.0

## Where the pole slot sits, in tile units: how far along `roadStartPositions`,
## and how far to the driver's right of the centreline.
##
## Read off the art. The tile paints four slots alternating sides, at 0.077..0.423,
## 0.577..0.923, 1.077..1.423 and 1.577..1.923 along it, across a cell whose road
## runs 0.155..0.845. Driven as `PIECES` lays it — in through S — the slots march
## towards the exit, the last of them spanning x 0.224..0.431. So pole is 1.75
## along and 0.1725 to the driver's right of the middle of the road.
##
## Which is also what says the grid tile belongs before the line rather than
## after it: the slots lead up to the tile's exit, and the exit is where
## `roadStart` joins.
const GRID_POLE_ALONG := 1.75
const GRID_POLE_ACROSS := 0.1725

## Where the start/finish line sits along the layout, in tile units.
##
## Not zero, which is the trap, and no longer under 1 either.
##
## The walker starts at the *leading edge* of the first tile of the start run,
## and that tile is `roadStartPositions`, 2 units of grid slots. The line itself
## is on the `roadStart` tile behind it, which is another 2 units long and carries
## the line across the middle of itself: the painted stripe spans z 0.905..0.954
## of that tile and the gantry straddles it at 0.905..1.095. Timing from arc 0
## therefore started and stopped the clock most of 40 m before the car reached
## anything the player can see.
##
## The fractional part is the midpoint of that whole assembly, so the trigger is
## within half a metre of both the stripe and the middle of the arch rather than
## exact on one and a metre out on the other.
##
## Mirrored from 0.96 when `roadStart` was turned round to face its screens at the
## grid. The arch is symmetric about the tile midpoint and did not move; the
## stripe did, from 0.905..0.954 to 1.046..1.095, so the trigger moves with it and
## keeps the same relationship to both.
## The start lights on the gantry: how high they hang, how far apart, and how big.
## Fallback only, for a circuit whose start tile could not be measured.
const LIGHTS_HEIGHT := 7.4
## How far the lights hang below the underside of the arch, and how far around the
## start line to look for it.
const LIGHTS_DROP := 1.15
const LIGHTS_REACH := 12.0
## Anything shorter than this near the line is the road, not the arch.
const GANTRY_MIN_H := 2.0
## How far the panel stands off the face it is mounted on.
const LIGHTS_PROUD := 0.12
const LIGHTS_SPAN := 3.4
const LIGHTS_SIZE := 0.9
const LIGHTS_COUNT := 3
const LIGHTS_HOUSING := Color(0.08, 0.08, 0.09)

const START_LINE_ALONG := 2.0 + 1.04
const START_LINE_ARC := START_LINE_ALONG * SCALE

const DIRS := {
	"N": Vector2(0, -1), "S": Vector2(0, 1),
	"E": Vector2(1, 0), "W": Vector2(-1, 0),
}

## Deck height of the bridge corner pieces, in tile units, measured from the art:
## their road surface tops out at local y 0.117 and every Kenney glb carries its
## mesh 0.01 low, so the deck sits 0.107 above the piece origin.
##
## Not 0.5 like `roadStraightBridge`, which is a full bridge with supports down to
## the ground; the bridge corners are deck-only sections meant to be carried at
## height. Getting this wrong does not fail loudly — the corner simply sits a few
## metres proud of the straights it joins.
const BRIDGE_CORNER_DECK := 0.107

# name -> cell size, origin shift, connection points in normalised cell coords,
# connection heights in tile units, and for corners the arc centre. An `entry`
# names the connection the piece must be driven in through, for art that is not
# symmetric end to end.
const PIECES := {
	## Also laid backwards, and for the same kind of reason as the grid tile
	## below: the gantry's three screens are on one face only, and driven the way
	## the search picks by default they face *down* the circuit, showing the grid
	## nothing but a blank grey arch on the one part of the lap every player looks
	## at from a standstill.
	##
	## Turning the tile round is safe for timing because the arch is symmetric
	## about the tile's midpoint — it spans 0.905..1.095 of two units, so it maps
	## onto itself and does not move. The painted stripe is not symmetric and does
	## move, from 0.905..0.954 to 1.046..1.095, which is what `START_LINE_ALONG`
	## accounts for. Lap *times* are unaffected either way: the start line and the
	## finish line are the same gate, so moving it shifts where a lap is measured
	## from, not how long it takes.
	"roadStart": {
		"cell": Vector2(1.26, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.63, 0.0), "S": Vector2(0.63, 2.0)},
		"entry": "S",
	},
	## Laid backwards on purpose — driven in through S and out through N, which
	## is a 180-degree turn of the art within the same two cells.
	##
	## Each slot is painted as a U: a bar closing one end and a strip down either
	## side, open at the other end. The car noses in through the open end and
	## stops at the bar, so the bar has to be the *forward* edge. As the tile is
	## authored the bar is at the low-z end and the opening faces high z, which is
	## the way the walker drives it — every box open behind the car and barred
	## across its nose, a grid you reverse into.
	##
	## The tile survives being turned round because everything else on it is
	## symmetric about the cell centre: the road, both kerbs and both verges map
	## onto themselves, and the four slots map onto each other's places (they
	## alternate sides, so mirroring across and along together lands each one
	## where another was). Only the U's opening changes hand, which is the point.
	"roadStartPositions": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"entry": "S",
	},
	"roadStraightLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
	},
	"roadStraight": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
	},
	## Tunnel road. The kit has **no tunnel art of any kind**, so these are
	## ordinary straights — `model` points at the same .glb — that additionally
	## ask for a shell to be swept over them (`_build_tunnels`).
	##
	## Expressed as pieces rather than as a separate list of arc ranges because
	## that is how everything else about a circuit is written: a layout says what
	## road goes where, and a tunnel is a kind of road. It also means the span
	## cannot drift out of step with the tiles under it, which a hand-written
	## range of metres would.
	##
	## Covered, not buried. Genuinely underground road is out of reach for three
	## separate reasons — no art, elevation levels clamped to zero and above, and
	## a 4 km ground slab whose collision top *is* y=0 — so this is Monaco's
	## tunnel rather than a subway: the road stays where it is and gets a roof.
	"roadStraightTunnel": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
		"model": "roadStraight",
		"tunnel": true,
	},
	"roadStraightLongTunnel": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"model": "roadStraightLong",
		"tunnel": true,
	},
	# Climbs 0.5 units over its 2 units of length, as a flat wedge: 8 vertices,
	# so the grade arrives and leaves at a hard crease. Kept because it is a
	# valid piece, but nothing emits it any more — see `roadRampLongCurved`.
	"roadRampLong": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"conn_y": {"N": 0.5, "S": 0.0},
	},
	# Same rise, same footprint, same connections — but the surface eases into
	# the grade and out of it instead of breaking into it, so a crest is a crest
	# rather than a ridge. `RAMP_PROFILE` reproduces its shape for collision.
	"roadRampLongCurved": {
		"cell": Vector2(1.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 2.0)},
		"conn_y": {"N": 0.5, "S": 0.0},
		"eased": true,
	},
	# Flat, but sits at ramp-top height.
	"roadStraightBridge": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"N": Vector2(0.5, 0.0), "S": Vector2(0.5, 1.0)},
		"conn_y": {"N": 0.5, "S": 0.5},
	},
	# The arc centre is the *outer* corner of the block, not the point where the
	# two centre lines cross. Both give a quarter circle through the same two
	# connection points — they are mirror images across the chord — but only this
	# one leaves the arc tangent to the straights it joins. Centred on the
	# crossing point instead, the road turns the wrong way out of each end and
	# the centreline cuts across the inside of the bend.
	"roadCornerSmall": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"E": Vector2(1.0, 0.5), "S": Vector2(0.5, 1.0)},
		"arc": Vector2(1.0, 1.0),
	},
	"roadCornerLarge": {
		"cell": Vector2(2.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"E": Vector2(2.0, 0.5), "S": Vector2(0.5, 2.0)},
		"arc": Vector2(2.0, 2.0),
	},
	"roadCornerLarger": {
		"cell": Vector2(3.0, 3.0), "shift": Vector2(0.35, 3.65),
		"conns": {"E": Vector2(3.0, 0.5), "S": Vector2(0.5, 3.0)},
		"arc": Vector2(3.0, 3.0),
	},
	# Corners that hold their height, so an elevated section can carry on round a
	# bend instead of having to come back down for it. Same footprint and arc as
	# the flat corners; only the deck height differs.
	"roadCornerBridgeSmall": {
		"cell": Vector2(1.0, 1.0), "shift": Vector2(0.35, 1.65),
		"conns": {"E": Vector2(1.0, 0.5), "S": Vector2(0.5, 1.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(1.0, 1.0),
	},
	"roadCornerBridgeLarge": {
		"cell": Vector2(2.0, 2.0), "shift": Vector2(0.35, 2.65),
		"conns": {"E": Vector2(2.0, 0.5), "S": Vector2(0.5, 2.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(2.0, 2.0),
	},
	"roadCornerBridgeLarger": {
		"cell": Vector2(3.0, 3.0), "shift": Vector2(0.35, 3.65),
		"conns": {"E": Vector2(3.0, 0.5), "S": Vector2(0.5, 3.0)},
		"conn_y": {"E": BRIDGE_CORNER_DECK, "S": BRIDGE_CORNER_DECK},
		"arc": Vector2(3.0, 3.0),
	},
}

## Everything the caller could want to know about a build: the node itself, and
## whether the loop actually joined up.
##
## The tool turns `closed` into a non-zero exit code so a broken circuit cannot
## be committed; the editor turns the same numbers into a live readout so the
## player can see *how far* off closing they are while painting.
class BuildResult extends RefCounted:
	var root: Node3D
	var closed: bool
	var gap: Vector2          # tile units still between the end and the start
	var height_gap: float     # tile units of unreturned elevation
	var turn_total: int       # net quarter-turns; +/-4 for a single clean loop
	## True when the loop never crosses itself. A figure of eight is `closed` but
	## not `simple`: its two halves turn opposite ways and cancel to zero.
	var simple: bool
	var length: float         # lap distance in metres
	var peak: float           # highest point in metres
	var triangles: int        # collision ribbon size
	var gate_spacing: float   # metres between checkpoints

	func summary() -> String:
		return "gap = (%.2f, %.2f) height %.2f | net turns %d | %s%s" % [
			gap.x, gap.y, height_gap, turn_total,
			"CLOSED" if closed else "*** DOES NOT CLOSE ***",
			"" if simple else " (crosses itself)"
		]

var centreline: Array[Vector3] = []
## Roll angle at each centreline point, in radians, positive where the road
## leans into a left-hand turn. Always the same length as `centreline`.
var bank := PackedFloat32Array()

var _triangles := 0
var _gate_spacing := 0.0
## Centreline index ranges covered by tunnel road, filled during the walk.
var _tunnel_spans: Array[Vector2i] = []
## Which look this circuit is being built with. Empty means "whatever the circuit
## is named", which is how the shipped ones get theirs; a player's track carries
## its own choice and passes it in.
var _look := ""
## One entry per placed tile: its node, and the centreline index range it spans.
## Filled during the walk and consumed by `_reshape_tiles`, which cannot run until
## the whole loop is known — a corner's bank reaches back into the straight
## before it, which has already been placed by the time the corner is reached.
var _placed: Array = []
## Centreline index ranges that sit inside a corner arc, with the bank that
## corner asks for. Turned into a continuous profile by `_build_bank_profile`.
var _corner_spans: Array = []
## The road's lateral direction at each centreline point; see `_side_vectors`.
var _sides: Array[Vector3] = []
## How far, in world units, the centreline at each point sits above the surface
## the tile mesh under it actually has. Zero everywhere except inside a ramp
## chain of more than one tile, where the profile spans the whole chain but each
## mesh still carries its own — see `_trace_straight`. Always the same length as
## `centreline`; `_frame_at` hands it to the tile reshaper so the visible road
## and the collision ribbon stay the same surface.
var _ramp_lift := PackedFloat32Array()

## Layout grammar:
##   ["S", piece, repeat]              straight run
##   ["S", piece, repeat, rise_sign]   ramp; +1 climbs, -1 descends, same mesh
##   ["C", piece, "left"|"right"]      corner, banked to suit its radius
##   ["C", piece, turn, bank_degrees]  corner banked by an explicit amount; 0 is
##                                     flat, and is not the same as saying nothing
##
## A layout only makes a circuit if it closes: gap (0, 0), net turns +/-4, and
## height back to 0. Callers must check `BuildResult.closed` — the builder still
## returns geometry for a broken layout so the editor can draw it.
##
## With `with_geometry` false nothing is instanced and `result.root` is null;
## see `measure()`.
func build(
	track_name: String, layout: Array, with_geometry := true, look := ""
) -> BuildResult:
	_look = look
	centreline = []
	bank = PackedFloat32Array()
	_triangles = 0
	_gate_spacing = 0.0
	_tunnel_spans.clear()
	_placed = []
	_corner_spans = []
	_sides = []
	_ramp_lift = PackedFloat32Array()

	var root_node: Node3D = null
	var roads: Node3D = null
	if with_geometry:
		root_node = Node3D.new()
		root_node.name = "Track_%s" % track_name
		roads = Node3D.new()
		roads.name = "RoadVisuals"
		roads.scale = Vector3(SCALE, SCALE * VERT, SCALE)
		root_node.add_child(roads)

	var pos := Vector2.ZERO
	var heading := DIRS["S"]
	var height := 0.0
	var turn_total := 0
	var peak := 0.0

	for seg in layout:
		var kind: String = seg[0]
		var piece: String = seg[1]
		if kind == "S":
			var rise_sign: int = seg[3] if seg.size() > 3 else 0
			var count := int(seg[2])
			# A level change of N is N ramp tiles in a row, and each mesh eases in
			# *and* out of its own two cells. Traced one at a time that is N humps,
			# not one hill: the gradient returns to zero at every tile seam, so a
			# 0-to-3 climb pitches the car three times on the way up. The chain is
			# therefore given a single profile spanning all N tiles. Peak gradient
			# is unchanged — an eased ramp's steepest point is a fixed multiple of
			# its average, and stretching rise and length together leaves that
			# alone — so this only removes the undulation.
			var chain := {}
			if rise_sign != 0 and count > 1:
				chain = {
					"base": height,
					"rise": _tile_rise(piece) * rise_sign * count,
					"count": count,
				}
			for i in count:
				var r := _place(roads, piece, pos, heading, heading, height, rise_sign)
				var from_idx := _mark()
				if not chain.is_empty():
					chain["index"] = i
				_trace_straight(piece, r[2], height, r[0], r[5], chain)
				_record(r[6], from_idx)
				# Recorded as centreline indices rather than metres, so the shell
				# is swept over exactly the samples the road was traced onto and
				# the two cannot disagree about where the tunnel is.
				if PIECES[piece].get("tunnel", false):
					_tunnel_spans.append(
						Vector2i(from_idx, maxi(from_idx, centreline.size() - 1))
					)
				pos = r[0]
				height = r[5]
				peak = maxf(peak, height)
		else:
			var turn: String = seg[2]
			var new_heading := _rotate(heading, 90.0 if turn == "left" else -90.0)
			turn_total += (1 if turn == "left" else -1)
			var r := _place(roads, piece, pos, heading, new_heading, height, 0)
			var from_idx := _mark()
			_trace_arc(piece, r[3], r[4], r[2], r[0], height)
			_record(r[6], from_idx)
			# A fourth element is a bank in degrees. Without one the corner is
			# flat, so "said nothing" and "said zero" now mean the same thing,
			# and neither can quietly bank a circuit nobody asked to bank.
			_note_corner(piece, turn, from_idx,
				float(seg[3]) if seg.size() > 3 else 0.0)
			pos = r[0]
			height = r[5]
			heading = new_heading

	_build_bank_profile()

	var total := 0.0
	for i in centreline.size() - 1:
		total += centreline[i].distance_to(centreline[i + 1])

	if with_geometry:
		# After the whole loop, because a corner's bank reaches back into the
		# straight before it and forward into the one after.
		_reshape_tiles()
		if BARRIERS_ENABLED:
			_build_wall_collision(root_node)
		_build_road_collision(root_node)
		_build_checkpoints(root_node)
		_build_start_lights(root_node)
		_build_ground(root_node, track_name)
		_build_lighting(root_node, track_name)
		_build_scenery(root_node, track_name)

		# In the pole slot, which is behind the line rather than past it: the
		# timer starts a second or two in instead of after a full out lap, and
		# the car starts on the one painted box that is drawn for it. Measured
		# from arc zero — the leading edge of the grid tile — rather than back
		# from the line, so it stays in the box the art puts there.
		var grid := _point_at_arc(GRID_POLE_ALONG * SCALE)
		var spawn := Marker3D.new()
		spawn.name = "SpawnPoint"
		# The car model faces local +Z, so align +Z with the track tangent.
		var tan: Vector2 = grid[1]
		# Driver's right for a Y-up right-handed basis is cross(forward, up),
		# which for a tangent (x, z) is (-z, x).
		var across := Vector3(-tan.y, 0.0, tan.x) * (GRID_POLE_ACROSS * SCALE)
		spawn.position = (grid[0] as Vector3) + across + Vector3(0.0, 1.0, 0.0)
		spawn.rotation.y = atan2(tan.x, tan.y)
		root_node.add_child(spawn)

	var result := BuildResult.new()
	result.root = root_node
	result.gap = pos
	result.height_gap = height
	result.turn_total = turn_total
	result.length = total
	result.peak = peak * SCALE * VERT
	result.triangles = _triangles
	result.gate_spacing = _gate_spacing
	# Closed means the walk came back to the pose it set off from: same place,
	# same height, same heading. Heading returns exactly when the quarter-turns
	# are a multiple of four.
	#
	# This used to demand `absi(turn_total) == 4`, which is a stronger claim —
	# not just "it joins up" but "it joins up without ever crossing itself". That
	# was right while a circuit could not cross itself, and it is the thing a
	# crossover circuit legitimately fails: a figure of eight is one loop turning
	# one way and one turning the other, so its turns cancel to **zero**. It joins
	# up perfectly.
	#
	# The stronger claim is kept as `simple` rather than dropped, because it is
	# still what every painted circuit must satisfy — `TrackShape` only permits a
	# crossing when it is asked to, and it is not asked to yet.
	result.simple = absi(turn_total) == 4
	result.closed = (
		is_zero_approx(pos.x) and is_zero_approx(pos.y) and is_zero_approx(height)
		and turn_total % 4 == 0
	)
	return result

## Walks a layout without building anything, filling `centreline` and returning
## the same closure and length figures as a real build. The editor recompiles on
## every mouse move and the menu measures every custom track it lists, so both
## need the numbers without paying for the tiles.
func measure(layout: Array) -> BuildResult:
	return build("measure", layout, false)

# Returns [exit_pos, exit_heading, entry_pos, origin, theta, exit_height, holder]
func _place(
	parent: Node3D, piece: String, pos: Vector2, heading: Vector2,
	want_heading: Vector2, height: float, rise_sign: int
) -> Array:
	var desc: Dictionary = PIECES[piece]
	var conns: Dictionary = desc["conns"]
	var conn_y: Dictionary = desc.get("conn_y", {})
	var keys: Array = conns.keys()
	# A piece whose art is not symmetric end to end says which way it is driven.
	# Without one, the first rotation that fits wins, and for a straight piece
	# that is always the untuned one — the search would never turn a tile round
	# on its own however wrong the result looked.
	var entry: String = desc.get("entry", "")

	for theta in [0.0, 90.0, 180.0, 270.0]:
		for a in keys:
			if entry != "" and a != entry:
				continue
			for b in keys:
				if a == b:
					continue
				if not _rotate(DIRS[a], theta).is_equal_approx(-heading):
					continue
				if not _rotate(DIRS[b], theta).is_equal_approx(want_heading):
					continue

				var y_in: float = conn_y.get(a, 0.0)
				var y_out: float = conn_y.get(b, 0.0)
				var rise := y_out - y_in
				# A ramp mesh climbs or descends depending only on which end is
				# entered, so the caller says which it wanted.
				if rise_sign > 0 and rise <= 0.0:
					continue
				if rise_sign < 0 and rise >= 0.0:
					continue

				var entry_local: Vector2 = conns[a]
				var exit_local: Vector2 = conns[b]
				var origin := pos - _rotate(entry_local, theta)
				var exit_pos := origin + _rotate(exit_local, theta)

				# No parent means a measuring walk: the arithmetic is all that is
				# wanted, and instancing a few hundred GLB tiles is by far the
				# most expensive thing the builder does.
				var holder: Node3D = null
				if parent != null:
					holder = Node3D.new()
					# Lift the piece so its entry connection meets the running height.
					holder.position = Vector3(origin.x, height - y_in, origin.y)
					holder.rotation.y = deg_to_rad(theta)
					parent.add_child(holder)

					# `model` lets a piece borrow another's art. A tunnel is an
					# ordinary straight with a shell over it, and the kit has no
					# tunnel tile to point at.
					var inst: Node3D = load(
						"res://assets/kenney/racing_kit/%s.glb"
						% desc.get("model", piece)
					).instantiate()
					var shift: Vector2 = desc["shift"]
					inst.position = Vector3(shift.x, 0.0, shift.y)
					holder.add_child(inst)

				return [exit_pos, want_heading, pos, origin, theta, height + rise, holder]

	push_error("no placement for %s heading %s -> %s rise_sign %d" % [
		piece, heading, want_heading, rise_sign
	])
	return [pos, heading, pos, Vector2.ZERO, 0.0, height, null]

func _rotate(v: Vector2, deg: float) -> Vector2:
	var a := deg_to_rad(deg)
	var c := cos(a)
	var s := sin(a)
	# Matches Godot's Y-rotation acting on (x, z).
	return Vector2(v.x * c + v.y * s, -v.x * s + v.y * c)

func _world(p: Vector2, h: float) -> Vector3:
	return Vector3(p.x * SCALE, h * SCALE * VERT, p.y * SCALE)

## The index the next traced point will extend from, so a tile can be given the
## span it occupies. Zero on the first piece, whose entry point does not exist
## yet — the tracer appends it.
func _mark() -> int:
	return maxi(centreline.size() - 1, 0)

func _record(holder: Node3D, from_idx: int) -> void:
	if holder == null:
		return
	_placed.append({"holder": holder, "from": from_idx, "to": centreline.size() - 1})

## Height of the eased ramp's surface a fraction `t` of the way along it, as a
## fraction of its total rise.
##
## This is `roadRampLongCurved`'s own profile, recovered from the mesh: it is
## smootherstep, matching the art to under a centimetre at every one of its 25
## rows of vertices. It is reproduced here rather than sampled from the GLB
## because `measure()` traces the centreline without loading a single mesh, and
## the editor measures on every mouse move.
##
## The point of it is that the derivative is zero at both ends, so the ramp
## meets the flat road it joins at a matched gradient. The plain `roadRampLong`
## wedge meets it at 25%, and that step in gradient is a bump the wheels find
## even though nothing about the road looks raised.
static func _ease(t: float) -> float:
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)

## The height one tile of `piece` gains, read from its own connection heights so
## the chain arithmetic in `build` cannot drift from the art.
func _tile_rise(piece: String) -> float:
	var conn_y: Dictionary = PIECES.get(piece, {}).get("conn_y", {})
	var lo := INF
	var hi := -INF
	for key in conn_y:
		lo = minf(lo, conn_y[key])
		hi = maxf(hi, conn_y[key])
	return 0.0 if lo > hi else hi - lo

## Samples a straight into the centreline. Flat straights only need their two
## ends, but bank transitions and ramp profiles are curves drawn along the
## straight, so it is subdivided finely enough to carry them.
##
## `chain` is set for a tile that is one of several ramps making a single level
## change. It carries the chain's `base` height, total `rise`, tile `count` and
## this tile's `index`, and makes the profile here a slice of one ease across the
## whole chain rather than a complete ease across this tile. `from_h` and `to_h`
## still describe the mesh, which keeps its own shape and its own placement; the
## difference between the two profiles is recorded in `_ramp_lift` and applied to
## the tile's vertices later, so the road the player sees is the road the ribbon
## is built from.
func _trace_straight(
	piece: String, from: Vector2, from_h: float, to: Vector2, to_h: float,
	chain: Dictionary = {}
) -> void:
	if centreline.is_empty():
		centreline.append(_world(from, from_h))
		_ramp_lift.append(0.0)

	var eased: bool = PIECES.get(piece, {}).get("eased", false)
	var steps := maxi(1, int(ceil(from.distance_to(to) / TRACE_STEP)))
	if eased:
		steps = maxi(steps, RAMP_STEPS)
	for i in range(1, steps + 1):
		var t := float(i) / float(steps)
		var tile_h := lerpf(from_h, to_h, _ease(t) if eased else t)
		var h := tile_h
		if not chain.is_empty():
			var u := (float(chain["index"]) + t) / float(chain["count"])
			h = float(chain["base"]) + float(chain["rise"]) * _ease(u)
		centreline.append(_world(from.lerp(to, t), h))
		# In world units, because that is where the vertices it corrects live.
		_ramp_lift.append((h - tile_h) * SCALE * VERT)

func _trace_arc(
	piece: String, origin: Vector2, theta: float, from: Vector2, to: Vector2, h: float
) -> void:
	var desc: Dictionary = PIECES[piece]
	if not desc.has("arc"):
		_trace_straight(piece, from, h, to, h)
		return
	if centreline.is_empty():
		centreline.append(_world(from, h))
		_ramp_lift.append(0.0)

	var centre := origin + _rotate(desc["arc"], theta)
	var v0 := from - centre
	var v1 := to - centre
	var a0 := atan2(v0.y, v0.x)
	var a1 := atan2(v1.y, v1.x)
	var radius := v0.length()
	# Take the short way round; a tile corner is always a quarter turn.
	var delta := wrapf(a1 - a0, -PI, PI)
	for i in range(1, ARC_STEPS + 1):
		var a: float = a0 + delta * (float(i) / ARC_STEPS)
		centreline.append(_world(centre + Vector2(cos(a), sin(a)) * radius, h))
		# Corner tiles are flat end to end, so they are never part of a chain.
		_ramp_lift.append(0.0)

# --- banking ---

## Records that the arc just traced wants banking, and how much.
##
## `degrees` comes from the layout when it says, and from the corner's own radius
## when it does not: a size-N corner is an NxN block, so `arc` is (N, N) and N
## picks the default level. That also means the bridge corners default the same
## way as the flat ones, which is what you want — an elevated sweeper is exactly
## where you least want the road to go level.
func _note_corner(piece: String, turn: String, from_idx: int, degrees: float) -> void:
	if is_zero_approx(degrees):
		return
	# Positive rolls the outside of a left-hander up; a right-hander is its
	# mirror, so it simply carries the opposite sign all the way through.
	var sign := 1.0 if turn == "left" else -1.0
	_corner_spans.append({
		"from": from_idx,
		"to": centreline.size() - 1,
		"bank": deg_to_rad(clampf(degrees, -MAX_BANK_DEG, MAX_BANK_DEG)) * sign,
	})

## Turns the per-corner requests into a roll angle for every centreline point.
##
## Each corner holds its full bank across its own arc and eases to nothing over
## `BANK_TRANSITION` of road at each end, and the contributions are *summed*.
## Summing is what makes an S-bend work: a left immediately followed by a right
## has overlapping transitions of opposite sign, which cancel through the middle,
## so the road rolls from one way to the other through flat exactly where the car
## changes hands. Taking the strongest instead would hold one corner's bank right
## up to the other's and put a step between them.
##
## Two corners the same way round that close together do reinforce, which is why
## the total is clamped.
func _build_bank_profile() -> void:
	bank.resize(centreline.size())
	bank.fill(0.0)
	_sides = _side_vectors()
	if _corner_spans.is_empty() or centreline.size() < 2:
		return

	# Arc length at each point, and the loop's total, so transitions can be
	# measured in metres of road rather than in points — the sampling is not
	# uniform, and an arc step is a third of a straight's step.
	var arc := PackedFloat32Array()
	arc.resize(centreline.size())
	arc[0] = 0.0
	for i in range(1, centreline.size()):
		arc[i] = arc[i - 1] + centreline[i - 1].distance_to(centreline[i])
	var total: float = arc[arc.size() - 1]
	if total <= 0.0:
		return

	var transition := BANK_TRANSITION * SCALE
	var limit := deg_to_rad(MAX_BANK_DEG)
	for span in _corner_spans:
		var a: float = arc[span["from"]]
		var b: float = arc[span["to"]]
		var amount: float = span["bank"]
		for i in centreline.size():
			var d := _arc_distance_outside(arc[i], a, b, total)
			if d >= transition:
				continue
			bank[i] += amount * _ease(1.0 - d / transition)
	for i in bank.size():
		bank[i] = clampf(bank[i], -limit, limit)

	# Ride the centreline up onto the embankment, so it goes on describing the
	# middle of the road. Height still closes: bank is zero at the start line, so
	# the lift is zero there too, and the walker's own running height — which is
	# what closure is measured from — is not touched at all.
	for i in centreline.size():
		centreline[i].y += _bank_lift(bank[i])

## How far a point is from the span [a, b], measured the short way round the
## loop; zero inside it.
##
## Wrapping matters: the corner before the start line has its exit transition
## running off the end of the centreline and onto the beginning, and without the
## wrap that corner alone would snap flat at the start/finish line.
static func _arc_distance_outside(s: float, a: float, b: float, total: float) -> float:
	var from_a := fposmod(s - a, total)
	var span := fposmod(b - a, total)
	if from_a <= span:
		return 0.0
	return minf(from_a - span, total - from_a)

## The centreline's lateral direction at each point — the car's right — averaged
## across the two segments meeting there.
##
## Averaging is the point. Taking each quad's own perpendicular leaves the two
## quads at a shared point disagreeing by the turn between them, which on an arc
## step is over a metre of overlap at the ribbon's edge. Flat, that is invisible;
## banked, the two quads also disagree about which way is up, and the seam
## becomes a step the wheels drop off.
func _side_vectors() -> Array[Vector3]:
	var sides: Array[Vector3] = []
	sides.resize(centreline.size())
	var dirs: Array[Vector2] = []
	for i in centreline.size() - 1:
		var d := centreline[i + 1] - centreline[i]
		var flat := Vector2(d.x, d.z)
		dirs.append(flat.normalized() if flat.length() > 0.001 else Vector2.ZERO)
	for i in centreline.size():
		var before: Vector2 = dirs[i - 1] if i > 0 else dirs[dirs.size() - 1]
		var after: Vector2 = dirs[i] if i < dirs.size() else dirs[dirs.size() - 1]
		var avg := before + after
		if avg.length() < 0.001:
			avg = after if after != Vector2.ZERO else before
		avg = avg.normalized()
		sides[i] = Vector3(-avg.y, 0.0, avg.x)
	return sides

## How far the middle of a banked road stands above the ground it is built on.
##
## The embankment rises from its inside edge, so the centre of the road ends up
## half the total climb above ground level. `_build_bank_profile` adds this to the
## centreline itself, which keeps "the centreline is the middle of the road" true
## for the things that rely on it — where the grid sits, where the timing gates
## hang — through a banked corner as much as through a flat one.
static func _bank_lift(roll: float) -> float:
	return absf(tan(roll)) * BANK_FULL_HALF

## The road's cross-section: how far the surface sits above the centreline at a
## lateral offset of `lateral` metres, under a roll of `roll` radians.
##
## Purely vertical — the point does not move sideways. A rigid roll would also
## pull it inwards by cos(roll), which at 10 degrees is 1.5% of the road's width
## for no visible gain, and it would leave the deformation unable to reproduce a
## point exactly where the bank is zero. Vertical-only is exact there, which is
## what lets a tile that is banked at one end and flat at the other stay welded to
## the tiles either side of it.
##
## Shape, from the inside of the corner outwards: flat apron at ground level, a
## straight climb across the whole width of the road, then a straight grade back
## down to ground by the edge of the tile — with every join between those rounded
## off over `BANK_FILLET`.
##
## The straights are straight rather than eased because an eased grade peaks at
## nearly twice its average slope, and it is the peak that decides whether a car
## running wide is turned back or thrown. The rounding is what stops the joins
## between them doing the throwing instead.
static func _bank_rise(lateral: float, roll: float) -> float:
	if is_zero_approx(roll):
		return 0.0
	var climb := absf(tan(roll))
	var lift := climb * BANK_FULL_HALF
	# Measured towards the high side, so one set of cases covers both hands.
	var out := lateral * signf(roll)

	var ground := -lift
	var road := climb * out
	var apron := (
		climb * 2.0 * BANK_FULL_HALF
		* (BANK_FADE_HALF - out) / (BANK_FADE_HALF - BANK_FULL_HALF)
		- lift
	)

	if out < -BANK_FULL_HALF - BANK_FILLET:
		return ground
	if out < -BANK_FULL_HALF + BANK_FILLET:
		return lerpf(ground, road, _bank_blend(out, -BANK_FULL_HALF))
	if out < BANK_FULL_HALF - BANK_FILLET:
		return road
	if out < BANK_FULL_HALF + BANK_FILLET:
		return lerpf(road, apron, _bank_blend(out, BANK_FULL_HALF))
	if out < BANK_FADE_HALF - BANK_FILLET:
		return apron
	if out < BANK_FADE_HALF + BANK_FILLET:
		return lerpf(apron, ground, _bank_blend(out, BANK_FADE_HALF))
	return ground

## Rounds one join. Zero slope at both ends of the window, so the blended curve
## leaves each straight at exactly the straight's own gradient and the profile has
## no corner left in it anywhere.
static func _bank_blend(out: float, at: float) -> float:
	return smoothstep(-1.0, 1.0, (out - at) / BANK_FILLET)

## The same cross-section's gradient, for turning normals with the surface.
##
## Differentiated numerically rather than by hand. The rounded profile has six
## cases and the normals have to agree with the shape exactly — a hand-derived
## twin would be one more thing to keep in step, for a saving of nothing that
## matters at build time.
static func _bank_slope(lateral: float, roll: float) -> float:
	const STEP := 0.05
	return (
		_bank_rise(lateral + STEP, roll) - _bank_rise(lateral - STEP, roll)
	) / (2.0 * STEP)

## A point on the driving surface: `lateral` metres to the side of a centreline
## point, lifted by the bank's cross-section there.
static func _ribbon_point(
	at: Vector3, side: Vector3, roll: float, lateral: float
) -> Vector3:
	return at + side * lateral + Vector3.UP * _bank_rise(lateral, roll)

## Lateral offsets at which the collision ribbon is sampled across its width.
##
## The straight parts of the cross-section need a cut only at each end, because a
## strip reproduces a straight exactly. The rounded joins have to be sampled
## *through*, and the join between the road and its apron gets the most: it is
## the convex one, so it is the only place where the corners left between samples
## can still throw the car. Sampling it coarsely would just replace one sharp
## crest with a handful of smaller ones.
##
## A single quad edge to edge, which is what this used to be, would interpolate
## straight across the whole cross-section and give the car a flat road under a
## banked one.
static func _ribbon_cuts() -> Array[float]:
	var cuts: Array[float] = [-RIBBON_HALF, 0.0, RIBBON_HALF]
	for side in [-1.0, 1.0]:
		# Three samples through each rounded join is enough to keep the shape
		# without the ribbon getting expensive: it is a static shape, but it is
		# also serialised into the committed scene files, and finer sampling was
		# measured to buy nothing at all — nine samples across the crest left the
		# car exactly as planted as three.
		for k in range(-1, 2):
			cuts.append(side * (BANK_FULL_HALF + BANK_FILLET * k))
			cuts.append(side * (BANK_FADE_HALF + BANK_FILLET * k))
	cuts.sort()

	var out: Array[float] = []
	for c in cuts:
		if c < -RIBBON_HALF or c > RIBBON_HALF:
			continue
		if out.is_empty() or c - out[out.size() - 1] > 0.001:
			out.append(c)
	return out

## Rebuilds the tiles that sit on banked road so the art agrees with what the
## wheels are driving on.
##
## There is no banked corner in the Kenney kit, and there is no rigid rotation
## that would make one: a corner held at a constant bank is a slice of a cone,
## so the roll has to be applied per vertex, about the arc, not to the tile as a
## whole. Rolling the tile bodily instead leaves its two ends tilted across the
## straights they join, which shows up as a step at every corner entry.
##
## So each affected tile's mesh is rebuilt vertex by vertex. The Kenney art is
## kept exactly — same surfaces, same materials, same kerbs and markings — and
## only the shape changes. Everything on the tile rolls, the verge included,
## which is what makes the road read as banked rather than as a flat road with a
## tilted stripe on it.
##
## Tiles on flat road are left alone, so they keep sharing one imported mesh;
## only corners and the road either side of them pay for a unique one.
## Two things send a tile through the reshaper, and they use the same machinery:
## a corner that is banked, and a ramp inside a chain whose grade is the chain's
## rather than its own. Both are a per-vertex vertical correction against the
## centreline; see `_roll_point`.
func _reshape_tiles() -> void:
	for entry in _placed:
		# A segment of margin at each end, so a vertex on the seam between two
		# tiles projects onto the same centreline segment whichever tile it
		# belongs to, and the two stay welded instead of tearing open.
		var lo: int = maxi(int(entry["from"]) - 1, 0)
		var hi: int = mini(int(entry["to"]) + 1, centreline.size() - 1)
		if not _span_is_banked(lo, hi) and not _span_is_lifted(lo, hi):
			continue
		_reshape_tile(entry["holder"], lo, hi)

func _span_is_banked(lo: int, hi: int) -> bool:
	for i in range(lo, hi + 1):
		if absf(bank[i]) > BANK_EPSILON:
			return true
	return false

func _span_is_lifted(lo: int, hi: int) -> bool:
	for i in range(lo, hi + 1):
		if absf(_ramp_lift[i]) > LIFT_EPSILON:
			return true
	return false

## Swaps a tile's imported scene for a single `MeshInstance3D` carrying a baked,
## banked copy of its geometry.
##
## Replacing the instance rather than overriding the mesh inside it is
## deliberate. A property written onto a node *inside* an instanced sub-scene is
## the same mechanism that has already shipped a car with eight wheels here, and
## it would leave the shipped `.tscn` files depending on override behaviour for
## something as load-bearing as the shape of the road. A node this builder owns
## outright packs and reloads with no such subtlety.
##
## The replacement keeps the holder's "one mesh per piece" shape and sits at
## identity, with its vertices baked into holder space.
func _reshape_tile(holder: Node3D, lo: int, hi: int) -> void:
	var holder_to_track := (holder.get_parent() as Node3D).transform * holder.transform
	var track_to_holder := holder_to_track.affine_inverse()

	var sources: Array = []
	for mi in _mesh_instances(holder):
		if mi.mesh != null:
			sources.append([mi.mesh, holder_to_track * _relative_transform(mi, holder)])
	if sources.is_empty():
		return

	for child in holder.get_children():
		holder.remove_child(child)
		child.free()

	for src in sources:
		var mi := MeshInstance3D.new()
		mi.mesh = _reshaped_mesh(
			src[0], src[1], holder_to_track, track_to_holder, lo, hi
		)
		holder.add_child(mi)

## A copy of `src` with every vertex rolled about the centreline, expressed in
## the holder's own space.
func _reshaped_mesh(
	src: Mesh, local_to_track: Transform3D, holder_to_track: Transform3D,
	track_to_holder: Transform3D, lo: int, hi: int
) -> ArrayMesh:
	# Normals do not transform like positions under a non-uniform scale, and
	# `RoadVisuals` carries one — VERT squashes y to half. The inverse transpose
	# is what keeps them perpendicular to the surface through that squash.
	var normals_to_track := local_to_track.basis.inverse().transposed()
	var normals_from_track := holder_to_track.basis.transposed()

	var out := ArrayMesh.new()
	for s in src.get_surface_count():
		var arrays: Array = src.surface_get_arrays(s)
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var has_normals := normals != null and normals.size() == verts.size()

		var new_verts := PackedVector3Array()
		new_verts.resize(verts.size())
		var new_normals := PackedVector3Array()
		if has_normals:
			new_normals.resize(verts.size())

		for i in verts.size():
			var at := local_to_track * verts[i]
			var frame := _frame_at(at, lo, hi)
			if frame.is_empty():
				new_verts[i] = track_to_holder * at
				if has_normals:
					new_normals[i] = normals[i]
				continue
			new_verts[i] = track_to_holder * _roll_point(at, frame)
			if has_normals:
				new_normals[i] = (
					normals_from_track * _roll_direction(
						(normals_to_track * normals[i]).normalized(), frame
					)
				).normalized()

		arrays[Mesh.ARRAY_VERTEX] = new_verts
		if has_normals:
			arrays[Mesh.ARRAY_NORMAL] = new_normals
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		out.surface_set_material(s, src.surface_get_material(s))
	return out

## Where a point sits relative to the road: the centreline point directly below
## it, the roll there, and its own offset from it split into lateral,
## along-track and vertical parts.
##
## The search is horizontal, and restricted to the tile's own stretch of
## centreline. Both matter. Projecting in 3D would fold the road's gradient into
## the lateral offset, so a vertex on a ramp would slide along the road as well
## as across it; and searching the whole loop would be a few hundred segments per
## vertex, on tiles with hundreds of vertices, at runtime.
func _frame_at(w: Vector3, lo: int, hi: int) -> Dictionary:
	var p := Vector2(w.x, w.z)
	var best := INF
	var out := {}
	for i in range(lo, hi):
		var a := centreline[i]
		var b := centreline[i + 1]
		var base := Vector2(a.x, a.z)
		var seg := Vector2(b.x - a.x, b.z - a.z)
		var len2 := seg.length_squared()
		if len2 < 0.000001:
			continue
		var t := clampf((p - base).dot(seg) / len2, 0.0, 1.0)
		var foot := base + seg * t
		var d := foot.distance_squared_to(p)
		if d >= best:
			continue
		best = d
		var tangent := seg / sqrt(len2)
		var side: Vector3 = _sides[i].lerp(_sides[i + 1], t)
		side = side.normalized() if side.length() > 0.001 else _sides[i]
		out = {
			"side": side,
			"tangent": Vector3(tangent.x, 0.0, tangent.y),
			"roll": lerpf(bank[i], bank[i + 1], t),
			"lift": lerpf(_ramp_lift[i], _ramp_lift[i + 1], t),
			"lateral": (p - foot).dot(Vector2(side.x, side.z)),
		}
	return out

## Lifts a point onto the banked cross-section. Purely vertical, and exactly the
## same function the collision ribbon is built from, which is what makes the road
## the car drives on the road the player can see.
##
## The bank lift is added back here because a tile is placed at the height the
## walker reached, which is the ground the embankment is built on, while the
## ribbon is measured from a centreline that has already been raised onto it.
## `frame["lift"]` is the other correction of the same kind: inside a multi-tile
## ramp the centreline follows one grade across the whole chain while the mesh
## still carries its own per-tile ease, and this is the gap between them.
static func _roll_point(w: Vector3, frame: Dictionary) -> Vector3:
	var roll: float = frame["roll"]
	return w + Vector3.UP * (
		_bank_rise(frame["lateral"], roll) + _bank_lift(roll) + frame["lift"]
	)

## The matching rotation for a normal: the surface has been tilted by its own
## local gradient, which is the full bank across the tarmac and the opposite way
## across the verge that grades back down.
static func _roll_direction(v: Vector3, frame: Dictionary) -> Vector3:
	var angle := atan(_bank_slope(frame["lateral"], frame["roll"]))
	var side: Vector3 = frame["side"]
	var tangent: Vector3 = frame["tangent"]
	var cs := cos(angle)
	var sn := sin(angle)
	var lateral := v.dot(side)
	return (
		side * (lateral * cs - v.y * sn)
		+ Vector3.UP * (lateral * sn + v.y * cs)
		+ tangent * v.dot(tangent)
	).normalized()

static func _mesh_instances(root_node: Node) -> Array[MeshInstance3D]:
	var out: Array[MeshInstance3D] = []
	if root_node is MeshInstance3D:
		out.append(root_node)
	for c in root_node.get_children():
		out.append_array(_mesh_instances(c))
	return out

static func _relative_transform(node: Node3D, ancestor: Node3D) -> Transform3D:
	var out := Transform3D()
	var at := node
	while at != null and at != ancestor:
		out = at.transform * out
		at = at.get_parent() as Node3D
	return out

## Above this height a section is carried on a bridge deck, and there is no
## ground beside it.
const RAISED_ABOVE := 0.5

## How far out the road's usable edge is at a point, in metres.
##
## On the ground it is `RIBBON_HALF`: the collision ribbon runs 1.4 m past the
## visible tile, over the verge, which is deliberate — it catches a car that has
## run wide instead of dropping it off an invisible kerb.
##
## **On a raised section there is no verge.** The tile *is* the deck and it stops
## at `ROAD_HALF`, so anything placed beyond that is standing in mid-air. That is
## exactly how the trackside railing looked on every bridge: its outer face sat at
## 8.9 m against a deck edge at 7.
func _edge_half(i: int) -> float:
	return ROAD_HALF if centreline[i].y > RAISED_ABOVE else RIBBON_HALF

## The group the drivable ribbon's body joins, and the collision layer it adds to
## itself, so anything that needs to know whether a point is on the road can ask
## the collision world rather than re-deriving it from the centreline.
##
## The group is how you *find* the road; the layer is how you *ask about* it. A
## ray masked to `ROAD_LAYER` can hit nothing else, so the question needs one cast
## and has one answer.
##
## That took two attempts. The obvious version — cast normally and check what came
## back — cannot work here, because the flat parts of the ribbon and the top face
## of the ground slab are at exactly y = 0 and which one a ray returns is
## arbitrary. Walking down through the hits while excluding each collider in turn
## does not rescue it either: measured across the four shipped circuits, the same
## `Ground` body came back three times running from a single point, so the walk
## burned its whole budget and reported road as field on 40% of Suzuka. Masking
## the ray sidesteps the coincidence rather than trying to survive it.
const ROAD_GROUP := "road_surface"
const ROAD_LAYER := 8

## The driving surface: a ribbon of quads along the centreline, as one concave
## shape. Seamless for the raycast wheels, and it follows the elevation changes
## that the flat ground plane cannot.
func _build_road_collision(root_node: Node3D) -> void:
	var body := StaticBody3D.new()
	body.name = "RoadSurface"
	# Grouped, not just named. This is the collision world's answer to "is that
	# point on the road", which `TyreMarks` asks before laying anything so ruts
	# stop at the verge instead of wandering across a field that grips exactly
	# like tarmac. A group survives being packed into a `.tscn`, so it works for
	# the baked circuits and the ones built at runtime alike.
	# `true` for persistent, which is **not** the default. Without it the group
	# lives only on the node in memory and is dropped by `PackedScene.pack`, so
	# every runtime-built circuit knew where its road was and every shipped one
	# did not — marks would simply have stopped appearing on the baked tracks.
	body.add_to_group(ROAD_GROUP, true)
	# Layer 1 as well, so everything that collided with the road before still
	# does; the extra bit is only there to be asked about.
	body.collision_layer |= ROAD_LAYER
	root_node.add_child(body)

	var cuts := _ribbon_cuts()
	var faces := PackedVector3Array()
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		if Vector2(b.x - a.x, b.z - a.z).length() < 0.001:
			continue
		# Each end carries its own roll, so a strip inside a bank transition is
		# twisted rather than flat, and consecutive strips share their edges
		# exactly.
		for k in cuts.size() - 1:
			var a_in := _ribbon_point(a, _sides[i], bank[i], cuts[k])
			var a_out := _ribbon_point(a, _sides[i], bank[i], cuts[k + 1])
			var b_in := _ribbon_point(b, _sides[i + 1], bank[i + 1], cuts[k])
			var b_out := _ribbon_point(b, _sides[i + 1], bank[i + 1], cuts[k + 1])
			faces.append_array([a_in, b_in, b_out])
			faces.append_array([a_in, b_out, a_out])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	# Concave shapes are one-sided by default, so whether the ribbon collides at
	# all depends on triangle winding - and getting that wrong means the car
	# silently falls through the elevated sections. Collide from both sides.
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.name = "RoadCollision"
	col.shape = shape
	body.add_child(col)
	_triangles = faces.size() / 3

## How high anything built so far stands over a point, or 0 if nothing does.
##
## Used to find the start gantry's arch, which is a Kenney tile and knows its own
## height far better than a constant here does.
func _height_over(root_node: Node3D, point: Vector3, radius: float) -> float:
	return _gantry(root_node, point, radius, Vector3.ZERO).x

## The start gantry, measured out of the scene that was just built: how tall it
## stands over `point`, and how far its **front face** is from that point back
## towards the grid.
##
## The face is the number that matters. The arch straddles the start line, so a
## panel placed at the line itself sits inside the structure, halfway through its
## depth — which is what "in the middle of the fixture rather than placed on it"
## looks like. A sign goes *on* a wall.
##
## Only the parts of the tile that are actually arch are measured: anything below
## `GANTRY_MIN_H` is the road it is standing on, and including that would put the
## face at the end of the tile rather than at the front of the structure.
func _gantry(
	root_node: Node3D, point: Vector3, radius: float, along: Vector3
) -> Vector2:
	var top := 0.0
	var face := 0.0
	var visuals := root_node.get_node_or_null("RoadVisuals")
	if visuals == null:
		return Vector2.ZERO
	for mi in _mesh_instances(visuals):
		if mi.mesh == null:
			continue
		var where := _relative_transform(mi, root_node)
		var box := mi.mesh.get_aabb()
		var centre: Vector3 = where * (box.position + box.size * 0.5)
		if Vector2(centre.x - point.x, centre.z - point.z).length() > radius:
			continue
		var high: float = (where * (box.position + box.size)).y - point.y
		if high < GANTRY_MIN_H:
			continue
		top = maxf(top, high)
		if along == Vector3.ZERO:
			continue
		# How far back along the road this piece reaches, taking every corner of
		# its box so a rotated tile is measured honestly.
		for cx in [0.0, 1.0]:
			for cz in [0.0, 1.0]:
				for cy in [0.0, 1.0]:
					var corner: Vector3 = where * (box.position
						+ Vector3(box.size.x * cx, box.size.y * cy, box.size.z * cz))
					face = minf(face, (corner - point).dot(along))
	return Vector2(top, face)

## The start lights, on the gantry the grid sits under.
##
## A race used to simply *begin* — the scene loaded and the car was already free,
## which is the one moment of a race that every driver looks at and there was
## nothing there. Five lights that come on one at a time and then go out together
## is the whole grammar of a motor race start, and it costs one row of boxes.
##
## Mounted on the arch of the `roadStart` tile, which is why they are placed off
## `START_LINE_ARC` rather than off the spawn: the car sits *behind* the line in
## the pole box, and lights hung over the car would be behind the driver.
##
## The housings are lit geometry; each lens is its own node so it can glow on its
## own. `start_lights.gd` runs the countdown and swaps the lens materials.
func _build_start_lights(root_node: Node3D) -> void:
	if centreline.size() < 4:
		return
	var sample := _point_at_arc(START_LINE_ARC)
	if sample.is_empty():
		return
	var at: Vector3 = sample[0]
	var tan: Vector2 = sample[1]

	var rig := Node3D.new()
	rig.name = "StartLights"
	rig.set_script(load("res://scripts/track/start_lights.gd"))
	# **Hung from the gantry, not floating at a guessed height.**
	#
	# `LIGHTS_HEIGHT` was a constant, and a constant cannot know how tall the
	# `roadStart` arch actually is — so the lights hovered above the structure
	# they are supposed to be bolted to. The arch is measured out of the scene
	# that was just built, and the bar hangs a fixed drop below its underside.
	var found := _gantry(root_node, at, LIGHTS_REACH, Vector3.ZERO)
	var hang: float = (found.x - LIGHTS_DROP) if found.x > 0.0 else LIGHTS_HEIGHT
	rig.position = at + Vector3.UP * clampf(hang, 4.5, 12.0)

	# > **Mounting it on the *face* of the arch is not done, and it is the thing
	# > that would make it read as fitted.** The panel sits at the start line,
	# > which is the middle of the arch's depth, so it is inside the structure
	# > rather than on it — a sign hung through a wall instead of on it.
	# >
	# > `_gantry` will report the front face when given a direction along the
	# > road, and it was tried: it moved the panel 0.12 m, because measuring
	# > "furthest back" across the arch's own mesh boxes does not find the face
	# > the grid sees. What that needs is the `roadStart` piece's own geometry
	# > understood — which corner of which sub-mesh is the front — rather than an
	# > extent taken over the lot.
	rig.rotation.y = _yaw_along(tan)
	root_node.add_child(rig)

	var housings := SurfaceTool.new()
	housings.begin(Mesh.PRIMITIVE_TRIANGLES)
	# A dark backing board behind the lamps, which is what a real gantry panel is
	# and what makes the lamps *read*. Tucked under the arch they are seen against
	# whatever the sky is doing beyond it, and a lit lens against a bright sky is
	# a smaller contrast than the same lens against black.
	_box(housings, Vector3(0.0, 0.0, LIGHTS_SIZE * 0.2),
		Vector3(LIGHTS_SPAN + LIGHTS_SIZE * 0.85, LIGHTS_SIZE * 1.6,
			LIGHTS_SIZE * 0.18))
	# One lamp per node rather than one mesh for the row, because they light **in
	# sequence** — three going on one at a time as the count runs down, then all
	# three turning green together. A single shared material can only be all on or
	# all off, which is a set of traffic lights rather than a countdown.
	var span := LIGHTS_SPAN - LIGHTS_SIZE
	for i in LIGHTS_COUNT:
		var across := (float(i) / float(LIGHTS_COUNT - 1) - 0.5) * span
		_box(housings, Vector3(across, 0.0, 0.0),
			Vector3(LIGHTS_SIZE * 1.3, LIGHTS_SIZE * 1.3, LIGHTS_SIZE * 0.5))

		var lens_shape := SurfaceTool.new()
		lens_shape.begin(Mesh.PRIMITIVE_TRIANGLES)
		# Proud of the housing on the face the grid can see. The grid is behind
		# the line, and `_yaw_along` puts local +Z down the circuit, so that face
		# is local -Z.
		_box(lens_shape, Vector3(across, 0.0, -LIGHTS_SIZE * 0.3),
			Vector3(LIGHTS_SIZE, LIGHTS_SIZE, LIGHTS_SIZE * 0.3))
		lens_shape.generate_normals()
		var lens := MeshInstance3D.new()
		lens.name = "Lens%d" % i
		lens.mesh = lens_shape.commit()
		lens.material_override = StartLights.lens_material(StartLights.LENS_DARK)
		rig.add_child(lens)

	housings.generate_normals()
	var housing_mesh: ArrayMesh = housings.commit()
	var dark := StandardMaterial3D.new()
	dark.albedo_color = LIGHTS_HOUSING
	dark.roughness = 0.8
	housing_mesh.surface_set_material(0, dark)
	var frame := MeshInstance3D.new()
	frame.name = "Housings"
	frame.mesh = housing_mesh
	rig.add_child(frame)

func _build_checkpoints(root_node: Node3D) -> void:
	var holder := Node3D.new()
	holder.name = "Checkpoints"
	root_node.add_child(holder)

	var total := _total_length()
	var step := total / float(CHECKPOINT_COUNT)
	_gate_spacing = step

	var script: Script = load("res://scripts/track/checkpoint.gd")
	# Gate 0 goes on the painted line and the rest follow it round, rather than
	# all of them hanging off arc zero. Otherwise the lap both starts and ends
	# before the car reaches the line it is being timed to.
	#
	# The box is then pushed forward by half its own depth, because `body_entered`
	# fires when the car first touches the *leading face* — so it is that face,
	# not the centre, that is the trigger plane and belongs on the line. The gate
	# is deliberately thick so nothing tunnels through it at speed, and every
	# metre of that thickness was a metre of the lap timed early.
	for i in CHECKPOINT_COUNT:
		var sample := _point_at_arc(
			START_LINE_ARC + CHECKPOINT_T * 0.5 + step * float(i)
		)
		var pt: Vector3 = sample[0]
		var tan: Vector2 = sample[1]

		var area := Area3D.new()
		area.name = "Checkpoint%02d" % i
		area.set_script(script)
		area.set("index", i)
		area.position = pt + Vector3(0.0, CHECKPOINT_H * 0.5, 0.0)
		area.rotation.y = atan2(tan.x, tan.y)
		holder.add_child(area)

		var col := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3(CHECKPOINT_W, CHECKPOINT_H, CHECKPOINT_T)
		col.shape = box
		area.add_child(col)

## Something solid at the edge of the road, so running wide has a consequence.
##
## **Collision only.** The rails you can see are scenery, built as one
## `MultiMesh` by `_scenery_barrier`, and this deliberately does not build a
## second set: an earlier version of this function instanced a `MeshInstance3D`
## per rail, which is several hundred draw calls a lap on a single-threaded
## compatibility-renderer web build, and every one of them would have been sitting
## inside a rail that was already there.
##
## One `ConcavePolygonShape3D` for the whole circuit rather than a box per
## segment, for the same reason the road surface is one shape: the centreline has
## a point every metre or so, and a `CollisionShape3D` apiece would be well over a
## thousand nodes in every baked scene.
##
## `backface_collision` because the winding differs between the two sides and a
## wall that only stops the car from one direction is worse than no wall — you
## would drive through it from the outside and then be trapped behind it.
func _build_wall_collision(root_node: Node3D) -> void:
	var walls := StaticBody3D.new()
	walls.name = "Walls"
	root_node.add_child(walls)

	# Built on the **edge of the drivable ribbon**, from the same `_ribbon_point`
	# the road collision is built from, rather than by offsetting the centreline
	# by a constant.
	#
	# That is a correction, not a preference. `_offset_line` pushes each segment
	# out perpendicular in plan by a fixed gap, and on a corner tighter than that
	# gap the inside line folds through the centre and comes out the other side —
	# a size-1 corner has a 7 m centreline radius against a 9.8 m gap, so the
	# inside wall landed *on the tarmac*, 6.6 m from the centreline. It also
	# ignored roll and elevation, so a wall on a banked corner stood in the air.
	# Standing the wall on the ribbon's own edge makes it the boundary of the
	# drivable surface by construction, and it inherits banking and height for
	# free.
	var faces := PackedVector3Array()
	for hand in [-1.0, 1.0]:
		for i in centreline.size() - 1:
			# Tucked in to the deck edge on a bridge; see `_edge_half`.
			var side: float = _edge_half(i) * hand
			var next_side: float = _edge_half(i + 1) * hand
			var a := _ribbon_point(centreline[i], _sides[i], bank[i], side)
			var b := _ribbon_point(centreline[i + 1], _sides[i + 1], bank[i + 1], next_side)
			if a.distance_to(b) < 0.01:
				continue
			var a_top := a + Vector3.UP * WALL_H
			var b_top := b + Vector3.UP * WALL_H
			faces.append_array([a, b, b_top])
			faces.append_array([a, b_top, a_top])

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	shape.backface_collision = true
	var col := CollisionShape3D.new()
	col.name = "WallCollision"
	col.shape = shape
	walls.add_child(col)

func _first_mesh(n: Node) -> MeshInstance3D:
	if n is MeshInstance3D:
		return n
	for c in n.get_children():
		var m := _first_mesh(c)
		if m != null:
			return m
	return null

## A copy of the centreline pushed `gap` tile units to one side; `side` is +1 for
## the driver's right. Scenery asks for several different gaps, so the distance
## is a parameter rather than the wall's own constant.
func _offset_line(side: float, gap := WALL_GAP) -> Array[Vector3]:
	var out: Array[Vector3] = []
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var d := Vector2(b.x - a.x, b.z - a.z)
		if d.length() < 0.01:
			continue
		var n := Vector2(-d.y, d.x).normalized() * gap * side
		var off := Vector3(n.x, 0.0, n.y)
		if out.is_empty():
			out.append(a + off)
		out.append(b + off)
	return out

func _total_length() -> float:
	var total := 0.0
	for i in centreline.size() - 1:
		total += centreline[i].distance_to(centreline[i + 1])
	return total

## Position and horizontal tangent at a given arc length along the centreline.
##
## The arc wraps, because everything is now placed relative to the start line:
## the grid slot sits at a negative arc and the last gates run past the end.
func _point_at_arc(target: float) -> Array:
	if centreline.is_empty():
		return [Vector3.ZERO, Vector2(0, 1)]
	var total := _total_length()
	if total <= 0.0:
		return [centreline[0], Vector2(0, 1)]
	target = fposmod(target, total)
	var travelled := 0.0
	for i in centreline.size() - 1:
		var a := centreline[i]
		var b := centreline[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		if travelled + seg_len >= target:
			var dir := seg / seg_len
			return [a + dir * (target - travelled), Vector2(dir.x, dir.z).normalized()]
		travelled += seg_len
	var last := centreline[centreline.size() - 1]
	return [last, Vector2(0, 1)]

## Walks a 3D polyline at fixed arc-length intervals, returning
## [point, horizontal tangent].
func _resample(line: Array[Vector3], step: float) -> Array:
	var out := []
	# A zero step would advance the walk by nothing and spin forever. The tool
	# could never reach that, but a player's half-painted loop can compile to a
	# degenerate centreline, and the editor recompiles on every mouse move.
	if line.size() < 2 or step <= 0.0:
		return out
	var carry := 0.0
	for i in line.size() - 1:
		var a := line[i]
		var b := line[i + 1]
		var seg := b - a
		var seg_len := seg.length()
		if seg_len < 0.001:
			continue
		var dir := seg / seg_len
		var flat := Vector2(dir.x, dir.z).normalized()
		var t := carry
		while t < seg_len:
			out.append([a + dir * t, flat])
			t += step
		carry = t - seg_len
	return out

func _build_ground(root_node: Node3D, track_name: String = "") -> void:
	var ground := StaticBody3D.new()
	ground.name = "Ground"
	root_node.add_child(ground)

	var mi := MeshInstance3D.new()
	mi.name = "GroundMesh"
	var plane := PlaneMesh.new()
	plane.size = Vector2(4000.0, 4000.0)
	var shader_mat := ShaderMaterial.new()
	shader_mat.shader = load("res://assets/shaders/ground_grid.gdshader")
	shader_mat.set_shader_parameter("grid_size", 10.0)
	shader_mat.set_shader_parameter("line_width", 0.08)
	# Sits between two greens it has to answer to, and is a compromise on
	# purpose. The road tiles carry a strip of the kit's `grass` (0.586, 0.774,
	# 0.688) along both verges, and the trees are that same colour: against the
	# near-black green this used to be, every tile read as a pale panel laid on
	# the ground with a visible edge, and matching the kit exactly instead made
	# the trees disappear into the field they stand in. A middle value leaves the
	# verge reading as a mown strip and the trees as objects on it.
	# Theme for the colour, hour for how dark it reads. The ground plane is
	# `unshaded` — deliberately, because flat bright grass is the look — which
	# means it receives no light and would otherwise stay noon-bright green under
	# a night sky. The tint is what the lighting cannot do for it.
	var theme := CircuitLook.theme_of(track_name, _look)
	var tint: float = CircuitLook.sky_of(track_name, _look).get("ground_tint", 1.0)
	shader_mat.set_shader_parameter("base_color", (theme["ground"] as Color) * tint)
	shader_mat.set_shader_parameter("line_color", (theme["lines"] as Color) * tint)
	plane.material = shader_mat
	mi.mesh = plane
	mi.position.y = -0.02
	ground.add_child(mi)

	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(4000.0, 1.0, 4000.0)
	col.shape = box
	col.position.y = -0.5
	ground.add_child(col)

## A late-morning sky, and the settings that stop a flat-shaded kit reading as
## flat. The kit's materials are untextured colour at roughness 1, so contrast
## has to come from the light: a warm sun against a cool sky ambient is what
## separates a kerb from the verge next to it.
##
## Fog is doing structural work rather than weather. The ground is a 4 km plane
## and the circuit sits in the middle of it, so without fog the plane ends at a
## hard line against the sky and the far side of the lap is as crisp as the
## corner being driven. Fading both into the sky colour puts a horizon there.

## The look, as far as one hard-coded preset can carry it.
##
## The target is Horizon Chase: vivid flat-shaded colour blocking, big graphic
## skies, bright and readable, never grimy. Kenney's palette is pastel — mint
## grass, near-white kerbs, a soft orange car — so the gap between the kit and
## the target is almost entirely saturation, and saturation is a property of the
## `Environment` rather than of any asset. Nothing here needs new art.
##
## These are constants rather than a resource on purpose. A per-circuit
## time-of-day preset is the right home for them and is scheduled (see
## `docs/roadmap.md`, M16); putting the structure in now, with one circuit's worth
## of values and nothing to vary, would be building the fitting before there is
## anything to fit.
##
## The horizon colour is shared with the fog rather than repeated, because the
## two are the same edge seen twice: fog exists to land the ground plane into the
## sky, and it can only do that while it is the colour the sky is there.
##
## These are the `noon` preset's values, kept as named constants because the
## suite and the editor both want "the default look" without holding a preset.
## The real palette now lives in `SkyPreset`, one entry per hour.
const SKY_SHADER := "res://assets/shaders/sky.gdshader"
const SKY_TOP := Color(0.11, 0.36, 0.85)
const SKY_HORIZON := Color(0.62, 0.82, 0.97)
const GRADE_SATURATION := 1.35
const GRADE_CONTRAST := 1.10
const GRADE_BRIGHTNESS := 1.02

func _build_lighting(root_node: Node3D, track_name: String = "") -> void:
	var preset := CircuitLook.sky_of(track_name, _look)

	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.rotation_degrees = preset["sun_angle"]
	sun.light_color = preset["sun_color"]
	sun.light_energy = preset["sun_energy"]
	# Whether it casts is decided below, once the key light exists: **only one
	# directional light in the scene may cast shadows.**
	sun.shadow_enabled = false
	# The default 0.1 leaves the car's own shadow detached from its tyres at this
	# scale, which reads as the car hovering.
	sun.shadow_normal_bias = 0.5
	sun.directional_shadow_max_distance = 320.0
	root_node.add_child(sun)

	# Recorded on the root rather than passed, because the thing that applies it
	# runs at *load*: `surface_road` rebuilds the road material every race and is
	# static, so it has the track but not the hour. Metadata serialises into the
	# packed scene, so a baked circuit and a painted one carry it the same way.
	root_node.set_meta("road_glow", preset.get("road_glow", 0.0))
	# The centreline, so anything at *runtime* can ask where the road goes.
	#
	# A shipped circuit is a packed scene and the layout that produced it lives in
	# `tools/`, which the game deliberately never loads — so until now the only
	# things that knew the shape of a baked circuit were its collision ribbon and
	# its sixteen gates. That is enough to drive on and not enough to reason
	# about: a scripted lap, a minimap, a "you are off the racing line" cue and a
	# kerb all want the same two numbers, how far along and how far across.
	#
	# About 20 KB on the longest circuit, which is a fifth of what the audio
	# costs.
	root_node.set_meta("centreline", PackedVector3Array(centreline))
	# The car's headlights, for the same reason and by the same route. Written
	# from the *resolved* preset rather than from a track id, so a painted circuit
	# carries its hour as surely as a shipped one.
	root_node.set_meta("headlights", preset.get("headlights", 0.0))

	# The floodlighting, and it is **not** the trackside masts.
	#
	# Building the base illumination out of downward spot cones does not work, and
	# the reason is the angular falloff: a spot goes to *zero* at its cone edge
	# whatever `spot_angle_attenuation` is set to. So sixty-four cones pointed
	# straight down at a flat road are sixty-four discs with dark rims — "a bunch
	# of glowing yellow spots", which is what they were called and what they were.
	# Earlier arithmetic here claimed 92% brightness at the overlap; it measured
	# only the *distance* term and ignored the angular one, which is the term that
	# matters at exactly that point.
	#
	# A real circuit under floodlights is *evenly* lit, with the world beyond it
	# dark — the light arrives from many masts at once from many directions, which
	# is much closer to a directional light than to a point one. So that is what
	# it is: a second `DirectionalLight3D`, warm, steeply down, **casting
	# shadows**. It lights the road, the barriers and the buildings uniformly, it
	# gives the car a shadow that swings as it turns, and it costs one light.
	#
	# It does not light the field, because the ground plane is `unshaded` and
	# receives nothing — so the surroundings stay dark by construction, which is
	# the contrast a floodlit circuit is made of.
	if float(preset.get("key_energy", 0.0)) > 0.0:
		var key := DirectionalLight3D.new()
		key.name = "Floodlight"
		key.rotation_degrees = preset.get("key_angle", Vector3(-72.0, 20.0, 0.0))
		key.light_color = preset.get("key_color", Color.WHITE)
		key.light_energy = preset["key_energy"]
		key.shadow_normal_bias = 0.5
		key.directional_shadow_max_distance = 220.0
		root_node.add_child(key)

		# **Exactly one caster, and it is the brighter light.**
		#
		# Both of these cast until now, and two directional shadow maps over the
		# same geometry is what made the wheels look wrong — and look wrong
		# *differently on every circuit*, because only the lit hours had a second
		# light and its angle and strength changed with the hour. A small curved
		# object shadowed twice from two directions is all banding.
		#
		# The brighter one wins rather than the key one always, because at sunset
		# the sun is still the light and the masts are only just switching on. A
		# moon at 0.28 casting shadows at night was wrong on its own terms too.
		var key_leads: bool = key.light_energy >= sun.light_energy
		key.shadow_enabled = key_leads
		sun.shadow_enabled = not key_leads
	else:
		# Nothing else to defer to.
		sun.shadow_enabled = true

	var we := WorldEnvironment.new()
	we.name = "WorldEnvironment"
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY

	# A shader rather than `ProceduralSkyMaterial`: flat bands, an oversized sun
	# and stylised cloud stripes are the look, and a procedural sky can only give
	# a smooth gradient and a small disc. See assets/shaders/sky.gdshader.
	var sky_mat := ShaderMaterial.new()
	sky_mat.shader = load(SKY_SHADER)
	# **Converted to linear on the way in.** A shader uniform set through
	# `set_shader_parameter` arrives exactly as given and is used as linear
	# radiance, while `ProceduralSkyMaterial` — which this replaced — took the
	# same `Color` and converted it internally. Handing the old sRGB numbers
	# straight to a shader therefore rendered the sky at roughly twice its
	# intended brightness: sRGB 0.62 is linear 0.34, and a horizon authored as a
	# pale blue came out very nearly white. With fog and the grade on top of it,
	# the whole distance washed out.
	#
	# The presets stay authored in sRGB, because that is how anyone picking a
	# colour thinks about it, and the conversion happens once here at the
	# boundary.
	sky_mat.set_shader_parameter("top_color", (preset["top"] as Color).srgb_to_linear())
	sky_mat.set_shader_parameter("horizon_color", (preset["horizon"] as Color).srgb_to_linear())
	sky_mat.set_shader_parameter("ground_color", (preset["ground"] as Color).srgb_to_linear())
	sky_mat.set_shader_parameter("sun_color", (preset["sun_disc"] as Color).srgb_to_linear())
	sky_mat.set_shader_parameter("cloud_color", (preset["cloud"] as Color).srgb_to_linear())
	sky_mat.set_shader_parameter("cloud_amount", preset["cloud_amount"])
	sky_mat.set_shader_parameter("horizon_falloff", preset["horizon_falloff"])
	sky_mat.set_shader_parameter("sun_size", preset["sun_size"])
	env.sky = Sky.new()
	env.sky.sky_material = sky_mat

	# A fixed fill rather than the sky's own irradiance. Taking ambient from the
	# sky means the fill *is* the sky colour, and against this kit — which is
	# almost entirely white and pale grey — every shaded face went frankly blue:
	# the barrier down the far side of the road looked painted a different colour
	# from the one down the near side. This is the same cool light with most of
	# the saturation taken out of it, and it skips the sky irradiance pass.
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = preset["ambient"]
	env.ambient_light_energy = preset["ambient_energy"]
	# Sky reflections on roughness-1 materials cost a lot and change nothing.
	env.reflected_light_source = Environment.REFLECTION_SOURCE_DISABLED

	# Filmic rather than linear: the white kerbs and the grid markings clip to a
	# featureless white under linear tonemapping, which is most of why the
	# start/finish area used to lose its detail.
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	# Raised alongside the contrast below. Pushing contrast lifts the top of the
	# range, and the kerbs and grid markings are already the brightest things in
	# the frame — at the old 1.8 they went back to clipping to featureless white,
	# which is the exact failure ACES was chosen to fix.
	env.tonemap_white = 2.1

	# **Left neutral, because the grade is a LUT now and the LUT subsumes these.**
	# Godot applies brightness, contrast and saturation *before* the colour
	# correction texture, so anything left in them would grade the image twice —
	# once with the three dials the look was authored on and once with the table
	# built from those same numbers. `ColourGrade.from_bcs` is the conversion, and
	# it is exact rather than approximate, so neutral here loses nothing.
	#
	# `adjustment_enabled` still has to be **true**: it gates the whole block,
	# colour correction included, so a false here silently disables the grade.
	env.adjustment_enabled = true
	env.adjustment_saturation = 1.0
	env.adjustment_contrast = 1.0
	env.adjustment_brightness = 1.0
	# The table itself is attached on load by `grade_scene`, not here. An
	# `ImageTexture3D` is built at runtime and does not survive `PackedScene.pack`
	# — the same serialisation limit that keeps `surface_road` out of the builder —
	# so what the circuit carries is the *name* of its look and the LUT is fetched
	# through it.
	root_node.set_meta("look", CircuitLook.name_of(track_name, _look))

	env.fog_enabled = true
	env.fog_mode = Environment.FOG_MODE_DEPTH
	# The sky's own horizon colour, not a second one that happens to match: fog
	# exists to land the 4 km ground plane into the sky, and it can only do that
	# while it *is* the colour the sky is at that edge.
	env.fog_light_color = preset["horizon"]
	# Starts beyond anything the chase camera can see, so nothing being driven
	# through is ever hazed; it only exists to land the far side of the lap and
	# the edge of the ground plane softly into the sky. Capped below 1 so the
	# horizon keeps a trace of what is out there instead of going flat white.
	env.fog_depth_begin = preset["fog_begin"]
	env.fog_depth_end = 2600.0
	env.fog_density = 0.72

	we.environment = env
	root_node.add_child(we)

## Attaches the circuit's colour grade to its environment, in place.
##
## Called by `race.gd` on the track it is about to show, for the same reason
## `surface_road` is: an `ImageTexture3D` is built at runtime and a runtime
## texture does not survive `PackedScene.pack`. Baking the grade into the scene
## would ship four circuits with an empty `adjustment_color_correction` and no
## warning, because an ungraded frame is a *plausible* frame — it is merely flatter
## than it should be, which is exactly the kind of regression nobody notices.
##
## So the circuit carries the **name** of its look as metadata and the table is
## fetched through it here. Idempotent: assigning the same cached texture again
## costs nothing, which matters because `race.gd` runs this on every race start.
##
## Silent when a circuit has no look recorded. That is not defensive coding — the
## suite builds bare roots to measure geometry on, and the editor's `measure()`
## path builds without lighting at all.
static func grade_scene(track_root: Node3D) -> void:
	if not track_root.has_meta("look"):
		return
	var we := track_root.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if we == null or we.environment == null:
		return
	we.environment.adjustment_color_correction = ColourGrade.lut(
		String(track_root.get_meta("look"))
	)

## Re-surfaces the drivable part of every tile as tarmac, in place.
##
## Called by `race.gd` on the track it is about to show, rather than from
## `build`, and that is the whole point of it being public and static. The tiles
## are GLB *instances*, and a surface override set on an instance's internal node
## does not survive `PackedScene.pack` — the shipped circuits baked with the
## override present on the handful of tiles `_reshape_tiles` had rebuilt into
## ordinary nodes, and absent on every other one, which is a road that changes
## colour at each banked corner. Doing it on load sidesteps serialisation
## entirely and treats a baked circuit and a player's identically.
##
## Applied as an override rather than by editing the meshes because those come
## out of the shared GLB import: one cached resource serving every instance of
## that piece, which is not ours to write to.
##
## Only the surface Kenney names `road` is replaced. The white lines, the kerbs
## and the painted grid boxes are all on the `grey` surface and the verges on
## `grass`, so both survive — which is why this matches by name rather than by
## surface index, the pieces not agreeing on the order.
static func surface_road(track_root: Node3D, surface: String = "") -> void:
	var spec := RoadSurface.named(surface)
	var tarmac := ShaderMaterial.new()
	tarmac.shader = load("res://assets/shaders/tarmac.gdshader")
	# Linear on the way in, like every other colour handed to a shader.
	tarmac.set_shader_parameter("base_color", (spec["base"] as Color).srgb_to_linear())
	tarmac.set_shader_parameter("grit_color", (spec["grit"] as Color).srgb_to_linear())
	tarmac.set_shader_parameter("grain_amount", spec["grain"])
	tarmac.set_shader_parameter("base_roughness", spec["roughness"])
	# The shape of the surface, which is what separates dirt and snow from a
	# recoloured road. Zero on tarmac, deliberately: see `RoadSurface`.
	tarmac.set_shader_parameter("relief", spec.get("relief", 0.0))
	tarmac.set_shader_parameter("relief_scale", spec.get("relief_scale", 1.6))
	tarmac.set_shader_parameter("patch_amount", spec.get("patch", 0.0))
	tarmac.set_shader_parameter("stones", spec.get("stones", 0.0))
	tarmac.set_shader_parameter("sparkle", spec.get("sparkle", 0.0))
	# The floor under the whole lighting rig. Whatever the sun and the lamps are
	# doing, the tarmac does not drop below readable — a racing line you cannot
	# see is not a hard circuit, it is a broken one. Zero in daylight, so this
	# costs the bright hours nothing.
	tarmac.set_shader_parameter("glow", track_root.get_meta("road_glow", 0.0))
	# **Only the road visuals**, not everything in the scene wearing a material
	# Kenney happened to call "road".
	#
	# The kit shares one atlas, and twelve scenery surfaces on a shipped circuit —
	# building aprons, pit garage floors — carry that same material name. They
	# were being re-surfaced as tarmac too. That was invisible while tarmac was
	# only a colour; the moment the road gained an emission floor for the dark
	# hours it became **glowing buildings**, which is exactly how it was found.
	#
	# Matching by branch rather than by material name is the fix: `RoadVisuals`
	# holds the tiles the car drives on and nothing else.
	var visuals := track_root.get_node_or_null("RoadVisuals")
	for mi in _mesh_instances(visuals if visuals != null else track_root):
		if mi.mesh == null:
			continue
		for i in mi.mesh.get_surface_count():
			var mat := mi.mesh.surface_get_material(i)
			if mat != null and mat.resource_name == ROAD_SURFACE:
				mi.set_surface_override_material(i, tarmac)

	_surface_field(track_root, spec)

## Carries the condition off the road and out into the field beside it.
##
## Without this, snow was a white ribbon laid across a green summer lawn, which
## reads as a painted road rather than as weather. The outfield is *blended*
## toward the condition rather than replaced by it, so the circuit's theme colour
## and the hour's darkening still come through underneath — a snowy dusk stays
## dusk.
##
## Written as a surface override built from the mesh material, never by editing
## the mesh material itself. That material is a resource inside a packed scene and
## `instantiate()` shares resources rather than copying them, so mutating it would
## compound every time a race started — five races on snow and the field would be
## five blends further from where it began. Reading the untouched original and
## writing a fresh override makes the call idempotent.
static func _surface_field(track_root: Node3D, spec: Dictionary) -> void:
	var amount: float = spec.get("field_amount", 0.0)
	var mi := track_root.get_node_or_null("Ground/GroundMesh") as MeshInstance3D
	if mi == null or mi.mesh == null:
		return
	if amount <= 0.0:
		# Cleared rather than skipped: the same circuit can be raced on dirt and
		# then on tarmac without being rebuilt in between.
		mi.set_surface_override_material(0, null)
		return
	var source := mi.mesh.surface_get_material(0) as ShaderMaterial
	if source == null:
		return
	var tinted := source.duplicate() as ShaderMaterial
	var field: Color = (spec.get("field", Color.WHITE) as Color).srgb_to_linear()
	for key in ["base_color", "line_color"]:
		var was = source.get_shader_parameter(key)
		if was is Color:
			tinted.set_shader_parameter(key, (was as Color).lerp(field, amount))
	mi.set_surface_override_material(0, tinted)

## Dresses the circuit: barriers the whole way round, lighting columns, trees on
## the outfield, and a paddock of grandstands and pit garages at the start line.
##
## Placement is seeded off the circuit's own name, so a track looks the same
## every time it is built. That matters more than it sounds: a shipped circuit is
## baked once, but a player's is rebuilt from its layout on every single race,
## and scenery that reshuffled between laps would make the same corner
## unrecognisable each time round.
func _build_scenery(root_node: Node3D, track_name: String) -> void:
	if not SCENERY_ENABLED or centreline.size() < 4:
		return

	var scenery := Node3D.new()
	scenery.name = "Scenery"
	root_node.add_child(scenery)

	var rng := RandomNumberGenerator.new()
	rng.seed = hash(track_name)

	var road := _road_index()

	_scenery_barrier(scenery, road)
	_scenery_posts(scenery, road, track_name)
	_scenery_trees(scenery, rng, road, track_name)
	_lamp_lights(scenery, track_name)
	_scenery_paddock(scenery, road)
	_scenery_markers(scenery, road, track_name)
	_build_tunnels(scenery)
	_build_horizon(scenery, track_name)
	_build_road_overlay(scenery)

## The road's own coordinate system, as a ribbon laid over the tarmac.
##
## **This is M17's first step, and the reason it comes before anything else.**
## Both the racing-line rubber and the tyre-track deformation texture need the
## road to carry two numbers per point — how far along the lap, and how far across
## the road — and the tiles cannot: they are shared cached meshes, and only the
## banked and lifted ones are ever rebuilt. A ribbon generated from the centreline
## has both by construction, because it is built across the road.
##
## What it draws today is the rubber. The darkness is **baked into vertex colour**
## from `ParTime.racing_line` — the same line the lap estimate is computed on — so
## the dark band on the tarmac is literally the line the game thinks is quickest.
## No texture, no per-frame work, one draw call.
func _build_road_overlay(scenery: Node3D) -> void:
	if centreline.size() < 4 or _sides.size() != centreline.size():
		return
	var line := ParTime.racing_line(centreline)
	if line.size() != centreline.size():
		return

	# Where the racing line sits across the road at each point, as a signed
	# offset in metres. Projected onto the road's own across-vector so a banked or
	# climbing section measures the same as a flat one.
	var across := PackedFloat32Array()
	across.resize(centreline.size())
	for i in centreline.size():
		var delta := line[i] - centreline[i]
		var side := _sides[i]
		side.y = 0.0
		if side.length() < 0.001:
			across[i] = 0.0
			continue
		across[i] = delta.dot(side.normalized())

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := centreline.size()
	for i in n - 1:
		for j in OVERLAY_STRIPS:
			# Lateral positions of this strip's two edges, -1 to 1 across the road.
			var u0 := -1.0 + 2.0 * float(j) / float(OVERLAY_STRIPS)
			var u1 := -1.0 + 2.0 * float(j + 1) / float(OVERLAY_STRIPS)
			_overlay_quad(st, i, i + 1, u0, u1, across)

	var mat := ShaderMaterial.new()
	mat.shader = load(OVERLAY_SHADER)
	mat.set_shader_parameter("rubber_color", OVERLAY_COLOR.srgb_to_linear())
	mat.set_shader_parameter("strength", OVERLAY_STRENGTH)

	var mi := MeshInstance3D.new()
	mi.name = "RoadOverlay"
	var mesh: ArrayMesh = st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scenery.add_child(mi)

## One strip of overlay between two centreline points, carrying its lateral
## coordinate as UV and its rubber as vertex alpha.
func _overlay_quad(
	st: SurfaceTool, i: int, j: int, u0: float, u1: float,
	across: PackedFloat32Array
) -> void:
	var pts := [
		[i, u0], [j, u0], [j, u1],
		[i, u0], [j, u1], [i, u1],
	]
	for pair in pts:
		var k: int = pair[0]
		var u: float = pair[1]
		var lateral := u * ROAD_HALF
		var p := _ribbon_point(centreline[k], _sides[k], bank[k], lateral)
		p.y += OVERLAY_LIFT
		# How far this vertex is from the racing line, in metres, turned into
		# how much rubber is on it. A Gaussian rather than a hard band: rubber
		# thins outwards, it does not stop.
		var d: float = (lateral - across[k]) / OVERLAY_WIDTH
		st.set_color(Color(1.0, 1.0, 1.0, exp(-d * d)))
		# The coordinate this whole ribbon exists to carry: how far along the lap,
		# and how far across the road.
		st.set_uv(Vector2(float(k) / float(centreline.size()), (u + 1.0) * 0.5))
		st.add_vertex(p)

## A ring of distant land, so the world ends in something rather than in nothing.
##
## Everything past the circuit currently fades into flat fog, which is honest —
## there *is* nothing out there — and reads as a missing backdrop rather than as
## distance. A band of silhouettes is the cheapest thing that says the circuit is
## somewhere, and it is a signature of the look this game is aiming at.
##
## Deliberately crude: one band of peaks, unshaded, one flat colour from the
## hour's preset. It is 1.2 km away and about a quarter fogged at that range, so
## detail would be invisible even if it were there — and being unshaded means it
## does not care where the sun is, only what colour the preset says distance
## should be.
##
## No collision, like all scenery, and no shadow: a 2.4 km ring inside the
## shadow-casting range would push everything else out of the shadow atlas.
func _build_horizon(scenery: Node3D, track_name: String) -> void:
	var preset := CircuitLook.sky_of(track_name, _look)
	var rng := RandomNumberGenerator.new()
	# Seeded off the circuit, so each one gets its own skyline and gets the same
	# one every time it is built.
	rng.seed = hash("horizon:%s" % track_name)

	var segments := 96
	# Heights first, so each peak is shared by the two faces either side of it and
	# the ridge joins up instead of being a row of loose spikes.
	var heights := PackedFloat32Array()
	heights.resize(segments)
	for i in segments:
		# Two overlapping waves plus noise: enough to read as terrain rather than
		# as a sawtooth, without pretending to be a landscape.
		var a := TAU * float(i) / float(segments)
		var ridge := 0.55 + 0.45 * sin(a * 3.0 + rng.randf() * 0.2)
		var range_wave := 0.6 + 0.4 * sin(a * 7.0 + 1.3)
		heights[i] = HORIZON_MIN + (HORIZON_MAX - HORIZON_MIN) * (
			ridge * range_wave * rng.randf_range(0.7, 1.0)
		)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in segments:
		var j := (i + 1) % segments
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(j) / float(segments)
		var p0 := Vector3(cos(a0), 0.0, sin(a0)) * HORIZON_RADIUS
		var p1 := Vector3(cos(a1), 0.0, sin(a1)) * HORIZON_RADIUS
		# Sunk well below the ground plane so the base is never visible as a seam,
		# whatever the camera is doing.
		var base := Vector3(0.0, -60.0, 0.0)
		_quad(st, p0 + base, p1 + base,
			p1 + Vector3(0.0, heights[j], 0.0),
			p0 + Vector3(0.0, heights[i], 0.0))

	var mat := StandardMaterial3D.new()
	mat.resource_name = "horizon"
	mat.albedo_color = preset["silhouette"]
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	# Seen from inside the ring, so the faces point away by default.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var mi := MeshInstance3D.new()
	mi.name = "Horizon"
	var mesh: ArrayMesh = st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	scenery.add_child(mi)


## Sweeps a shell over every stretch of tunnel road: a wall down each side and a
## roof across the top.
##
## Generated rather than placed, because the kit has no tunnel art at all. That
## is the same reason the collision ribbon and the barrier are generated — the
## tiles are a vocabulary, not a complete one.
##
## **No collision**, like every other piece of scenery here. `car_controller`
## finds which way is up by casting a ray downwards and treating whatever it hits
## as the road it is standing on; a solid roof would be read as a surface the car
## was resting against. The walls are equally decorative — the barriers they sit
## outside of do not collide either.
##
## The roof does cast a shadow, which is most of what sells it: the tarmac
## underneath goes dark on the way in and comes back on the way out, without
## anything being lit or unlit specially.
func _build_tunnels(scenery: Node3D) -> void:
	if _tunnel_spans.is_empty() or _sides.size() != centreline.size():
		return

	var mat := StandardMaterial3D.new()
	mat.resource_name = "tunnel"
	mat.albedo_color = TUNNEL_COLOR
	mat.roughness = 0.95
	# Seen from the inside as much as the outside, and a tunnel with a
	# back-faced roof is a tunnel with no roof from underneath.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var quads := 0
	for span in _tunnel_spans:
		for i in range(span.x, span.y):
			quads += _tunnel_span(st, i, i + 1)
	if quads == 0:
		return

	var mi := MeshInstance3D.new()
	mi.name = "Tunnel"
	var mesh: ArrayMesh = st.commit()
	mesh.surface_set_material(0, mat)
	mi.mesh = mesh
	scenery.add_child(mi)

## One slice of shell between two centreline samples. Returns how many quads it
## added, so a degenerate span contributes nothing rather than a sliver.
func _tunnel_span(st: SurfaceTool, i: int, j: int) -> int:
	if centreline[i].distance_to(centreline[j]) < 0.001:
		return 0
	# Taken across the banked cross-section, the way the barrier is, so a tunnel
	# on a banked corner would stand on the road rather than lean through it.
	var a_l := _ribbon_point(centreline[i], _sides[i], bank[i], -TUNNEL_HALF)
	var a_r := _ribbon_point(centreline[i], _sides[i], bank[i], TUNNEL_HALF)
	var b_l := _ribbon_point(centreline[j], _sides[j], bank[j], -TUNNEL_HALF)
	var b_r := _ribbon_point(centreline[j], _sides[j], bank[j], TUNNEL_HALF)
	var up := Vector3.UP * TUNNEL_HEIGHT

	_quad(st, a_l, b_l, b_l + up, a_l + up)          # left wall
	_quad(st, a_r, b_r, b_r + up, a_r + up)          # right wall
	_quad(st, a_l + up, b_l + up, b_r + up, a_r + up)  # roof
	return 3

func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var normal := (b - a).cross(d - a)
	if normal.length() > 0.001:
		st.set_normal(normal.normalized())
	for v in [a, b, c, a, c, d]:
		st.add_vertex(v)

## One continuous barrier down each side, swept along the centreline so it curves
## with the road and rises with it.
func _scenery_barrier(scenery: Node3D, road: Dictionary) -> void:
	var mat := StandardMaterial3D.new()
	mat.resource_name = "barrier"
	mat.albedo_color = BARRIER_COLOR
	mat.roughness = 0.8
	# Normals are written per face below, so culling has no shading to protect
	# and switching it off saves having to reason about winding on a strip that
	# turns both ways round the lap.
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED

	for sgn in [-1.0, 1.0]:
		var side := float(sgn)
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var spans := 0
		var prev := {}
		for i in _barrier_vertices():
			var here := _barrier_station(i, side)
			# **Pulled in before it is given up on.**
			#
			# A barrier point that lands on another leg's tarmac has to go — but
			# the old rule simply dropped it, on the reasoning that "the barrier
			# already standing between them serves both". Where two legs run one
			# tile apart, *both* sides are rejected by that rule, each assuming
			# the other exists, and neither is built: measured, 50 m stretches of
			# several circuits had no railing on either side. Trying a tighter
			# offset first keeps the rail wherever one will fit at all.
			var fitted := false
			for pull in RAIL_PULL_IN:
				here = _barrier_station(i, side, pull)
				if not _clear_of_road(road, here["inner"], RAIL_CLEARANCE * SCALE,
						i, RAIL_OWN_SPAN):
					continue
				# **And it must still be going forwards.**
				#
				# A curve offset inward by more than its own radius folds back
				# through itself — the classic parallel-curve failure — and the
				# quads between consecutive stations come out crossed. On the
				# inside of a size-1 corner the centreline radius is 7 m and the
				# rail sits 8.4 m in, so it inverts, and what you see is the rail
				# tying itself in a bow at every tight corner.
				#
				# Rather than work out which side of the turn is the inside and
				# clamp against a computed radius — two sign conventions to get
				# wrong — the fold is detected where it shows: if the step from
				# the last station to this one points *against* the road, this
				# offset is impossible here and a tighter one is tried.
				if not prev.is_empty():
					var step: Vector3 = (here["inner"] as Vector3) - (prev["inner"] as Vector3)
					if step.dot(_tangent_at(i)) <= 0.0:
						continue
				fitted = true
				break
			if not fitted:
				prev = {}
				continue
			if not prev.is_empty():
				_barrier_span(st, prev, here)
				spans += 1
			prev = here
		if spans == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.name = "Barrier%s" % ("Left" if side < 0.0 else "Right")
		var mesh: ArrayMesh = st.commit()
		mesh.surface_set_material(0, mat)
		mi.mesh = mesh
		scenery.add_child(mi)

## Which centreline points the barrier actually needs: the ones where the road
## turns, changes height, or has simply run straight for long enough.
func _barrier_vertices() -> PackedInt32Array:
	var keep := PackedInt32Array([0])
	if centreline.size() < 3:
		return keep
	var last_dir := Vector2.ZERO
	var last_kept := 0
	for i in range(1, centreline.size()):
		var d := centreline[i] - centreline[i - 1]
		var flat := Vector2(d.x, d.z)
		if flat.length() < 0.001:
			continue
		flat = flat.normalized()
		var turned: bool = last_dir != Vector2.ZERO and absf(flat.angle_to(last_dir)) > BARRIER_MIN_TURN
		var far: bool = centreline[i].distance_to(centreline[last_kept]) > BARRIER_MAX_SPAN
		var climbed := absf(centreline[i].y - centreline[last_kept].y) > 0.05
		if turned or far or climbed:
			keep.append(i)
			last_kept = i
			last_dir = flat
		elif last_dir == Vector2.ZERO:
			last_dir = flat
	keep.append(centreline.size() - 1)
	return keep

## Which way the road is going at a point, flattened.
func _tangent_at(i: int) -> Vector3:
	var a := centreline[maxi(i - 1, 0)]
	var b := centreline[mini(i + 1, centreline.size() - 1)]
	var t := Vector3(b.x - a.x, 0.0, b.z - a.z)
	return t.normalized() if t.length() > 0.0001 else Vector3.FORWARD

## Where the barrier's foot sits at one centreline point, and which way is out.
func _barrier_station(i: int, side: float, pull: float = 0.0) -> Dictionary:
	# Taken across the banked cross-section, so on a banked corner the barrier
	# stands on the embankment rather than sinking into it.
	var base := _ribbon_point(
		centreline[i], _sides[i], bank[i], maxf(_edge_half(i) - pull, 1.0) * side
	)
	var out_dir := _sides[i] * side
	out_dir.y = 0.0
	out_dir = out_dir.normalized() if out_dir.length() > 0.001 else Vector3.RIGHT
	return {"inner": base, "out": out_dir}

## The length of barrier between two stations: a face towards the road, a face
## away from it, and a cap along the top.
func _barrier_span(st: SurfaceTool, a: Dictionary, b: Dictionary) -> void:
	var up := Vector3.UP * BARRIER_HEIGHT
	var a_in: Vector3 = a["inner"]
	var b_in: Vector3 = b["inner"]
	var a_out: Vector3 = a_in + (a["out"] as Vector3) * BARRIER_THICK
	var b_out: Vector3 = b_in + (b["out"] as Vector3) * BARRIER_THICK
	var inward: Vector3 = -((a["out"] as Vector3) + (b["out"] as Vector3)).normalized()

	_barrier_quad(st, inward, a_in, a_in + up, b_in + up, b_in)
	_barrier_quad(st, -inward, b_out, b_out + up, a_out + up, a_out)
	_barrier_quad(st, Vector3.UP, a_in + up, a_out + up, b_out + up, b_in + up)

static func _barrier_quad(
	st: SurfaceTool, normal: Vector3, a: Vector3, b: Vector3, c: Vector3, d: Vector3
) -> void:
	for v in [a, b, c, a, c, d]:
		st.set_normal(normal)
		st.add_vertex(v)

## Lighting columns, on the driver's left only — a full avenue down both sides
## of a 14 m road turns every straight into a tunnel.
func _scenery_posts(scenery: Node3D, road: Dictionary, track_name: String) -> void:
	var post := _prop("lightPostLarge")
	var xforms: Array[Transform3D] = []
	# Walked along the **centreline**, with the column offset out from it, rather
	# than walked along the offset line.
	#
	# This is what makes the lamps light the road. The old version resampled the
	# column line and then kept those same points as "the road beside the column"
	# — with a `+ Vector3(0, 0, 0)` where the offset back to the track should have
	# gone. So every lamp and every pool was anchored 13.3 m from the centreline,
	# out on the grass. A lamp 9.5 m up with a 28 degree half-cone lights a circle
	# from 8.25 m to 18.35 m out, and the road ends at 7: the lamps could not
	# reach the track at all, at any energy. Walking the centreline means the road
	# point is what is known and the column is what is derived, which is the way
	# round that cannot drift.
	for p in _resample(centreline, POST_STEP):
		var road_pt: Vector3 = p[0]
		var tan: Vector2 = p[1]
		# Same perpendicular and sign as `_offset_line(-1.0)`, so the columns
		# stand exactly where they always did.
		var out := Vector2(-tan.y, tan.x).normalized() * (POST_GAP * SCALE) * -1.0
		var pt := road_pt + Vector3(out.x, 0.0, out.y)
		# Standing on the ground rather than on the road, so a column beside a
		# raised section is as tall as the climb makes it look.
		pt.y = 0.0
		if not _clear_of_road(road, pt, POST_CLEARANCE * SCALE):
			continue
		xforms.append(_prop_xform(pt, _yaw_along(tan), POST_SCALE, post["offset"]))
	_multimesh(scenery, "LightPosts", post, xforms)

## A real light on every trackside column, at the hours that have any.
##
## The pools below are painted on the tarmac and light **only** the tarmac. That
## was the whole of the night rig, and it is why a dark circuit still read as
## broken: the car itself, the barriers, the trees and the kerbs all stayed black
## whatever lamp they were under, and a car passing a column did not brighten.
## Nothing about a light is happening in an additive disc.
##
## A `SpotLight3D` aimed down is what a street lamp actually is, and it gives all
## of that for free — including on the road's own relief, which dirt and snow now
## have.
##
## > The old comment here argued against real lights on two grounds. One was the
## > look: a real light has a smooth falloff gradient, which this game avoids
## > everywhere else. That is still true, and it is why the pools stay — the hard
## > edge on the road is the graphic statement and the lamp is the illumination.
## > They do different jobs.
## >
## > The other was cost: twenty-odd point lights is a great deal to ask of the
## > Compatibility renderer the web build is stuck with. That one is answered
## > rather than dismissed — `distance_fade` switches a lamp off past 190 m, so
## > the number *live* at any moment is the handful around the car rather than the
## > whole circuit. Shadows stay off, which is where the real cost would be.
func _lamp_lights(scenery: Node3D, track_name: String) -> void:
	var preset := CircuitLook.sky_of(track_name, _look)
	var energy: float = preset.get("lamp_energy", 0.0)
	if centreline.size() < 4 or energy <= 0.0:
		return

	var at := _resample(centreline, MAST_STEP)
	if at.size() < 3:
		return

	var masts := Node3D.new()
	masts.name = "Floodlights"
	scenery.add_child(masts)

	var frames: Array[Transform3D] = []
	var heads: Array[Transform3D] = []
	var colour: Color = preset.get("lamp_color", Color.WHITE)

	for i in at.size():
		var road: Vector3 = at[i][0]
		var tan: Vector2 = at[i][1]
		# Alternating sides, so the track is lit from both and a car is never
		# edge-lit from one direction all lap. It also halves how often a mast
		# appears on either verge, which keeps them reading as landmarks.
		var side := 1.0 if i % 2 == 0 else -1.0
		var out := Vector2(-tan.y, tan.x).normalized() * (MAST_GAP * SCALE) * side
		var foot := Vector3(road.x + out.x, road.y, road.z + out.y)
		var yaw := _yaw_along(tan)

		frames.append(Transform3D(Basis(Vector3.UP, yaw), foot))
		heads.append(Transform3D(
			Basis(Vector3.UP, yaw), foot + Vector3.UP * MAST_HEIGHT
		))

		# **Aimed at the road well ahead of the mast, not straight down at its own
		# feet.** That is what makes the pools tile: a cone striking the road at
		# an angle lays down a long ellipse along the track, so consecutive masts
		# overlap end to end instead of stamping separate circles.
		#
		# Aimed *along the centreline*, by stepping forward through the same
		# resampled list, rather than by extrapolating the tangent. A straight
		# line 50 m from a corner leaves the circuit — measured, half the masts on
		# La Sarthe were aiming past the track into the field, and only the width
		# of the cone was keeping the road lit at all.
		var target: Vector3 = at[(i + MAST_LOOKAHEAD) % at.size()][0]
		var head := foot + Vector3.UP * MAST_HEIGHT
		var lamp := SpotLight3D.new()
		lamp.name = "Mast%03d" % i
		# **Aimed by building the basis, not by `look_at_from_position`.** That
		# call works through `global_transform` and quietly does nothing on a node
		# outside the tree — and the whole circuit is built detached and then
		# packed, so it could never work here. Every mast was left pointing along
		# its default -Z, horizontally, and 92% of the road was measured unlit.
		lamp.transform = Transform3D(
			Basis.looking_at(target - head, Vector3.UP), head
		)
		lamp.light_color = colour
		lamp.light_energy = energy
		lamp.spot_range = MAST_RANGE
		lamp.spot_angle = MAST_ANGLE
		lamp.spot_attenuation = LAMP_FALLOFF
		lamp.spot_angle_attenuation = LAMP_CONE_FALLOFF
		# Shadows belong to the key light. These exist to put visible pools on the
		# track, and a shadow map apiece is what makes a light of this count
		# unaffordable on the Compatibility renderer the web build needs.
		lamp.shadow_enabled = false
		# Only the masts near the car are ever live.
		lamp.distance_fade_enabled = true
		lamp.distance_fade_begin = LAMP_FADE_FROM
		lamp.distance_fade_length = LAMP_FADE_OVER
		masts.add_child(lamp)

	_multimesh_of(masts, "MastFrames", _mast_frame_mesh(), frames)
	var head_mm := _multimesh_of(masts, "MastHeads", _mast_head_mesh(), heads)
	if head_mm != null:
		# The fixtures have to *look* switched on. A mast throwing light while its
		# own lamps are dark grey is the clearest possible sign the light is not
		# coming from anything.
		var glow := StandardMaterial3D.new()
		glow.albedo_color = colour
		glow.emission_enabled = true
		glow.emission = colour
		glow.emission_energy_multiplier = MAST_GLOW
		glow.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		head_mm.material_override = glow

## The structure: a column with a headframe across the top, in one mesh so a
## circuit's worth of masts is a single instanced draw.
##
## Built from boxes rather than vendored, because the Kenney racing kit has street
## lamps and no floodlight masts — and a floodlit circuit is recognisable almost
## entirely by the silhouette of the masts around it.
func _mast_frame_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box(st, Vector3(0.0, MAST_HEIGHT * 0.5, 0.0),
		Vector3(MAST_POLE, MAST_HEIGHT, MAST_POLE))
	# **Spanning local Z, which `_yaw_along` lays down the track.** The headframe
	# runs *parallel* with the circuit, so a row of masts reads as a line of
	# fixtures rather than as arms poking across the road at every angle a corner
	# happens to take. Built along local X it reached 4.5 m either side of the
	# pole, straight out over the tarmac on one side and into the field on the
	# other.
	_box(st, Vector3(0.0, MAST_HEIGHT + MAST_RIG_H * 0.5, 0.0),
		Vector3(MAST_POLE * 1.6, MAST_RIG_H, MAST_RIG_W))
	st.generate_normals()
	var mesh: ArrayMesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_color = MAST_COLOR
	mat.roughness = 0.85
	mesh.surface_set_material(0, mat)
	return mesh

## The lamps on the headframe, as a separate mesh so they can be emissive while
## the structure is not.
func _mast_head_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var span := MAST_RIG_W - MAST_LAMP_W
	# Along the headframe, which is along the track.
	for i in MAST_LAMPS:
		var t := (float(i) / float(MAST_LAMPS - 1) - 0.5) * span
		_box(st, Vector3(0.0, MAST_RIG_H + MAST_LAMP_H * 0.5, t),
			Vector3(MAST_LAMP_W * 0.7, MAST_LAMP_H, MAST_LAMP_W))
	st.generate_normals()
	return st.commit()

## One axis-aligned box, appended to a running surface.
func _box(st: SurfaceTool, centre: Vector3, size: Vector3) -> void:
	var h := size * 0.5
	var corner := [
		centre + Vector3(-h.x, -h.y, -h.z), centre + Vector3(h.x, -h.y, -h.z),
		centre + Vector3(h.x, h.y, -h.z), centre + Vector3(-h.x, h.y, -h.z),
		centre + Vector3(-h.x, -h.y, h.z), centre + Vector3(h.x, -h.y, h.z),
		centre + Vector3(h.x, h.y, h.z), centre + Vector3(-h.x, h.y, h.z),
	]
	for face in [[0, 1, 2, 3], [5, 4, 7, 6], [4, 0, 3, 7],
			[1, 5, 6, 2], [3, 2, 6, 7], [4, 5, 1, 0]]:
		for i in [0, 1, 2, 0, 2, 3]:
			st.add_vertex(corner[face[i]])

## A `MultiMesh` of one shape at a list of transforms, written through `buffer`
## because the per-instance setters do not survive a headless run.
func _multimesh_of(
	parent: Node3D, node_name: String, mesh: Mesh, xforms: Array[Transform3D]
) -> MultiMeshInstance3D:
	if xforms.is_empty():
		return null
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	mm.buffer = _instance_buffer(xforms)
	var mi := MultiMeshInstance3D.new()
	mi.name = node_name
	mi.multimesh = mm
	parent.add_child(mi)
	return mi

## The painted light pools are **gone**, and this note is what is left of them.
##
## They were flat additive discs laid on the tarmac under each column: a stand-in
## for lighting from before there was any, and defended for a long time as the
## graphic statement — a hard-edged pool being more in keeping than a smooth
## falloff. That defence stopped being true the moment real fixtures existed, and
## what they actually looked like, said three separate times by the person
## playing it, was *yellow glow spots*. A disc of colour added to the road is not
## light and no amount of tuning makes it behave like light: it does not move with
## the eye, it does not fall on the car, and its edge is a circle at every angle.
##
## The masts light the road now. See `_lamp_lights`.

## Small markers down both verges, close together.
##
## "Density is speed" (`docs/ideas.md`): what sells pace in this kind of racer is
## a lot of things streaming past at the edge of vision, not a bigger number on
## the speedometer. Trees are too far out and too sparse to do it — they read as
## landscape. These stand just off the tarmac at a few metres apart, so at
## 160 km/h they arrive about twenty a second.
##
## Cheap by construction: one `MultiMesh` per circuit, a model of a few triangles,
## no collision and no shadow. The same clearance test the barrier uses keeps them
## off another leg of the circuit, so a marker never appears in the middle of the
## road where the lap doubles back.
func _scenery_markers(
	scenery: Node3D, road: Dictionary, track_name: String
) -> void:
	var theme := CircuitLook.theme_of(track_name, _look)
	var prop := _prop(String(theme["marker"]))
	var step: float = float(theme["marker_step"]) * SCALE
	var xforms: Array[Transform3D] = []
	for sgn in [-1.0, 1.0]:
		var side := float(sgn)
		for p in _resample(_offset_line(side, MARKER_GAP * SCALE), step):
			var pt: Vector3 = p[0]
			if not _clear_of_road(road, pt, MARKER_CLEARANCE * SCALE):
				continue
			# Facing across the road, so the flag reads as a flag rather than as
			# an edge-on sliver from the driver's seat.
			xforms.append(_prop_xform(
				pt, _yaw_facing(p[1], side), MARKER_SCALE, prop["offset"]
			))
	_multimesh(scenery, "Markers", prop, xforms, false)

## Trees on the outfield, at a random distance out and skipping the paddock, so
## the horizon has something in it without walling the circuit in.
func _scenery_trees(
	scenery: Node3D, rng: RandomNumberGenerator, road: Dictionary,
	track_name: String
) -> void:
	var theme := CircuitLook.theme_of(track_name, _look)
	var chance: float = theme["tree_chance"]
	var tree_scale: float = theme["tree_scale"]
	var large := _prop("treeLarge")
	var small := _prop("treeSmall")
	var large_x: Array[Transform3D] = []
	var small_x: Array[Transform3D] = []

	var paddock: Vector3 = _point_at_arc(START_LINE_ARC)[0]
	var clear := maxf(absf(PADDOCK_FROM), PADDOCK_TO) * SCALE + PADDOCK_GAP * SCALE

	for sgn in [-1.0, 1.0]:
		var side := float(sgn)
		for p in _resample(_offset_line(side, TREE_GAP_NEAR * SCALE), TREE_STEP):
			if rng.randf() > chance:
				continue
			var tan: Vector2 = p[1]
			var outward := Vector3(-tan.y, 0.0, tan.x) * side
			var out := rng.randf_range(0.0, TREE_GAP_FAR - TREE_GAP_NEAR) * SCALE
			var pt: Vector3 = (p[0] as Vector3) + outward * out
			pt.y = 0.0
			if pt.distance_to(paddock) < clear:
				continue
			if not _clear_of_road(road, pt, TREE_CLEARANCE * SCALE):
				continue
			var s := tree_scale * SCALE * rng.randf_range(0.75, 1.15)
			var basis := Basis(Vector3.UP, rng.randf_range(0.0, TAU)).scaled(Vector3(s, s, s))
			if rng.randf() < 0.55:
				large_x.append(Transform3D(basis, pt + basis * (large["offset"] as Vector3)))
			else:
				small_x.append(Transform3D(basis, pt + basis * (small["offset"] as Vector3)))

	_multimesh(scenery, "TreesLarge", large, large_x)
	_multimesh(scenery, "TreesSmall", small, small_x)

## The start/finish area: grandstands along the driver's left, the pit buildings
## opposite, and a banner tower either side of the line.
##
## Laid out by arc length rather than by position, so it follows the road even
## when the start straight is short enough to bend away underneath it — which a
## player's circuit is perfectly entitled to do.
func _scenery_paddock(scenery: Node3D, road: Dictionary) -> void:
	var buildings := Node3D.new()
	buildings.name = "Paddock"
	scenery.add_child(buildings)

	# Every building in the kit is authored one tile unit wide, so stepping by one
	# unit of arc puts them shoulder to shoulder into an unbroken terrace.
	var step := 1.0 * SCALE
	var slots := _paddock_slots()

	# Covered stands at the ends and open ones through the middle, so the terrace
	# has a silhouette instead of being one extruded block.
	for i in slots:
		var arc := START_LINE_ARC + (PADDOCK_FROM + float(i)) * step
		var covered: bool = i < 2 or i >= slots - 2 or i % 5 == 0
		_place_prop(buildings, road,
			"grandStandCovered" if covered else "grandStand", arc, -1.0, PADDOCK_GAP)

	# Pit lane opposite: the office bookends a run of garages.
	for i in slots:
		var arc := START_LINE_ARC + (PADDOCK_FROM + float(i)) * step
		var piece := "pitsGarage"
		if i == 0:
			piece = "pitsOfficeRoof"
		elif i == slots - 1:
			piece = "pitsOffice"
		_place_prop(buildings, road, piece, arc, 1.0, PADDOCK_GAP)

	# Behind the grandstands, where a real paddock puts the hospitality. Stepped
	# by two because the long tent is two units wide.
	for i in range(0, slots, 2):
		var arc := START_LINE_ARC + (PADDOCK_FROM + float(i) + 0.5) * step
		_place_prop(buildings, road, "tentLong", arc, -1.0, PADDOCK_GAP + 1.4)

	# Flanking the line itself. Red on the driver's right, green on the left, so
	# the pair reads the same way round on every circuit.
	_place_prop(buildings, road, "bannerTowerRed", START_LINE_ARC, 1.0, 0.9,
		TOWER_CLEARANCE)
	_place_prop(buildings, road, "bannerTowerGreen", START_LINE_ARC, -1.0, 0.9,
		TOWER_CLEARANCE)

## How many one-unit slots the paddock gets before the road turns out from under
## it. Always at least the run behind the line, so the grid keeps its backdrop
## even on a circuit with no straight to speak of.
func _paddock_slots() -> int:
	var start: Vector2 = _point_at_arc(START_LINE_ARC)[1]
	var total := int(PADDOCK_TO - PADDOCK_FROM)
	var behind := int(absf(PADDOCK_FROM))
	for i in range(behind, total):
		var here: Vector2 = _point_at_arc(START_LINE_ARC + (PADDOCK_FROM + float(i)) * SCALE)[1]
		if absf(here.angle_to(start)) > PADDOCK_MAX_TURN:
			return i
	return total

## Instances one GLB beside the road at a given arc length, turned to face the
## road. `side` is +1 for the driver's right and `gap` is tile units out from the
## centreline.
##
## Silently places nothing if the spot is taken by another part of the circuit.
## A cramped layout therefore loses buildings one at a time rather than being
## refused a paddock outright, which is the same principle the elevation system
## follows: a request that does not fit is reduced, not rejected.
func _place_prop(
	parent: Node3D, road: Dictionary, prop_name: String,
	arc: float, side: float, gap: float, clearance := PADDOCK_CLEARANCE
) -> void:
	var sample := _point_at_arc(arc)
	var tan: Vector2 = sample[1]
	var outward := Vector3(-tan.y, 0.0, tan.x) * side
	var pt: Vector3 = (sample[0] as Vector3) + outward * (gap * SCALE)
	# On the ground, not on the road: a paddock beside a climb stays where it was
	# built rather than climbing with it.
	pt.y = 0.0
	if not _clear_of_road(road, pt, clearance * SCALE):
		return

	var inst: Node3D = load("res://assets/kenney/racing_kit/%s.glb" % prop_name).instantiate()
	var offset: Vector3 = _prop(prop_name)["offset"]
	var basis := Basis(Vector3.UP, _yaw_facing(tan, side)).scaled(
		Vector3(SCALE, SCALE, SCALE)
	)
	# Numbered, because Godot renames a clashing sibling to something like
	# `@Node3D@168` and a paddock of four grandstands would otherwise bake with
	# three of them unnamed.
	inst.name = "%s%d" % [prop_name, parent.get_child_count()]
	inst.transform = Transform3D(basis, pt + basis * offset)
	parent.add_child(inst)

## Side of the bucket the road index is built in, in tile units. Every clearance
## test above is under this, which is what lets a lookup examine only the nine
## buckets around a point and still be exact.
const ROAD_INDEX_CELL := 1.5

## Buckets the centreline by position so a prop can ask "is any road near here?"
## without measuring against all fifteen hundred points of the loop.
##
## Flattened to the XZ plane deliberately: a raised section still occupies the
## ground beneath it as far as scenery is concerned, because the ground plane a
## tree stands on runs under the whole circuit.
## Each entry is `(x, z, index along the centreline)`. The third component is what
## lets a caller ask "clear of the road *other than the bit I am standing beside*".
func _road_index() -> Dictionary:
	var cell := ROAD_INDEX_CELL * SCALE
	var index := {}
	for i in centreline.size():
		var p := centreline[i]
		var key := Vector2i(int(floor(p.x / cell)), int(floor(p.z / cell)))
		if not index.has(key):
			index[key] = PackedVector3Array()
		index[key].append(Vector3(p.x, p.z, float(i)))
	return index

## Whether `pt` is at least `clearance` from every part of the road.
##
## `beside` and `span` exempt a stretch of the lap from the test, for the one
## caller that is *supposed* to be close to the road: the trackside railing stands
## at the road's own edge, so measured against its own leg it is never clear of
## anything. Everything else — posts, trees, markers — wants the plain question
## and passes no exemption.
##
## Without this the railing vanished from every raised section the moment it was
## tucked in to the deck edge, because at 7 m from its own centreline it failed a
## 7.7 m clearance against the very road it was lining.
func _clear_of_road(
	index: Dictionary, pt: Vector3, clearance: float,
	beside: int = -1, span: int = 0
) -> bool:
	var cell := ROAD_INDEX_CELL * SCALE
	var flat := Vector2(pt.x, pt.z)
	var cx := int(floor(pt.x / cell))
	var cz := int(floor(pt.z / cell))
	var total := centreline.size()
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var bucket: PackedVector3Array = index.get(Vector2i(cx + dx, cz + dz),
				PackedVector3Array())
			for q in bucket:
				if flat.distance_to(Vector2(q.x, q.y)) >= clearance:
					continue
				if beside >= 0 and total > 0:
					var apart: int = absi(int(q.z) - beside)
					if mini(apart, total - apart) <= span:
						continue
				return false
	return true

## A prop's mesh and the shift that moves its origin to the centre of its
## footprint at ground level.
##
## Needed because the kit exports every model with the same arbitrary offset
## baked into the node above the mesh — nothing is centred on its own origin, so
## placed naively each prop lands about half a tile from where it was put.
func _prop(prop_name: String) -> Dictionary:
	var src: Node3D = load("res://assets/kenney/racing_kit/%s.glb" % prop_name).instantiate()
	var mi := _first_mesh(src)
	var aabb := mi.mesh.get_aabb()
	aabb.position += mi.position
	var centre := aabb.position + aabb.size * 0.5
	# Base rather than middle: props stand on the ground.
	centre.y = aabb.position.y
	var out := {"mesh": mi.mesh, "offset": -centre}
	src.free()
	return out

## Stands a prop upright at a point, at a given yaw and uniform scale.
func _prop_xform(point: Vector3, yaw: float, scale: float, offset: Vector3) -> Transform3D:
	var basis := Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale))
	return Transform3D(basis, point + basis * offset)

## Yaw that lays a model's local +z along the road. Its local +x then points
## straight across the road, which is what a lighting gantry's arm wants.
static func _yaw_along(tan: Vector2) -> float:
	return atan2(tan.x, tan.y)

## Yaw that turns a model's local +z back in towards the road from `side`.
##
## Every building in this kit is authored facing +z, established by rendering
## them from that direction rather than by trying an angle and looking at the
## result — which is how the grandstands first went in seating-outwards.
static func _yaw_facing(tan: Vector2, side: float) -> float:
	return atan2(tan.y * side, -tan.x * side)

## One draw call per prop type.
##
## The mesh and its materials are duplicated rather than referenced. An imported
## mesh's `resource_path` points inside `.godot/imported/`, which is a build
## cache: not committed, and renamed whenever the import settings change. Baking
## that path into a shipped circuit would leave it pointing at nothing on a fresh
## checkout. Duplicating clears the path, so PackedScene writes the data out.
## One draw call per prop type.
##
## `casts_shadow` is off for anything placed in the hundreds. A few small props
## either side of the road are not worth a shadow each, and they would crowd the
## directional light's atlas — which the *car's* shadow needs, and which is the
## one shadow that matters.
func _multimesh(
	parent: Node3D, node_name: String, prop: Dictionary,
	xforms: Array[Transform3D], casts_shadow: bool = true
) -> void:
	if xforms.is_empty():
		return
	var mesh: ArrayMesh = (prop["mesh"] as ArrayMesh).duplicate()
	for i in mesh.get_surface_count():
		var mat := mesh.surface_get_material(i)
		if mat != null:
			mesh.surface_set_material(i, mat.duplicate())

	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	mm.buffer = _instance_buffer(xforms)
	# Computed rather than left to the renderer. A MultiMesh's automatic bounds
	# come from the RenderingServer, which under --headless is the dummy driver
	# and returns nothing — a baked circuit would load with bounds of zero size
	# and every prop would be frustum-culled from any angle but one.
	mm.custom_aabb = _instances_aabb(mesh.get_aabb(), xforms)

	var mmi := MultiMeshInstance3D.new()
	mmi.name = node_name
	mmi.multimesh = mm
	if not casts_shadow:
		mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mmi)

## Packs instance transforms the way `MultiMesh.buffer` wants them: twelve floats
## each, as three rows of a 3x4 matrix.
##
## Built by hand instead of calling `set_instance_transform` per instance,
## because that call goes through the RenderingServer and comes back out of it —
## and `tools/build_track.gd` bakes the shipped circuits under `--headless`,
## where the server is a stub that stores nothing. Every baked track came out
## with the right instance *count* and an empty buffer, so all two hundred rails
## sat at the origin and the circuits looked exactly as bare as before the
## scenery was written. Nothing errors; the data is simply gone.
static func _instance_buffer(xforms: Array[Transform3D]) -> PackedFloat32Array:
	var buf := PackedFloat32Array()
	buf.resize(xforms.size() * 12)
	var at := 0
	for t in xforms:
		var b := t.basis
		buf[at + 0] = b.x.x; buf[at + 1] = b.y.x; buf[at + 2] = b.z.x; buf[at + 3] = t.origin.x
		buf[at + 4] = b.x.y; buf[at + 5] = b.y.y; buf[at + 6] = b.z.y; buf[at + 7] = t.origin.y
		buf[at + 8] = b.x.z; buf[at + 9] = b.y.z; buf[at + 10] = b.z.z; buf[at + 11] = t.origin.z
		at += 12
	return buf

## The bounds one mesh covers once placed at every one of `xforms`.
static func _instances_aabb(mesh_aabb: AABB, xforms: Array[Transform3D]) -> AABB:
	var out := xforms[0] * mesh_aabb
	for i in range(1, xforms.size()):
		out = out.merge(xforms[i] * mesh_aabb)
	return out

## Set `owner` on nodes you created and on instanced sub-scene *roots*, but
## never on an instance's internal nodes — those then serialise on top of the
## instance and everything appears twice. Only needed when packing to a file.
static func set_owner_recursive(n: Node, owner_node: Node) -> void:
	for c in n.get_children():
		c.owner = owner_node
		if c.scene_file_path.is_empty():
			set_owner_recursive(c, owner_node)
