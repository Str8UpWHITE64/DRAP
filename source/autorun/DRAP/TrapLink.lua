-- DRAP/TrapLink.lua
-- TrapLink: trade traps with the rest of the multiworld.
--
-- Protocol (cross-game, shared with Sonic Adventure 2, Super Mario World and
-- others): a Bounce carrying the tag "TrapLink" and
--     { time, source = <player name>, trap_name = <standard trap name> }
-- A client that gets a trap sends its standard name out; every other client
-- with the tag looks the name up in its own table and fires the nearest thing
-- it has, or ignores it.
--
-- SENDING happens when a trap actually FIRES out of TrapBank, not when the
-- item arrives: a server !collect then goes out one trap per 30 s instead of
-- all at once, the persisted consumed[] tally means it is sent once, and a
-- reconnect replay never re-sends. A trap that arrived over the link never
-- sends (it takes the TrapBank link path, which has no item hook).
--
-- RECEIVING never touches an item count. The name is mapped to one of our own
-- traps and queued in TrapBank, which pays it out through the same fire
-- function, 30 s gate and PlayerReady check as an item trap -- so the
-- safeguards on the costume swap (applied only on an area load) and on the
-- inventory traps (noClash=false, spaced breaks) are the ones already in
-- those functions, and nothing here reaches past them.
--
-- A trap the player took out of their yaml's enabled_traps is never applied.
-- Army Trap is Special Forces both ways, so another game's Army Trap brings
-- the soldiers (only when this slot's yaml allows Special Forces).
--
-- The rule: a trap goes out under a name we would take back as that same
-- trap. W I D E Trap comes in as Giant, so Giant goes out as W I D E Trap.
-- Nothing sends as one thing and comes back as another, so two DRAP players
-- trade exactly the same traps. Checked at load, below.
--
-- Names are the exact strings on the TrapLink sheet, apart from the traps
-- with no equal or similar trap there: those send and receive only their own
-- item name, so they link between DRAP players and nowhere else. A name that
-- is not in RECEIVE below is ignored (logged), which is the protocol's
-- expectation.

local Shared = require("DRAP/Shared")
local TrapBank = require("DRAP/TrapBank")

local M = Shared.create_module("TrapLink")

------------------------------------------------------------
-- Mapping
------------------------------------------------------------

-- Our trap -> the name we send. Every trap sends, and each name is one RECEIVE
-- turns back into the same trap. Own item names: no equal or similar trap on
-- the sheet.
M.SEND = {
    ["Giant Trap"]              = "W I D E Trap",
    ["Night Trap"]              = "Nightmare Trap",
    ["Convicts Respawn Trap"]   = "Convicts Respawn Trap",
    ["Last Shot Trap"]          = "Last Shot Trap",
    ["Where'd Your Inventory Go? Trap"] = "Items to Bombs",
    ["Goddamnit, Donut! Trap"]  = "Goddamnit, Donut! Trap",
    ["Boxers Trap"]             = "Boxers Trap",
    ["Skipped Arm Day Trap"]    = "Skipped Arm Day Trap",
    ["Stomach Ache Trap"]       = "Poison Trap",
    ["Zombait Trap"]            = "Chaser Trap",
    ["Skipped Leg Day Trap"]    = "Slowness Trap",
    ["Damage Player Trap"]      = "Damage Trap",
    ["Hostile NPC Trap"]        = "Police Trap",
    ["Special Forces Trap"]     = "Army Trap",
    ["Butterfingers Trap"]      = "Disarm Trap",
    ["Bald Trap"]               = "Bald Trap",
    ["Oops More Zombies Trap"]  = "Bee Trap",
    ["Potty Mouth Trap"]        = "Yap Trap",
    ["Bonk Trap"]               = "Bonk Trap",
    ["1 HP Trap"]               = "One Hit KO",
    ["Tiny Trap"]               = "Tiny Trap",
    ["Cardio Trap"]             = "Fast Trap",
    ["Teleport Trap"]           = "Teleport Trap",
    ["Invisibility Trap"]       = "Invisible Trap",
    ["Knockout Gas Trap"]       = "Gas Trap",
}

-- Our trap -> the standard names that fire it.
local RECEIVE_GROUPS = {
    ["Damage Player Trap"] = { "Damage Trap", "Burn Trap" },
    ["Stomach Ache Trap"] = {
        "Poison Trap", "Poison Mushroom", "Food Poisoning Trap", "Toxin Trap",
        "Poisontoad", "Guest Vomiting Trap",
    },
    -- Frank cannot be frozen, so the freeze family becomes the slow.
    ["Skipped Leg Day Trap"] = {
        "Slowness Trap", "Slow Trap", "Freeze Trap", "Frozen Trap",
        "Paralyze Trap", "Paralysis Trap", "Sticky Floor Trap", "Tar Trap",
    },
    ["Potty Mouth Trap"] = {
        "Yap Trap", "Aaa Trap", "E. Gadd Ramblings", "Exposition Trap",
        "Hey! Trap", "Spam Trap", "Taunt Trap",
    },
    ["Oops More Zombies Trap"] = {
        "Bee Trap", "Dead Ringer Trap", "Spooky Time", "Summon Trap",
    },
    ["Zombait Trap"] = { "Chaser Trap", "Honey Trap" },
    -- Everything in the inventory is swapped out for something else.
    ["Where'd Your Inventory Go? Trap"] = {
        "Items to Bombs", "Where'd Your Inventory Go? Trap",
    },
    ["Special Forces Trap"] = { "Army Trap" },
    ["Hostile NPC Trap"] = { "Police Trap" },
    -- Disarm is what Butterfingers does: everything in Frank's hands drops.
    ["Butterfingers Trap"] = { "Disarm Trap", "Eject Ability" },
    ["Bald Trap"] = { "Bald Trap", "No Hat Trap" },
    ["Bonk Trap"] = {
        "Bonk Trap", "Banana Peel Trap", "Jump Trap", "Push Trap", "Slip Trap",
        "Spring Trap", "Squash Trap", "Thwimp Trap",
    },
    ["Tiny Trap"] = { "Tiny Trap", "Shrink Trap" },
    -- Anodyne and Noita set HP to 1 under this name. Instant Death Trap is the
    -- real instant kill and stays unmapped.
    ["1 HP Trap"] = { "One Hit KO", "One Hit Trap" },
    -- The speed-up counterpart of Skipped Leg Day. "Fast" alone is a
    -- different (camera/time) trap on the sheet, so only the Trap names.
    ["Cardio Trap"] = { "Fast Trap", "Speed Up Trap" },
    -- Giant Trap: the sheet has no grow/giant name to send, but wide and fat
    -- are close enough to receive.
    ["Giant Trap"] = { "W I D E Trap", "Fat CJ Trap" },
    ["Night Trap"] = { "Nightmare Trap" },
    ["Invisibility Trap"] = { "Invisible Trap", "Invisibility Trap" },
    -- The cultists' powder: gas, stun and sleep names all knock Frank out.
    ["Knockout Gas Trap"] = {
        "Gas Trap", "Stinky Trap", "Stun Trap", "Sleep Trap", "Sleeptoad",
    },
    -- Sent home to the Security Room, followers left where they are.
    ["Teleport Trap"] = { "Teleport Trap", "Bubble Trap", "Home Trap" },
}

-- Standard name -> our trap.
M.RECEIVE = {}
for ours, names in pairs(RECEIVE_GROUPS) do
    for _, std in ipairs(names) do
        assert(M.RECEIVE[std] == nil, "TrapLink name mapped twice: " .. std)
        M.RECEIVE[std] = ours
    end
end
-- Our own item names, for the traps that send under them. A trap whose name
-- is already taken by another receive group stays unsent rather than lie.
for ours, sent in pairs(M.SEND) do
    if sent == ours then
        if M.RECEIVE[ours] == nil or M.RECEIVE[ours] == ours then
            M.RECEIVE[ours] = ours
        else
            M.log.warn(string.format("%s: own name already receives as %s -- not linked out",
                ours, tostring(M.RECEIVE[ours])))
            M.SEND[ours] = nil
        end
    end
end
-- The rule: what we send for a trap comes back as that trap. A break here is
-- a mapping mistake (test_traplink catches it); in game that trap just stops
-- linking out instead of taking the module down.
for ours, sent in pairs(M.SEND) do
    if M.RECEIVE[sent] ~= ours then
        M.log.warn(string.format("%s sends %s but receives it as %s -- not linked out",
            ours, sent, tostring(M.RECEIVE[sent])))
        M.SEND[ours] = nil
    end
end

-- Damage that is NOT ours to rebroadcast over DamageLink, with how long the
-- DamageLink sender is muted for while it runs.
local MUTE_DAMAGE = {
    ["Damage Player Trap"] = 3,
    ["Stomach Ache Trap"]  = 60,
    ["1 HP Trap"]          = 3,
}

------------------------------------------------------------
-- State
------------------------------------------------------------

local enabled = false
local allowed = nil     -- set of our trap names the yaml allows; nil = no filter

function M.is_enabled() return enabled end

function M.set_enabled(on)
    enabled = (on == true)
    M.log("TrapLink " .. (enabled and "on" or "off"))
end

--- slot_data.enabled_traps: the list of trap names the player's yaml allows.
--- Anything else is refused on receipt. nil/non-table leaves it unfiltered.
function M.set_enabled_traps(list)
    if type(list) ~= "table" then allowed = nil; return end
    allowed = {}
    for k, v in pairs(list) do
        if type(v) == "string" then allowed[v] = true
        elseif type(k) == "string" and v == true then allowed[k] = true end
    end
end

function M.allows(trap)
    return allowed == nil or allowed[trap] == true
end

------------------------------------------------------------
-- Sending
------------------------------------------------------------

--- Called by TrapBank after an item trap fired cleanly.
function M.on_item_fired(trap)
    if not enabled then return end
    local std = M.SEND[trap]
    if not std then return end
    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    if Bridge and Bridge.send_trap_link then
        Bridge.send_trap_link(std)
    end
end

------------------------------------------------------------
-- Receiving
------------------------------------------------------------

--- A TrapLink bounce arrived (Bridge has already dropped our own echo).
--- Returns the trap of ours that was queued, or nil and why not.
function M.receive(trap_name, source)
    if not enabled then return nil, "off" end
    if type(trap_name) ~= "string" or trap_name == "" then return nil, "no name" end
    source = tostring(source or "someone")

    local ours = M.RECEIVE[trap_name]
    if not ours then
        M.log(string.format("'%s' from %s -- no equivalent, ignored", trap_name, source))
        return nil, "unmapped"
    end
    if not M.allows(ours) then
        M.log(string.format("'%s' from %s -- %s is not enabled in this slot, ignored",
            trap_name, source, ours))
        return nil, "disabled"
    end
    if not TrapBank.enqueue_link(ours, source) then return nil, "unregistered" end
    M.log(string.format("'%s' from %s -> %s", trap_name, source, ours))
    return ours
end

------------------------------------------------------------
-- TrapBank hooks
------------------------------------------------------------

local function before_link_fire(trap)
    local secs = MUTE_DAMAGE[trap]
    if not secs then return end
    local DL = package.loaded["DRAP/trackers/DamageLink"]
    if DL and DL.mute then DL.mute(secs) end
end

-- A timed trap already running is not stacked: the repeat waits (and expires
-- if it never gets a clear window).
local function link_gate(trap)
    local PB = package.loaded["DRAP/effects/PlayerBuffs"]
    if PB and PB.is_trap_active and PB.is_trap_active(trap) then return false end
    return true
end

function M.init()
    TrapBank.on_item_fired = M.on_item_fired
    TrapBank.on_link_fire = before_link_fire
    TrapBank.link_gate = link_gate
end

------------------------------------------------------------
-- Console
------------------------------------------------------------

--- Testing: arm without a server.
_G.drap_traplink = function(on)
    M.set_enabled(on ~= false)
end

--- Testing: receive a TrapLink as if another game had sent it. Needs
--- drap_traplink(true). The usual pacing and Frank-is-ready rules still apply.
_G.drap_traplink_receive = function(name, source)
    local ours, why = M.receive(name or "Damage Trap", source or "console")
    M.log("receive -> " .. tostring(ours or why))
end

_G.drap_traplink_status = function()
    M.log(string.format("enabled=%s pending=%d filter=%s",
        tostring(enabled), TrapBank.pending_links(),
        allowed and "slot yaml" or "none"))
    local Bridge = _G.AP and _G.AP.AP_BRIDGE
    if Bridge and Bridge.get_trap_link_tag then
        M.log("bounce tag: " .. tostring(Bridge.get_trap_link_tag()))
    end
end

return M
