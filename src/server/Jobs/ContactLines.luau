--!strict
-- What pickup contacts say. Server-only (it lives in ServerScriptService), so clients never see
-- the answer pools. Add lines or whole questions here; the dialogue UI renders whatever the
-- server sends.
--
-- Each question names the contract fact it checks (`answer`):
--   "passcode"  the code word the player got on their phone when they accepted the contract
--   "syndicate" who the contract is for (shown on every contract card)
-- `decoys` are the wrong options; two are drawn at random, never equal to the right answer.

export type Question = {
	id: string,
	weight: number,
	answer: "passcode" | "syndicate",
	lines: { string },
	decoys: { string },
}

local CODES = {
	"Blue Lantern",
	"Midnight Run",
	"Cold Harbor",
	"Silver Fox",
	"Red Ledger",
	"Paper Moon",
	"Iron Gate",
	"Quiet Tide",
	"Black Orchid",
	"North Star",
	"Glass Key",
	"Copper Kettle",
	"Velvet Road",
	"Last Ferry",
	"Grey Heron",
	"Salt Line",
}

return {
	-- the pool passcodes are drawn from
	Codes = CODES,

	-- shown over the contact's head
	Names = { "Vinnie", "Marlo", "Dee", "Sal", "Kit", "Rook", "Nico", "June" },

	Questions = {
		{
			id = "code",
			weight = 3,
			answer = "passcode",
			lines = {
				"You're here for the pickup? What's the code?",
				"Quiet. Give me the word before we talk.",
				"Took your time. Code?",
				"Don't look at the crates. Look at me. Password?",
			},
			decoys = CODES,
		},
		{
			id = "sender",
			weight = 1,
			answer = "syndicate",
			lines = {
				"Who sent you?",
				"Who are you running for?",
			},
			decoys = { "Southside Kings", "The Dock Rats", "Lucky Seven Crew", "The Orchard Boys", "Night Market Union" },
		},
	} :: { Question },

	Correct = {
		"That's the one. Crate's in your trunk. Don't scratch it.",
		"Good. Load up and get moving.",
		"Right answer. Now forget my face.",
	},

	Wrong = {
		"That's not it. Think, then try again.",
		"Wrong word, friend. One more go.",
		"Nope. You sure you're the driver?",
	},
}
