--!strict

-- The hanging-rope curve: a vertical parabola through the two endpoints with a
-- given droop ("sag", in studs) at its middle. A parabola rather than a true
-- catenary because it is predictable, cheap, and exactly invertible -- which
-- estimateSag below relies on to recover the sag of an already-built rope.

-- The vertical offset below the straight chord at parameter t (0 at A, 1 at B).
local function sagOffsetAt(sag: number, t: number): number
	return sag * 4 * t * (1 - t)
end

-- segments+1 points along the curve from a to b. sag > 0 droops down, < 0 arches up.
local function computePoints(a: Vector3, b: Vector3, sag: number, segments: number): { Vector3 }
	local points = table.create(segments + 1)
	for i = 0, segments do
		local t = i / segments
		table.insert(points, a:Lerp(b, t) - Vector3.yAxis * sagOffsetAt(sag, t))
	end
	return points
end

-- Recover the sag from an ordered polyline of rope vertices (the inverse of
-- computePoints). Each interior point implies a sag via the parabola formula at
-- its chord parameter; averaging them tolerates hand-built ropes that only
-- approximate the curve. Points near the ends are skipped: 4*t*(1-t) -> 0 there,
-- so dividing by it amplifies placement noise.
local function estimateSag(points: { Vector3 }): number
	local n = #points
	if n < 3 then
		return 0
	end
	local a = points[1]
	local b = points[n]
	local chord = b - a
	local chordLenSq = chord:Dot(chord)
	local total = 0
	local count = 0
	for i = 2, n - 1 do
		local p = points[i]
		local t = if chordLenSq < 1e-6 then (i - 1) / (n - 1) else math.clamp((p - a):Dot(chord) / chordLenSq, 0, 1)
		local weight = 4 * t * (1 - t)
		if weight > 0.4 then
			local drop = (a:Lerp(b, t) - p).Y
			total += drop / weight
			count += 1
		end
	end
	if count == 0 then
		return 0
	end
	return total / count
end

return {
	computePoints = computePoints,
	estimateSag = estimateSag,
	sagOffsetAt = sagOffsetAt,
}
