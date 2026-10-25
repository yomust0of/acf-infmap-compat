-- ACF3 <-> InfMap compatibility addon: entry point.
--
-- Standalone: nothing here edits ACF or InfMap. It wraps ACF's own functions at runtime and keeps the originals, so
-- deleting the addon folder restores stock behaviour. Does nothing on maps that are not InfMap maps.
--
-- Evidence labels used in every file of this addon:
--   SEEN  = read in the source of ACF or InfMap (file named), or exercised against ACF's real files in a mock.
--   KNOWN = standard GMod/Source behaviour that I did not re-check here.
--   GUESS = inference. Only a live game can confirm it. `acf_infmap_status` helps.
--
--   SEEN:  autorun files in one folder run alphabetically, and "zz_" sorts after "!!inf_init" (InfMap) and
--          "acf_loader" (ACF). KNOWN: GMod really runs them in that order.
--   SEEN:  ACF's loader fires the hook "ACF_OnLoadAddon" after every load and every acf_reload  (includes/gloader.lua)
--   SEEN:  acf_reload runs ACF's files again, which REPLACES the functions this addon wraps. The hook above is how the
--          wrappers are put back.
--   SEEN:  InfMap's autorun returns before defining the InfMap table unless the 2nd word of the map name is "infmap"
--          (autorun/!!inf_init.lua), so `InfMap == nil` means "not an InfMap map".
--   GUESS: that the server sends this autorun file to clients on its own. AddCSLuaFile() below is the explicit version.

ACFInfMapCompat = ACFInfMapCompat or {}

local Compat = ACFInfMapCompat

if SERVER then
	AddCSLuaFile()
	AddCSLuaFile("acf_infmap_compat/sh_core.lua")
	AddCSLuaFile("acf_infmap_compat/cl_sounds.lua")
	AddCSLuaFile("acf_infmap_compat/cl_effects.lua")
	AddCSLuaFile("acf_infmap_compat/cl_replay.lua")
	AddCSLuaFile("acf_infmap_compat/cl_bullets.lua")
	AddCSLuaFile("acf_infmap_compat/cl_render.lua")
	AddCSLuaFile("acf_infmap_compat/cl_origin.lua")
	AddCSLuaFile("acf_infmap_compat/cl_menu.lua")
end

if not InfMap then
	-- Same rule InfMap itself uses. If the map IS an InfMap map and the table is missing, InfMap is not loaded.
	if string.Explode("_", string.lower(game.GetMap()))[2] == "infmap" then
		MsgC(Color(255, 200, 80), "[ACF-InfMap] ", color_white, "This is an InfMap map but InfMap is not loaded. The ACF/InfMap compatibility addon is idle.\n")
	end

	return
end

include("acf_infmap_compat/sh_core.lua")

if SERVER then
	include("acf_infmap_compat/sv_config.lua")
	include("acf_infmap_compat/sv_sounds.lua")
	include("acf_infmap_compat/sv_traces.lua")
	include("acf_infmap_compat/sv_wire.lua")
	include("acf_infmap_compat/sv_e2ranger.lua")
	include("acf_infmap_compat/sv_bullets.lua")
	include("acf_infmap_compat/sv_effects.lua")
	include("acf_infmap_compat/sv_settings.lua")
	include("acf_infmap_compat/sv_visclip.lua")

	-- every module has declared its section of config.lua by now
	Compat.LoadConfig()
else
	include("acf_infmap_compat/cl_sounds.lua")
	include("acf_infmap_compat/cl_effects.lua")
	include("acf_infmap_compat/cl_replay.lua")
	include("acf_infmap_compat/cl_bullets.lua")
	--include("acf_infmap_compat/cl_render.lua")
	include("acf_infmap_compat/cl_origin.lua")
	include("acf_infmap_compat/cl_menu.lua")
end

-- Wrap now (ACF has already loaded: "acf_loader" sorts before "zz_"), again after every acf_reload, and once more at
-- Initialize in case ACF finished loading late.
Compat.Install()

hook.Add("ACF_OnLoadAddon", "ACFInfMapCompat", Compat.Install)
hook.Add("Initialize", "ACFInfMapCompat", Compat.Install)
hook.Add("InitPostEntity", "ACFInfMapCompat", Compat.Install) -- scripted entities (Wire's) are registered by then
