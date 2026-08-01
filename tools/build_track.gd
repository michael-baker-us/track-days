extends SceneTree

# Bakes the shipped circuits into committed .tscn files.
#
# All the geometry lives in scripts/track/track_builder.gd, which the game also
# calls at runtime to build player-authored tracks. This file is only the three
# layouts plus the save step, so a custom track and a shipped one are made of
# exactly the same thing.
#
# Every layout must close: the builder reports a gap that has to be (0, 0) with
# net +/-4 turns and height back to 0, or the loop does not join up. This script
# exits non-zero if any track fails, so a broken circuit cannot ship silently.
#
# ## These are three real circuits, seen through a 90-degree grid
#
# Ardennes is Spa-Francorchamps, Monte Carlo is Monaco, La Sarthe is Le Mans.
# The tile set only turns in right angles and only in three radii, so none of
# them is a survey — what carries over is the shape of the lap and the order of
# its corners: where the hairpin is, which straight is the long one, which bends
# are quick enough to be worth banking, and where the road climbs.
#
# Each layout was solved as a rectilinear polygon first. A leg of the polygon
# spans `straight_cells + N_in + N_out - 1` tile units, where N is the size of
# the corner at either end, so choosing the outline in whole units decides the
# straight counts rather than the other way round, and closure is arithmetic
# instead of trial and error. The outlines were also checked for a road that
# crosses or touches itself, which the closure test says nothing about.
#
# ## "right" here is the driver's right
#
# All three of these run clockwise, like the circuits they come from, so all
# three are right-dominant with a net turn total of -4, and La Source, Sainte
# Devote and the Dunlop chicane all turn right.
#
# Worth stating because it is easy to talk yourself out of. The car's forward is
# local +Z, and for a Y-up right-handed basis the driver's right is
# cross(forward, up), which is -X: facing south, the driver's right is *west*.
# Reaching for Godot's `Vector2.rotated` at that point says a -90 degree rotation
# takes south to east, and concludes that the builder's labels are inverted. They
# are not. `TrackBuilder._rotate` is not `Vector2.rotated` — it runs the other way
# on purpose, to match a Y rotation acting on (x, z) — and it takes south to west.
# The labels have always meant what they say.
#
# The first draft of these three was written the other way round and every one of
# them came out as a mirror image of the real circuit. Measure it off the built
# centreline rather than deriving it: the test suite now does.
#
# ## The grid goes down before the line, not after it
#
# Every layout opens `roadStartPositions` then `roadStart`, matching what the
# compiler emits for a player's track. The slots painted on the grid tile march
# towards its exit end, so with the line first they end up past it, running away
# from it, and the pole slot is the one furthest from the line. See
# `TrackBuilder.GRID_POLE_ALONG`, which is also where the car is parked.
#
# ## Height stops at one level
#
# `roadStraightBridge` is drawn with 0.5 tile units of structure below its deck,
# which is exactly one level of climb: raised by one, it stands on the ground,
# and raised by two it floats 3.5 m above it. So every climb here goes up a
# level, holds, and comes back down inside the same straight. Corners stay on the
# ground for the same reason -- the bridge corners are deck-only pieces with no
# structure at all, meant for the editor's sustained elevated sections.

# Spa-Francorchamps: La Source, the climb through Eau Rouge onto a long straight
# at height, then the fast half of the lap. The three big sweepers carry 4
# degrees of bank and the medium bends 2.5; the hairpin and the chicane get
# nothing, because banking is a per-corner choice and a hairpin banked hard is a
# skate bowl. 1473 m, 14 corners, 3.5 m of climb.
const ARDENNES := [
	["S", "roadStartPositions", 1],
	["S", "roadStart", 1],
	["S", "roadStraightLong", 2],
	# La Source: two of the smallest corners back to back, which is as close to a
	# hairpin as a right-angle tile set gets. The road comes back 2 units away.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraight", 1],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 3],
	# Eau Rouge and Raidillon: the left-right flick, and then the climb.
	["C", "roadCornerLarge", "left", 2.5],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right", 2.5],
	["S", "roadStraightLong", 1],
	["S", "roadRampLongCurved", 1, 1],
	# The Kemmel straight, held at height over the crest and then run out flat.
	["S", "roadStraightBridge", 4],
	["S", "roadRampLongCurved", 1, -1],
	["S", "roadStraightLong", 5],
	# Les Combes and Malmedy, the chicane at the top of the hill.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 1],
	# Rivage, turning the lap back down the valley.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 3],
	["S", "roadStraight", 1],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	# Pouhon, Fagnes, Stavelot: the fast, banked half.
	["C", "roadCornerLarger", "left", 4.0],
	["S", "roadStraightLong", 4],
	["C", "roadCornerLarge", "right", 2.5],
	["S", "roadStraightLong", 1],
	["C", "roadCornerLarger", "right", 4.0],
	["S", "roadStraightLong", 4],
	["S", "roadStraight", 1],
	# Blanchimont, flat out, onto a rise back towards the line.
	["C", "roadCornerLarger", "left", 4.0],
	["S", "roadStraight", 1],
	["S", "roadRampLongCurved", 1, 1],
	["S", "roadStraightBridge", 1],
	["S", "roadRampLongCurved", 1, -1],
	["S", "roadStraight", 1],
	# The Bus Stop chicane, and out onto the pit straight.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
]

# Monaco: the shortest circuit, the tightest, and the flattest in the only sense
# that matters here -- **not one corner on it is banked**. That is the point of
# it next to the other two. Banking is a choice per corner rather than something
# every bend gets, and a street circuit is where the answer is honestly no: the
# road is a road, and eleven of these fourteen corners are the smallest tile in
# the set, taken slowly enough that leaning them would buy nothing. Every corner
# says `0.0` out loud rather than saying nothing, because those have to keep
# meaning the same thing.
#
# The lap steps down the hill in four bends and steps back along the harbour in
# four more, which is both what Monaco does and the only way a loop with this
# many same-handed corners closes without the road crossing itself.
# 1054 m, 14 corners, 3.5 m of climb up Beau Rivage.
const MONTE_CARLO := [
	["S", "roadStartPositions", 1],
	["S", "roadStart", 1],
	["S", "roadStraightLong", 2],
	["S", "roadStraight", 1],
	# Sainte Devote, and the climb up Beau Rivage.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraight", 1],
	["S", "roadRampLongCurved", 1, 1],
	["S", "roadStraightBridge", 1],
	["S", "roadRampLongCurved", 1, -1],
	["S", "roadStraight", 1],
	# Massenet into Casino, one straight into the other with nothing between.
	["C", "roadCornerLarge", "left", 0.0],
	["C", "roadCornerLarge", "right", 0.0],
	["S", "roadStraightLong", 2],
	# Mirabeau and Loews, stepping down to the sea.
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 2],
	# Portier, onto the longest straight on the circuit -- and the tunnel, which
	# is where Monaco's actually is: out of Portier, under the hotel, and back
	# into daylight braking for the chicane.
	#
	# Same thirteen cells as before, so the loop closes exactly as it did; eight
	# of them are now roofed. Covered rather than buried: see the note on
	# `roadStraightTunnel`.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraightLongTunnel", 4],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	# The Nouvelle Chicane.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraight", 1],
	# Tabac, and the run along the harbour.
	["C", "roadCornerLarge", "right", 0.0],
	["S", "roadStraightLong", 4],
	# The swimming pool complex: four of the smallest corners in 100 m.
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraight", 1],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	["C", "roadCornerSmall", "left", 0.0],
	# Rascasse and Anthony Noghes, back onto the line.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
]

# Le Mans: the longest of the three and the one that is mostly straight. Three
# runs down the Mulsanne, split by chicanes, take up a quarter of the lap on
# their own, and the second of them goes over a crest at speed. Then Indianapolis
# -- the biggest sweeper in the set, banked as hard as anything is banked --
# Arnage, and the Porsche Curves, which are three of the medium corners taken as
# one continuous change of direction. 1768 m, 18 corners, 3.5 m of climb.
const LA_SARTHE := [
	["S", "roadStartPositions", 1],
	["S", "roadStart", 1],
	["S", "roadStraightLong", 4],
	["S", "roadStraight", 1],
	# The Dunlop chicane, then the curve under the bridge.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right", 2.5],
	["S", "roadStraightLong", 1],
	# The Esses, downhill in reality and simply quick here.
	["C", "roadCornerLarge", "left", 1.5],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "right", 1.5],
	["S", "roadStraightLong", 1],
	# Tertre Rouge, onto the Mulsanne.
	["C", "roadCornerLarge", "right", 2.5],
	["S", "roadStraightLong", 8],
	# First chicane.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	# Second run, over a crest.
	["S", "roadStraightLong", 2],
	["S", "roadRampLongCurved", 1, 1],
	["S", "roadStraightBridge", 3],
	["S", "roadRampLongCurved", 1, -1],
	["S", "roadStraightLong", 1],
	# Second chicane.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 4],
	["S", "roadStraight", 1],
	# Mulsanne corner: everything stops here.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 8],
	# Indianapolis, then Arnage.
	["C", "roadCornerLarger", "right", 4.0],
	["S", "roadStraightLong", 2],
	["S", "roadStraight", 1],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	# The Porsche Curves.
	["C", "roadCornerLarge", "left", 2.5],
	["S", "roadStraightLong", 1],
	["C", "roadCornerLarge", "right", 2.5],
	["S", "roadStraight", 1],
	["C", "roadCornerLarge", "left", 2.5],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	# The Ford chicane, and the line.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 1],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
]

# Suzuka: the one circuit in the world that is a figure of eight, and the reason
# crossings are worth having at all. The back half of the lap runs over the front
# half on a bridge, so the road passes over itself once and the two halves turn
# opposite ways.
#
# ## Why this one closes with zero net turns
#
# The other three are simple loops: four more turns one way than the other, a net
# of -4. A figure of eight is one loop turning right and one turning left, so its
# turns **cancel to zero** — and it still joins up perfectly, because closure is
# about coming back to the same place, height and heading, not about how many
# times you went round. `TrackBuilder` used to conflate the two; see the note on
# `BuildResult.simple`.
#
# ## Why the bridge is at level two, not one
#
# `roadStraightBridge` carries 0.5 tile units of structure below its deck, which
# is exactly one level. At level one it stands on the ground — fine for a crest,
# useless here, because the ground is where the other half of the lap is. At
# level two the deck sits 7 m up with **3.5 m of clear air beneath it**, which is
# what the road underneath needs. The supports stop short of the ground rather
# than punching through the road below, which is the honest limit of a tile set
# that was never drawn for this.
#
# The climb is two ramps up and two down, four cells each, with three cells of
# held bridge in the middle — and the crossing sits on the middle one of those
# three, so the road is level and at full height exactly where it passes over.
#
# ## The shape
#
# Two 6-unit squares sharing one cell, traced as a single lap:
#
#     +-----+           the long E-W straight runs along the middle, on the
#     |     |           ground, and carries the start line. The long N-S
#     +--X--+           straight crosses it at X, on the bridge. Everything
#     |     |           else is the two loops that join them up.
#     +-----+
#
# Deliberately plain otherwise: six corners, all the smallest tile, nothing
# banked. This circuit exists to show one thing, and dressing it up would only
# make it harder to see whether that one thing works.
const SUZUKA := [
	# The pit straight, on the ground, heading east. Seventeen cells between the
	# corner behind and the corner ahead, of which the grid and the line take
	# four. The bridge crosses over the middle of this, five cells past the line —
	# so the lap opens by driving *under* the road it will cross *over* later.
	["S", "roadStartPositions", 1],
	["S", "roadStart", 1],
	["S", "roadStraightLong", 6],
	["S", "roadStraight", 1],
	# North-east loop: three lefts back to the top of the crossing straight.
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 4],
	["C", "roadCornerSmall", "left", 0.0],
	["S", "roadStraightLong", 4],
	["C", "roadCornerSmall", "left", 0.0],
	# The crossing straight, heading south. Flat, up two levels, across, down
	# again, flat — seventeen cells, with the crossing on the middle one of the
	# three held cells so the road is level and at full height exactly where it
	# passes over.
	#
	# The elevated section is kept to three cells rather than run the length of
	# the straight. The supports hang 3.5 m clear of the ground at this height, so
	# every elevated cell is a cell of bridge with nothing under it: short reads
	# as a bridge, long would read as a viaduct on stilts that stop early.
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	["S", "roadRampLongCurved", 2, 1],
	["S", "roadStraightBridge", 3],
	["S", "roadRampLongCurved", 2, -1],
	["S", "roadStraightLong", 1],
	["S", "roadStraight", 1],
	# South-west loop: three rights back onto the pit straight.
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 4],
	["C", "roadCornerSmall", "right", 0.0],
	["S", "roadStraightLong", 4],
	["C", "roadCornerSmall", "right", 0.0],
]

const TRACKS := {
	"ardennes": {"file": "res://scenes/track/track_ardennes.tscn", "layout": ARDENNES},
	"monte_carlo": {
		"file": "res://scenes/track/track_monte_carlo.tscn", "layout": MONTE_CARLO
	},
	"la_sarthe": {"file": "res://scenes/track/track_la_sarthe.tscn", "layout": LA_SARTHE},
	"suzuka": {"file": "res://scenes/track/track_suzuka.tscn", "layout": SUZUKA},
}

func _initialize() -> void:
	var ok := true
	for track_name in TRACKS:
		if not _bake(track_name, TRACKS[track_name]):
			ok = false
	quit(0 if ok else 1)

## Returns false if the layout does not close or the save fails, so a bad
## layout fails loudly rather than silently shipping a circuit with a gap in it.
func _bake(track_name: String, spec: Dictionary) -> bool:
	var builder := TrackBuilder.new()
	var result := builder.build(track_name, spec["layout"])
	var out_path: String = spec["file"]

	print("[%s] closure %s" % [track_name, result.summary()])
	print("road collision: %d triangles" % result.triangles)
	print("checkpoints: %d spaced %.0f m apart" % [
		TrackBuilder.CHECKPOINT_COUNT, result.gate_spacing
	])

	TrackBuilder.set_owner_recursive(result.root, result.root)
	var packed := PackedScene.new()
	packed.pack(result.root)
	var err := ResourceSaver.save(packed, out_path)

	print("       %s | lap %.0f m | peak %.1f m | %s" % [
		out_path.get_file(), result.length, result.peak,
		"saved" if err == OK else "SAVE FAILED %s" % err
	])
	result.root.free()
	return result.closed and err == OK
