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
-- Convicts Respawn and Special Forces are never mapped: one needs a scoop
-- item, the other flips the whole mall's enemy layout.
--
-- Names are the exact strings on the TrapLink sheet. A name that is not in
-- RECEIVE below is ignored (logged), which is the protocol's expectation.

local Shared = require("DRAP/Shared")
local TrapBank = require("DRAP/TrapBank")

local M = Shared.create_module("TrapLink")

------------------------------------------------------------
-- Mapping
------------------------------------------------------------

-- Our trap -> the standard name we send. A trap with no entry does not send.
-- Not sent: Convicts Respawn, Last Shot, Where'd Your Inventory Go?,
-- Goddamnit Donut!, Boxers, Skipped Arm Day, Giant (no honest match on the sheet).
M.SEND = {
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
}

-- Our trap -> the standard names that fire it.
local RECEIVE_GROUPS = {
    ["Damage Player Trap"] = {
        "Damage Trap", "Electrocution Trap", "Burn Trap", "Fire Trap",
        "Explosion Trap", "Bomb", "Bomb Trap", "TNT Trap", "TNT Barrel Trap",
        "Meteor Trap", "Spike Ball Trap", "Energy Drain Trap",
        "Mana Drain Trap", "Rockfall Trap", "Radiation Trap",
    },
    ["Stomach Ache Trap"] = {
        "Poison Trap", "Poison Mushroom", "Food Poisoning Trap", "Toxin Trap",
        "Gas Trap", "Stinky Trap", "Poisontoad", "Guest Vomiting Trap",
    },
    -- Frank cannot be frozen, so the freeze family becomes the slow.
    ["Skipped Leg Day Trap"] = {
        "Slowness Trap", "Slow Trap", "Sticky Floor Trap", "Sticky Hands Trap",
        "Tar Trap", "Tarr Trap", "Iron Boots Trap", "Sinking Trap",
        "Underwater Trap",
        "Freeze Trap", "Frozen Trap", "Ice Trap", "Ice Floor Trap",
        "Frost Trap", "Paralyze Trap", "Paralysis Trap", "Stun Trap",
        "Chaos Control Trap", "Sleep Trap", "Sleeptoad", "Confuse Trap",
        "Confusion Trap", "Confound Trap",
    },
    ["Skipped Arm Day Trap"] = {
        "Disarm Trap", "Resistance Trap", "No Guarding", "Double Damage",
    },
    ["Potty Mouth Trap"] = {
        "Yap Trap", "Laughter Trap", "Spam Trap", "Taunt Trap", "Hey! Trap",
        "Help Trap", "Get Out Trap", "Whoops! Trap", "Text Trap", "Phone Trap",
        "Literature Trap", "Exposition Trap", "Tutorial Trap", "Tip Trap",
        "Trivia Trap", "Cutscene Trap",
        "Aaa Trap", "E. Gadd Ramblings", "Wailnard",
    },
    ["Oops More Zombies Trap"] = {
        "Bee Trap", "Army Trap", "Summon Trap", "Ghost", "Spooky Time",
        "Guest Spawn Trap",
        "Buyon Trap", "Person Trap", "Ninja Trap", "Dead Ringer Trap",
        "Monkey Trap", "Flint Trap", "Paratoad", "Animal Trap", "Frog Trap",
    },
    ["Zombait Trap"] = { "Chaser Trap", "Fear Trap", "Honey Trap" },
    ["Hostile NPC Trap"] = { "Police Trap" },
    ["Butterfingers Trap"] = {
        "Empty Item Box Trap", "Items to Bombs", "Tool Swap Trap",
        "Gadget Shuffle Trap", "Eject Ability",
    },
    ["Bald Trap"] = { "Bald Trap", "No Hat Trap" },
    ["Bonk Trap"] = {
        "Bonk Trap", "Banana Peel Trap", "Banana Trap", "Slip Trap",
        "Push Trap", "Spring Trap", "Squash Trap", "Thwimp Trap", "Jump Trap",
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
