class_name AssetManifest
extends RefCounted

## Which Poly Haven assets this game ships, at what resolution, and what they
## cost to download.
##
## **The manifest exists before any asset does**, which is the whole point of
## M19's first step: the budget has to be a thing the suite can fail on rather
## than a paragraph in a document. A limit that lives only in prose erodes exactly
## the way the `[rendering]` block of `project.godot` has — three times now.
##
## ## The split, which is the same one `tools/` already makes everywhere
##
## `tools/fetch_assets.gd` downloads the 4K source into a gitignored directory.
## Only the **downsized derivatives the game actually ships** are committed. The
## 4K source is a builder's input and does not belong in the history any more
## than a `.blend` would.
##
## ## Why `arm` and not three files
##
## Poly Haven publishes AO, Roughness and Metalness separately *and* pre-packed
## into one `arm` texture, one channel each. Packed is a third of the files and a
## third of the requests, and it is the layout Godot's `StandardMaterial3D` reads
## natively through its ORM slot. Shipping the loose maps would be paying three
## times for one surface.
##
## ## The numbers, and they are the reason the budget is not a formality
##
## Measured from Poly Haven's own API rather than estimated. `bytes` below is the
## **source JPEG** total for the three maps at that resolution — not what lands in
## the `.pck`, which is VRAM-compressed on import and will differ. It is an order
## of magnitude, and the order of magnitude is the finding:
##
## - The web `.pck` today is about **11 MB**, whole game.
## - One texture set at **1K** is 2.7 to 3.7 MB.
## - The same set at **2K** is 12 to 14 MB — *more than the entire game*.
##
## So 2K on the web is not a tuning choice, it is out of the question, and even
## 1K is a third of the current download per surface. This is the first milestone
## whose primary cost is bytes rather than frames, and these figures are what that
## sentence means.

## The most any single asset may ship at, per platform. Godot will not downscale
## per platform on its own, so this is enforced by the suite instead.
const MAX_RESOLUTION := {"desktop": "2k", "web": "1k"}

## Resolutions in order, so a comparison is an index rather than a string parse.
const RESOLUTIONS := ["1k", "2k", "4k", "8k"]

## What the whole manifest may cost the web build, in source megabytes. Set
## against the 11 MB the game currently is: this allows the download to roughly
## double and no more, and it is deliberately tight enough to force a choice
## rather than wide enough to accept whatever gets added.
const WEB_BUDGET_MB := 12.0

## What each kind of asset is made of, and in what format.
##
## A texture is three maps as JPEG — `arm` being ambient occlusion, roughness and
## metalness packed one per channel, so there is no separate AO or Rough entry on
## purpose. An **HDRI is one file** and it must be `.hdr` rather than JPEG,
## because the whole reason to use one is the range above white that a JPEG
## cannot hold: an 8-bit sky lights a scene like a photograph of a sky, which is
## the thing being replaced.
const KINDS := {
	"texture": {"maps": ["Diffuse", "nor_gl", "arm"], "format": "jpg"},
	"hdri": {"maps": ["hdri"], "format": "hdr"},
}

## Kept for the suite and for anything that only deals in surfaces.
const MAPS := ["Diffuse", "nor_gl", "arm"]

static func kind_of(id: String) -> Dictionary:
	return KINDS[String(ASSETS[id].get("kind", "texture"))]

## Every asset, its id on Poly Haven, and what it is for here.
##
## Ids are **verified against the API**, not written from memory: an id that does
## not exist fails at fetch time on someone else's machine, months later, with no
## way to tell whether the asset was renamed or never existed.
const ASSETS := {
	# M19 step 3: the road overlay ribbon, which is the one surface on the
	# circuit with a UV set worth sampling. Chosen for being close to flat and
	# nearly square in world size (2.05 m across), so the grain lands at a
	# believable scale on an 11 m road without a tiling factor nobody can defend.
	"asphalt_03": {
		"use": "road",
		"desktop": "2k", "web": "1k",
		"bytes_1k": 2820000, "bytes_2k": 12660000,
	},
	# The runoff and the verge, and the surface a dirt circuit wants under it.
	"gravel_floor_02": {
		"use": "runoff",
		"desktop": "2k", "web": "1k",
		"bytes_1k": 3890000, "bytes_2k": 14800000,
	},
	# M19 step 2: the first HDRI, for `noon`. One hour rather than six, because
	# what step 2 has to answer first is whether real irradiance and the hand-tuned
	# sky shader can agree at all — and six skies is five more downloads than that
	# question needs.
	#
	# **The budget is what makes this one at a time.** Six HDRIs at 1 K is 7 MB
	# against a 12 MB web ceiling that two surfaces have already taken 6.7 MB of.
	# The guard will refuse the fourth or fifth, which is the guard working: the
	# decision it forces is whether the web build gets HDRIs at all, or gets them
	# at a resolution chosen for irradiance rather than for looking at.
	"kloofendal_43d_clear_puresky": {
		"kind": "hdri",
		"use": "noon",
		"desktop": "2k", "web": "1k",
		"bytes_1k": 1184531, "bytes_2k": 4624289,
	},
}

static func ids() -> Array:
	return ASSETS.keys()

## How far up `RESOLUTIONS` a name sits, or -1 if it is not one of them.
static func rank(resolution: String) -> int:
	return RESOLUTIONS.find(resolution)

## What the manifest costs a platform, in megabytes of source.
static func cost_mb(platform: String) -> float:
	var total := 0.0
	for id in ASSETS:
		var entry: Dictionary = ASSETS[id]
		total += float(entry.get("bytes_%s" % entry[platform], 0)) / 1048576.0
	return total
