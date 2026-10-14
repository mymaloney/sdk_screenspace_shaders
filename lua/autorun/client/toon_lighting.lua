-- Toon lighting for models in Garry's Mod
--
-- Uses the engine's own $lightwarptexture (the feature behind TF2's look): every
-- VertexLitGeneric model material gets a hard-stepped light ramp, so models are
-- shaded in flat cartoon bands by the engine itself, following the real lights,
-- without touching textures.
--
-- Lightwarp only works in the phong/bumpmap lighting path, so materials without
-- phong get $phong 1 (with $phongboost 0, so no extra shine) and a flat normal map
-- if they have none. Everything is restored when turned off.
--
-- Static props are the exception: the engine decides at map load whether a static
-- prop gets baked vertex lighting (no bumpmap) or runtime lighting (bumpmap). Adding
-- a bumpmap afterwards leaves it with no lighting at all, so it renders black.
-- Materials used by static props are therefore only patched if they already have a
-- bumpmap. Static props are found through NikNaks (installed with the GShader
-- library); without it no bumpmaps are added at all, to be safe.
--
-- Usage: toon_lighting 1

local toon_lighting            = CreateClientConVar("toon_lighting", "0", true, false, "Cartoon (toon) lighting on models.", 0, 1)
local toon_lighting_bands      = CreateClientConVar("toon_lighting_bands", "2", true, false, "Number of light bands (2 = shadow and lit).", 2, 8)
local toon_lighting_threshold  = CreateClientConVar("toon_lighting_threshold", "0.5", true, false, "Where the shadow side ends (0.5 = where the surface turns away from the light).", 0.05, 0.95)
local toon_lighting_softness   = CreateClientConVar("toon_lighting_softness", "0.02", true, false, "Softness of the band edges.", 0, 0.25)
local toon_lighting_shadow     = CreateClientConVar("toon_lighting_shadow", "0.15", true, false, "Direct light kept on the shadow side.", 0, 1)
local toon_lighting_brightness = CreateClientConVar("toon_lighting_brightness", "1", true, false, "Brightness of the lit side.", 0.25, 2)
local toon_lighting_flat_mats  = CreateClientConVar("toon_lighting_flat_mats", "1", true, false, "While enabled, set mat_specular 0 and mat_disable_bloom 1.", 0, 1)
-- engine settings that were active before we changed them, restored when turned off
local toon_lighting_saved_mats = CreateClientConVar("toon_lighting_saved_mats", "", true, false, "Internal: settings to restore.")

-------------------------------------------------------------------------------
-- Light ramp
-------------------------------------------------------------------------------

local RAMP_WIDTH, RAMP_HEIGHT = 256, 4

local rampRT = GetRenderTargetEx("_rt_ToonLightwarp", RAMP_WIDTH, RAMP_HEIGHT,
	RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(4, 8, 256, 512), 0, IMAGE_FORMAT_RGBA8888)

-- flat normal map, for materials that need one to use the lightwarp path
local flatNormalRT = GetRenderTargetEx("_rt_ToonFlatNormal", 4, 4,
	RT_SIZE_LITERAL, MATERIAL_RT_DEPTH_NONE, bit.bor(256, 512), 0, IMAGE_FORMAT_RGBA8888)

-- Brightness of the direct light at ramp position u. The engine looks the ramp up
-- with u = half-lambert N.L (0 = facing away, 0.5 = edge-on, 1 = facing the light)
local function RampValue(u)
	local bands = math.floor(toon_lighting_bands:GetFloat())
	local threshold = toon_lighting_threshold:GetFloat()
	local softness = math.max(toon_lighting_softness:GetFloat(), 0.001)

	-- band boundaries are spread evenly from the threshold to fully lit
	local level = 0
	for j = 1, bands - 1 do
		local boundary = threshold + (j - 1) * (1 - threshold) / (bands - 1)
		level = level + math.Clamp((u - boundary + softness) / (2 * softness), 0, 1)
	end

	local lit = toon_lighting_brightness:GetFloat()
	return Lerp(level / (bands - 1), toon_lighting_shadow:GetFloat() * lit, lit)
end

local rampDirty = true

local function DrawRamp()
	render.PushRenderTarget(rampRT)
	cam.Start2D()
		render.Clear(0, 0, 0, 255)
		for x = 0, RAMP_WIDTH - 1 do
			-- the engine doubles the ramp value, so 0.5 means unchanged brightness
			local c = math.Clamp(RampValue((x + 0.5) / RAMP_WIDTH) * 0.5 * 255, 0, 255)
			surface.SetDrawColor(c, c, c, 255)
			surface.DrawRect(x, 0, 1, RAMP_HEIGHT)
		end
	cam.End2D()
	render.PopRenderTarget()

	render.PushRenderTarget(flatNormalRT)
		render.Clear(128, 128, 255, 255)
	render.PopRenderTarget()
end

for _, cvar in ipairs({ toon_lighting_bands, toon_lighting_threshold, toon_lighting_softness, toon_lighting_shadow, toon_lighting_brightness }) do
	cvars.AddChangeCallback(cvar:GetName(), function() rampDirty = true end, "ToonLighting")
end

-------------------------------------------------------------------------------
-- Material patching
-------------------------------------------------------------------------------

-- [material name] = { mat = IMaterial, saved = original params }
local patched = {}
-- material names that aren't model materials, so they're not checked again
local skipped = {}

local function IsTexture(tex)
	return tex and !tex:IsError()
end

local function SaveParams(mat)
	local lightwarp = mat:GetTexture("$lightwarptexture")
	local bump = mat:GetTexture("$bumpmap")
	return {
		lightwarp  = IsTexture(lightwarp) and lightwarp or nil,
		bump       = IsTexture(bump) and bump or nil,
		phong      = mat:GetInt("$phong"),
		phongboost = mat:GetFloat("$phongboost"),
		halflambert = mat:GetInt("$halflambert"),
	}
end

local function RestoreInt(mat, key, value)
	if value then mat:SetInt(key, value) else mat:SetUndefined(key) end
end

local function RestoreFloat(mat, key, value)
	if value then mat:SetFloat(key, value) else mat:SetUndefined(key) end
end

local function RestoreTexture(mat, key, value)
	if value then mat:SetTexture(key, value) else mat:SetUndefined(key) end
end

local function ApplyParams(mat, saved)
	if (saved.phong or 0) == 0 then
		mat:SetInt("$phong", 1)
		mat:SetFloat("$phongboost", 0)
	end
	if !saved.bump then
		mat:SetTexture("$bumpmap", flatNormalRT)
	end
	-- the ramp is laid out for half-lambert lighting
	mat:SetInt("$halflambert", 1)
	mat:SetTexture("$lightwarptexture", rampRT)
	mat:Recompute()
end

local function IsPatchedNow(mat)
	local tex = mat:GetTexture("$lightwarptexture")
	return tex and tex:GetName() == rampRT:GetName()
end

-- materials used by static props (nil = unknown, NikNaks not available)
local staticPropMaterials
local staticPropsCollected = false

-- static props aren't entities on the client, so look their models up through NikNaks
-- and read the materials from a temporary clientside model
local function CollectStaticPropMaterials()
	if staticPropsCollected then return end
	staticPropsCollected = true

	if !NikNaks or !NikNaks.CurrentMap then return end
	local ok, models = pcall(NikNaks.CurrentMap.GetStaticPropModels, NikNaks.CurrentMap)
	if !ok or !models then return end

	staticPropMaterials = {}
	for _, model in ipairs(models) do
		local csModel = ClientsideModel(model, RENDERGROUP_OTHER)
		if IsValid(csModel) then
			for _, name in ipairs(csModel:GetMaterials() or {}) do
				staticPropMaterials[name] = true
			end
			csModel:Remove()
		end
	end
end

-- adding a bumpmap is only safe if no static prop uses the material (see top)
local function CanAddBumpmap(name)
	return staticPropMaterials != nil and !staticPropMaterials[name]
end

local function PatchMaterial(name)
	if name == "" or skipped[name] then return end

	local entry = patched[name]
	if entry then
		-- materials can get reloaded by the engine (e.g. when settings change)
		if !IsPatchedNow(entry.mat) then ApplyParams(entry.mat, entry.saved) end
		return
	end

	local mat = Material(name)
	local shader = mat and !mat:IsError() and string.lower(mat:GetShader() or "") or ""
	if !string.find(shader, "vertexlitgeneric", 1, true) then
		skipped[name] = true
		return
	end

	local saved = SaveParams(mat)
	if !saved.bump and !CanAddBumpmap(name) then
		skipped[name] = true
		return
	end

	patched[name] = { mat = mat, saved = saved }
	ApplyParams(mat, saved)
end

local function RestoreAll()
	for _, entry in pairs(patched) do
		local mat, saved = entry.mat, entry.saved
		RestoreTexture(mat, "$lightwarptexture", saved.lightwarp)
		RestoreTexture(mat, "$bumpmap", saved.bump)
		RestoreInt(mat, "$phong", saved.phong)
		RestoreFloat(mat, "$phongboost", saved.phongboost)
		RestoreInt(mat, "$halflambert", saved.halflambert)
		mat:Recompute()
	end
	patched = {}
end

local function PatchStaticProps()
	for name in pairs(staticPropMaterials or {}) do
		PatchMaterial(name)
	end
end

local function PatchEntity(ent)
	for _, name in ipairs(ent:GetMaterials() or {}) do
		PatchMaterial(name)
	end
	-- material overrides set by tools/addons
	PatchMaterial(ent:GetMaterial() or "")
	for i = 0, #(ent:GetMaterials() or {}) - 1 do
		PatchMaterial(ent:GetSubMaterial(i) or "")
	end
end

-- entities only need checking again when their model changes
local entityModels = setmetatable({}, { __mode = "k" })

local function ScanEntities(force)
	-- needed before patching anything, to know which materials static props use
	CollectStaticPropMaterials()

	for _, ent in ipairs(ents.GetAll()) do
		local model = ent:GetModel()
		if model and (force or entityModels[ent] != model) then
			entityModels[ent] = model
			PatchEntity(ent)
		end
	end
end

-------------------------------------------------------------------------------
-- Engine settings
-------------------------------------------------------------------------------

-- specular reflections and bloom add shine that fights the flat look.
-- (mat_bumpmap 0 is not used: it turns off the lighting path lightwarp needs)
local FLAT_MATS = {
	{ "mat_specular", "0" },
	{ "mat_disable_bloom", "1" },
}

local function ApplyFlatMats(enable)
	local saved = toon_lighting_saved_mats:GetString()

	if enable then
		if saved != "" then return end -- already applied (e.g. carried over from last session)

		local old = {}
		for _, setting in ipairs(FLAT_MATS) do
			local cvar = GetConVar(setting[1])
			old[#old + 1] = cvar and cvar:GetString() or ""
			RunConsoleCommand(setting[1], setting[2])
		end
		RunConsoleCommand(toon_lighting_saved_mats:GetName(), table.concat(old, " "))
	else
		if saved == "" then return end

		local old = string.Explode(" ", saved)
		for i, setting in ipairs(FLAT_MATS) do
			if old[i] and old[i] != "" then
				RunConsoleCommand(setting[1], old[i])
			end
		end
		RunConsoleCommand(toon_lighting_saved_mats:GetName(), "")
	end
end

-------------------------------------------------------------------------------
-- Enable/disable
-------------------------------------------------------------------------------

local active = false

local function Enable()
	active = true
	rampDirty = true

	local bumpmap = GetConVar("mat_bumpmap")
	if bumpmap and !bumpmap:GetBool() then
		MsgN("[toon_lighting] mat_bumpmap is 0, models can't use toon lighting. Set mat_bumpmap 1.")
	end

	-- give the engine a moment to apply the settings above (they can reload
	-- materials) before patching, then keep up with new entities
	timer.Create("ToonLighting_Scan", 1, 0, function()
		ScanEntities(false)
	end)
	timer.Simple(1, function()
		if !active then return end
		CollectStaticPropMaterials()
		ScanEntities(true)
		PatchStaticProps()
	end)
end

local function Disable()
	active = false
	timer.Remove("ToonLighting_Scan")
	RestoreAll()
	table.Empty(entityModels)
end

local function Update()
	local enable = toon_lighting:GetBool()
	ApplyFlatMats(enable and toon_lighting_flat_mats:GetBool())

	if enable and !active then Enable()
	elseif !enable and active then Disable() end
end

cvars.AddChangeCallback(toon_lighting:GetName(), Update, "ToonLighting")
cvars.AddChangeCallback(toon_lighting_flat_mats:GetName(), Update, "ToonLighting")
hook.Add("InitPostEntity", "ToonLighting", Update)

-- after settings changes the engine may reload materials, so re-check everything
cvars.AddChangeCallback("mat_specular", function()
	if active then timer.Simple(1, function() if active then ScanEntities(true) PatchStaticProps() end end) end
end, "ToonLighting")

hook.Add("PreRender", "ToonLighting", function()
	if !active or !rampDirty then return end
	rampDirty = false
	DrawRamp()
end)

-- render targets can lose their contents (alt-tab, resolution change), so redraw now and then
timer.Create("ToonLighting_Ramp", 5, 0, function() rampDirty = true end)
hook.Add("OnScreenSizeChanged", "ToonLighting", function() rampDirty = true end)

list.Set("PostProcess", "Toon Lighting", {
	["icon"] = "gui/postprocess/colourmod.png",
	["convar"] = "toon_lighting",
	["category"] = "#effects_pp",
	["cpanel"] = function(panel)
		panel:Help("Cartoon lighting on models, using the engine's light ramp ($lightwarptexture).")
		panel:CheckBox("Enable", "toon_lighting")
		panel:CheckBox("Flat materials (no specular or bloom)", "toon_lighting_flat_mats")
		panel:NumSlider("Bands", "toon_lighting_bands", 2, 8, 0)
		panel:NumSlider("Shadow threshold", "toon_lighting_threshold", 0.05, 0.95, 2)
		panel:NumSlider("Edge softness", "toon_lighting_softness", 0, 0.25, 3)
		panel:NumSlider("Shadow light", "toon_lighting_shadow", 0, 1, 2)
		panel:NumSlider("Lit brightness", "toon_lighting_brightness", 0.25, 2, 2)
	end
})
