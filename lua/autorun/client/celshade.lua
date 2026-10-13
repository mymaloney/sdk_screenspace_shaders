-- Garry's Mod driver for the example_celshade shader
-- Requires the GShader library: https://steamcommunity.com/sharedfiles/filedetails/?id=3542644649
--
-- Usage: pp_celshade 1

local pp_celshade              = CreateClientConVar("pp_celshade", "0", true, false, "Enable cel-shading post process.", 0, 1)
local pp_celshade_bands        = CreateClientConVar("pp_celshade_bands", "4", true, false, "Number of shading bands.", 2, 16)
local pp_celshade_softness     = CreateClientConVar("pp_celshade_softness", "0.05", true, false, "Softness between bands.", 0, 0.5)
local pp_celshade_saturation   = CreateClientConVar("pp_celshade_saturation", "1.05", true, false, "Saturation multiplier.", 0, 3)
local pp_celshade_minbright    = CreateClientConVar("pp_celshade_minbright", "0.1", true, false, "Pixels darker than this keep their original brightness.", 0, 1)
local pp_celshade_thickness    = CreateClientConVar("pp_celshade_thickness", "1", true, false, "Outline thickness in pixels.", 0.5, 4)
local pp_celshade_depth_thresh = CreateClientConVar("pp_celshade_depth_thresh", "0.02", true, false, "Depth outline threshold.", 0.001, 1)
local pp_celshade_norm_thresh  = CreateClientConVar("pp_celshade_norm_thresh", "0.4", true, false, "Normal outline threshold.", 0.01, 2)
local pp_celshade_outline      = CreateClientConVar("pp_celshade_outline", "1", true, false, "Outline opacity.", 0, 1)
local pp_celshade_fade         = CreateClientConVar("pp_celshade_fade", "3000", true, false, "Distance where outlines fade out.", 100, 20000)
local pp_celshade_rim          = CreateClientConVar("pp_celshade_rim", "0", true, false, "Rim light strength.", 0, 1)

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
	mat:SetFloat("$c3_w", pp_celshade_rim:GetFloat())

	local eye = EyePos()
	mat:SetFloat("$c3_x", eye.x)
	mat:SetFloat("$c3_y", eye.y)
	mat:SetFloat("$c3_z", eye.z)

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
		panel:NumSlider("Bands", "pp_celshade_bands", 2, 16, 0)
		panel:NumSlider("Band softness", "pp_celshade_softness", 0, 0.5, 2)
		panel:NumSlider("Saturation", "pp_celshade_saturation", 0, 3, 2)
		panel:NumSlider("Shadow detail", "pp_celshade_minbright", 0, 1, 2)
		panel:NumSlider("Outline thickness", "pp_celshade_thickness", 0.5, 4, 1)
		panel:NumSlider("Depth threshold", "pp_celshade_depth_thresh", 0.001, 0.2, 3)
		panel:NumSlider("Normal threshold", "pp_celshade_norm_thresh", 0.01, 2, 2)
		panel:NumSlider("Outline opacity", "pp_celshade_outline", 0, 1, 2)
		panel:NumSlider("Outline fade distance", "pp_celshade_fade", 100, 20000, 0)
		panel:NumSlider("Rim light", "pp_celshade_rim", 0, 1, 2)
	end
})
