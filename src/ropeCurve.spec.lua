--!strict

local TestTypes = require("./TestTypes")
local ropeCurve = require("./ropeCurve")

return function(t: TestTypes.TestContext)
	local function near(a: number, b: number, tolerance: number): boolean
		return math.abs(a - b) <= tolerance
	end
	local function nearV(a: Vector3, b: Vector3, tolerance: number): boolean
		return (a - b).Magnitude <= tolerance
	end

	t.test("computePoints hits both endpoints exactly and has segments+1 points", function()
		local a = Vector3.new(0, 10, 0)
		local b = Vector3.new(20, 14, 6)
		local points = ropeCurve.computePoints(a, b, 3, 8)
		t.expect(#points).toBe(9)
		t.expect(nearV(points[1], a, 1e-4)).toBeTruthy()
		t.expect(nearV(points[9], b, 1e-4)).toBeTruthy()
	end)

	t.test("computePoints droops by the sag at the middle", function()
		local a = Vector3.new(0, 10, 0)
		local b = Vector3.new(20, 10, 0)
		local points = ropeCurve.computePoints(a, b, 3, 8)
		local chordMid = a:Lerp(b, 0.5)
		t.expect(near(points[5].Y, chordMid.Y - 3, 1e-4)).toBeTruthy()
	end)

	t.test("zero sag is a straight line", function()
		local a = Vector3.new(0, 10, 0)
		local b = Vector3.new(20, 18, 4)
		local points = ropeCurve.computePoints(a, b, 0, 4)
		for i, p in points do
			t.expect(nearV(p, a:Lerp(b, (i - 1) / 4), 1e-4)).toBeTruthy()
		end
	end)

	t.test("estimateSag inverts computePoints", function()
		for _, sag in { 0, 1.5, 4, -2 } do
			local a = Vector3.new(0, 10, 0)
			local b = Vector3.new(24, 16, -8)
			local points = ropeCurve.computePoints(a, b, sag, 10)
			t.expect(near(ropeCurve.estimateSag(points), sag, 0.01)).toBeTruthy()
		end
	end)

	t.test("estimateSag returns 0 for degenerate polylines", function()
		t.expect(ropeCurve.estimateSag({})).toBe(0)
		t.expect(ropeCurve.estimateSag({ Vector3.zero, Vector3.one })).toBe(0)
	end)
end
