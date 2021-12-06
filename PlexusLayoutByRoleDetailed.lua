--[[--------------------------------------------------------------------
    Copyright (C) 2014, 2018 Johnny C. Lam.
    See the file LICENSE.txt for copying permission.
--]]--------------------------------------------------------------------

--[[
    PlexusLayoutByRoleDetailed is a Plexus layout plugin that groups members as tanks,
    melee DPS, healers, and ranged DPS.

    PlexusLayoutByRoleDetailed manipulates the "nameList" attribute of layout groups
    used by the secure group headers in PlexusLayout to place members into
    different groups based on their role.
--]]

-- GLOBALS: Plexus

local Plexus = _G.Plexus
local PlexusLayoutByRoleDetailed = Plexus:NewModule("PlexusLayoutByRoleDetailed")

local ceil = math.ceil
local floor = math.floor
local ipairs = ipairs
local pairs = pairs
--local setmetatable = setmetatable
local strsub = string.sub
local tconcat = table.concat
local tinsert = table.insert
local tonumber = tonumber
local wipe = _G.wipe
-- GLOBALS: _G
-- GLOBALS: GetClassInfo
-- GLOBALS: GetInstanceInfo
-- GLOBALS: LibStub
-- GLOBALS: UnitGUID
-- GLOBALS: UnitIsPlayer
local MAX_RAID_MEMBERS = _G.MAX_RAID_MEMBERS -- FrameXML/RaidFrame.lua
local MEMBERS_PER_RAID_GROUP = _G.MEMBERS_PER_RAID_GROUP -- FrameXML/RaidFrame.lua

local PlexusLayout = Plexus:GetModule("PlexusLayout")
local PlexusRoster = Plexus:GetModule("PlexusRoster")
local UnitIsPlayer = _G.UnitIsPlayer
local GetInstanceInfo = _G.GetInstanceInfo
local LibStub = _G.LibStub
local LGIST = LibStub:GetLibrary("LibGroupInSpecT-1.1")

local GetClassInfo = _G.GetClassInfo

-- The localized string table.
local L = Plexus.L
do
    L["Group"] = _G.GROUP
    L["Healer"] = _G.HEALER
    L["Tank"] = _G.TANK
end

-- Pet layout group.
local petGroup = {
    isPetGroup = true,
    groupBy = "CLASS",
    groupingOrder = "HUNTER,WARLOCK,MAGE,DEATHKNIGHT,DRUID,PRIEST,SHAMAN,MONK,PALADIN,DEMONHUNTER,ROGUE,WARRIOR",
}

---------------------------------------------------------------------

-- Layout table registered with PlexusLayout.
PlexusLayoutByRoleDetailed.layout = {}

-- Map GUIDs to roles ("tank", "melee", "healer", "ranged").
PlexusLayoutByRoleDetailed.roleByGUID = {}

do
    PlexusLayoutByRoleDetailed.defaultDB = {
        debug = false,
        -- Map layout groups to raid role.
        role = {
            [1] = "tank",
            [2] = "melee",
            [3] = "healer",
            [4] = "ranged",
        },
        -- Healer classes that should be displayed in the melee role.
        meleeHealer = {},
        -- Ignore Blizzard roles.
        useBlizzardRole = false,
    }

    --[[
        1st group: [dropdown] (tank/melee/healer/ranged)
        2nd group: [dropdown] (tank/melee/healer/ranged)
        3rd group: [dropdown] (tank/melee/healer/ranged)
        4th group: [dropdown] (tank/melee/healer/ranged)

        Healers to display as melee role:
        [ ] Druid
        [ ] Monk
        [ ] Paladin
        [ ] Priest
        [ ] Shaman
    --]]

    local roleSelect = {
        tank = L["Tank"],
        melee = L["Melee"],
        healer = L["Healer"],
        ranged = L["Ranged"],
    }

    local healerClassLocalization = {
        PALADIN = GetClassInfo(2),
        PRIEST = GetClassInfo(5),
        SHAMAN = GetClassInfo(7),
        MONK = GetClassInfo(10),
        DRUID = GetClassInfo(11),
    }

    PlexusLayoutByRoleDetailed.options = {
        name = L["Raid Role Groups"],
        type = "group",
        args = {
            roles = {
                name = L["Group Roles"],
                desc = L["Assign roles to display in each group."],
                order = 10,
                type = "group",
                inline = true,
                get = function(info)
                    -- Strip "group" from "groupN".
                    local index = tonumber(strsub(info[#info], 6))
                    return PlexusLayoutByRoleDetailed.db.profile.role[index]
                end,
                set = function(info, v)
                    -- Strip "group" from "groupN".
                    local index = tonumber(strsub(info[#info], 6))
                    PlexusLayoutByRoleDetailed.db.profile.role[index] = v
                    PlexusLayoutByRoleDetailed:UpdateLayout()
                end,
                args = {
                    group1 = {
                        name = L["Group"] .. " 1",
                        order = 10,
                        type = "select",
                        values = roleSelect,
                    },
                    group2 = {
                        name = L["Group"] .. " 2",
                        order = 20,
                        type = "select",
                        values = roleSelect,
                    },
                    group3 = {
                        name = L["Group"] .. " 3",
                        order = 30,
                        type = "select",
                        values = roleSelect,
                    },
                    group4 = {
                        name = L["Group"] .. " 4",
                        order = 40,
                        type = "select",
                        values = roleSelect,
                    },
                },
            },
            meleeHealer = {
                name = L["Melee healers"],
                desc = L["Healer classes to display in the melee role."],
                order = 20,
                type = "multiselect",
                values = healerClassLocalization,
                get = function(_, k)
                    return PlexusLayoutByRoleDetailed.db.profile.meleeHealer[k]
                end,
                set = function(_, k, v)
                    PlexusLayoutByRoleDetailed.db.profile.meleeHealer[k] = v
                    PlexusLayoutByRoleDetailed:UpdateRoster()
                end,
            },
            useBlizzardRole = {
                name = L["Use Blizzard role"],
                desc = L["Enable the Blizzard-assigned role to supersede the specialization role."],
                order = 30,
                type = "toggle",
                get = function(_)
                    return PlexusLayoutByRoleDetailed.db.profile.useBlizzardRole
                end,
                set = function(_, value)
                    PlexusLayoutByRoleDetailed.db.profile.useBlizzardRole = value
                    PlexusLayoutByRoleDetailed:UpdateRoster()
                end,
            },
        },
    }
end

---------------------------------------------------------------------

-- Insert the value at the rightmost insertion point of a sorted array using
-- binary search.  Returns the array index at which the value was inserted.
-- Binary search algorithm pseudocode from: http://rosettacode.org/wiki/Binary_search
local function binaryInsert(t, value)
    local low, high = 1, #t
    while low <= high do
        -- invariants: value >= t[i] for all i < low
        --             value < t[i] for all i > high
        local mid = floor((low + high) / 2)
        if value and t[mid] and value < t[mid] then
            high = mid - 1
        else
            low = mid + 1
        end
    end
    tinsert(t, low, value)
    return low
end

-- Returns true if the unit is on the roster and is a player (not a pet or vehicle).
local function IsGroupMember(guid, unit)
    return PlexusRoster:IsGUIDInGroup(guid) and UnitIsPlayer(unit)
end

---------------------------------------------------------------------

function PlexusLayoutByRoleDetailed:PostInitialize()
    local layout = self.layout
    layout.name = L["By Raid Role Detailed"]
    layout.defaults = {
        sortMethod = "NAME",
        unitsPerColumn = MEMBERS_PER_RAID_GROUP,
    }
    -- Initialize empty group for each role.
    for i in ipairs(self.db.profile.role) do
        layout[i] = {}
    end
    PlexusLayout:AddLayout("ByRaidRoleDetailed", layout)
end

function PlexusLayoutByRoleDetailed:PostEnable()
    PlexusLayoutByRoleDetailed:RegisterEvent("INSPECT_READY", "InspectReady")
    LGIST.RegisterCallback(self, "GroupInSpecT_Update", "OnUnitRoleChanged")
    LGIST.RegisterCallback(self, "GroupInSpecT_Update", "OnUnitJoined")
    --LGIST.Registercallback(self, "GroupInSpecT_Remove", "OnUnitLeft")
end

function PlexusLayoutByRoleDetailed:PostDisable()
    LGIST.UnregisterCallback(self, "GroupInSpecT_Update")
    LGIST.UnregisterCallback(self, "GroupInSpecT_Update")
    --LGIST.UnregisterCallback(self, "GroupInSpecT_Remove")
end

function PlexusLayoutByRoleDetailed:InspectReady(event, guid)
    LGIST:Rescan(guid)
end

function PlexusLayoutByRoleDetailed:OnUnitRoleChanged(event, guid, unit, oldRole, newRole)
    if IsGroupMember(guid, unit) then
        self:Debug("OnUnitRoleChanged", event, guid, unit, oldRole, newRole)
        local role = self:ToRaidRole(guid, newRole)
        self:UpdateRole(guid, role)
        self:UpdateLayout()
    end
end

function PlexusLayoutByRoleDetailed:OnUnitJoined(event, guid, unit)
    if IsGroupMember(guid, unit) then
        self:Debug("OnUnitJoined", event, guid, unit)
        local info = LGIST:GetCachedInfo(guid)
        local lgistRole = info.spec_role_detailed
        local role = self:ToRaidRole(guid, lgistRole)
        self:UpdateRole(guid, role)
        self:UpdateLayout()
    end
end

function PlexusLayoutByRoleDetailed:OnUnitLeft(event, guid)
    self:Debug("OnUnitLeft", event, guid)
    self.roleByGUID[guid] = nil
    self:UpdateLayout()
end

---------------------------------------------------------------------

-- Convert the role associated with the GUID to the raid role,
-- accounting for melee healers and Blizzard roles.
function PlexusLayoutByRoleDetailed:ToRaidRole(guid, role)
    local raidRole = role or ""
    -- Adjust role if this healer is a "melee healer".
    if raidRole == "healer" then
        local info = LGIST:GetCachedInfo(guid)
        local class = info.class
        if class and self.db.profile.meleeHealer[class] then
            raidRole = "melee"
        end
    end
    -- Prefer the Blizzard role for tanks and healers if requested.
    if self.db.profile.useBlizzardRole then
        local info = LGIST:GetCachedInfo(guid)
        local blizzardRole = info.spec_role
        if blizzardRole == "TANK" then
            raidRole = "tank"
        elseif blizzardRole == "HEALER" then
            raidRole = "healer"
        end
    end
    -- There is no "none" raid role, so convert all "none" into "ranged".
    if raidRole == "none" then
        raidRole = "ranged"
    end
    return raidRole
end

-- Update the role for the GUID.
function PlexusLayoutByRoleDetailed:UpdateRole(guid, role)
    local oldRole = self.roleByGUID[guid]
    if oldRole ~= role then
        self:Debug("UpdateRole", guid, oldRole, role)
        self.roleByGUID[guid] = role
    end
end

-- Update the roles of the entire roster.
function PlexusLayoutByRoleDetailed:UpdateRoster()
    local updated = false
    for guid, oldRole in pairs(self.roleByGUID) do
        local info = LGIST:GetCachedInfo(guid)
        local lgistRole = info.spec_role_detailed
        local role = self:ToRaidRole(guid, lgistRole)
        updated = updated or (oldRole ~= role)
        self:UpdateRole(guid, role)
    end
    if updated then
        self:UpdateLayout()
    end
end

do
    local t = {}	-- scratch array for NameList()

    -- Returns a string of names in that role sorted alphabetically and
    -- separated by commas.
    function PlexusLayoutByRoleDetailed:NameList(role)
        wipe(t)
        for guid, guidRole in pairs(self.roleByGUID) do
            if guidRole == role then
                local name = PlexusRoster:GetFullNameByGUID(guid)
                binaryInsert(t, name)
            end
        end
        return tconcat(t, ",")
    end
end

function PlexusLayoutByRoleDetailed:UpdateLayout()
    self:Debug("UpdateLayout")
    -- Get the maximum number of players in the group.
    local _, instanceType, _, _, maxPlayers, _, _, _, instanceGroupSize = GetInstanceInfo()
    if instanceType == "none" then
        maxPlayers = MAX_RAID_MEMBERS
    else
        maxPlayers = maxPlayers < instanceGroupSize and maxPlayers or instanceGroupSize
    end
    local unitsPerColumn = MEMBERS_PER_RAID_GROUP
    local maxColumns = ceil(maxPlayers / unitsPerColumn)

    -- Update the default attributes.
    local defaults = self.layout.defaults
    defaults.unitsPerColumn = unitsPerColumn
    defaults.maxColumns = maxColumns

    -- Update the nameList attribute in each layout group.
    for i, role in ipairs(self.db.profile.role) do
        local group = self.layout[i]
        group.nameList = self:NameList(role)
    end

    -- Add the pet group if selected.
    local numGroups = #self.db.profile.role
    if PlexusLayout.db.profile.showPets then
        self.layout[numGroups + 1] = petGroup
    else
        self.layout[numGroups + 1] = nil
    end

    -- Apply changes.
    PlexusLayout:ReloadLayout()
end