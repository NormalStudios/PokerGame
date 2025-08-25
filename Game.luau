-- File: ReplicatedStorage/PokerGame.lua (or wherever your module lives)

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")

local Cards = ReplicatedStorage.Cards
local RemoteEvents = ReplicatedStorage.RemoteEvents

local PokerGame = {}
PokerGame.__index = PokerGame

-- //////////////////////////////
-- Core Construction
-- //////////////////////////////

function PokerGame.new()
	local self = setmetatable({
		-- Table / Hand state
		Pot = 0,
		BuyIn = math.random(1, 10),

		-- Players & Cards
		PlayerHands = {},        -- [userId] = { "CardName", "CardName" }
		InHand = {},             -- [userId] = true/false (fold removes)
		AllIn = {},              -- [userId] = true/false
		Connections = {},

		Flop = {},               -- we keep ALL 5 community cards here (3 flop + turn + river)
		BurnedCards = {},

		-- Betting State
		CurrentBet = 0,          -- highest price to match for this street
		MinRaise  = 10,          -- table min (use BigBlind typically)
		RoundContrib = {},       -- [userId] = chips put in this street
		TotalContrib = {},       -- [userId] = chips put in across all streets

		-- Side Pots (built from TotalContrib)
		Pots = {},               -- array of { Amount = number, Eligible = { [userId]=true } }

		-- Table Config (tune)
		SmallBlind = 5,
		BigBlind   = 10,
	}, PokerGame)

	self.Bet = self.BuyIn -- keep existing field if other UI expects it
	return self
end

-- //////////////////////////////
-- Deck & Dealing
-- //////////////////////////////

function PokerGame:BuildDeck()
	self.Deck = {}
	for _, Card in pairs(Cards:GetDescendants()) do
		if Card:IsA("MeshPart") then
			table.insert(self.Deck, Card.Name)
		end
	end
end

function PokerGame:GiveCard()
	local Index = math.random(1, #self.Deck)
	local Card = self.Deck[Index]
	table.remove(self.Deck, Index)
	return Card
end

function PokerGame:GivePlayerHand()
	local Hand = {}
	for i = 1, 2 do
		local Card = self:GiveCard()
		table.insert(Hand, Card)
	end
	return Hand
end

function PokerGame:BurnCard()
	local Card = self:GiveCard()
	table.insert(self.BurnedCards, Card)
end

function PokerGame:ShowFlop()
	-- Burn 1, deal 3 face-up (append to Flop)
	self:BurnCard()
	for i = 1, 3 do
		local Card = self:GiveCard()
		table.insert(self.Flop, Card)
	end
end

function PokerGame:TurnCard()
	-- Burn 1, deal 1 face-up (append to Flop)
	self:BurnCard()
	local Card = self:GiveCard()
	table.insert(self.Flop, Card)
end

function PokerGame:RiverCard()
	-- Burn 1, deal 1 face-up (append to Flop)
	self:BurnCard()
	local Card = self:GiveCard()
	table.insert(self.Flop, Card)
end

-- //////////////////////////////
-- Player Lifecycle
-- //////////////////////////////

function PokerGame:Fold(UserId)
	self.InHand[UserId] = false
	self.AllIn[UserId] = self.AllIn[UserId] or false
	self.PlayerHands[UserId] = nil
end

function PokerGame:HandleLeaving()
	self.Connections["PlayerRemoving"] = Players.PlayerRemoving:Connect(function(Player)
		self:Fold(Player.UserId)
	end)
end

function PokerGame:DisconnectFunctions()
	for Key, Conn in pairs(self.Connections) do
		if Conn then
			Conn:Disconnect()
			self.Connections[Key] = nil
		end
	end
end

function PokerGame:BuyIn()
	local PlayersPlaying = {}

	for _, Player in pairs(Players:GetPlayers()) do
		local Data = _G.PlayersData[Player.UserId]
		local HasEnough = Data and Data:RemoveGold(self.BuyIn) -- buy-in once for hand

		if HasEnough then
			table.insert(PlayersPlaying, Player)
			self.Pot += self.BuyIn
			self.InHand[Player.UserId] = true
			self.AllIn[Player.UserId] = false
			self.TotalContrib[Player.UserId] = (self.TotalContrib[Player.UserId] or 0) + self.BuyIn
			self.RoundContrib[Player.UserId] = 0
		else
			self:Fold(Player.UserId)
		end
	end

	return PlayersPlaying
end

-- //////////////////////////////
-- Betting Streets
-- //////////////////////////////

function PokerGame:StartStreet()
	-- New betting street resets current bet and per-street contributions
	self.CurrentBet = 0
	self.MinRaise  = self.BigBlind
	for UserId, _ in pairs(self.InHand) do
		self.RoundContrib[UserId] = 0
	end
end

-- Attempt to remove chips from player for an exact amount.
-- Returns amount actually paid (0 if fail). Flags AllIn if client told us so.
local function SafeRemoveGold(UserId, Amount, IsAllInFlag)
	if Amount <= 0 then return 0 end
	local Player = Players:GetPlayerByUserId(UserId)
	if not Player then return 0 end
	local Data = _G.PlayersData[UserId]
	if not Data then return 0 end

	-- RemoveGold must succeed fully for Amount, or fail (no partial knowledge here).
	-- For **all-in**, the client should send Decision="AllIn" and provide the exact amount they're jamming.
	local Ok = Data:RemoveGold(Amount)
	if not Ok then
		return 0
	end

	if IsAllInFlag then
		_G.Game.AllIn[UserId] = true
	end
	return Amount
end

function PokerGame:SendPlayersBet()
	-- This keeps your per-player solicitation pattern, but:
	-- - supports "Check", "Call", "Raise/Bet", "Fold", and **"AllIn"** (client must send amount)
	-- - allows under-call all-ins via the "AllIn" decision (client supplies amount)
	-- - updates self.Pot, RoundContrib, TotalContrib, AllIn, InHand appropriately

	local SomeoneBet = (self.CurrentBet > 0)

	for UserId, Hand in pairs(self.PlayerHands) do
		-- Skip folded or already all-in players
		if not self.InHand[UserId] or self.AllIn[UserId] then
			continue
		end

		local Player = Players:GetPlayerByUserId(UserId)
		if not Player then
			self:Fold(UserId)
			continue
		end

		local ToCall = math.max(0, self.CurrentBet - (self.RoundContrib[UserId] or 0))

		-- Fire UI with current context (you can extend your client to show "All In" and pass amount)
		-- Args: BuyIn, SomeoneBet, ToCall, MinRaise
		RemoteEvents.Bet:FireClient(Player, self.BuyIn, SomeoneBet, ToCall, self.MinRaise)

		local Made = false
		local Decision = nil
		local Amount = 0

		local Key = "Bet_" .. tostring(UserId)
		if self.Connections[Key] then
			self.Connections[Key]:Disconnect()
			self.Connections[Key] = nil
		end

		self.Connections[Key] = RemoteEvents.Bet.OnServerEvent:Connect(function(From, D, A)
			if From ~= Player then return end
			Decision = D
			Amount = tonumber(A) or 0 -- used for Raise/Bet or AllIn amount
			Made = true
		end)

		-- Wait (simple timeout)
		local t = 0
		local T = 15
		while not Made and t < T do
			task.wait(1)
			t += 1
		end

		if self.Connections[Key] then
			self.Connections[Key]:Disconnect()
			self.Connections[Key] = nil
		end

		if not Made then
			-- Timeout -> fold
			self:Fold(UserId)
			continue
		end

		-- Process decision
		if Decision == "Fold" then
			self:Fold(UserId)

		elseif Decision == "Check" then
			if ToCall == 0 then
				-- legal check
			else
				-- illegal check -> fold (or auto-call if you prefer)
				self:Fold(UserId)
			end

		elseif Decision == "Call" then
			-- Must match ToCall exactly. If insufficient chips, client should instead send "AllIn".
			if ToCall > 0 then
				local Paid = SafeRemoveGold(UserId, ToCall, false)
				if Paid <= 0 then
					-- Could not pay full call. Without a way to know stack,
					-- treat as fold. (If you want partial calls, use "AllIn" from client.)
					self:Fold(UserId)
				else
					self.Pot += Paid
					self.RoundContrib[UserId] = (self.RoundContrib[UserId] or 0) + Paid
					self.TotalContrib[UserId] = (self.TotalContrib[UserId] or 0) + Paid
					SomeoneBet = true
				end
			end

		elseif Decision == "AllIn" then
			-- Client must pass their exact all-in amount in Amount.
			-- This can be:
			--   - <= ToCall  -> under-call (creates side pots later)
			--   - >= ToCall  -> sets a new raise only if it reaches a valid threshold (see below)
			local AllInPaid = SafeRemoveGold(UserId, Amount, true)
			if AllInPaid <= 0 then
				-- Could not all-in -> fold
				self:Fold(UserId)
			else
				self.Pot += AllInPaid
				self.RoundContrib[UserId] = (self.RoundContrib[UserId] or 0) + AllInPaid
				self.TotalContrib[UserId] = (self.TotalContrib[UserId] or 0) + AllInPaid

				-- If all-in covers a full valid raise, update CurrentBet/MinRaise.
				-- Otherwise, it is just a call-for-less (no new price to match).
				local NewTotalThisPlayer = self.RoundContrib[UserId]
				if self.CurrentBet == 0 then
					-- First bet of the street must be at least BigBlind to set a price.
					if NewTotalThisPlayer >= self.BigBlind then
						self.CurrentBet = NewTotalThisPlayer
						self.MinRaise = math.max(self.MinRaise, self.BigBlind)
						SomeoneBet = true
					end
				else
					-- Raise must be at least (CurrentBet + MinRaise)
					if NewTotalThisPlayer >= (self.CurrentBet + self.MinRaise) then
						self.MinRaise = math.max(self.MinRaise, NewTotalThisPlayer - self.CurrentBet)
						self.CurrentBet = NewTotalThisPlayer
						SomeoneBet = true
					end
				end
			end

		elseif Decision == "Raise" or Decision == "Bet" then
			-- Target bet amount for this player on this street:
			-- If first bet of street: at least BigBlind
			-- Else: at least CurrentBet + MinRaise
			local Target
			if self.CurrentBet == 0 then
				Target = math.max(Amount, self.BigBlind)
			else
				Target = math.max(Amount, self.CurrentBet + self.MinRaise)
			end

			local Need = math.max(0, Target - (self.RoundContrib[UserId] or 0))
			local Paid = SafeRemoveGold(UserId, Need, false)

			if Paid <= 0 then
				-- Could not hit the raise target; treat as failure (fold or ask client to AllIn)
				self:Fold(UserId)
			else
				self.Pot += Paid
				self.RoundContrib[UserId] = (self.RoundContrib[UserId] or 0) + Paid
				self.TotalContrib[UserId] = (self.TotalContrib[UserId] or 0) + Paid

				-- If player fully reached Target, it’s a valid raise/bet.
				if (self.RoundContrib[UserId] or 0) >= Target then
					self.MinRaise = math.max(self.MinRaise, Target - self.CurrentBet)
					self.CurrentBet = Target
					SomeoneBet = true
				else
					-- Short of Target => not a valid new price. Keep as call-for-less (no price change).
					-- If this “short” was actually meant as AllIn, send Decision="AllIn" from client with explicit amount.
				end
			end
		end
	end
end

-- //////////////////////////////
-- Side Pots
-- //////////////////////////////

-- Build side pots from TotalContrib and eligibility.
-- READABLE MATH:
--   Think in "layers" of contribution. Each layer takes the smallest positive
--   remaining contribution among players, and creates a pot equal to:
--       layerAmount * numberOfContributorsInThisLayer
--   Eligible players for that pot are those who did NOT fold (InHand or AllIn true).
function PokerGame:BuildPotsFromTotals()
	-- Copy remaining paid amounts
	local Paid = {}
	local Eligible = {}
	for UserId, Total in pairs(self.TotalContrib) do
		Paid[UserId] = Total or 0
		if self.InHand[UserId] or self.AllIn[UserId] then
			Eligible[UserId] = true
		end
	end

	self.Pots = {}

	local function MinPositive()
		local m = math.huge
		for _, v in pairs(Paid) do
			if v > 0 and v < m then
				m = v
			end
		end
		if m == math.huge then return 0 end
		return m
	end

	while true do
		local Layer = MinPositive()
		if Layer <= 0 then
			break
		end

		-- Contributors are everyone who still has Paid > 0
		local Contributors = {}
		for Uid, v in pairs(Paid) do
			if v > 0 then
				table.insert(Contributors, Uid)
			end
		end
		if #Contributors == 0 then
			break
		end

		-- Pot amount for this layer:
		--   Amount = Layer * (#Contributors)
		local PotAmount = Layer * #Contributors

		-- Subtract this layer from everyone who contributed
		for _, Uid in ipairs(Contributors) do
			Paid[Uid] = Paid[Uid] - Layer
		end

		-- Eligible = players who did not fold (InHand or AllIn)
		local PotEligible = {}
		for Uid, ok in pairs(Eligible) do
			if ok then PotEligible[Uid] = true end
		end

		table.insert(self.Pots, {
			Amount = PotAmount,
			Eligible = PotEligible
		})
	end
end

-- //////////////////////////////
-- Awarding (hook up to your showdown logic)
-- //////////////////////////////
-- When you’re ready to pay winners after showdown:
-- 1) Rank hands for players still eligible (InHand/AllIn).
-- 2) For each pot in self.Pots (in order), find the BEST eligible hand among Pot.Eligible.
-- 3) PAY THAT PLAYER HERE (give them gold: Data:AddGold(self.Pots[i].Amount) or equivalent).
-- NOTE: Folded players are not eligible, but their chips remain in the pots.

-- Example skeleton (you’ll supply your own ranking):
-- function PokerGame:AwardPots(RankCallback)
--     -- RankCallback(UserId, PlayerHand, FlopArray) -> numeric rank, higher is better
--     for _, pot in ipairs(self.Pots) do
--         local bestUid, bestRank = nil, -math.huge
--         for Uid, ok in pairs(pot.Eligible) do
--             if ok then
--                 local hand = self.PlayerHands[Uid]
--                 if hand then
--                     local rank = RankCallback(Uid, hand, self.Flop)
--                     if rank > bestRank then
--                         bestRank = rank
--                         bestUid = Uid
--                     end
--                 end
--             end
--         end
--         if bestUid then
--             -- >>> GIVE GOLD HERE to bestUid for pot.Amount <<<
--             -- local Data = _G.PlayersData[bestUid]
--             -- if Data and Data.AddGold then Data:AddGold(pot.Amount) end
--         end
--     end
-- end

return PokerGame
