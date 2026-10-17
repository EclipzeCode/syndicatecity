--!strict
-- Single place that defines every remote. The server creates them; clients wait for them.
-- Treat every remote like a public API endpoint: the server validates all arguments.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local FUNCTIONS = {
	"GetContracts", -- () -> { Contract }
	"AcceptContract", -- (contractId: string) -> (ok: boolean, err: string?)
}

local EVENTS = {
	"ContractUpdated", -- server -> client: (status: JobStatus, contract: Contract?)
}

local folder: Instance
if RunService:IsServer() then
	folder = Instance.new("Folder")
	folder.Name = "Remotes"
	for _, name in FUNCTIONS do
		local remote = Instance.new("RemoteFunction")
		remote.Name = name
		remote.Parent = folder
	end
	for _, name in EVENTS do
		local remote = Instance.new("RemoteEvent")
		remote.Name = name
		remote.Parent = folder
	end
	folder.Parent = ReplicatedStorage
else
	folder = ReplicatedStorage:WaitForChild("Remotes")
end

local Remotes = {}

function Remotes.func(name: string): RemoteFunction
	return folder:WaitForChild(name) :: RemoteFunction
end

function Remotes.event(name: string): RemoteEvent
	return folder:WaitForChild(name) :: RemoteEvent
end

return Remotes
