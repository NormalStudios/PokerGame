local HandMath = {}

local Suits = {"Hearts", "Spades", "Clubs", "Diamonds"}

--//////////////////////////////
-- Utilities
--//////////////////////////////

local function StartsWith(s, prefix)
	return string.sub(s, 1, #prefix) == prefix
end

local function ParseCard(CardName)
	-- CardName examples: "Hearts1", "Hearts10", "Hearts13"
	-- Returns: Suit (string), Rank (number with Ace=14 for comparisons), RawRank (1..13)
	for _, Suit in ipairs(Suits) do
		if StartsWith(CardName, Suit) then
			local NumStr = string.sub(CardName, #Suit + 1)
			local Raw = tonumber(NumStr) or 0  -- 1..13 (Ace=1, King=13)
			local Rank = (Raw == 1) and 14 or Raw  -- Treat Ace as 14 (high) for most compares
			return Suit, Rank, Raw
		end
	end
	-- Fallback (invalid input)
	return "Unknown", 0, 0
end

local function CloneArray(arr)
	local out = {}
	for i, v in ipairs(arr) do out[i] = v end
	return out
end

local function SortDesc(a, b) return a > b end

-- Compare two score objects returned by Evaluate7; returns
--  1 if A > B, -1 if A < B, 0 if tie
local function CompareScores(A, B)
	if A.Rank ~= B.Rank then
		return (A.Rank > B.Rank) and 1 or -1
	end
	-- Same category: use ordered tiebreakers
	for i = 1, math.max(#A.Tiebreakers, #B.Tiebreakers) do
		local av = A.Tiebreakers[i] or 0
		local bv = B.Tiebreakers[i] or 0
		if av ~= bv then
			return (av > bv) and 1 or -1
		end
	end
	return 0
end

--//////////////////////////////
-- Hand Evaluation Core (7 -> best 5)
--//////////////////////////////

-- Build frequency maps for ranks & suits
local function BuildMaps(Cards)
	-- Cards: array of card name strings
	local Ranks = {}        -- Rank -> count (Rank: 2..14 where 14 is Ace)
	local RankToCards = {}  -- Rank -> { indices }
	local SuitsMap = {}     -- Suit -> { indices }
	local Parsed = {}       -- { {Suit, Rank, Raw, Name}, ... }

	for i, name in ipairs(Cards) do
		local suit, rank, raw = ParseCard(name)
		Parsed[i] = {Suit = suit, Rank = rank, Raw = raw, Name = name}
		Ranks[rank] = (Ranks[rank] or 0) + 1
		RankToCards[rank] = RankToCards[rank] or {}
		table.insert(RankToCards[rank], i)

		SuitsMap[suit] = SuitsMap[suit] or {}
		table.insert(SuitsMap[suit], i)
	end

	return Parsed, Ranks, RankToCards, SuitsMap
end

-- Find best straight (returns topRank, list of chosen ranks 5-long) from a set of ranks.
-- Ace-low wheel (A-2-3-4-5) is represented with topRank = 5.
local function BestStraightTopRank(UniqueRanks)
	-- Include Ace as 1 for wheel check by appending 1 if 14 present
	local hasAce = false
	for _, r in ipairs(UniqueRanks) do if r == 14 then hasAce = true break end end
	local ranks = CloneArray(UniqueRanks)
	table.sort(ranks) -- ascending
	if hasAce then table.insert(ranks, 1) end

	-- Walk consecutive sequences
	local bestTop = 0
	local runLen = 1
	for i = 2, #ranks do
		if ranks[i] == ranks[i-1] + 1 then
			runLen += 1
		elseif ranks[i] ~= ranks[i-1] then
			runLen = 1
		end
		if runLen >= 5 then
			-- Top is current ranks[i]
			local top = ranks[i]
			-- Normalize A-2-3-4-5: if top==5 and 1 is present in window, treat as 5 (already)
			bestTop = math.max(bestTop, top)
		end
	end
	return bestTop
end

-- Return a list of ranks present sorted by frequency, then by rank desc.
-- Useful for building tiebreakers (e.g., for pairs/trips/quads).
local function RanksByFrequency(Ranks)
	local items = {}
	for r, c in pairs(Ranks) do
		table.insert(items, {Rank = r, Cnt = c})
	end
	table.sort(items, function(a, b)
		if a.Cnt ~= b.Cnt then return a.Cnt > b.Cnt end
		return a.Rank > b.Rank
	end)
	return items
end

-- Evaluate the best 5-card hand from 7 cards.
-- Returns:
-- {
--   Rank = int (category: 8=StraightFlush,7=Four,6=FullHouse,5=Flush,4=Straight,3=Trips,2=TwoPair,1=Pair,0=High),
--   Tiebreakers = { ...numbers... }, -- compare lexicographically
--   BestFive = { "CardName", ...5 },
--   Name = "Full House" (etc)
-- }
local function Evaluate7(Cards)
	-- Parse + maps
	local parsed, rankMap, rankToCards, suitsMap = BuildMaps(Cards)

	-- Build unique rank list
	local unique = {}
	for r, _ in pairs(rankMap) do table.insert(unique, r) end
	table.sort(unique, SortDesc) -- we’ll also need ascending later

	-- 1) Straight Flush (or Royal)
	local bestSFTop = 0
	local bestSFSuit = nil
	for suit, idxs in pairs(suitsMap) do
		if #idxs >= 5 then
			-- Collect ranks in this suit
			local suitRanksMap = {}
			for _, ci in ipairs(idxs) do
				local r = parsed[ci].Rank
				suitRanksMap[r] = true
			end
			local suitUnique = {}
			for r, _ in pairs(suitRanksMap) do table.insert(suitUnique, r) end
			local top = BestStraightTopRank(suitUnique)
			if top > bestSFTop then
				bestSFTop = top
				bestSFSuit = suit
			end
		end
	end
	if bestSFTop > 0 then
		-- Tiebreaker is top rank (Royal is just top=14)
		return {
			Rank = 8,
			Tiebreakers = {bestSFTop},
			BestFive = {}, -- (optional: choose exact 5 cards; not strictly needed for logic)
			Name = (bestSFTop == 14) and "Royal Flush" or "Straight Flush"
		}
	end

	-- 2) Four of a Kind
	local fourRank = nil
	for r, c in pairs(rankMap) do
		if c == 4 then
			if not fourRank or r > fourRank then fourRank = r end
		end
	end
	if fourRank then
		-- Kicker = highest other rank
		local kicker = 0
		for r, _ in pairs(rankMap) do
			if r ~= fourRank then kicker = math.max(kicker, r) end
		end
		return {
			Rank = 7,
			Tiebreakers = {fourRank, kicker},
			BestFive = {},
			Name = "Four of a Kind"
		}
	end

	-- 3) Full House (3 + 2)
	local tripRanks = {}
	local pairRanks = {}
	for r, c in pairs(rankMap) do
		if c >= 3 then table.insert(tripRanks, r)
		elseif c >= 2 then table.insert(pairRanks, r)
		end
	end
	table.sort(tripRanks, SortDesc)
	table.sort(pairRanks, SortDesc)
	-- Edge: two trips counts as (highest trip) + (second trip as pair)
	if #tripRanks >= 2 then
		return {
			Rank = 6,
			Tiebreakers = {tripRanks[1], tripRanks[2]},
			BestFive = {},
			Name = "Full House"
		}
	elseif #tripRanks >= 1 and #pairRanks >= 1 then
		return {
			Rank = 6,
			Tiebreakers = {tripRanks[1], pairRanks[1]},
			BestFive = {},
			Name = "Full House"
		}
	end

	-- 4) Flush
	local flushSuit = nil
	for suit, idxs in pairs(suitsMap) do
		if #idxs >= 5 then
			flushSuit = suit
			break
		end
	end
	if flushSuit then
		-- Take top 5 ranks of that suit
		local vals = {}
		for _, i in ipairs(suitsMap[flushSuit]) do
			table.insert(vals, parsed[i].Rank)
		end
		table.sort(vals, SortDesc)
		local top5 = {}
		for i = 1, math.min(5, #vals) do top5[#top5+1] = vals[i] end
		return {
			Rank = 5,
			Tiebreakers = top5,
			BestFive = {},
			Name = "Flush"
		}
	end

	-- 5) Straight (any suit)
	local uniqueAsc = CloneArray(unique)
	table.sort(uniqueAsc) -- ascending
	local straightTop = BestStraightTopRank(uniqueAsc)
	if straightTop > 0 then
		return {
			Rank = 4,
			Tiebreakers = {straightTop},
			BestFive = {},
			Name = "Straight"
		}
	end

	-- 6) Three of a Kind
	if #tripRanks >= 1 then
		local t = tripRanks[1]
		-- Two best kickers
		local kicks = {}
		for _, r in ipairs(unique) do
			if r ~= t then table.insert(kicks, r) end
			if #kicks == 2 then break end
		end
		return {
			Rank = 3,
			Tiebreakers = {t, kicks[1] or 0, kicks[2] or 0},
			BestFive = {},
			Name = "Three of a Kind"
		}
	end

	-- 7) Two Pair
	if #pairRanks >= 2 then
		table.sort(pairRanks, SortDesc)
		local p1, p2 = pairRanks[1], pairRanks[2]
		local kicker = 0
		for _, r in ipairs(unique) do
			if r ~= p1 and r ~= p2 then
				kicker = r
				break
			end
		end
		return {
			Rank = 2,
			Tiebreakers = {p1, p2, kicker},
			BestFive = {},
			Name = "Two Pair"
		}
	end

	-- 8) One Pair
	if #pairRanks >= 1 then
		local p = pairRanks[1]
		local kicks = {}
		for _, r in ipairs(unique) do
			if r ~= p then table.insert(kicks, r) end
			if #kicks == 3 then break end
		end
		return {
			Rank = 1,
			Tiebreakers = {p, kicks[1] or 0, kicks[2] or 0, kicks[3] or 0},
			BestFive = {},
			Name = "One Pair"
		}
	end

	-- 9) High Card
	-- Top 5 ranks
	local top = {}
	table.sort(unique, SortDesc)
	for i = 1, math.min(5, #unique) do top[#top+1] = unique[i] end
	return {
		Rank = 0,
		Tiebreakers = top,
		BestFive = {},
		Name = "High Card"
	}
end

--//////////////////////////////
-- Public API (as per your shape)
--//////////////////////////////

-- Combine a player's 2 cards with the 5 table cards
local function CombinePlayerHandWithTableHand(TableHand, PlayerHand)
	local all = {}
	for _, c in ipairs(TableHand or {}) do table.insert(all, c) end
	for _, c in ipairs(PlayerHand or {}) do table.insert(all, c) end
	return all
end

-- Calculate the best hand for one player vs the table
function HandMath.Calculate(TableHand, PlayerHand)
	-- Expecting: TableHand = 5 strings, PlayerHand = 2 strings (but we accept ≥0 defensively)
	local seven = CombinePlayerHandWithTableHand(TableHand, PlayerHand)
	return Evaluate7(seven)
end

-- Given the table hand and a dictionary of PlayerHands (UserId -> {2 cards}),
-- compute the winner and return:
--   WinnerUserId, Results
-- where Results[UserId] = score object from Evaluate7() with extra fields.
function HandMath.CalculateHighestHand(TableHand, PlayerHands)
	local bestUid = nil
	local bestScore = nil
	local results = {}

	for UserId, Hand in pairs(PlayerHands) do
		local score = HandMath.Calculate(TableHand, Hand)
		score.UserId = UserId
		results[UserId] = score

		if not bestScore then
			bestUid, bestScore = UserId, score
		else
			local cmp = CompareScores(score, bestScore)
			if cmp == 1 then
				bestUid, bestScore = UserId, score
			end
		end
	end

	return bestUid, results
end

return HandMath
