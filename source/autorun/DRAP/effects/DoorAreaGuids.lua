-- DRAP/effects/DoorAreaGuids.lua
-- SignBoardUI.Element.mMessageId Guid -> area-name catalog. Used by
-- DoorPromptOverlay to recognize door-prompt elements and look up the
-- redirected destination. See docs/reframework/features/door_prompt_overlay.md
-- for capture method + how to add new entries.

local M = {}

-- Forward map: Guid -> display name. The elevator examine-button entry is
-- kept here for catalog completeness but excluded from IS_DOOR_GUID below.
M.GUID_TO_NAME = {
    ["9bddc2b5-d770-447d-aeb4-133ab3079e9c"] = "Heliport",
    ["111e6d27-4ff4-4044-b6da-8b25eea4303a"] = "Security Room",
    ["058a2b24-c2f1-4269-b220-faee9174682b"] = "Rooftop",
    ["3f700ed1-2214-493d-9ce2-721dc99ed1a7"] = "Warehouse",
    ["e0b317e3-7ccd-4723-9103-321910648b3a"] = "Paradise Plaza",
    ["bc967804-b1cb-4acf-97ba-39a4b35a2226"] = "Colby's Movieland",
    ["10f4fa91-d7ba-4f90-8d1e-4bb32c273554"] = "Leisure Park",
    ["0d3f4daa-5c91-423c-b5ac-4ac1ee0cbcff"] = "North Plaza",
    ["19280413-0a02-474f-aba7-be29664a4433"] = "Crislip's Home Saloon",
    ["8060168f-eb6d-473b-a0a5-8d3daed5b8ff"] = "Food Court",
    ["f777fa5e-403f-4e31-9d3d-71232e1fab87"] = "Wonderland Plaza",
    ["c7439705-4e4a-40aa-87c2-0d1725bed17f"] = "Al Fresca Plaza",
    ["a7cc0769-fd79-4a12-af2f-0c049fd8ea03"] = "Entrance Plaza",
    ["1681336a-70ee-4ed3-be50-354e011999cb"] = "Seon's Food and Stuff",
    ["300b24ac-5a42-4066-ac67-3fbed2221c29"] = "Maintenance Tunnel",
    ["a0853b54-526c-43bd-a409-969d8c21e9bb"] = "Carlito's Hideout",
    ["edf988ca-f3b8-4f59-b228-ff1c96ed6ac5"] = "Elevator - Examine button",
}

-- Reverse map: display name -> Guid (derived).
M.NAME_TO_GUID = {}
for guid, name in pairs(M.GUID_TO_NAME) do
    M.NAME_TO_GUID[name] = guid
end

-- Set of door-transition Guids (excludes non-transition interactions).
M.IS_DOOR_GUID = {}
for _, name in ipairs({
    "Heliport", "Security Room", "Rooftop", "Warehouse",
    "Paradise Plaza", "Colby's Movieland", "Leisure Park", "North Plaza",
    "Crislip's Home Saloon", "Food Court", "Wonderland Plaza",
    "Al Fresca Plaza", "Entrance Plaza", "Seon's Food and Stuff",
    "Maintenance Tunnel", "Carlito's Hideout",
}) do
    local guid = M.NAME_TO_GUID[name]
    if guid then M.IS_DOOR_GUID[guid] = true end
end

return M
