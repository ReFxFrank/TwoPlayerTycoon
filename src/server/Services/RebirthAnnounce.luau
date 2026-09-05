--!strict
--[[
    RebirthAnnounce
    Everything the clients are told about a Transcendence vote: the running ballot, the terminal push
    that closes the modal, and the toast wording.

    Split out of RebirthService for the 300-line ceiling, and it is a real seam -- this is the whole
    client-facing surface of the vote, and the one place its wire shape is decided.
    Owner: server  |  Consumers: RebirthService
]]

local RebirthAnnounce = {}

--- `deps` supplies the remote service and the small readers RebirthService already owns, so this
--- module needs no view of the Sanctum type.
export type Deps = {
	Remotes: any,
	Occupants: (any) -> { any },
	UserId: (any) -> number?,
	Name: (any) -> string,
	PlotId: (any) -> number,
}

local d: Deps? = nil

function RebirthAnnounce.bind(deps: Deps): ()
	d = deps
end

function RebirthAnnounce.notify(sanctum: any, kind: string, text: string): ()
	local deps = d
	if deps == nil or deps.Remotes == nil then return end
	deps.Remotes:FireClients(deps.Occupants(sanctum), "Notify", { Kind = kind, Text = text })
end

-- The ballot as the client renders it. Keys are STRINGS (RebirthController indexes Names/Votes by
-- tostring(UserId)), and an ExpiresAt that is not in the future is the terminal push every ending
-- shares -- which is what closes the modal on a cancel, an expiry and a completed vote alike.
function RebirthAnnounce.broadcast(sanctum: any, vote: Vote?): ()
	local deps = d
	if deps == nil or deps.Remotes == nil then return end
	local names: { [string]: string }, ballots: { [string]: boolean } = {}, {}
	local recipients = deps.Occupants(sanctum)
	if vote ~= nil then
		for _, player in ipairs(recipients) do
			local userId = deps.UserId(player)
			if userId ~= nil then
				names[tostring(userId)] = deps.Name(player)
				local cast = vote.Ballots[userId]
				if cast ~= nil then ballots[tostring(userId)] = cast end
			end
		end
	end
	deps.Remotes:FireClients(recipients, "RebirthVoteState", { PlotId = deps.PlotId(sanctum),
		Votes = ballots, Names = names, ExpiresAt = if vote ~= nil then vote.ExpiresAt else 0 })
end

return RebirthAnnounce
