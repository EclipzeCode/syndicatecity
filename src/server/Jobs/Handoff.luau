--!strict
-- Cargo pickups as a meeting: a contact NPC waits at the pickup point while any accepted
-- contract needs it, and hands over the cargo once the player answers its question (usually the
-- contract's passcode) correctly. Wrong answers just get a retry.
--
-- This module is the presentation and verification layer only. JobService owns the contract:
-- it calls prepare() when a contract is accepted and release() when it ends, and gives this
-- module two callbacks (see init). The right answer never leaves the server except as the
-- passcode JobService sends to the contract's own player.
--
-- Remotes:
--   ContactDialogue (server -> client): ("open", { contact, line, options }) | ("close", reason?)
--   AnswerContact   (client -> server, RemoteFunction): (choice: number) -> { ok, line, done }
--   CloseContact    (client -> server): () the player closed the dialogue

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Shared.Config)
local Palette = require(ReplicatedStorage.Shared.Palette)
local Remotes = require(ReplicatedStorage.Shared.Remotes)
local Types = require(ReplicatedStorage.Shared.Types)
local ContactLines = require(script.Parent.ContactLines)

local CONTACT = Config.Jobs.Contact

export type Api = {
	-- true while `player`'s active contract is `contractId` and its cargo hasn't been loaded yet
	canPickUp: (player: Player, contractId: string) -> boolean,
	-- loads the cargo for that contract; false if the contract moved on in the meantime
	loadCargo: (player: Player, contractId: string) -> boolean,
}

-- One player's pickup: the question their contact will ask and the right answer.
type Pending = {
	contractId: string,
	pickupName: string,
	line: string,
	options: { string },
	correct: number,
}

type Session = {
	contractId: string,
	pickupName: string,
	lastAnswer: number,
}

type Contact = {
	model: Model,
	root: BasePart,
	users: { [Player]: boolean },
	name: string,
}

local Handoff = {}

local api: Api
local rng = Random.new()
local pickups: { [string]: BasePart } = {}
local contacts: { [string]: Contact } = {}
local pending: { [Player]: Pending } = {}
local sessions: { [Player]: Session } = {}
local contactsFolder: Folder

local dialogueEvent = Remotes.event("ContactDialogue")

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
		return nil
	end
	return root
end

local function pickLine(lines: { string }): string
	return lines[rng:NextInteger(1, #lines)]
end

local function pickQuestion(): ContactLines.Question
	local total = 0
	for _, q in ContactLines.Questions do
		total += q.weight
	end
	local roll = rng:NextNumber() * total
	for _, q in ContactLines.Questions do
		roll -= q.weight
		if roll <= 0 then
			return q
		end
	end
	return ContactLines.Questions[1]
end

---------------------------------------------------------------------------------------------------
-- Contact NPCs
---------------------------------------------------------------------------------------------------

-- A blocky stand-in character, anchored in place, with a "Contact" tag over its head.
local function buildContact(pickup: BasePart, name: string): Contact
	local model = Instance.new("Model")
	model.Name = `Contact ({pickup.Name})`
	local ground = pickup.Position.Y - pickup.Size.Y / 2
	-- face the nearest road, so the contact looks out at whoever pulls up
	local position = Vector3.new(pickup.Position.X, ground, pickup.Position.Z)
	local facing = Vector3.new(0, 0, -1)
	local map = workspace:FindFirstChild("Map")
	local graph = map and map:FindFirstChild("RoadGraph")
	if graph then
		local best = math.huge
		for _, value in graph:GetChildren() do
			if value:IsA("Vector3Value") then
				local flat = Vector3.new(value.Value.X - position.X, 0, value.Value.Z - position.Z)
				if flat.Magnitude < best and flat.Magnitude > 1 then
					best = flat.Magnitude
					facing = flat.Unit
				end
			end
		end
	end
	local base = CFrame.lookAt(position, position + facing)

	local jacket = Color3.fromRGB(46, 50, 60)
	local function add(partName: string, size: Vector3, offset: Vector3, color: Color3): Part
		local p = Instance.new("Part")
		p.Name = partName
		p.Size = size
		p.CFrame = base * CFrame.new(offset)
		p.Color = color
		p.Anchored = true
		p.CanCollide = partName == "HumanoidRootPart"
		p.Material = Enum.Material.SmoothPlastic
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p.Parent = model
		return p
	end
	local skin = Palette.Buildings[1]
	local root = add("HumanoidRootPart", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), jacket)
	root.Transparency = 1
	add("Torso", Vector3.new(2, 2, 1), Vector3.new(0, 3, 0), jacket)
	local head = add("Head", Vector3.new(1.2, 1.2, 1.2), Vector3.new(0, 4.6, 0), skin)
	add("Cap", Vector3.new(1.3, 0.4, 1.3), Vector3.new(0, 5.25, 0), Palette.Pickup)
	add("Left Arm", Vector3.new(1, 2, 1), Vector3.new(-1.5, 3, 0), jacket)
	add("Right Arm", Vector3.new(1, 2, 1), Vector3.new(1.5, 3, 0), jacket)
	add("Left Leg", Vector3.new(1, 2, 1), Vector3.new(-0.5, 1, 0), Color3.fromRGB(30, 32, 38))
	add("Right Leg", Vector3.new(1, 2, 1), Vector3.new(0.5, 1, 0), Color3.fromRGB(30, 32, 38))
	model.PrimaryPart = root

	local tag = Instance.new("BillboardGui")
	tag.Name = "ContactTag"
	tag.Size = UDim2.fromOffset(120, 34)
	tag.StudsOffsetWorldSpace = Vector3.new(0, 2.6, 0)
	tag.MaxDistance = 160
	tag.LightInfluence = 0
	tag.Parent = head
	local label = Instance.new("TextLabel")
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = `◆ {name}`
	label.Font = Enum.Font.GothamBold
	label.TextSize = 16
	label.TextColor3 = Palette.Pickup
	label.TextStrokeTransparency = 0.4
	label.Parent = tag

	-- shown only to players whose contract uses this pickup (ContactController); the server
	-- checks everything again when it's triggered
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "ContactPrompt"
	prompt.ActionText = "Talk"
	prompt.ObjectText = name
	prompt.HoldDuration = 0
	prompt.MaxActivationDistance = CONTACT.InteractDistance
	prompt.RequiresLineOfSight = false
	prompt:SetAttribute("PickupName", pickup.Name)
	prompt.Parent = root
	CollectionService:AddTag(prompt, "ContactPrompt")

	model.Parent = contactsFolder
	return { model = model, root = root, users = {}, name = name }
end

local function closeSession(player: Player, reason: string?)
	if sessions[player] then
		sessions[player] = nil
		dialogueEvent:FireClient(player, "close", reason)
	end
end

local function withinReach(player: Player, contact: Contact, slack: number): boolean
	local root = rootOf(player)
	return root ~= nil and (root.Position - contact.root.Position).Magnitude <= CONTACT.InteractDistance + slack
end

local function onTalk(player: Player, pickupName: string)
	local contact = contacts[pickupName]
	local job = pending[player]
	if not contact or not job or job.pickupName ~= pickupName or sessions[player] then
		return
	end
	if not api.canPickUp(player, job.contractId) or not withinReach(player, contact, 2) then
		return
	end
	sessions[player] = { contractId = job.contractId, pickupName = pickupName, lastAnswer = 0 }
	-- turn to face the driver
	local root = rootOf(player)
	if root then
		local from = contact.model:GetPivot().Position
		local look = Vector3.new(root.Position.X, from.Y, root.Position.Z)
		if (look - from).Magnitude > 0.5 then
			contact.model:PivotTo(CFrame.lookAt(from, look))
		end
	end
	dialogueEvent:FireClient(player, "open", {
		contact = contact.name,
		line = job.line,
		options = job.options,
	})
end

local function addUser(pickupName: string, player: Player)
	local contact = contacts[pickupName]
	if not contact then
		local pickup = pickups[pickupName]
		if not pickup then
			return
		end
		contact = buildContact(pickup, pickLine(ContactLines.Names))
		contacts[pickupName] = contact
		local prompt = contact.root:FindFirstChild("ContactPrompt") :: ProximityPrompt
		prompt.Triggered:Connect(function(who)
			onTalk(who, pickupName)
		end)
	end
	contact.users[player] = true
end

local function removeUser(pickupName: string, player: Player, delaySeconds: number)
	local contact = contacts[pickupName]
	if not contact then
		return
	end
	contact.users[player] = nil
	-- linger a moment so the contact doesn't vanish mid-goodbye
	task.delay(delaySeconds, function()
		if contacts[pickupName] == contact and next(contact.users) == nil then
			contacts[pickupName] = nil
			contact.model:Destroy()
		end
	end)
end

---------------------------------------------------------------------------------------------------
-- Answers
---------------------------------------------------------------------------------------------------

type Reply = { ok: boolean, line: string, done: boolean }

local function onAnswer(player: Player, choice: unknown): Reply?
	local session = sessions[player]
	local job = pending[player]
	if not session or not job or job.contractId ~= session.contractId then
		return nil
	end
	-- debounce double clicks and scripted spam; the client disables its buttons meanwhile anyway
	local now = os.clock()
	if now - session.lastAnswer < CONTACT.AnswerCooldown then
		return nil
	end
	session.lastAnswer = now
	if typeof(choice) ~= "number" or choice ~= math.floor(choice) or choice < 1 or choice > #job.options then
		return nil
	end
	local contact = contacts[job.pickupName]
	if not contact or not api.canPickUp(player, job.contractId) or not withinReach(player, contact, 8) then
		closeSession(player, "The contact won't talk to you here.")
		return { ok = false, line = "", done = true }
	end
	if choice ~= job.correct then
		return { ok = false, line = pickLine(ContactLines.Wrong), done = false }
	end
	-- end the session first: loading the cargo makes JobService call release(), and this reply,
	-- not a "close" event, should be what ends the dialogue on the client
	sessions[player] = nil
	-- loadCargo re-checks the contract, so a replayed answer can't load a second crate
	if not api.loadCargo(player, job.contractId) then
		return { ok = false, line = "", done = true }
	end
	return { ok = true, line = pickLine(ContactLines.Correct), done = true }
end

---------------------------------------------------------------------------------------------------
-- Contract hooks
---------------------------------------------------------------------------------------------------

-- Called when `player` accepts `contract`: chooses the question and passcode, and sends a
-- contact to the pickup. Returns the passcode for the player's phone.
function Handoff.prepare(player: Player, contract: Types.Contract): string
	Handoff.release(player, 0)
	local passcode = pickLine(ContactLines.Codes)
	local question = pickQuestion()
	local answer = if question.answer == "syndicate" then contract.syndicate else passcode

	-- the right answer plus two different decoys, shuffled
	local options = { answer }
	local decoys = table.clone(question.decoys)
	while #options < 3 and #decoys > 0 do
		local candidate = table.remove(decoys, rng:NextInteger(1, #decoys)) :: string
		if not table.find(options, candidate) then
			table.insert(options, candidate)
		end
	end
	for i = #options, 2, -1 do
		local j = rng:NextInteger(1, i)
		options[i], options[j] = options[j], options[i]
	end

	pending[player] = {
		contractId = contract.id,
		pickupName = contract.pickupName,
		line = pickLine(question.lines),
		options = options,
		correct = table.find(options, answer) :: number,
	}
	addUser(contract.pickupName, player)
	return passcode
end

-- Called when the player's contract no longer needs the contact (cargo loaded, delivered,
-- failed, busted) or the player leaves. Safe to call more than once.
function Handoff.release(player: Player, lingerSeconds: number?)
	local job = pending[player]
	pending[player] = nil
	closeSession(player)
	if job then
		removeUser(job.pickupName, player, lingerSeconds or 0)
	end
end

-- Studio test hook: the player's pending pickup (see Tools.ServerTests).
function Handoff.debugPending(player: Player): (string?, { string }?, number?)
	local job = pending[player]
	if not job then
		return nil
	end
	return job.pickupName, job.options, job.correct
end

-- Studio test hook: open the dialogue as if the player had triggered the contact's prompt.
function Handoff.debugTalk(player: Player)
	local job = pending[player]
	if job then
		onTalk(player, job.pickupName)
	end
end

function Handoff.debugAnswer(player: Player, choice: unknown): Reply?
	return onAnswer(player, choice)
end

function Handoff.debugSessionOpen(player: Player): boolean
	return sessions[player] ~= nil
end

function Handoff.init(pickupParts: { BasePart }, callbacks: Api)
	api = callbacks
	for _, part in pickupParts do
		pickups[part.Name] = part
	end
	contactsFolder = Instance.new("Folder")
	contactsFolder.Name = "Contacts"
	contactsFolder.Parent = workspace

	Remotes.func("AnswerContact").OnServerInvoke = onAnswer
	Remotes.event("CloseContact").OnServerEvent:Connect(function(player)
		sessions[player] = nil
	end)
	Players.PlayerRemoving:Connect(function(player)
		Handoff.release(player)
	end)

	-- end dialogues that can't continue: walked away, died, or the contract moved on
	task.spawn(function()
		while true do
			task.wait(0.5)
			for player, session in sessions do
				local contact = contacts[session.pickupName]
				if not player.Parent or not contact or not api.canPickUp(player, session.contractId) then
					closeSession(player)
				elseif not withinReach(player, contact, 8) then
					closeSession(player, "You walked away from the contact.")
				end
			end
		end
	end)
end

return Handoff
