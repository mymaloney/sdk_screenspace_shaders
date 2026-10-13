-- Garry's Mod driver for the example_celshade shader
-- Requires the GShader library: https://steamcommunity.com/sharedfiles/filedetails/?id=3542644649
--
-- Usage: pp_celshade 1

local pp_celshade              = CreateClientConVar("pp_celshade", "0", true, false, "Enable cel-shading post process.", 0, 1)
local pp_celshade_bands        = CreateClientConVar("pp_celshade_bands", "4", true, false, "Number of shading bands for models and props.", 1, 16)
local pp_celshade_softness     = CreateClientConVar("pp_celshade_softness", "0.05", true, false, "Softness between bands.", 0, 0.5)
local pp_celshade_saturation   = CreateClientConVar("pp_celshade_saturation", "1.05", true, false, "Saturation multiplier.", 0, 3)
local pp_celshade_minbright    = CreateClientConVar("pp_celshade_minbright", "0.1", true, false, "Pixels darker than this keep their original brightness.", 0, 1)
local pp_celshade_thickness    = CreateClientConVar("pp_celshade_thickness", "1", true, false, "Outline thickness in pixels.", 0.5, 4)
local pp_celshade_depth_thresh = CreateClientConVar("pp_celshade_depth_thresh", "0.02", true, false, "Depth outline threshold.", 0.001, 1)
local pp_celshade_norm_thresh  = CreateClientConVar("pp_celshade_norm_thresh", "0.4", true, false, "Normal outline threshold.", 0.01, 2)
local pp_celshade_outline      = CreateClientConVar("pp_celshade_outline", "1", true, false, "Outline opacity.", 0, 1)
local pp_celshade_fade         = CreateClientConVar("pp_celshade_fade", "3000", true, false, "Distance where outlines fade out.", 100, 20000)
local pp_celshade_light          = CreateClientConVar("pp_celshade_light", "1", true, false, "Hard shadow edges on the world (0 = off). Needs r_shaderlib_lightmaps 1.", 0, 1)
local pp_celshade_light_contrast = CreateClientConVar("pp_celshade_light_contrast", "0.1", true, false, "How much the light must change to count as a shadow edge.", 0.01, 1)
local pp_celshade_light_radius   = CreateClientConVar("pp_celshade_light_radius", "48", true, false, "Distance (units) searched for shadow edges. Should cover the width of soft shadows.", 4, 256)

local mat = Material("effects/shaders/example_celshade")

hook.Add("RenderScreenspaceEffects", "CelShade", function()
	if !pp_celshade:GetBool() then return end
	if !shaderlib then return end -- GShader library not installed
	if !shaderlib.CanDrawEffects() then return end

	mat:SetFloat("$c0_x", pp_celshade_bands:GetFloat())
	mat:SetFloat("$c0_y", pp_celshade_softness:GetFloat())
	mat:SetFloat("$c0_z", pp_celshade_saturation:GetFloat())
	mat:SetFloat("$c0_w", pp_celshade_minbright:GetFloat())
	mat:SetFloat("$c1_x", pp_celshade_thickness:GetFloat())
	mat:SetFloat("$c1_y", pp_celshade_depth_thresh:GetFloat())
	mat:SetFloat("$c1_z", pp_celshade_norm_thresh:GetFloat())
	mat:SetFloat("$c1_w", pp_celshade_outline:GetFloat())
	mat:SetFloat("$c2_w", pp_celshade_fade:GetFloat())

	-- hard lighting only works when GShader is building its lightmap buffer,
	-- otherwise _rt_Lightmaps is missing or stale, so turn the feature off
	local lightmaps = GetConVar("r_shaderlib_lightmaps")
	local useLightmaps = shaderlib.rt_Lightmaps and lightmaps and lightmaps:GetBool()
	if useLightmaps then
		mat:SetTexture("$texture3", shaderlib.rt_Lightmaps)
	end
	mat:SetFloat("$c3_x", useLightmaps and pp_celshade_light:GetFloat() or 0)
	mat:SetFloat("$c3_y", pp_celshade_light_contrast:GetFloat())
	mat:SetFloat("$c3_z", render.GetHDREnabled() and 16 or 4.59479)

	-- the shader divides this by depth to get the search radius in pixels
	local view = render.GetViewSetup()
	local pixelsPerUnit = (ScrW() * 0.5) / math.tan(math.rad(view.fov * 0.5))
	mat:SetFloat("$c3_w", pp_celshade_light_radius:GetFloat() * pixelsPerUnit)

	-- shaderlib.DrawScreenQuad draws with the transform pp_vs30 expects;
	-- render.DrawScreenQuad would place the quad incorrectly
	render.UpdateScreenEffectTexture()
	render.SetMaterial(mat)
	shaderlib.DrawScreenQuad()
end)

list.Set("PostProcess", "Cel Shading", {
	["icon"] = "gui/postprocess/shaderlib.jpg",
	["convar"] = "pp_celshade",
	["category"] = "#shaders_pp",
	["cpanel"] = function(panel)
		panel:Help("Cartoony cel-shading. Requires GShader library with reconstruction enabled.")
		panel:CheckBox("Enable", "pp_celshade")
		panel:NumSlider("Model bands", "pp_celshade_bands", 1, 16, 0)
		panel:NumSlider("Band softness", "pp_celshade_softness", 0, 0.5, 2)
		panel:NumSlider("Saturation", "pp_celshade_saturation", 0, 3, 2)
		panel:NumSlider("Shadow detail", "pp_celshade_minbright", 0, 1, 2)
		panel:NumSlider("Outline thickness", "pp_celshade_thickness", 0.5, 4, 1)
		panel:NumSlider("Depth threshold", "pp_celshade_depth_thresh", 0.001, 0.2, 3)
		panel:NumSlider("Normal threshold", "pp_celshade_norm_thresh", 0.01, 2, 2)
		panel:NumSlider("Outline opacity", "pp_celshade_outline", 0, 1, 2)
		panel:NumSlider("Outline fade distance", "pp_celshade_fade", 100, 20000, 0)
		panel:Help("Hard world lighting (needs GShader lightmaps: r_shaderlib_lightmaps 1)")
		panel:NumSlider("Hard shadows", "pp_celshade_light", 0, 1, 2)
		panel:NumSlider("Shadow edge contrast", "pp_celshade_light_contrast", 0.01, 1, 2)
		panel:NumSlider("Shadow edge radius", "pp_celshade_light_radius", 4, 256, 0)
	end
})
