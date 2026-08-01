class_name ShareCode
extends RefCounted

## A circuit as a string you can put in a message.
##
## ## Why a code rather than a file
##
## Custom tracks are already JSON under `user://`, chosen deliberately so they
## could be swapped — and then sharing was never built. The obvious form is
## "hand someone the file", which does not work on the target that matters: the
## web export has no filesystem to hand anything from, `user://` is browser
## storage, and a downloads-and-uploads flow needs UI on both sides.
##
## A code works identically on desktop and in a browser, needs nothing but the
## clipboard, and survives being pasted into whatever people already talk in.
##
## ## Shape
##
## `TD1-<base64>`, where the payload is a compressed JSON document. The prefix is
## outside the base64 on purpose: it makes a code recognisable on sight, it lets
## the version be read before anything is decoded, and it gives `decode` a cheap
## way to reject a paste that was never a code at all rather than failing deep
## inside a decompressor.
##
## ## Ghosts are opt-in, and that is a measurement rather than a preference
##
## `docs/roadmap.md` left open whether a shared circuit carries its author's best
## lap by default. It cannot: a lap is ~230 KB of samples, which is two orders of
## magnitude more than the layout and far past what anyone will paste into a
## message. So a plain code is the circuit, and attaching a lap is a deliberate
## second choice for when the transport can carry it.
##
## ## Everything here is hostile input
##
## A code arrives from another person, so `decode` treats every field as a claim
## rather than a fact. It reports failures instead of raising them, and it never
## returns a half-built circuit — `TrackLayout.compile` calls `TrackShape.walk`,
## so an invalid layout cannot be *built*, but the player still has to be told
## why rather than watching a Load button do nothing.

const PREFIX := "TD1-"
const VERSION := 1

## Refuses a paste that could not possibly be a circuit before allocating
## anything to hold it. A drawn loop is a few hundred cells; a hundred thousand
## is someone testing what happens.
const MAX_DECODED_BYTES := 4 * 1024 * 1024
const MAX_CELLS := 20000

class Result extends RefCounted:
	var ok := false
	## Empty when `ok`. Written for the player, not for a log.
	var error := ""
	var layout: TrackLayout
	var ghost: Ghost

	static func failed(message: String) -> Result:
		var r := Result.new()
		r.error = message
		return r

## The circuit as a code, optionally carrying a recorded lap.
##
## The id is deliberately **not** included. Ids are local — `TrackStore` hands
## them out and lap records are keyed on them — so importing someone's circuit
## under their id would let it inherit whatever the receiving player had recorded
## against that name. The importer allocates a fresh one.
static func encode(layout: TrackLayout, ghost: Ghost = null) -> String:
	var doc := layout.to_dict()
	doc.erase("id")
	doc["share"] = VERSION
	if ghost != null and not ghost.is_empty():
		doc["ghost"] = Marshalls.raw_to_base64(ghost.to_bytes())

	var raw := JSON.stringify(doc).to_utf8_buffer()
	return PREFIX + Marshalls.raw_to_base64(
		raw.compress(FileAccess.COMPRESSION_DEFLATE)
	) + "|%d" % raw.size()

## Turns a pasted code back into a circuit, or explains why it could not.
##
## The uncompressed size travels after a `|` rather than inside the payload
## because `decompress` needs it up front. It is a claim like everything else
## here, so it is bounded before it is believed — the whole point of a size field
## is that it sizes an allocation.
static func decode(code: String) -> Result:
	# Pasting through a chat window or an email wraps lines and adds spaces, and
	# a code that fails because of what the transport did to it would look like a
	# code that was never valid.
	var cleaned := code.strip_edges()
	for junk in [" ", "\n", "\r", "\t"]:
		cleaned = cleaned.replace(junk, "")

	if not cleaned.begins_with(PREFIX):
		return Result.failed(
			"That does not look like a circuit code — they start with \"%s\"."
			% PREFIX
		)
	cleaned = cleaned.substr(PREFIX.length())

	var bar := cleaned.rfind("|")
	if bar < 0:
		return Result.failed("That code is incomplete — the end is missing.")
	var expected := int(cleaned.substr(bar + 1))
	if expected <= 0 or expected > MAX_DECODED_BYTES:
		return Result.failed("That code claims an impossible size.")

	var body := cleaned.substr(0, bar)
	# Checked here rather than left to `Marshalls`, which logs an engine error on
	# its way to returning nothing. A mistyped or half-copied code is the most
	# ordinary failure this function has, and it should not look like a fault in
	# the game — the same reasoning as the length field in `Ghost`.
	if body.is_empty() or not _is_base64(body):
		return Result.failed("That code is damaged and cannot be read.")

	var packed := Marshalls.base64_to_raw(body)
	if packed.is_empty():
		return Result.failed("That code is damaged and cannot be read.")

	var raw := packed.decompress(expected, FileAccess.COMPRESSION_DEFLATE)
	if raw.size() != expected:
		return Result.failed("That code is damaged and cannot be read.")

	var parsed = JSON.parse_string(raw.get_string_from_utf8())
	if not (parsed is Dictionary):
		return Result.failed("That code is damaged and cannot be read.")

	var doc: Dictionary = parsed
	if int(doc.get("share", 0)) != VERSION:
		return Result.failed(
			"That circuit was shared by a different version of the game."
		)
	# Bounded before `from_dict` walks it: a cell list is the one field in here
	# that an author controls the length of.
	var cells = doc.get("cells", [])
	if not (cells is Array) or cells.size() > MAX_CELLS:
		return Result.failed("That circuit is too large to be real.")

	var result := Result.new()
	result.layout = TrackLayout.from_dict(doc)
	# Never the sender's id; see `encode`.
	result.layout.id = ""

	# The last check, and the one that matters: is this a circuit at all? The
	# compiler calls the same `TrackShape.walk` the editor does, so anything it
	# refuses could never have been drawn.
	var compiled := result.layout.compile()
	if not compiled.ok:
		return Result.failed(
			"That code decoded, but it is not a valid circuit: %s"
			% ("; ".join(compiled.errors) if not compiled.errors.is_empty()
				else "it does not form one closed loop")
		)

	if doc.has("ghost"):
		# A ghost that will not load is not worth refusing the circuit over.
		result.ghost = Ghost.from_bytes(
			Marshalls.base64_to_raw(String(doc["ghost"]))
		)

	result.ok = true
	return result

## Whether every character could have come out of `Marshalls.raw_to_base64`.
static func _is_base64(text: String) -> bool:
	for c in text:
		var ok := (
			(c >= "A" and c <= "Z") or (c >= "a" and c <= "z")
			or (c >= "0" and c <= "9") or c == "+" or c == "/" or c == "="
		)
		if not ok:
			return false
	return true
