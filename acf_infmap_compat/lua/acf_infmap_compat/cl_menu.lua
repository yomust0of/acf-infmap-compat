-- Settings menu (client): Spawn menu -> Utilities tab -> "ACF InfMap" -> "Settings".
--
-- Two halves:
--   * YOUR settings (far effects and bullets: on/off, distance, size). Client console variables, saved on your machine.
--   * SERVER settings (sound and effect ranges, the fixes' on/off switches). Only a superadmin can change
--     them: each change is sent to the server (sv_settings.lua), which checks the sender and the value. Everyone else sees them
--     as read-only text. Ranges are shown in metres; the console variables themselves hold units (1 m = 39.37 units).
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   KNOWN: spawnmenu.AddToolMenuOption inside the PopulateToolMenu hook; DForm:Help / CheckBox / NumSlider / Button; DNumSlider's
--          OnValueChanged; DCheckBoxLabel's OnChange.
--   GUESS: the layout. The panel code is not run by the test harness (it has no UI), only the parts that decide values are.
--          If the panel misbehaves, every setting here is also a plain console variable (acf_infmap_status lists them).

local Compat = ACFInfMapCompat

--- Sends one server setting. `Units` is the raw convar value.
local function Send(Name, Units)
	net.Start("ACFInfMapCompat_Setting")
		net.WriteString(Name)
		net.WriteFloat(Units)
	net.SendToServer()
end

Compat.SendSetting = Send

local function ServerRow(Panel, Def, Admin)
	local Var = GetConVar(Def.Name)

	if not Var then
		Panel:Help(Def.Label .. ": not available (the server's settings are not replicated to you yet)")

		return
	end

	local Factor = Def.Factor or 1

	if not Admin then
		if Def.Kind == "bool" then
			Panel:Help(string.format("%s: %s", Def.Label, Var:GetBool() and "on" or "off"))
		else
			Panel:Help(string.format("%s: %g", Def.Label, Var:GetFloat() / Factor))
		end

		return
	end

	if Def.Kind == "bool" then
		local Box = Panel:CheckBox(Def.Label)

		Box:SetValue(Var:GetBool())

		Box.OnChange = function(_, Value)
			if (Value and true or false) ~= Var:GetBool() then Send(Def.Name, Value and 1 or 0) end
		end
	else
		local Slider = Panel:NumSlider(Def.Label, nil, Def.Min / Factor, Def.Max / Factor, 0)

		Slider:SetValue(Var:GetFloat() / Factor)

		Slider.OnValueChanged = function(_, Value)
			local Units = Value * Factor

			if math.abs(Units - Var:GetFloat()) < 0.5 then return end

			-- One message after the slider has been still for a moment, not one per pixel
			timer.Create("ACFInfMapCompat_Set_" .. Def.Name, 0.4, 1, function() Send(Def.Name, Units) end)
		end
	end
end

local function Build(Panel)
	Panel:ClearControls()

	Panel:Help("Fixes for ACF on InfMap. Run acf_infmap_status in the console to see what is active.")

	Panel:Help("YOUR SETTINGS (saved on this computer)")
	Panel:CheckBox("Show effects the engine cannot place (replayed from ACF's own effect code)", "acf_infmap_cl_replay")
	Panel:NumSlider("Far effect distance (metres)", "acf_infmap_cl_replay_distance", 0, 10000, 0)
	Panel:NumSlider("Far effect size", "acf_infmap_cl_replay_scale", 0.1, 5, 2)
	Panel:CheckBox("Keep bullets alive past the engine's limit (needed for impacts far away, and far tracers)", "acf_infmap_cl_bullets")
	Panel:Button("Test: explosion 1500 m ahead of you", "acf_infmap_fartest", "1500")
	Panel:CheckBox("Keep visual clips and Prop2Mesh meshes right in other chunks", "acf_infmap_cl_render_fix")
	Panel:CheckBox("Ask the server for visual clips a prop is missing when it comes into range", "acf_infmap_cl_visclip_resync")
	Panel:NumSlider("Visual clip check range (chunks)", "acf_infmap_cl_visclip_range", 1, 100, 0)
	Panel:CheckBox("In other chunks, run scripted entities' own Draw (laser beams, glows, overlays)", "acf_infmap_cl_render_draw")
	Panel:CheckBox("Correct render boxes that scripted entities in other chunks set in world coordinates (lazers that fire)", "acf_infmap_cl_render_bounds")
	Panel:CheckBox("Keep the engine position of ACF entities in other chunks right (lazers drawn too far away)", "acf_infmap_cl_origin_fix")
	Panel:Button("Print what the render fix sees (meshes, clips)", "acf_infmap_renderdebug")
	Panel:Button("Print what happens to lazers (any class: type acf_infmap_entdebug <part of the name>)", "acf_infmap_entdebug", "lazer")

	local Admin = IsValid(LocalPlayer()) and LocalPlayer():IsSuperAdmin()

	Panel:Help(Admin and "SERVER SETTINGS (you are a superadmin: changes apply to everyone)" or "SERVER SETTINGS (read-only: only a superadmin can change them)")

	for _, Def in ipairs(Compat.ServerSettings) do ServerRow(Panel, Def, Admin) end

	Panel:Help("How long a bullet may fly before the server removes it (by caliber) is set in lua/acf_infmap_compat/config.lua on the server.")
	Panel:Help("The effect range decides who is sent an effect at all. Far effects can only show what the server sent, so keep it at least as large as your far distance (1 km = 1000 m). Three chunks is about 1520 m.")
end

hook.Add("PopulateToolMenu", "ACFInfMapCompat_Menu", function()
	spawnmenu.AddToolMenuOption("Utilities", "ACF InfMap", "ACFInfMapCompat_Settings", "Settings", "", "", Build)
end)
