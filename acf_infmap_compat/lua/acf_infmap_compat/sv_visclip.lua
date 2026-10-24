-- Visual Clip resync (server): answers a client's "I have these props but no clips for them" with Visual Clip's own messages.
--
-- Problem (root cause 6 in cl_render.lua): Visual Clip announces a clip with net.Broadcast and names the prop with
-- net.WriteEntity. A client that does not know the prop yet reads NULL and throws the clip away, and the server only re-sends
-- everything once, at join. Props that reach a client later (a dupe pasted outside its PVS, or a different chunk) never get their
-- clips on that client.
--
-- Fix: the client (cl_render.lua) asks once per prop, when the prop first comes within `acf_infmap_cl_visclip_range` chunks of the
-- player and the client holds no clips for it. This file validates the request, and sends Visual Clip's own "clipping_all_prop_clips"
-- message (the same one it uses at join) for each prop that really has clips, only to the asking player, a few per tick.
--
-- Evidence labels: SEEN = read in source / run in the mock, KNOWN = standard GMod behaviour not re-checked, GUESS = needs a game.
--   SEEN:  Clipping.EntityClips[ent] holds a prop's clips, Clipping.SendAllPropClips(ent, ply) sends them to one player,
--          Clipping.RenderingInside[ent] holds the "render inside" flag (Clip_Tool autorun/server/sv_clipping.lua). All are looked up
--          on the global `Clipping` when a request arrives, so a reload of Visual Clip is picked up.
--   SEEN:  the client's handler for "clipping_all_prop_clips" APPENDS to the clips it already has (AddPropClip). The client therefore
--          only asks for props that hold no clips (ent.MaxClips == nil). If a Broadcast clip arrives between request and answer, the
--          prop gets the same plane twice: drawn identically, only the per-prop plane cap is used up faster. GUESS: rare, harmless.
--   SEEN:  requests are bounded: at most 255 entity numbers per message, at most 10 messages per second per player, at most
--          4096 waiting answers per player, and 8 answers per server tick in total.
--   KNOWN: net.Receive callbacks get (length, player) on the server; Entity(index) returns NULL for a free index.
--   GUESS: that Visual Clip is the Clip_Tool this was read from. If the global `Clipping` is missing the requests are ignored and the
--          status says so.

local Compat = ACFInfMapCompat
local Stats  = Compat.Stats

local On = CreateConVar("acf_infmap_fix_visclip", "1", Compat.ServerFlags, "1 = resend visual clips to players whose client missed them. 0 = stock Visual Clip behaviour.", 0, 1)

for _, Name in ipairs({"ClipRequestsSeen", "ClipRequestsRefused", "ClipsResent"}) do
	Stats[Name] = Stats[Name] or 0
end

util.AddNetworkString("ACFInfMapCompat_ClipRequest")

local MaxMessagesPerSecond = 10
local MaxQueue             = 4096
local PerTick              = 8

local Queues = {} -- [UserID] = {Player, List = {ents}, Set = {[ent] = true}}

local function Found()
	return istable(Clipping) and istable(Clipping.EntityClips) and isfunction(Clipping.SendAllPropClips)
end

local function QueueOf(Ply)
	local Id    = Ply:UserID()
	local Queue = Queues[Id]

	if not Queue then
		Queue = {Player = Ply, List = {}, Set = {}}
		Queues[Id] = Queue
	end

	return Queue
end

--- Handles one request. `Indices` is the list of entity numbers the client named. Returns how many were queued. Exposed for tests.
function Compat.QueueClipRequest(Ply, Indices)
	if not On:GetBool() or not Found() or not IsValid(Ply) then return 0 end

	local Queue, Added = QueueOf(Ply), 0

	for _, Index in ipairs(Indices) do
		local Ent = Entity(Index)

		if IsValid(Ent) and Clipping.EntityClips[Ent] and not Queue.Set[Ent] and #Queue.List < MaxQueue then
			Queue.List[#Queue.List + 1] = Ent
			Queue.Set[Ent] = true
			Added = Added + 1
		end
	end

	return Added
end

net.Receive("ACFInfMapCompat_ClipRequest", function(_, Ply)
	if not IsValid(Ply) then return end

	local Now = SysTime()

	if not Ply.ACFInfMapClipWindow or Now - Ply.ACFInfMapClipWindow > 1 then
		Ply.ACFInfMapClipWindow = Now
		Ply.ACFInfMapClipMessages = 0
	end

	Ply.ACFInfMapClipMessages = Ply.ACFInfMapClipMessages + 1

	if Ply.ACFInfMapClipMessages > MaxMessagesPerSecond then
		Stats.ClipRequestsRefused = Stats.ClipRequestsRefused + 1

		return
	end

	local Count   = net.ReadUInt(8)
	local Indices = {}

	for I = 1, Count do Indices[I] = net.ReadUInt(14) end

	Stats.ClipRequestsSeen = Stats.ClipRequestsSeen + Count

	Compat.QueueClipRequest(Ply, Indices)
end)

local function SendOne(Ply, Ent)
	if not Found() or not IsValid(Ply) or not IsValid(Ent) then return end

	local Clips = Clipping.EntityClips[Ent]

	if not istable(Clips) or #Clips == 0 then return end

	Clipping.SendAllPropClips(Ent, Ply)

	if istable(Clipping.RenderingInside) and Clipping.RenderingInside[Ent] then
		net.Start("clipping_render_inside")
			net.WriteEntity(Ent)
			net.WriteBit(true)
		net.Send(Ply)
	end

	Stats.ClipsResent = Stats.ClipsResent + 1
end

--- Sends up to `Budget` queued answers. Returns how many were sent. Exposed for tests.
function Compat.DrainClipQueues(Budget)
	local Sent = 0

	for Id, Queue in pairs(Queues) do
		if not IsValid(Queue.Player) then
			Queues[Id] = nil
		else
			while Sent < Budget and #Queue.List > 0 do
				local Ent = table.remove(Queue.List)

				Queue.Set[Ent] = nil

				local OK, Err = pcall(SendOne, Queue.Player, Ent)

				if not OK then Compat.Warn("Visual clip resend failed: ", tostring(Err)) end

				Sent = Sent + 1
			end

			if #Queue.List == 0 then Queues[Id] = nil end
		end

		if Sent >= Budget then break end
	end

	return Sent
end

hook.Add("Think", "ACFInfMapCompat_ClipResend", function()
	if next(Queues) ~= nil then Compat.DrainClipQueues(PerTick) end
end)

hook.Add("PlayerDisconnected", "ACFInfMapCompat_ClipResend", function(Ply)
	if IsValid(Ply) then Queues[Ply:UserID()] = nil end
end)

local function Report()
	Compat.Status["visual clip resync"] = Found() and "ready" or "idle (Visual Clip's server side was not found)"
end

Report()

Compat.Register("sv_visclip", Report)

Compat.StatusLines.sv_visclip = function()
	local Waiting = 0

	for _, Queue in pairs(Queues) do Waiting = Waiting + #Queue.List end

	return {
		string.format("visclip: resync %s, Visual Clip %s, %d prop number(s) requested, %d answer(s) sent, %d request(s) refused, %d waiting",
			On:GetBool() and "ON" or "OFF", Found() and "found" or "NOT FOUND", Stats.ClipRequestsSeen, Stats.ClipsResent, Stats.ClipRequestsRefused, Waiting),
	}
end
