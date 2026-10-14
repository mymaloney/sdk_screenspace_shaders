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
-- The phong path ignores lighting baked into a model's vertices. Physics props switch
-- to that when they come to rest, so r_PhysPropStaticLighting is set to 0 while
-- enabled. Static props always use it, so patched static props render black.
-- Materials used by static props are therefore never patched. Instead, spawned models using them get their own
-- copy of the material (through a client-side sub-material override), and the copy is
-- patched. Static prop models are read from the map's .bsp file; if that fails,
-- nothing is patched at all, to be safe.
--
-- toon_lighting_inspect prints what happened to the materials of the model you're
-- looking at.
--
-- Usage: toon_lighting 1

local toon_lighting            = CreateClientConVar("toon_lighting", "0", true, false, "Cartoon (toon) lighting on models.", 0, 1)
local toon_lighting_bands      = CreateClientConVar("toon_lighting_bands", "2", true, false, "Number of light bands (2 = shadow and lit).", 2, 8)
local toon_lighting_threshold  = CreateClientConVar("toon_lighting_threshold", "0.5", true, false, "Where the shadow side ends (0.5 = where the surface turns away from the light).", 0.05, 0.95)
local toon_lighting_softness   = CreateClientConVar("toon_lighting_softness", "0.02", true, false, "Softness of the band edges.", 0, 0.25)
local toon_lighting_shadow     = CreateClientConVar("toon_lighting_shadow", "0.15", true, false, "Direct light kept on the shadow side.", 0, 1)
local toon_lighting_brightness = CreateClientConVar("toon_lighting_brightness", "1", true, false, "Brightness of the lit side.", 0.25, 2)
local toon_lighting_copies     = CreateClientConVar("toon_lighting_copies", "1", true, false, "Give spawned models that share materials with static props their own toon-lit copy.", 0, 1)
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

local function IsOurTexture(tex, rt)
	return tex and tex:GetName() == rt:GetName()
end

local function SaveParams(mat)
	local lightwarp = mat:GetTexture("$lightwarptexture")
	local bump = mat:GetTexture("$bumpmap")

	-- materials stay modified in memory until the game restarts, so a material can
	-- still carry our changes from before this script was (re)loaded. In that case
	-- its originals are what we would have saved back then
	if IsOurTexture(bump, flatNormalRT) then
		return {}
	end

	return {
		lightwarp  = (IsTexture(lightwarp) and !IsOurTexture(lightwarp, rampRT)) and lightwarp or nil,
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

local function RestoreMaterial(mat, saved)
	RestoreTexture(mat, "$lightwarptexture", saved.lightwarp)
	RestoreTexture(mat, "$bumpmap", saved.bump)
	RestoreInt(mat, "$phong", saved.phong)
	RestoreFloat(mat, "$phongboost", saved.phongboost)
	RestoreInt(mat, "$halflambert", saved.halflambert)
	mat:Recompute()
end

local function IsPatchedNow(mat)
	local tex = mat:GetTexture("$lightwarptexture")
	return tex and tex:GetName() == rampRT:GetName()
end

-- materials used by static props (nil = unknown)
local staticPropMaterials
local staticPropsCollected = false

local SPRP_LUMP_ID = 1936749168 -- "sprp", the static prop game lump
local GAME_LUMP_INDEX = 35

-- reads the static prop model list straight from the map's .bsp
local function ReadStaticPropModels()
	local f = file.Open("maps/" .. game.GetMap() .. ".bsp", "rb", "GAME")
	if !f then return nil end

	local models
	local ok, err = pcall(function()
		if f:Read(4) != "VBSP" then return end

		-- header: ident, version, then 64 lumps of { offset, length, version, fourCC }
		f:Seek(8 + GAME_LUMP_INDEX * 16)
		local gameLumpOffset = f:ReadLong()

		f:Seek(gameLumpOffset)
		local lumpCount = f:ReadLong()
		for _ = 1, lumpCount do
			local id = f:ReadLong()
			local flags = f:ReadUShort()
			f:ReadUShort() -- version
			local offset = f:ReadLong()
			f:ReadLong() -- length

			if id == SPRP_LUMP_ID then
				if bit.band(flags, 1) != 0 then return end -- compressed, not supported

				-- model dictionary: count, then 128 byte null-padded paths
				f:Seek(offset)
				local count = f:ReadLong()
				if count < 0 or count > 16384 then return end

				models = {}
				for i = 1, count do
					local path = string.match(f:Read(128) or "", "^[^%z]*")
					if path and path != "" then models[#models + 1] = path end
				end
				return
			end
		end

		models = {} -- no static prop lump: the map has no static props
	end)
	f:Close()

	if !ok then
		MsgN("[toon_lighting] couldn't read static props from the map: ", err)
		return nil
	end
	return models
end

-- static props aren't entities on the client, so read their models from the map
-- and get the materials from a temporary clientside model
local function CollectStaticPropMaterials()
	if staticPropsCollected then return end
	staticPropsCollected = true

	local models = ReadStaticPropModels()
	if !models then
		MsgN("[toon_lighting] static props unknown, toon lighting is disabled on this map to be safe")
		return
	end

	staticPropMaterials = {}
	local count = 0
	for _, model in ipairs(models) do
		local csModel = ClientsideModel(model, RENDERGROUP_OTHER)
		if IsValid(csModel) then
			for _, name in ipairs(csModel:GetMaterials() or {}) do
				if !staticPropMaterials[name] then count = count + 1 end
				staticPropMaterials[name] = true
			end
			csModel:Remove()
		end
	end
	MsgN("[toon_lighting] found ", #models, " static prop models using ", count, " materials")
end

-- patching is only safe if no static prop uses the material (see top)
local function CanPatch(name)
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
	if !CanPatch(name) then
		skipped[name] = true
		-- undo our changes if it still has them from before (see SaveParams)
		if IsOurTexture(mat:GetTexture("$lightwarptexture"), rampRT) then
			RestoreMaterial(mat, saved)
		end
		return
	end

	patched[name] = { mat = mat, saved = saved }
	ApplyParams(mat, saved)
end

local function RestoreAll()
	for _, entry in pairs(patched) do
		RestoreMaterial(entry.mat, entry.saved)
	end
	patched = {}
end

local function PatchStaticProps()
	for name in pairs(staticPropMaterials or {}) do
		PatchMaterial(name)
	end
end

-------------------------------------------------------------------------------
-- Copies of static prop materials, for spawned models
-------------------------------------------------------------------------------

-- [original name] = { name = copy name, mat = IMaterial } or false if it can't be copied
local copies = {}
-- [entity] = { [sub-material index] = override string }, overrides we set
local overrides = setmetatable({}, { __mode = "k" })

-- material parameter keys that hold runtime state rather than material settings
local COPY_SKIP_KEYS = {
	["$flags2"] = true,
	["$flags_defined2"] = true,
}

-- converts a value from IMaterial:GetKeyValues() to a CreateMaterial keyvalue string
local function KeyValueString(value)
	local t = type(value)
	if t == "ITexture" then return !value:IsError() and value:GetName() or nil end
	if t == "number" then return tostring(value) end
	if t == "string" then return value != "" and value or nil end
	if t == "Vector" then return string.format("[%f %f %f]", value.x, value.y, value.z) end
	return nil -- matrices etc. keep their defaults
end

local function GetCopy(name)
	if copies[name] != nil then return copies[name] end
	copies[name] = false

	local mat = Material(name)
	if !mat or mat:IsError() then return false end

	local keyValues = {}
	for key, value in pairs(mat:GetKeyValues()) do
		if !COPY_SKIP_KEYS[string.lower(key)] then
			keyValues[key] = KeyValueString(value)
		end
	end

	local copyName = "toon_lighting_" .. string.gsub(name, "[/\\]", "_")
	local copy = CreateMaterial(copyName, "VertexLitGeneric", keyValues)
	if !copy or copy:IsError() then return false end

	local saved = SaveParams(copy)
	patched[copyName] = { mat = copy, saved = saved }
	ApplyParams(copy, saved)

	copies[name] = { name = copyName, mat = copy }
	return copies[name]
end

-- removes the overrides we set on an entity (leaving ones set by the server or tools)
local function RemoveOverrides(ent)
	local entOverrides = overrides[ent]
	if !entOverrides then return end
	if IsValid(ent) then
		for index, value in pairs(entOverrides) do
			if ent:GetSubMaterial(index) == value then ent:SetSubMaterial(index, "") end
		end
	end
	overrides[ent] = nil
end

local function ApplyCopies(ent)
	RemoveOverrides(ent)
	if !toon_lighting_copies:GetBool() or !staticPropMaterials then return end
	-- a whole-model material override replaces all sub-materials anyway
	if (ent:GetMaterial() or "") != "" then return end

	for i, name in ipairs(ent:GetMaterials() or {}) do
		local index = i - 1
		-- only where nothing else (server, tools) has overridden the material
		if staticPropMaterials[name] and (ent:GetSubMaterial(index) or "") == "" then
			local copy = GetCopy(name)
			if copy then
				local value = "!" .. copy.name -- "!" refers to a Lua-created material
				ent:SetSubMaterial(index, value)
				overrides[ent] = overrides[ent] or {}
				overrides[ent][index] = value
			end
		end
	end
end

-- client-side overrides can be reset, e.g. when the server updates the entity
local function LostOverrides(ent)
	local entOverrides = overrides[ent]
	if !entOverrides then return false end
	for index, value in pairs(entOverrides) do
		if ent:GetSubMaterial(index) != value then return true end
	end
	return false
end

local function RemoveAllOverrides()
	for ent in pairs(overrides) do
		RemoveOverrides(ent)
	end
end

local function PatchEntity(ent)
	for _, name in ipairs(ent:GetMaterials() or {}) do
		PatchMaterial(name)
	end
	ApplyCopies(ent)
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
		if model and (force or entityModels[ent] != model or LostOverrides(ent)) then
			entityModels[ent] = model
			PatchEntity(ent)
		end
	end
end

-------------------------------------------------------------------------------
-- Engine settings
-------------------------------------------------------------------------------

-- Settings needed for toon lighting to work:
-- resting physics props switch to baked per-vertex lighting (like static props),
-- which the lightwarp path ignores, so they would turn black when they stop moving
local REQUIRED_SETTINGS = {
	{ "r_PhysPropStaticLighting", "0" },
}

-- Optional: specular reflections and bloom add shine that fights the flat look.
-- (mat_bumpmap 0 is not used: it turns off the lighting path lightwarp needs)
local FLAT_SETTINGS = {
	{ "mat_specular", "0" },
	{ "mat_disable_bloom", "1" },
}

-- the original values are kept in an archived convar as "name=value;name=value",
-- so they can be restored even after a crash or restart
local function LoadSavedSettings()
	local saved = {}
	local str = toon_lighting_saved_mats:GetString()

	if str != "" and !string.find(str, "=", 1, true) then
		-- older format: "mat_specular mat_disable_bloom" values separated by spaces
		local old = string.Explode(" ", str)
		saved["mat_specular"] = old[1] != "" and old[1] or nil
		saved["mat_disable_bloom"] = old[2] != "" and old[2] or nil
		return saved
	end

	for _, pair in ipairs(string.Explode(";", str)) do
		local name, value = string.match(pair, "^([^=]+)=(.*)$")
		if name then saved[name] = value end
	end
	return saved
end

local function StoreSavedSettings(saved)
	local parts = {}
	for name, value in SortedPairs(saved) do
		parts[#parts + 1] = name .. "=" .. value
	end
	RunConsoleCommand(toon_lighting_saved_mats:GetName(), table.concat(parts, ";"))
end

local function ApplySettingList(list, enable, saved)
	for _, setting in ipairs(list) do
		local name, value = setting[1], setting[2]
		local cvar = GetConVar(name)

		if enable then
			-- only remember the original the first time (it may be carried over from last session)
			if saved[name] == nil and cvar then saved[name] = cvar:GetString() end
			RunConsoleCommand(name, value)
		elseif saved[name] != nil then
			RunConsoleCommand(name, saved[name])
			saved[name] = nil
		end
	end
end

local function ApplyEngineSettings(enable, flat)
	local saved = LoadSavedSettings()
	ApplySettingList(REQUIRED_SETTINGS, enable, saved)
	ApplySettingList(FLAT_SETTINGS, enable and flat, saved)
	StoreSavedSettings(saved)
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
	RemoveAllOverrides()
	RestoreAll()
	copies = {}
	table.Empty(entityModels)
end

local function Update()
	local enable = toon_lighting:GetBool()
	ApplyEngineSettings(enable, toon_lighting_flat_mats:GetBool())

	if enable and !active then Enable()
	elseif !enable and active then Disable() end
end

cvars.AddChangeCallback(toon_lighting:GetName(), Update, "ToonLighting")
cvars.AddChangeCallback(toon_lighting_flat_mats:GetName(), Update, "ToonLighting")
cvars.AddChangeCallback(toon_lighting_copies:GetName(), function()
	if active then ScanEntities(true) end
end, "ToonLighting")
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

local function DescribeTexture(tex)
	if !tex then return "none" end
	return tex:GetName() .. (tex:IsError() and " (error)" or "")
end

concommand.Add("toon_lighting_inspect", function()
	local ply = LocalPlayer()
	local tr = ply:GetEyeTrace()
	local ent = tr.Entity

	if !IsValid(ent) or ent:IsWorld() then
		MsgN("[toon_lighting] looking at the world (", tr.HitTexture or "?", "). Static props can't be inspected, spawn a copy instead.")
		return
	end

	MsgN("[toon_lighting] ", ent:GetClass(), " ", ent:GetModel() or "")
	for i, name in ipairs(ent:GetMaterials() or {}) do
		local mat = Material(name)
		local state = patched[name] and "patched" or (skipped[name] and "skipped" or "not seen")
		if staticPropMaterials and staticPropMaterials[name] then state = state .. ", used by static props" end

		MsgN("  ", name, " [", state, "]")
		MsgN("    shader: ", mat:GetShader() or "?",
			"  bumpmap: ", DescribeTexture(mat:GetTexture("$bumpmap")),
			"  phong: ", tostring(mat:GetInt("$phong")),
			"  lightwarp: ", DescribeTexture(mat:GetTexture("$lightwarptexture")))
		local saved = patched[name] and patched[name].saved
		if saved then
			MsgN("    original bumpmap: ", DescribeTexture(saved.bump), "  original phong: ", tostring(saved.phong))
		end

		local override = ent:GetSubMaterial(i - 1) or ""
		if override != "" then
			local ours = overrides[ent] and overrides[ent][i - 1] == override
			MsgN("    sub-material override: ", override, ours and " (toon copy)" or " (set by server/tool)")
		end
	end
end)

list.Set("PostProcess", "Toon Lighting", {
	["icon"] = "gui/postprocess/colourmod.png",
	["convar"] = "toon_lighting",
	["category"] = "#effects_pp",
	["cpanel"] = function(panel)
		panel:Help("Cartoon lighting on models, using the engine's light ramp ($lightwarptexture).")
		panel:CheckBox("Enable", "toon_lighting")
		panel:CheckBox("Flat materials (no specular or bloom)", "toon_lighting_flat_mats")
		panel:CheckBox("Toon copies for models sharing static prop materials", "toon_lighting_copies")
		panel:NumSlider("Bands", "toon_lighting_bands", 2, 8, 0)
		panel:NumSlider("Shadow threshold", "toon_lighting_threshold", 0.05, 0.95, 2)
		panel:NumSlider("Edge softness", "toon_lighting_softness", 0, 0.25, 3)
		panel:NumSlider("Shadow light", "toon_lighting_shadow", 0, 1, 2)
		panel:NumSlider("Lit brightness", "toon_lighting_brightness", 0.25, 2, 2)
	end
})
