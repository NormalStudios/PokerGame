--[[
Instead of immediatelly showing winner, shoot every person with a losing hand, then reveal the final person (adds more suspense)

--]]

local PokerGameCreator = require(script.Parent.PokerGame)

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")


local Modules = ServerScriptService.ServerModules
local RequiredStartupModules = Modules.RequiredStartupModules

for Index, Module in pairs(RequiredStartupModules:GetChildren()) do
	require(Module).Init()
end

-- Server loop
-- File: ServerScriptService/YourScript.server.lua

--[[
Instead of immediately showing winner,
shoot every person with a losing hand, then reveal the final person (adds suspense)
--]]

local PokerGameCreator = require(script.Parent.PokerGame)

local ServerScriptService = game:GetService("ServerScriptService")
local Players = game:GetService("Players")

local Modules = ServerScriptService.ServerModules
local RequiredStartupModules = Modules.RequiredStartupModules

for _, Module in pairs(RequiredStartupModules:GetChildren()) do
	require(Module).Init()
end

while true do
	_G.Game = PokerGameCreator.new()

	-- Post buy-in and build deck
	local PlayingPlayers = _G.Game:BuyIn()
	_G.Game:BuildDeck()

	-- Give hole cards
	for _, Player in pairs(PlayingPlayers) do
		local Hand = _G.Game:GivePlayerHand()
		_G.Game.PlayerHands[Player.UserId] = Hand
		_G.Game.InHand[Player.UserId] = true
	end

	_G.Game:HandleLeaving()

	-- Let players see hand
	task.wait(3)

	-- Pre-flop betting
	_G.Game:StartStreet()
	_G.Game:SendPlayersBet()

	-- Flop
	_G.Game:ShowFlop()
	task.wait(1)

	_G.Game:StartStreet()
	_G.Game:SendPlayersBet()
	task.wait(1)

	-- Turn
	_G.Game:TurnCard()
	task.wait(1)

	_G.Game:StartStreet()
	_G.Game:SendPlayersBet()
	task.wait(1)

	-- River
	_G.Game:RiverCard()
	task.wait(1)

	_G.Game:StartStreet()
	_G.Game:SendPlayersBet()

	-- Build side pots from total contributions
	_G.Game:BuildPotsFromTotals()

	-- At this point:
	-- 1) Evaluate hands for remaining players.
	-- 2) Determine winners per pot and PAY THEM HERE (see Awarding comments in module).
	-- 3) Do your "shoot the losers, reveal winner" VFX.
	-- (You can call a function like _G.Game:AwardPots(RankCallback) if you implement ranking.)

	-- Loop, or break based on table conditions
	
end
