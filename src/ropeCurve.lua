--!strict

-- The hanging-rope curve: a parabola through the two endpoints, drooping
-- "sag" studs vertically at its middle and bowing "sway" studs horizontally
-- (perpendicular to the chord) at its middle. A parabola rather than a true
-- catenary because it is predictable, cheap, and exactly invertible -- which
-- the estimators below rely on to recover the parameters of an already-built
-- rope.

-- The offset below/beside the straight chord at parameter t (0 at A, 1 at B).
local function sagOffsetAt(sag: number, t: number): number
	return sag * 4 * t * (1 - t)
end

-- The horizontal direction sway bows toward: the plan-view perpendicular of
-- the chord. nil for a vertical chord (no meaningful sideways direction).
-- Note the sign follows the A->B order, so a re-discovered rope's sway can
-- read negated if the walk happened to order the endpoints the other way;
-- rebuilds within one selection always use a consistent order.
local function swayDirection(a: Vector3, b: Vector3): Vector3?
	local chord = b - a
	local flat = Vector3.new(chord.X, 0, chord.Z)
	if flat.Magnitude < 0.01 then
		return nil
	end
	return Vector3.new(-flat.Z, 0, flat.X).Unit
end

-- segments+1 points along the curve from a to b. sag > 0 droops down, < 0
-- arches up; sway bows toward swayDirection (ignored for vertical chords).
local function computePoints(a: Vector3, b: Vector3, sag: number, segments: number, sway: number?): { Vector3 }
	local swayDir = if sway and sway ~= 0 then swayDirection(a, b) else nil
	local points = table.create(segments + 1)
	for i = 0, segments do
		local t = i / segments
		local point = a:Lerp(b, t) - Vector3.yAxis * sagOffsetAt(sag, t)
		if swayDir then
			point += swayDir * sagOffsetAt(sway :: number, t)
		end
		table.insert(points, point)
	end
	return points
end

-- The chord parameter of each interior point, recovered from the horizontal
-- projection: both the sag and sway offsets are perpendicular to the flat
-- chord direction, so this is exact. A near-vertical chord falls back to the
-- full projection; sag/sway are ill-defined there anyway.
local function chordParameter(a: Vector3, b: Vector3, p: Vector3, fallback: number): number
	local chord = b - a
	local chordXZ = Vector3.new(chord.X, 0, chord.Z)
	local chordXZLenSq = chordXZ:Dot(chordXZ)
	if chordXZLenSq > 1e-4 then
		return math.clamp((p - a):Dot(chordXZ) / chordXZLenSq, 0, 1)
	end
	local chordLenSq = chord:Dot(chord)
	if chordLenSq > 1e-6 then
		return math.clamp((p - a):Dot(chord) / chordLenSq, 0, 1)
	end
	return fallback
end

-- Recover a parabola parameter from an ordered polyline of rope vertices (the
-- inverse of computePoints), measuring each interior point's offset from the
-- chord along `measure`. Points near the ends are skipped: 4*t*(1-t) -> 0
-- there, so dividing by it amplifies placement noise.
local function estimateOffset(points: { Vector3 }, measure: (Vector3) -> number): number
	local n = #points
	if n < 3 then
		return 0
	end
	local a = points[1]
	local b = points[n]
	local total = 0
	local count = 0
	for i = 2, n - 1 do
		local p = points[i]
		local t = chordParameter(a, b, p, (i - 1) / (n - 1))
		local weight = 4 * t * (1 - t)
		if weight > 0.4 then
			total += measure(p - a:Lerp(b, t)) / weight
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	return total / count
end

local function estimateSag(points: { Vector3 }): number
	return estimateOffset(points, function(offset: Vector3): number
		return -offset.Y
	end)
end

local function estimateSway(points: { Vector3 }): number
	local n = #points
	if n < 3 then
		return 0
	end
	local swayDir = swayDirection(points[1], points[n])
	if not swayDir then
		return 0
	end
	return estimateOffset(points, function(offset: Vector3): number
		return offset:Dot(swayDir :: Vector3)
	end)
end

return {
	computePoints = computePoints,
	estimateSag = estimateSag,
	estimateSway = estimateSway,
	swayDirection = swayDirection,
	sagOffsetAt = sagOffsetAt,
}
