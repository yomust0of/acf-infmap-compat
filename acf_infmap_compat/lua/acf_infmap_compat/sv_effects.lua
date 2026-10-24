-- ACF effects (server half): tracers, muzzle flashes, impacts and explosions get a position the client can place.
--
-- Problem: ACF creates every effect with Effects.CreateEffect, which ends in util.Effect(Name, EffectData). The position
-- inside an EffectData is stored in a small fixed range (about +-16384 units per axis). Under InfMap the server's
-- Entity:GetPos() is a GLOBAL position, so effects in any chunk but the one around the world origin carry a position that
-- does not fit, and the engine also decides who receives the effect from that same wrong position.
--
-- Fix: for server-side effects that have an Origin (or an Entity), the effect is sent in this addon's own net message. It
-- carries the global Origin as three doubles and goes to every player within `acf_infmap_effect_range` of it. The client half
-- (cl_effects.lua) subtracts the local player's chunk, and then builds the EffectData and calls util.Effect itself, so the
-- effect code (muzzle flash, impact, tracer...) is ACF's own and sees an ordinary local position.
--
-- Two entry points feed the same sender:
--   * Effects.CreateEffect, which every ACF effect goes through (ACF's own hook ACF_PreCreateEffect runs here, once);
--   * util.Effect itself, but only for effect names that start with "acf_". That catches code that skips the helper:
--     acf_missile/init.lua calls util.Effect("ACF_Explosion") directly, and a mod such as a laser that calls util.Effect
--     with an ACF effect would be covered too. Every other effect (blood, sparks from other addons...) is left alone.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  Effects.CreateEffect: runs hook ACF_PreCreateEffect, fills EffectData via Set<Field> for every key of the table,
--          calls util.Effect(Name, Data, AllowOverride, Filter)                         (core/utilities/effects/effects_sh.lua)
--   SEEN:  acf_missile/init.lua line ~772 calls util.Effect("ACF_Explosion", Effect) directly (the util.Effect entry above).
--   SEEN:  GMod wiki, CEffectData:SetOrigin / SetStart: "Limited to world bounds (+-16386 on every axis) and has horrible
--          networking precision (17 bit float per component)". CEffectData:SetEntIndex / GetEntIndex are SERVER-only, which
--          is why the client half sets the entity with SetEntity.
--   SEEN:  bullet tracers: the server sends Origin = global bullet position; the client starts its own simulation from it and
--          ends it after 45 s or beyond 16380 units from the origin                    (ballistics_sv.lua, effects/acf_bullet_effect.lua)
--   SEEN:  only `Origin` is a world position in the effect tables ACF builds. `Start` holds a position in just two places
--          (Sparks from acf_rack and acf_torch, and the nested "cball_explode" of acf_impact, which is made on the client).
--   KNOWN: an unreliable net message can be dropped. A lost effect is just a missing flash; a lost bullet "Init" means that
--          bullet has no tracer. That is why effects are unreliable like the stock ones.
--   GUESS: how the stock path misplaces effects in other chunks. It follows from the two SEEN wiki lines above; nobody has
--          looked at it in game. Turn the fix off with `acf_infmap_fix_effects 0` to compare.
--   GUESS: that net unreliable messages of about 100-250 bytes (a muzzle flash) are accepted by the engine.
--   GUESS: that reading an EffectData with its Get<Field> functions on the server gives back what the caller set (the
--          util.Effect entry). The Effects.CreateEffect entry does not depend on this: it has the original table.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats
local Tag    = Compat.EffectTag

local Fix   = CreateConVar("acf_infmap_fix_effects", "1", Compat.ServerFlags, "1 = send ACF effects with a position the client can place under InfMap. 0 = stock ACF behaviour.", 0, 1)
local Range = CreateConVar("acf_infmap_effect_range", "120000", Compat.ServerFlags, "Players within this many units (global space) of an effect receive it. 39.37 units = 1 metre; the default is about 3 km (six chunks).", 0)

-- Earlier versions of this addon shipped 30000 (version 2) and 45000 (version 3) as the default, and FCVAR_ARCHIVE saves
-- whatever value a convar had, so a saved copy of an old default would hide the new one. Those exact values are treated as
-- "never changed". Any other value was chosen by someone and is kept.
if Range:GetFloat() == 30000 or Range:GetFloat() == 45000 then Range:SetFloat(120000) end

util.AddNetworkString("ACFInfMapCompat_Effect")

local function TagOf(Value)
	if isnumber(Value) then return Tag.Number end
	if isvector(Value) then return Tag.Vector end
	if isangle(Value) then return Tag.Angle end
	if isentity(Value) then return Tag.Entity end
	if isbool(Value) then return Tag.Bool end
end

-- True while one of this file's wrappers is running its stock fallback, so the util.Effect wrapper leaves that call alone
local InStock = false

local function Stock(Fn, ...)
	InStock = true

	local OK, Err = pcall(Fn, ...)

	InStock = false

	if not OK then error(Err, 0) end
end

--- The tail of the stock Effects.CreateEffect, without the hook (which has already run).
local function Vanilla(Name, Table, AllowOverride, Filter)
	local Effect = EffectData()

	for Field, Value in pairs(Table) do
		local Set = Effect["Set" .. Field]

		if Set then Set(Effect, Value) end
	end

	util.Effect(Name, Effect, AllowOverride, Filter)
end

local function Write(Tag_, Value)
	if Tag_ == Tag.Number then
		net.WriteDouble(Value)
	elseif Tag_ == Tag.Vector then
		net.WriteDouble(Value.x) net.WriteDouble(Value.y) net.WriteDouble(Value.z)
	elseif Tag_ == Tag.Angle then
		net.WriteFloat(Value.p) net.WriteFloat(Value.y) net.WriteFloat(Value.r)
	elseif Tag_ == Tag.Entity then
		net.WriteEntity(Value)
	else
		net.WriteBool(Value)
	end
end

--- Sends one effect. `Table` holds the fields by name (Origin, Scale...). Returns false when the effect has nothing to place
--- (the caller then keeps the stock behaviour), true when it was handled, even if nobody was in range.
local function SendEffect(Name, Table, AllowOverride, Filter)
	local Center = Table.Origin

	if not isvector(Center) then
		local Ent = Table.Entity

		Center = isentity(Ent) and IsValid(Ent) and Ent:GetPos() or nil
	end

	if not Center then return false end

	local Audience = Compat.PlayersInRange(Center, Range:GetFloat())

	if not Audience[1] then return true end

	-- Collect what can be sent
	local Send = {}

	for Field, Value in pairs(Table) do
		local Id, Kind = Compat.EffectFieldId[Field], TagOf(Value)

		if Id and Kind then Send[#Send + 1] = {Id, Kind, Value} end
	end

	net.Start("ACFInfMapCompat_Effect", true)
		net.WriteString(Name)
		net.WriteBool(AllowOverride and true or false)
		net.WriteBool(Filter == true)
		net.WriteUInt(#Send, 5)

		for _, Item in ipairs(Send) do
			net.WriteUInt(Item[1], 5)
			net.WriteUInt(Item[2], 3)
			Write(Item[2], Item[3])
		end
	net.Send(Audience)

	Stats.EffectsSent = Stats.EffectsSent + 1

	return true
end

Compat.SendEffect = SendEffect

--- Reads an EffectData back into a table, keeping only what was set (zero numbers, zero vectors and invalid entities are
--- "not set"). Returns nil when something goes wrong, so the caller keeps the stock behaviour.
local function FromData(Data)
	local Table = {}

	for _, Field in ipairs(Compat.EffectFields) do
		local Get = Data["Get" .. Field]

		if Get then
			local OK, Value = pcall(Get, Data)

			if not OK then return nil end

			if isnumber(Value) then
				if Value ~= 0 then Table[Field] = Value end
			elseif isvector(Value) then
				if Value.x ~= 0 or Value.y ~= 0 or Value.z ~= 0 then Table[Field] = Value end
			elseif isangle(Value) then
				if Value.p ~= 0 or Value.y ~= 0 or Value.r ~= 0 then Table[Field] = Value end
			elseif isentity(Value) then
				if IsValid(Value) then Table[Field] = Value end
			end
		end
	end

	return Table
end

Compat.EffectFromData = FromData

Compat.Register("sv_effects", function()
	Compat.Wrap(ACF.Utilities.Effects, "CreateEffect", function(Original)
		return function(Name, Table, AllowOverride, Filter)
			if not Fix:GetBool() or not Name or not Table then return Stock(Original, Name, Table, AllowOverride, Filter) end

			-- A recipient filter object means the caller chose the audience; leave it alone
			if Filter ~= nil and not isbool(Filter) then return Stock(Original, Name, Table, AllowOverride, Filter) end

			local HasEntity = isentity(Table.Entity) and IsValid(Table.Entity)

			-- Nothing to place: stock behaviour
			if not isvector(Table.Origin) and not HasEntity then return Stock(Original, Name, Table, AllowOverride, Filter) end

			local NewName, NewTable = hook.Run("ACF_PreCreateEffect", Name, Table)

			Name  = NewName or Name
			Table = NewTable or Table

			if not SendEffect(Name, Table, AllowOverride, Filter) then return Stock(Vanilla, Name, Table, AllowOverride, Filter) end
		end
	end, "Effects.CreateEffect")

	-- Direct util.Effect calls with an ACF effect name (see the header)
	Compat.Wrap(util, "Effect", function(Original)
		return function(Name, Data, AllowOverride, Filter)
			if InStock or not isstring(Name) or Data == nil or not Fix:GetBool() then return Original(Name, Data, AllowOverride, Filter) end
			if string.lower(string.sub(Name, 1, 4)) ~= "acf_" then return Original(Name, Data, AllowOverride, Filter) end
			if Filter ~= nil and not isbool(Filter) then return Original(Name, Data, AllowOverride, Filter) end

			local Table = FromData(Data)

			if not Table or not SendEffect(Name, Table, AllowOverride, Filter) then return Original(Name, Data, AllowOverride, Filter) end
		end
	end, "util.Effect (acf_* only)")
end)

Compat.StatusLines.sv_effects = function()
	return {
		string.format("effects: fix %s, range %g units (%.0f m)", Fix:GetBool() and "ON" or "OFF", Range:GetFloat(), Range:GetFloat() / Compat.MeterToUnit),
	}
end
