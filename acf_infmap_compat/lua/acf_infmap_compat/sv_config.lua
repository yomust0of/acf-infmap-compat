-- Config file reader (server): reads lua/acf_infmap_compat/config.lua and checks every value.
--
-- The file is plain Lua that sets ACFInfMapCompat.Config = {SectionName = {Key = value, ...}, ...}. Each module declares its own
-- section here with its built-in numbers (Compat.DefineConfig), and gets the checked numbers back in Compat.Live[SectionName].
-- A mistake in the file never stops the addon: the value falls back to the built-in one and the problem is printed.
--
-- Rules (the type of the built-in value decides): a true/false value must be true or false; a number must be a number above 0
-- and not NaN or infinity. A key the section does not know is reported (it is usually a typo) and ignored.
--
-- Cost: the file is read at start-up and by `acf_infmap_config_reload`. Nothing here runs per shot or per frame.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   KNOWN: `include` called from a function in this file finds lua/acf_infmap_compat/config.lua by the path written below, like
--          the autorun's includes.
--   GUESS: that `include` run from the console command reads the edited file again (not a cached copy). If it does not, the
--          server needs a restart after an edit, and the command prints the old numbers.

local Compat = ACFInfMapCompat

Compat.ConfigSections = Compat.ConfigSections or {} -- [Name] = {Defaults, Final, Report}
Compat.Live           = Compat.Live or {}           -- [Name] = the numbers in use (read at the moment of use, never kept)

--- Declares a section of config.lua.
--- @param Name string The key in ACFInfMapCompat.Config
--- @param Defaults table The built-in values (a value's type decides how the file's value is checked)
--- @param Final function? Called with (Out, Problems) after the keys are checked, for rules that involve several keys
--- @param Report function? Called with (Out), returns the lines `acf_infmap_config_reload` prints for the section
function Compat.DefineConfig(Name, Defaults, Final, Report)
	Compat.ConfigSections[Name] = {Defaults = Defaults, Final = Final, Report = Report}
	Compat.Live[Name]           = table.Copy(Defaults)
end

local function SectionNames()
	local Names = {}

	for Name in pairs(Compat.ConfigSections) do Names[#Names + 1] = Name end

	table.sort(Names)

	return Names
end

--- Reads config.lua again and checks it.
--- @return table # [SectionName] = the numbers now in use
--- @return string[] # what was wrong, empty when everything was fine
function Compat.LoadConfig()
	local Problems = {}

	Compat.Config = nil

	-- the call sits in a function of this file so that `include` finds the file the same way as for the other files
	local OK, Err = pcall(function() include("acf_infmap_compat/config.lua") end)

	if not OK then Problems[#Problems + 1] = "the file could not be read (" .. tostring(Err) .. "). Every built-in value is used" end

	local File = Compat.Config

	if OK and not istable(File) then
		Problems[#Problems + 1] = "the file did not set ACFInfMapCompat.Config to a table. Every built-in value is used"
	end

	File = istable(File) and File or {}

	for Name in pairs(File) do
		if not Compat.ConfigSections[Name] then Problems[#Problems + 1] = tostring(Name) .. " is not a section of this file (ignored)" end
	end

	local Live = {}

	for _, Name in ipairs(SectionNames()) do
		local Section = Compat.ConfigSections[Name]
		local Mine    = File[Name]

		if Mine ~= nil and not istable(Mine) then
			Problems[#Problems + 1] = Name .. " must be a table. Its built-in values are used"
			Mine = nil
		end

		Mine = Mine or {}

		local Out = {}

		for Key, Default in pairs(Section.Defaults) do
			local Value = Mine[Key]
			local Full  = Name .. "." .. Key

			if isbool(Default) then
				if isbool(Value) then
					Out[Key] = Value
				else
					if Value ~= nil then Problems[#Problems + 1] = Full .. " must be true or false. The built-in value (" .. tostring(Default) .. ") is used for it" end

					Out[Key] = Default
				end
			elseif isnumber(Value) and Value == Value and Value > 0 and Value < math.huge then
				Out[Key] = Value
			else
				if Value ~= nil then Problems[#Problems + 1] = Full .. " must be a number above 0. The built-in value (" .. tostring(Default) .. ") is used for it" end

				Out[Key] = Default
			end
		end

		for Key in pairs(Mine) do
			if Section.Defaults[Key] == nil then Problems[#Problems + 1] = Name .. "." .. tostring(Key) .. " is not a setting (ignored)" end
		end

		if Section.Final then Section.Final(Out, Problems) end

		Live[Name] = Out
	end

	Compat.Live = Live

	for _, Problem in ipairs(Problems) do Compat.Warn("config.lua: ", Problem, ".") end

	return Live, Problems
end

-- `acf_infmap_config_reload`: reads config.lua again and prints what each section now says. Server console, or a superadmin.
concommand.Add("acf_infmap_config_reload", function(Ply)
	if IsValid(Ply) and not Ply:IsSuperAdmin() then return end

	local Live, Problems = Compat.LoadConfig()

	Compat.Tell(Ply, string.format("[ACF-InfMap] config.lua read%s.", #Problems > 0 and (" with " .. #Problems .. " problem(s), see the server console") or ", no problems"))

	for _, Name in ipairs(SectionNames()) do
		local Report = Compat.ConfigSections[Name].Report

		if Report then
			for _, Line in ipairs(Report(Live[Name])) do Compat.Tell(Ply, Line) end
		end
	end
end)
