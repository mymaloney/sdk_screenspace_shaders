-- Toon lighting for the world in Garry's Mod (companion to toon_lighting.lua)
--
-- World brushes are lit by baked lightmaps, which have no light ramp like models do,
-- so the world is relit in screen space instead:
--   lighting = ambient * baked lightmap + sun * hard N.L * real-time sun shadow
--
-- 1. Every frame the scene is rendered from the sun with an orthographic camera into
--    a shadow map, with every material overridden by a depth-writing shader
--    (toon_sundepth). The camera sits outside the map, where the engine skips its
--    visibility culling, so everything in range casts shadows.
-- 2. A screen pass (toon_world) swaps each world pixel's baked lighting for the new
--    lighting. It needs GShader's world position and lightmap buffers.
--
-- Requires the GShader library. While enabled, r_shaderlib and r_shaderlib_lightmaps
-- are turned on (and restored afterwards).
--
-- Usage: toon_world 1

local toon_world             = CreateClientConVar("toon_world", "0", true, false, "Toon lighting with real-time sun shadows on the world.", 0, 1)
local toon_world_sun         = CreateClientConVar("toon_world_sun", "0.8", true, false, "Sun strength.", 0, 4)
local toon_world_ambient     = CreateClientConVar("toon_world_ambient", "0.6", true, false, "How much of the baked lighting is kept as fill light.", 0, 2)
local toon_world_sun_color   = CreateClientConVar("toon_world_sun_color", "", true, false, "Sun color as \"r g b\" (0-255). Empty = the map's light_environment color.")
local toon_world_sun_angles  = CreateClientConVar("toon_world_sun_angles", "", true, false, "Sun as \"pitch yaw\" like light_environment (pitch -90 = straight down). Empty = from the map.")
local toon_world_range       = CreateClientConVar("toon_world_range", "2048", true, false, "Shadows are drawn within this distance (units). Larger = blurrier shadows.", 256, 16384)
local toon_world_softness    = CreateClientConVar("toon_world_softness", "0.05", true, false, "Softness of the light/shadow terminator on surfaces.", 0.001, 0.5)
local toon_world_bias        = CreateClientConVar("toon_world_bias", "4", true, false, "Shadow depth bias (units), raise if surfaces shadow themselves in stripes.", 0, 64)
local toon_world_offset      = CreateClientConVar("toon_world_offset", "1.5", true, false, "Shadow normal offset in shadow map texels, raise if surfaces shadow themselves in stripes or teeth.", 0, 8)
local toon_world_resolution  = CreateClientConVar("toon_world_resolution", "2048", true, false, "Shadow map resolution (needs a game restart).", 512, 4096)
local toon_world_flip        = CreateClientConVar("toon_world_flip", "0", true, false, "Debug: flip the shadow map lookup if shadows look mirrored (1 = horizontal, 2 = vertical, 3 = both).", 0, 3)
local toon_world_debug       = CreateClientConVar("toon_world_debug", "0", false, false, "Debug view: 1 = shadow term (white lit, black shadow, red not relit), 2 = also show the shadow map.", 0, 2)
-- GShader settings that were active before we changed them, restored when turned off
local toon_world_saved       = CreateClientConVar("toon_world_saved", "", true, false, "Internal: settings to restore.")

local SKY_DISTANCE = 32768 -- how far towards the sun the shadow camera sits (outside the map)

-------------------------------------------------------------------------------
-- Render targets and materials
-------------------------------------------------------------------------------

local RESOLUTION = math.Clamp(toon_world_resolution:GetInt(), 512, 4096)

-- point sampled (1), clamped (4, 8), no mips (256, 512)
local shadowRT = GetRenderTargetEx("_rt_ToonSunShadow", RESOLUTION, RESOLUTION,
	RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_SEPARATE, bit.bor(1, 4, 8, 256, 512), 0, IMAGE_FORMAT_R32F)

local depthMat = CreateMaterial("toon_world_sundepth", "screenspace_general", {
	["$pixshader"]       = "toon_sundepth_ps30",
	["$vertexshader"]    = "toon_sundepth_vs30",
	["$basetexture"]     = "color/white",
	["$vertextransform"] = "1",
	["$softwareskin"]    = "1", -- skinned models are posed on the CPU, so the vertex shader can stay simple
	["$nocull"]          = "1", -- both sides cast shadows, so thin walls don't leak light
})

local relightMat = CreateMaterial("toon_world_relight", "screenspace_general", {
	["$pixshader"]       = "toon_world_ps30",
	["$vertexshader"]    = "pp_vs30",
	["$basetexture"]     = "_rt_FullFrameFB",
	["$texture3"]        = "_rt_ToonSunShadow",
	["$vertextransform"] = "1",
	["$ignorez"]         = "1",
})

-------------------------------------------------------------------------------
-- Sun from the map
-------------------------------------------------------------------------------

-- light_environment isn't networked to clients, so read it from the map's entity lump
local function ReadLightEnvironment()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if !f then return nil end

	local result
	pcall(function()
		if f:Read(4) != "VBSP" then return end
		f:Seek(8) -- lump 0 (entities): offset, length
		local offset = f:ReadLong()
		local length = f:ReadLong()
		f:Seek(offset)
		local entities = f:Read(length) or ""

		for block in string.gmatch(entities, "%b{}") do
			local keys = {}
			for key, value in string.gmatch(block, "\"([^\"]+)\"%s+\"([^\"]*)\"") do
				keys[string.lower(key)] = value
			end
			if keys.classname == "light_environment" then
				result = keys
				return
			end
		end
	end)
	f:Close()
	return result
end

local mapSun -- { dir = towards the sun, color = Vector } or false

-- direction towards the sun from light_environment style pitch/yaw, using VRAD's
-- SetupLightNormalFromProps (which gives the direction the light travels)
local function SunFromPitchYaw(pitch, yaw)
	local p, y = math.rad(pitch), math.rad(yaw)
	local travel = Vector(math.cos(y) * math.cos(p), math.sin(y) * math.cos(p), math.sin(p))
	return -travel
end

local function GetMapSun()
	if mapSun != nil then return mapSun end
	mapSun = false

	local ent = ReadLightEnvironment()
	if !ent then return mapSun end

	local angles = string.Explode(" ", ent.angles or "0 0 0")
	local yaw = tonumber(ent.angle) or tonumber(angles[2]) or 0
	local pitch = tonumber(ent.pitch) or tonumber(angles[1]) or -45
	if pitch == 0 then pitch = tonumber(angles[1]) or -45 end

	local light = string.Explode(" ", ent._light or "255 255 255 200")
	local color = Vector(tonumber(light[1]) or 255, tonumber(light[2]) or 255, tonumber(light[3]) or 255) / 255

	mapSun = { dir = SunFromPitchYaw(pitch, yaw), color = color }
	return mapSun
end

local function GetSun()
	local dir, color

	local custom = string.Explode(" ", string.Trim(toon_world_sun_angles:GetString()))
	if tonumber(custom[1]) and tonumber(custom[2]) then
		dir = SunFromPitchYaw(tonumber(custom[1]), tonumber(custom[2]))
	end

	local sun = GetMapSun()
	if !dir and sun then dir = sun.dir end
	if !dir then
		-- maps without light_environment may still have an env_sun
		local info = util.GetSunInfo()
		if info and info.direction and info.direction:LengthSqr() > 0 then dir = info.direction:GetNormalized() end
	end
	dir = dir or SunFromPitchYaw(-50, 30)

	local customColor = string.Explode(" ", string.Trim(toon_world_sun_color:GetString()))
	if tonumber(customColor[1]) and tonumber(customColor[2]) and tonumber(customColor[3]) then
		color = Vector(tonumber(customColor[1]), tonumber(customColor[2]), tonumber(customColor[3])) / 255
	end
	color = color or (sun and sun.color) or Vector(1, 1, 1)

	return dir, color
end

-------------------------------------------------------------------------------
-- Shadow map
-------------------------------------------------------------------------------

local renderingShadow = false
local shadowParams -- what the relight pass needs to look the shadow map up

local function RenderShadowMap()
	local sunDir = GetSun()
	local range = toon_world_range:GetFloat()

	local forward = -sunDir
	local angles = forward:Angle()
	local right, up = angles:Right(), angles:Up()

	-- snap the camera to whole shadow map texels, so shadows don't shimmer when moving
	local center = EyePos()
	local texel = 2 * range / RESOLUTION
	local x, y = center:Dot(right), center:Dot(up)
	center = center - right * (x - math.floor(x / texel) * texel) - up * (y - math.floor(y / texel) * texel)

	local origin = center + sunDir * SKY_DISTANCE
	local znear, zfar = 16, SKY_DISTANCE * 2

	renderingShadow = true
	render.PushRenderTarget(shadowRT)
		render.Clear(255, 255, 255, 255, true, true)
		render.WorldMaterialOverride(depthMat)
		render.MaterialOverride(depthMat)

		render.RenderView({
			origin = origin,
			angles = angles,
			x = 0, y = 0, w = RESOLUTION, h = RESOLUTION,
			aspect = 1,
			fov = 90,
			znear = znear,
			zfar = zfar,
			ortho = { left = -range, right = range, top = -range, bottom = range },
			drawhud = false,
			drawviewmodel = false,
			drawmonitors = false,
			dopostprocess = false,
			bloomtone = false,
		})

		render.MaterialOverride(nil)
		render.WorldMaterialOverride(nil)
	render.PopRenderTarget()
	renderingShadow = false

	-- world -> (u, v, depth) for the shadow map. Engine orthographic convention:
	-- u grows along the camera's right, v grows downward (against up), and depth is
	-- linear from 0 at znear to 1 at zfar
	local flip = toon_world_flip:GetInt()
	local su = bit.band(flip, 1) != 0 and -1 or 1
	local sv = bit.band(flip, 2) != 0 and -1 or 1
	local scale = 1 / (2 * range)
	local ru = right * (scale * su)
	local rv = up * (-scale * sv)
	local rz = forward * (1 / (zfar - znear))

	shadowParams = {
		matrix = Matrix({
			{ ru.x, ru.y, ru.z, 0.5 - ru:Dot(origin) },
			{ rv.x, rv.y, rv.z, 0.5 - rv:Dot(origin) },
			{ rz.x, rz.y, rz.z, -(forward:Dot(origin) + znear) / (zfar - znear) },
			{ 0, 0, 0, 1 },
		}),
		depthScale = 1 / (zfar - znear),
		texelSize = texel,
	}
end

-- keep the shadow view to opaque geometry: no sky, no translucents/effects, no viewmodel
local function SkipWhileShadowing()
	if renderingShadow then return true end
end
hook.Add("PreDrawSkyBox", "ToonWorld", SkipWhileShadowing)
hook.Add("PreDrawTranslucentRenderables", "ToonWorld", SkipWhileShadowing)
hook.Add("PreDrawEffects", "ToonWorld", SkipWhileShadowing)
hook.Add("PreDrawViewModel", "ToonWorld", SkipWhileShadowing)
hook.Add("PreDrawHalos", "ToonWorld", SkipWhileShadowing)

-------------------------------------------------------------------------------
-- Relight pass
-------------------------------------------------------------------------------

local function Relight()
	if !shadowParams or !shaderlib or !shaderlib.rt_Lightmaps or !shaderlib.rt_WPDepth then return end
	if shaderlib.CanDrawEffects and !shaderlib.CanDrawEffects() then return end

	local sunDir, sunColor = GetSun()
	local eye = EyePos()

	-- GShader's render targets may be created after this file loads, so bind them here
	relightMat:SetTexture("$texture1", shaderlib.rt_WPDepth)
	relightMat:SetTexture("$texture2", shaderlib.rt_Lightmaps)
	relightMat:SetMatrix("$VIEWPROJMAT", shadowParams.matrix)

	relightMat:SetFloat("$c0_x", sunDir.x)
	relightMat:SetFloat("$c0_y", sunDir.y)
	relightMat:SetFloat("$c0_z", sunDir.z)
	relightMat:SetFloat("$c0_w", toon_world_sun:GetFloat())
	relightMat:SetFloat("$c1_x", sunColor.x)
	relightMat:SetFloat("$c1_y", sunColor.y)
	relightMat:SetFloat("$c1_z", sunColor.z)
	relightMat:SetFloat("$c1_w", toon_world_ambient:GetFloat())
	relightMat:SetFloat("$c2_x", eye.x)
	relightMat:SetFloat("$c2_y", eye.y)
	relightMat:SetFloat("$c2_z", eye.z)
	relightMat:SetFloat("$c2_w", render.GetHDREnabled() and 16 or 4.59479)
	relightMat:SetFloat("$c3_x", toon_world_bias:GetFloat() * shadowParams.depthScale)
	relightMat:SetFloat("$c3_y", toon_world_offset:GetFloat() * shadowParams.texelSize)
	relightMat:SetFloat("$c3_z", toon_world_softness:GetFloat())
	relightMat:SetFloat("$c3_w", toon_world_debug:GetInt() > 0 and 1 or 0)

	render.UpdateScreenEffectTexture()
	render.SetMaterial(relightMat)
	shaderlib.DrawScreenQuad()
end

-------------------------------------------------------------------------------
-- GShader settings
-------------------------------------------------------------------------------

local REQUIRED_SETTINGS = {
	{ "r_shaderlib", "1" },          -- world position buffer
	{ "r_shaderlib_lightmaps", "1" }, -- lightmap buffer
}

local function ApplySettings(enable)
	local saved = {}
	for _, pair in ipairs(string.Explode(";", toon_world_saved:GetString())) do
		local name, value = string.match(pair, "^([^=]+)=(.*)$")
		if name then saved[name] = value end
	end

	for _, setting in ipairs(REQUIRED_SETTINGS) do
		local name, value = setting[1], setting[2]
		local cvar = GetConVar(name)
		if !cvar then continue end -- GShader not installed

		if enable then
			if saved[name] == nil then saved[name] = cvar:GetString() end
			RunConsoleCommand(name, value)
		elseif saved[name] != nil then
			RunConsoleCommand(name, saved[name])
			saved[name] = nil
		end
	end

	local parts = {}
	for name, value in SortedPairs(saved) do parts[#parts + 1] = name .. "=" .. value end
	RunConsoleCommand(toon_world_saved:GetName(), table.concat(parts, ";"))
end

-------------------------------------------------------------------------------
-- Enable/disable
-------------------------------------------------------------------------------

local active = false

local function Update()
	local enable = toon_world:GetBool()
	if enable and !shaderlib then
		MsgN("[toon_world] the GShader library is required")
		enable = false
	end

	ApplySettings(enable)
	active = enable
	if !enable then shadowParams = nil end
end

cvars.AddChangeCallback(toon_world:GetName(), Update, "ToonWorld")
hook.Add("InitPostEntity", "ToonWorld", Update)

hook.Add("PreRender", "ToonWorld", function()
	if !active or renderingShadow then return end
	RenderShadowMap()
end)

hook.Add("RenderScreenspaceEffects", "ToonWorld", function()
	if !active or renderingShadow then return end
	Relight()
end)

hook.Add("HUDPaint", "ToonWorld", function()
	if !active or toon_world_debug:GetInt() < 2 then return end
	render.DrawTextureToScreenRect(shadowRT, 0, 0, 384, 384)
end)

list.Set("PostProcess", "Toon World", {
	["icon"] = "gui/postprocess/colourmod.png",
	["convar"] = "toon_world",
	["category"] = "#effects_pp",
	["cpanel"] = function(panel)
		panel:Help("Toon lighting with real-time sun shadows on the world. Requires the GShader library.")
		panel:CheckBox("Enable", "toon_world")
		panel:NumSlider("Sun strength", "toon_world_sun", 0, 4, 2)
		panel:NumSlider("Fill light (baked)", "toon_world_ambient", 0, 2, 2)
		panel:NumSlider("Shadow range", "toon_world_range", 256, 16384, 0)
		panel:NumSlider("Terminator softness", "toon_world_softness", 0.001, 0.5, 3)
		panel:NumSlider("Shadow bias", "toon_world_bias", 0, 64, 1)
		panel:NumSlider("Shadow normal offset", "toon_world_offset", 0, 8, 2)
		panel:NumSlider("Debug view", "toon_world_debug", 0, 2, 0)
	end
})
