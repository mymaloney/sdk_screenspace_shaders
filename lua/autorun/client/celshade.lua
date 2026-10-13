-- Garry's Mod driver for the example_celshade shader
-- Requires the GShader library: https://steamcommunity.com/sharedfiles/filedetails/?id=3542644649
--
-- Usage: pp_celshade 1

local pp_celshade              = CreateClientConVar("pp_celshade", "0", true, false, "Enable cel-shading post process.", 0, 1)
local pp_celshade_bands        = CreateClientConVar("pp_celshade_bands", "4", true, false, "Number of shading bands.", 1, 16)
local pp_celshade_softness     = CreateClientConVar("pp_celshade_softness", "0.05", true, false, "Softness between bands.", 0, 0.5)
local pp_celshade_saturation   = CreateClientConVar("pp_celshade_saturation", "1.05", true, false, "Saturation multiplier.", 0, 3)
local pp_celshade_minbright    = CreateClientConVar("pp_celshade_minbright", "0.1", true, false, "Pixels darker than this keep their original brightness.", 0, 1)
local pp_celshade_thickness    = CreateClientConVar("pp_celshade_thickness", "1", true, false, "Outline thickness in pixels.", 0.5, 4)
local pp_celshade_depth_thresh = CreateClientConVar("pp_celshade_depth_thresh", "0.02", true, false, "Depth outline threshold.", 0.001, 1)
local pp_celshade_norm_thresh  = CreateClientConVar("pp_celshade_norm_thresh", "0.4", true, false, "Normal outline threshold.", 0.01, 2)
local pp_celshade_outline      = CreateClientConVar("pp_celshade_outline", "1", true, false, "Outline opacity.", 0, 1)
local pp_celshade_fade         = CreateClientConVar("pp_celshade_fade", "3000", true, false, "Distance where outlines fade out.", 100, 20000)
local pp_celshade_smooth       = CreateClientConVar("pp_celshade_smooth", "2", true, false, "Smoothing passes to clean up noisy textures (0 = off).", 0, 4)
local pp_celshade_smooth_size  = CreateClientConVar("pp_celshade_smooth_size", "8", true, false, "Smoothing radius in pixels.", 1, 32)
local pp_celshade_smooth_color = CreateClientConVar("pp_celshade_smooth_color", "0.2", true, false, "How different a color can be and still get smoothed away.", 0.01, 1)
local pp_celshade_detail       = CreateClientConVar("pp_celshade_detail", "0.25", true, false, "Texture detail kept, 0 = flat colors, 1 = original textures.", 0, 1)
local pp_celshade_shade_size   = CreateClientConVar("pp_celshade_shade_size", "48", true, false, "Area (pixels) brightness is averaged over before picking bands. Larger = bands follow lighting, not texture.", 4, 128)
local pp_celshade_flat_mats    = CreateClientConVar("pp_celshade_flat_mats", "1", true, false, "While enabled, set mat_specular 0, mat_bumpmap 0 and mat_disable_bloom 1.", 0, 1)
-- engine settings that were active before we changed them, restored when turned off
local pp_celshade_saved_mats   = CreateClientConVar("pp_celshade_saved_mats", "", true, false, "Internal: material settings to restore.")

-- relative depth difference treated as a different surface by the smoothing
local SMOOTH_DEPTH_TOLERANCE = 0.03

local mat = Material("effects/shaders/example_celshade")

local rtFlags = bit.bor(4, 8, 256, 512, 32768) -- clamp s/t, no mips, no lod, render target
local rtSmoothA = GetRenderTargetEx("_rt_CelSmoothA", ScrW(), ScrH(),
	RT_SIZE_FULL_FRAME_BUFFER, MATERIAL_RT_DEPTH_NONE, rtFlags, 0, IMAGE_FORMAT_RGBA8888)
local rtSmoothB = GetRenderTargetEx("_rt_CelSmoothB", ScrW(), ScrH(),
	RT_SIZE_FULL_FRAME_BUFFER, MATERIAL_RT_DEPTH_NONE, rtFlags, 0, IMAGE_FORMAT_RGBA8888)

local function SmoothMaterial(name, source)
	return CreateMaterial(name, "screenspace_general", {
		["$pixshader"]       = "example_celsmooth_ps30",
		["$vertexshader"]    = "pp_vs30",
		["$basetexture"]     = source,
		["$texture1"]        = "_rt_NormalsTangents",
		["$texture2"]        = "_rt_WPDepth",
		["$vertextransform"] = "1",
		["$ignorez"]         = "1",
		["$writealpha"]      = "1", -- alpha carries the shading brightness
	})
end

-- one material per source, so each pass reads the right texture
local smoothFirst      = SmoothMaterial("celshade_smooth_first", "_rt_FullFrameFB") -- horizontal, scene -> A
local smoothVertical   = SmoothMaterial("celshade_smooth_v", "_rt_CelSmoothA")       -- vertical, A -> B
local smoothHorizontal = SmoothMaterial("celshade_smooth_h", "_rt_CelSmoothB")       -- horizontal, B -> A

local function SetupSmooth(m, dirX, dirY, alphaIsShade)
	local spacing = pp_celshade_smooth_size:GetFloat() / 4 -- 4 color taps on each side
	m:SetFloat("$c0_x", dirX * spacing / ScrW())
	m:SetFloat("$c0_y", dirY * spacing / ScrH())
	m:SetFloat("$c0_z", pp_celshade_smooth_color:GetFloat())
	m:SetFloat("$c0_w", SMOOTH_DEPTH_TOLERANCE)

	local shadeSpacing = pp_celshade_shade_size:GetFloat() / 3 -- 3 shading taps on each side
	m:SetFloat("$c1_x", dirX * shadeSpacing / ScrW())
	m:SetFloat("$c1_y", dirY * shadeSpacing / ScrH())
	m:SetFloat("$c1_z", alphaIsShade and 1 or 0)
end

local function SmoothPass(m, target)
	render.PushRenderTarget(target)
		render.SetMaterial(m)
		shaderlib.DrawScreenQuad()
	render.PopRenderTarget()
end

hook.Add("RenderScreenspaceEffects", "CelShade", function()
	if !pp_celshade:GetBool() then return end
	if !shaderlib then return end -- GShader library not installed
	if !shaderlib.CanDrawEffects() then return end

	render.UpdateScreenEffectTexture()

	-- edge-preserving smoothing: scene -> A -> B, then B -> A -> B for extra passes
	local passes = pp_celshade_smooth:GetInt()
	if passes > 0 then
		-- the scene's alpha isn't shading brightness yet, the render targets' is
		SetupSmooth(smoothFirst, 1, 0, false)
		SetupSmooth(smoothVertical, 0, 1, true)
		SetupSmooth(smoothHorizontal, 1, 0, true)

		for pass = 1, passes do
			SmoothPass(pass == 1 and smoothFirst or smoothHorizontal, rtSmoothA)
			SmoothPass(smoothVertical, rtSmoothB)
		end
		mat:SetTexture("$texture3", rtSmoothB)
		mat:SetFloat("$c3_y", 1)
	else
		mat:SetTexture("$texture3", render.GetScreenEffectTexture())
		mat:SetFloat("$c3_y", 0)
	end

	mat:SetFloat("$c0_x", pp_celshade_bands:GetFloat())
	mat:SetFloat("$c0_y", pp_celshade_softness:GetFloat())
	mat:SetFloat("$c0_z", pp_celshade_saturation:GetFloat())
	mat:SetFloat("$c0_w", pp_celshade_minbright:GetFloat())
	mat:SetFloat("$c1_x", pp_celshade_thickness:GetFloat())
	mat:SetFloat("$c1_y", pp_celshade_depth_thresh:GetFloat())
	mat:SetFloat("$c1_z", pp_celshade_norm_thresh:GetFloat())
	mat:SetFloat("$c1_w", pp_celshade_outline:GetFloat())
	mat:SetFloat("$c2_w", pp_celshade_fade:GetFloat())
	mat:SetFloat("$c3_x", pp_celshade_detail:GetFloat())

	-- shaderlib.DrawScreenQuad draws with the transform pp_vs30 expects;
	-- render.DrawScreenQuad would place the quad incorrectly
	render.SetMaterial(mat)
	shaderlib.DrawScreenQuad()
end)

-- flat-looking materials: specular reflections, bumpmaps and bloom add noise that
-- turns into splotches once banded
local FLAT_MATS = {
	{ "mat_specular", "0" },
	{ "mat_bumpmap", "0" },
	{ "mat_disable_bloom", "1" },
}

local function ApplyFlatMats(enable)
	local saved = pp_celshade_saved_mats:GetString()

	if enable then
		if saved != "" then return end -- already applied (e.g. carried over from last session)

		local old = {}
		for _, setting in ipairs(FLAT_MATS) do
			local cvar = GetConVar(setting[1])
			old[#old + 1] = cvar and cvar:GetString() or ""
			RunConsoleCommand(setting[1], setting[2])
		end
		RunConsoleCommand(pp_celshade_saved_mats:GetName(), table.concat(old, " "))
	else
		if saved == "" then return end

		local old = string.Explode(" ", saved)
		for i, setting in ipairs(FLAT_MATS) do
			if old[i] and old[i] != "" then
				RunConsoleCommand(setting[1], old[i])
			end
		end
		RunConsoleCommand(pp_celshade_saved_mats:GetName(), "")
	end
end

local function UpdateFlatMats()
	ApplyFlatMats(pp_celshade:GetBool() and pp_celshade_flat_mats:GetBool())
end

cvars.AddChangeCallback(pp_celshade:GetName(), UpdateFlatMats, "CelShade")
cvars.AddChangeCallback(pp_celshade_flat_mats:GetName(), UpdateFlatMats, "CelShade")
hook.Add("InitPostEntity", "CelShade", UpdateFlatMats)

list.Set("PostProcess", "Cel Shading", {
	["icon"] = "gui/postprocess/shaderlib.jpg",
	["convar"] = "pp_celshade",
	["category"] = "#shaders_pp",
	["cpanel"] = function(panel)
		panel:Help("Cartoony cel-shading. Requires GShader library with reconstruction enabled.")
		panel:CheckBox("Enable", "pp_celshade")
		panel:CheckBox("Flat materials (no specular, bumpmaps or bloom)", "pp_celshade_flat_mats")
		panel:NumSlider("Bands", "pp_celshade_bands", 1, 16, 0)
		panel:NumSlider("Band softness", "pp_celshade_softness", 0, 0.5, 2)
		panel:NumSlider("Saturation", "pp_celshade_saturation", 0, 3, 2)
		panel:NumSlider("Shadow detail", "pp_celshade_minbright", 0, 1, 2)
		panel:Help("Smoothing (cleans up noisy and grungy textures)")
		panel:NumSlider("Smoothing passes", "pp_celshade_smooth", 0, 4, 0)
		panel:NumSlider("Smoothing radius", "pp_celshade_smooth_size", 1, 32, 0)
		panel:NumSlider("Smoothing strength", "pp_celshade_smooth_color", 0.01, 1, 2)
		panel:NumSlider("Shading area", "pp_celshade_shade_size", 4, 128, 0)
		panel:NumSlider("Texture detail", "pp_celshade_detail", 0, 1, 2)
		panel:Help("Outlines")
		panel:NumSlider("Outline thickness", "pp_celshade_thickness", 0.5, 4, 1)
		panel:NumSlider("Depth threshold", "pp_celshade_depth_thresh", 0.001, 0.2, 3)
		panel:NumSlider("Normal threshold", "pp_celshade_norm_thresh", 0.01, 2, 2)
		panel:NumSlider("Outline opacity", "pp_celshade_outline", 0, 1, 2)
		panel:NumSlider("Outline fade distance", "pp_celshade_fade", 100, 20000, 0)
	end
})
