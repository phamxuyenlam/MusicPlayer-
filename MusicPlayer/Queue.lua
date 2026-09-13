--[[
    Queue.lua
    ------------------------------------------------------------
    Queue core for MusicPlayer.lua

    Responsibilities:
        - Store tracks and the current position.
        - Add / insert / remove / move tracks.
        - Next / previous navigation.
        - Shuffle while preserving a recoverable order.
        - Repeat mode state (Off / One / All).
        - Play-next / play-last helpers.
        - Queue history.
        - Events for Ui.lua / MusicPlayer.lua.
        - Snapshot / serialization-friendly state.

    Design goal:
        Keep this module independent from playback. It NEVER talks
        directly to an audio backend.

    Expected Track shape:
        {
            id = "...",
            title = "...",
            artist = "...",
            duration = 123,
            thumbnail = "...",
            source = "youtube",
            ...
        }
--]]

local Queue = {}
Queue.__index = Queue

local VALID_REPEAT = {
    Off = true,
    One = true,
    All = true,
}

local DEFAULTS = {
    HistoryLimit = 100,
    Shuffle = false,
    RepeatMode = "Off",
    AllowDuplicates = true,
}

local function copy(value, depth)
    depth = depth or 0

    if depth > 8 then
        return value
    end

    if type(value) ~= "table" then
        return value
    end

    local result = {}

    for k, v in pairs(value) do
        result[copy(k, depth + 1)] = copy(v, depth + 1)
    end

    return result
end

local function normalizeTrack(track)
    if type(track) == "string" then
        return {
            id = track,
            url = track,
            title = track,
        }
    end

    if type(track) ~= "table" then
        return nil, "Track must be a string or table"
    end

    local result = copy(track)

    result.id = result.id
        or result.videoId
        or result.url
        or result.path
        or result.title

    result.title = result.title
        or result.name
        or result.id
        or "Unknown Track"

    return result
end

local function getTrackKey(track)
    if type(track) ~= "table" then
        return tostring(track)
    end

    return tostring(
        track.id
        or track.videoId
        or track.url
        or track.path
        or track.title
    )
end

local function removeAt(list, index)
    if index < 1 or index > #list then
        return nil
    end

    return table.remove(list, index)
end

local function clampIndex(index, minimum, maximum)
    if index < minimum then
        return minimum
    end

    if index > maximum then
        return maximum
    end

    return index
end

local function randomInt(minimum, maximum)
    if minimum >= maximum then
        return minimum
    end

    return math.random(minimum, maximum)
end

function Queue.new(options)
    local self = setmetatable({}, Queue)

    options = options or {}

    self.Config = {}

    for key, value in pairs(DEFAULTS) do
        self.Config[key] = value
    end

    for key, value in pairs(options) do
        self.Config[key] = value
    end

    self.Tracks = {}
    self.CurrentIndex = 0

    -- When shuffle is enabled, Tracks remains the active playback
    -- order. OriginalTracks preserves the user's logical order so
    -- shuffle can later be disabled/rebuilt safely.
    self.OriginalTracks = {}
    self.ShuffleEnabled = self.Config.Shuffle == true
    self.RepeatMode = VALID_REPEAT[self.Config.RepeatMode]
        and self.Config.RepeatMode
        or "Off"

    -- Queue history stores indexes/track snapshots, not references
    -- that may later be mutated by UI code.
    self.History = {}

    self.Events = {}

    self._nextOverrides = {}
    self._destroyed = false

    return self
end

----------------------------------------------------------------
-- Events
----------------------------------------------------------------

function Queue:On(eventName, callback)
    assert(type(eventName) == "string", "eventName must be a string")
    assert(type(callback) == "function", "callback must be a function")

    self.Events[eventName] = self.Events[eventName] or {}
    table.insert(self.Events[eventName], callback)

    local disconnected = false

    return {
        Disconnect = function()
            if disconnected then
                return
            end

            disconnected = true

            local listeners = self.Events[eventName]
            if not listeners then
                return
            end

            for i = #listeners, 1, -1 do
                if listeners[i] == callback then
                    table.remove(listeners, i)
                end
            end
        end,
    }
end

function Queue:Emit(eventName, ...)
    local listeners = self.Events[eventName]
    if not listeners then
        return
    end

    for i = #listeners, 1, -1 do
        local callback = listeners[i]

        if type(callback) ~= "function" then
            table.remove(listeners, i)
        else
            local ok = pcall(callback, ...)
            if not ok then
                -- Queue events must never break queue operations.
            end
        end
    end
end

----------------------------------------------------------------
-- Basic information
----------------------------------------------------------------

function Queue:GetLength()
    return #self.Tracks
end

function Queue:IsEmpty()
    return #self.Tracks == 0
end

function Queue:GetCurrentIndex()
    return self.CurrentIndex
end

function Queue:SetCurrentIndex(index, emit)
    if #self.Tracks == 0 then
        self.CurrentIndex = 0
        return false, "Queue is empty"
    end

    index = tonumber(index)

    if not index then
        return false, "Index must be a number"
    end

    index = math.floor(index)

    if index < 1 or index > #self.Tracks then
        return false, "Index out of range"
    end

    local oldIndex = self.CurrentIndex
    self.CurrentIndex = index

    self:_recordCurrent()
    self:Emit("CurrentChanged", self:GetCurrent(), index, oldIndex)

    if emit ~= false then
        self:Emit("SelectionChanged", self:GetCurrent(), index)
    end

    return true, self:GetCurrent()
end

function Queue:GetCurrent()
    if self.CurrentIndex < 1 then
        return nil
    end

    return self.Tracks[self.CurrentIndex]
end

function Queue:Current()
    return self:GetCurrent()
end

function Queue:Peek()
    return self:GetCurrent()
end

function Queue:Get(index)
    if index == nil then
        return self:GetCurrent()
    end

    index = tonumber(index)

    if not index then
        return nil
    end

    return self.Tracks[math.floor(index)]
end

function Queue:GetAll()
    return self.Tracks
end

function Queue:GetTracks()
    return self.Tracks
end

function Queue:GetOriginalOrder()
    return self.OriginalTracks
end

function Queue:ToArray()
    local result = {}

    for index, track in ipairs(self.Tracks) do
        result[index] = copy(track)
    end

    return result
end

function Queue:GetCurrentPosition()
    return self.CurrentIndex
end

----------------------------------------------------------------
-- Track matching
----------------------------------------------------------------

function Queue:Find(trackOrId)
    local key = type(trackOrId) == "table"
        and getTrackKey(trackOrId)
        or tostring(trackOrId)

    for index, track in ipairs(self.Tracks) do
        if getTrackKey(track) == key then
            return index, track
        end
    end

    return nil
end

function Queue:Contains(trackOrId)
    return self:Find(trackOrId) ~= nil
end

----------------------------------------------------------------
-- Add / insert
----------------------------------------------------------------

function Queue:_canAdd(track)
    if self.Config.AllowDuplicates then
        return true
    end

    return not self:Contains(track)
end

function Queue:_syncOriginalAfterInsert(index, track)
    if self.ShuffleEnabled then
        -- During shuffle, insert into logical order too. This means
        -- disabling shuffle doesn't silently delete a newly added track.
        index = clampIndex(index, 1, #self.OriginalTracks + 1)
        table.insert(self.OriginalTracks, index, copy(track))
    else
        table.insert(self.OriginalTracks, index, copy(track))
    end
end

function Queue:Add(track, playNow)
    local normalized, err = normalizeTrack(track)

    if not normalized then
        return false, err
    end

    if not self:_canAdd(normalized) then
        return false, "Duplicate track is not allowed"
    end

    table.insert(self.Tracks, normalized)
    table.insert(self.OriginalTracks, copy(normalized))

    local index = #self.Tracks

    self:Emit("Added", normalized, index)
    self:Emit("Changed", self)

    if self.CurrentIndex == 0 then
        self.CurrentIndex = 1

        self:Emit(
            "CurrentChanged",
            self:GetCurrent(),
            1,
            0
        )
    end

    if playNow then
        self:SetCurrentIndex(index)
    end

    return true, normalized, index
end

function Queue:Enqueue(track, playNow)
    return self:Add(track, playNow)
end

function Queue:Push(track, playNow)
    return self:Add(track, playNow)
end

function Queue:Insert(index, track, playNow)
    local normalized, err = normalizeTrack(track)

    if not normalized then
        return false, err
    end

    if not self:_canAdd(normalized) then
        return false, "Duplicate track is not allowed"
    end

    index = tonumber(index)

    if not index then
        return false, "Index must be a number"
    end

    index = math.floor(index)
    index = clampIndex(index, 1, #self.Tracks + 1)

    table.insert(self.Tracks, index, normalized)
    table.insert(self.OriginalTracks, index, copy(normalized))

    if self.CurrentIndex == 0 then
        self.CurrentIndex = 1
    elseif index <= self.CurrentIndex then
        self.CurrentIndex += 1
    end

    self:Emit("Added", normalized, index)
    self:Emit("Changed", self)

    if playNow then
        self:SetCurrentIndex(index)
    else
        self:Emit("CurrentChanged", self:GetCurrent(), self.CurrentIndex)
    end

    return true, normalized, index
end

function Queue:AddNext(track)
    if self:IsEmpty() then
        return self:Add(track)
    end

    local target = self.CurrentIndex + 1
    return self:Insert(target, track)
end

function Queue:PlayNext(track)
    return self:AddNext(track)
end

function Queue:AddLast(track)
    return self:Add(track)
end

function Queue:PlayLast(track)
    return self:AddLast(track)
end

function Queue:AddMany(tracks, playNow)
    if type(tracks) ~= "table" then
        return false, "tracks must be a table"
    end

    local added = {}

    for _, track in ipairs(tracks) do
        local ok, normalized, index = self:Add(track, false)

        if not ok then
            return false, normalized, added
        end

        table.insert(added, {
            track = normalized,
            index = index,
        })
    end

    if playNow and #added > 0 then
        self:SetCurrentIndex(added[1].index)
    end

    self:Emit("BatchAdded", added)

    return true, added
end

----------------------------------------------------------------
-- Remove
----------------------------------------------------------------

function Queue:Remove(index)
    index = tonumber(index)

    if not index then
        return false, "Index must be a number"
    end

    index = math.floor(index)

    if index < 1 or index > #self.Tracks then
        return false, "Index out of range"
    end

    local removed = table.remove(self.Tracks, index)
    table.remove(self.OriginalTracks, math.min(index, #self.OriginalTracks))

    if #self.Tracks == 0 then
        self.CurrentIndex = 0
    elseif index < self.CurrentIndex then
        self.CurrentIndex -= 1
    elseif index == self.CurrentIndex then
        if self.CurrentIndex > #self.Tracks then
            self.CurrentIndex = #self.Tracks
        end
    end

    self:Emit("Removed", removed, index)
    self:Emit("Changed", self)

    return true, removed
end

function Queue:Delete(index)
    return self:Remove(index)
end

function Queue:RemoveTrack(trackOrId)
    local index = self:Find(trackOrId)

    if not index then
        return false, "Track not found"
    end

    return self:Remove(index)
end

function Queue:Clear()
    local oldTracks = self:ToArray()

    self.Tracks = {}
    self.OriginalTracks = {}
    self.CurrentIndex = 0
    self._nextOverrides = {}

    self:Emit("Cleared", oldTracks)
    self:Emit("Changed", self)

    return true
end

function Queue:Reset()
    return self:Clear()
end

----------------------------------------------------------------
-- Move / reorder
----------------------------------------------------------------

function Queue:Move(fromIndex, toIndex)
    fromIndex = tonumber(fromIndex)
    toIndex = tonumber(toIndex)

    if not fromIndex or not toIndex then
        return false, "Indexes must be numbers"
    end

    fromIndex = math.floor(fromIndex)
    toIndex = math.floor(toIndex)

    if fromIndex < 1 or fromIndex > #self.Tracks then
        return false, "Source index out of range"
    end

    if #self.Tracks == 0 then
        return false, "Queue is empty"
    end

    toIndex = clampIndex(toIndex, 1, #self.Tracks)

    if fromIndex == toIndex then
        return true, self.Tracks[toIndex]
    end

    local track = table.remove(self.Tracks, fromIndex)
    table.insert(self.Tracks, toIndex, track)

    -- Move the logical-order copy when shuffle is disabled.
    if not self.ShuffleEnabled then
        local original = table.remove(self.OriginalTracks, fromIndex)
        table.insert(self.OriginalTracks, toIndex, original)
    end

    if self.CurrentIndex == fromIndex then
        self.CurrentIndex = toIndex
    elseif fromIndex < self.CurrentIndex and toIndex >= self.CurrentIndex then
        self.CurrentIndex -= 1
    elseif fromIndex > self.CurrentIndex and toIndex <= self.CurrentIndex then
        self.CurrentIndex += 1
    end

    self:Emit(
        "Moved",
        track,
        fromIndex,
        toIndex
    )

    self:Emit("Changed", self)

    return true, track
end

function Queue:MoveToTop(index)
    return self:Move(index, 1)
end

function Queue:MoveToBottom(index)
    return self:Move(index, #self.Tracks)
end

----------------------------------------------------------------
-- Navigation
----------------------------------------------------------------

function Queue:_getNextIndex()
    local count = #self.Tracks

    if count == 0 then
        return nil
    end

    if self.CurrentIndex < 1 then
        return 1
    end

    if self.ShuffleEnabled then
        local candidates = {}

        for index = 1, count do
            if index ~= self.CurrentIndex then
                candidates[#candidates + 1] = index
            end
        end

        if #candidates > 0 then
            return candidates[randomInt(1, #candidates)]
        end
    end

    local nextIndex = self.CurrentIndex + 1

    if nextIndex <= count then
        return nextIndex
    end

    if self.RepeatMode == "All" then
        return 1
    end

    return nil
end

function Queue:_getPreviousIndex()
    local count = #self.Tracks

    if count == 0 then
        return nil
    end

    if self.CurrentIndex < 1 then
        return count
    end

    local previousIndex = self.CurrentIndex - 1

    if previousIndex >= 1 then
        return previousIndex
    end

    if self.RepeatMode == "All" then
        return count
    end

    return nil
end

function Queue:GetNext()
    local index = self:_getNextIndex()
    return index and self.Tracks[index], index
end

function Queue:GetPrevious()
    local index = self:_getPreviousIndex()
    return index and self.Tracks[index], index
end

function Queue:PeekNext()
    return self:GetNext()
end

function Queue:PeekPrevious()
    return self:GetPrevious()
end

function Queue:Next()
    local track, index = self:GetNext()

    if not track then
        return nil, nil, "No next track"
    end

    local oldIndex = self.CurrentIndex
    self.CurrentIndex = index

    self:_recordCurrent()

    self:Emit(
        "CurrentChanged",
        track,
        index,
        oldIndex
    )

    self:Emit("Changed", self)

    return track, index
end

function Queue:Previous()
    local track, index = self:GetPrevious()

    if not track then
        return nil, nil, "No previous track"
    end

    local oldIndex = self.CurrentIndex
    self.CurrentIndex = index

    self:_recordCurrent()

    self:Emit(
        "CurrentChanged",
        track,
        index,
        oldIndex
    )

    self:Emit("Changed", self)

    return track, index
end

----------------------------------------------------------------
-- Repeat
----------------------------------------------------------------

function Queue:SetRepeat(mode)
    if not VALID_REPEAT[mode] then
        return false, "Repeat mode must be Off, One, or All"
    end

    local oldMode = self.RepeatMode
    self.RepeatMode = mode

    self:Emit("RepeatChanged", mode, oldMode)
    self:Emit("Changed", self)

    return true, mode
end

function Queue:SetRepeatMode(mode)
    return self:SetRepeat(mode)
end

function Queue:GetRepeat()
    return self.RepeatMode
end

function Queue:GetRepeatMode()
    return self.RepeatMode
end

function Queue:CycleRepeat()
    local nextMode

    if self.RepeatMode == "Off" then
        nextMode = "All"
    elseif self.RepeatMode == "All" then
        nextMode = "One"
    else
        nextMode = "Off"
    end

    return self:SetRepeat(nextMode)
end

function Queue:IsRepeatOne()
    return self.RepeatMode == "One"
end

function Queue:IsRepeatAll()
    return self.RepeatMode == "All"
end

----------------------------------------------------------------
-- Shuffle
----------------------------------------------------------------

function Queue:_shuffleArray(array)
    for i = #array, 2, -1 do
        local j = randomInt(1, i)
        array[i], array[j] = array[j], array[i]
    end
end

function Queue:SetShuffle(enabled)
    enabled = enabled == true

    if enabled == self.ShuffleEnabled then
        return true
    end

    if enabled then
        -- Save currently ordered tracks before shuffling.
        self.OriginalTracks = self:ToArray()

        local currentTrack = self:GetCurrent()

        self:_shuffleArray(self.Tracks)

        -- Keep the current track at the current slot when possible.
        if currentTrack then
            local currentKey = getTrackKey(currentTrack)

            local foundIndex

            for index, track in ipairs(self.Tracks) do
                if getTrackKey(track) == currentKey then
                    foundIndex = index
                    break
                end
            end

            if foundIndex and self.CurrentIndex >= 1 then
                self.Tracks[foundIndex], self.Tracks[self.CurrentIndex] =
                    self.Tracks[self.CurrentIndex], self.Tracks[foundIndex]
            end
        end
    else
        local currentTrack = self:GetCurrent()
        local currentKey = currentTrack and getTrackKey(currentTrack)

        self.Tracks = self:ToArray(self.OriginalTracks)

        if #self.OriginalTracks > 0 then
            self.Tracks = {}

            for _, track in ipairs(self.OriginalTracks) do
                table.insert(self.Tracks, copy(track))
            end
        end

        self.CurrentIndex = 0

        if currentKey then
            for index, track in ipairs(self.Tracks) do
                if getTrackKey(track) == currentKey then
                    self.CurrentIndex = index
                    break
                end
            end
        end

        if self.CurrentIndex == 0 and #self.Tracks > 0 then
            self.CurrentIndex = 1
        end
    end

    self.ShuffleEnabled = enabled

    self:Emit("ShuffleChanged", enabled)
    self:Emit("Changed", self)

    return true, enabled
end

function Queue:ShuffleEnabled(enabled)
    return self:SetShuffle(enabled)
end

function Queue:ToggleShuffle()
    return self:SetShuffle(not self.ShuffleEnabled)
end

function Queue:IsShuffleEnabled()
    return self.ShuffleEnabled
end

function Queue:Shuffle()
    -- Public explicit shuffle action.
    if #self.Tracks < 2 then
        return false, "Not enough tracks to shuffle"
    end

    if not self.ShuffleEnabled then
        return self:SetShuffle(true)
    end

    local current = self:GetCurrent()
    local currentKey = current and getTrackKey(current)

    self:_shuffleArray(self.Tracks)

    if currentKey then
        for index, track in ipairs(self.Tracks) do
            if getTrackKey(track) == currentKey then
                if self.CurrentIndex ~= index and self.CurrentIndex >= 1 then
                    self.Tracks[index], self.Tracks[self.CurrentIndex] =
                        self.Tracks[self.CurrentIndex], self.Tracks[index]
                end
                break
            end
        end
    end

    self:Emit("Shuffled", self.Tracks)
    self:Emit("Changed", self)

    return true
end

----------------------------------------------------------------
-- Queue jump helpers
----------------------------------------------------------------

function Queue:Jump(index)
    return self:SetCurrentIndex(index)
end

function Queue:PlayIndex(index)
    return self:SetCurrentIndex(index)
end

function Queue:First()
    if #self.Tracks == 0 then
        return false, "Queue is empty"
    end

    return self:SetCurrentIndex(1)
end

function Queue:Last()
    if #self.Tracks == 0 then
        return false, "Queue is empty"
    end

    return self:SetCurrentIndex(#self.Tracks)
end

----------------------------------------------------------------
-- Play-next overrides
--
-- Useful for "Play Next" from UI without disturbing the normal
-- queue order.
----------------------------------------------------------------

function Queue:SetPlayNext(track)
    local normalized, err = normalizeTrack(track)

    if not normalized then
        return false, err
    end

    table.insert(self._nextOverrides, normalized)
    self:Emit("PlayNextChanged", self._nextOverrides)

    return true, normalized
end

function Queue:GetPlayNext()
    return self._nextOverrides[1]
end

function Queue:ClearPlayNext()
    self._nextOverrides = {}
    self:Emit("PlayNextChanged", self._nextOverrides)
end

----------------------------------------------------------------
-- History
----------------------------------------------------------------

function Queue:_recordCurrent()
    local current = self:GetCurrent()

    if not current then
        return
    end

    local entry = copy(current)

    -- Keep the queue history compact by removing the immediately
    -- previous duplicate entry.
    local key = getTrackKey(entry)

    for i = #self.History, 1, -1 do
        if getTrackKey(self.History[i]) == key then
            table.remove(self.History, i)
        end
    end

    table.insert(self.History, 1, entry)

    while #self.History > self.Config.HistoryLimit do
        table.remove(self.History)
    end

    self:Emit("HistoryChanged", self.History)
end

function Queue:GetHistory()
    return self.History
end

function Queue:ClearHistory()
    self.History = {}
    self:Emit("HistoryChanged", self.History)
end

----------------------------------------------------------------
-- Serialization / persistence
----------------------------------------------------------------

function Queue:Snapshot()
    return {
        version = 1,

        tracks = self:ToArray(),
        originalTracks = (function()
            local result = {}
            for index, track in ipairs(self.OriginalTracks) do
                result[index] = copy(track)
            end
            return result
        end)(),

        currentIndex = self.CurrentIndex,

        shuffle = self.ShuffleEnabled,
        repeatMode = self.RepeatMode,

        history = (function()
            local result = {}
            for index, track in ipairs(self.History) do
                result[index] = copy(track)
            end
            return result
        end)(),
    }
end

function Queue:LoadSnapshot(snapshot)
    if type(snapshot) ~= "table" then
        return false, "Snapshot must be a table"
    end

    self.Tracks = {}
    self.OriginalTracks = {}
    self.History = {}
    self._nextOverrides = {}

    if type(snapshot.tracks) == "table" then
        for _, track in ipairs(snapshot.tracks) do
            local normalized = normalizeTrack(track)
            if normalized then
                table.insert(self.Tracks, normalized)
            end
        end
    end

    if type(snapshot.originalTracks) == "table" then
        for _, track in ipairs(snapshot.originalTracks) do
            local normalized = normalizeTrack(track)
            if normalized then
                table.insert(self.OriginalTracks, normalized)
            end
        end
    end

    if #self.OriginalTracks == 0 then
        for _, track in ipairs(self.Tracks) do
            table.insert(self.OriginalTracks, copy(track))
        end
    end

    self.CurrentIndex = tonumber(snapshot.currentIndex) or 0

    if #self.Tracks == 0 then
        self.CurrentIndex = 0
    else
        self.CurrentIndex = clampIndex(
            math.floor(self.CurrentIndex),
            1,
            #self.Tracks
        )
    end

    self.ShuffleEnabled = snapshot.shuffle == true

    if VALID_REPEAT[snapshot.repeatMode] then
        self.RepeatMode = snapshot.repeatMode
    else
        self.RepeatMode = "Off"
    end

    if type(snapshot.history) == "table" then
        for _, track in ipairs(snapshot.history) do
            local normalized = normalizeTrack(track)
            if normalized then
                table.insert(self.History, normalized)
            end
        end
    end

    while #self.History > self.Config.HistoryLimit do
        table.remove(self.History)
    end

    self:Emit("Loaded", self:Snapshot())
    self:Emit("Changed", self)

    return true
end

----------------------------------------------------------------
-- Validation / maintenance
----------------------------------------------------------------

function Queue:Validate()
    local errors = {}

    if #self.Tracks ~= #self.Tracks then
        table.insert(errors, "Internal track count mismatch")
    end

    if #self.Tracks > 0 then
        if self.CurrentIndex < 1 or self.CurrentIndex > #self.Tracks then
            table.insert(errors, "CurrentIndex out of range")
        end
    elseif self.CurrentIndex ~= 0 then
        table.insert(errors, "Empty queue must have CurrentIndex = 0")
    end

    if not VALID_REPEAT[self.RepeatMode] then
        table.insert(errors, "Invalid repeat mode")
    end

    if type(self.ShuffleEnabled) ~= "boolean" then
        table.insert(errors, "ShuffleEnabled must be boolean")
    end

    return #errors == 0, errors
end

function Queue:Deduplicate()
    local seen = {}
    local newTracks = {}
    local newOriginal = {}

    for _, track in ipairs(self.Tracks) do
        local key = getTrackKey(track)

        if not seen[key] then
            seen[key] = true
            table.insert(newTracks, track)
        end
    end

    seen = {}

    for _, track in ipairs(self.OriginalTracks) do
        local key = getTrackKey(track)

        if not seen[key] then
            seen[key] = true
            table.insert(newOriginal, track)
        end
    end

    local currentKey = getTrackKey(self:GetCurrent())

    self.Tracks = newTracks
    self.OriginalTracks = newOriginal

    self.CurrentIndex = 0

    if currentKey then
        for index, track in ipairs(self.Tracks) do
            if getTrackKey(track) == currentKey then
                self.CurrentIndex = index
                break
            end
        end
    end

    if self.CurrentIndex == 0 and #self.Tracks > 0 then
        self.CurrentIndex = 1
    end

    self:Emit("Changed", self)

    return true
end

----------------------------------------------------------------
-- Configuration
----------------------------------------------------------------

function Queue:SetHistoryLimit(limit)
    limit = tonumber(limit)

    if not limit then
        return false, "History limit must be a number"
    end

    limit = math.max(0, math.floor(limit))
    self.Config.HistoryLimit = limit

    while #self.History > limit do
        table.remove(self.History)
    end

    self:Emit("Changed", self)

    return true, limit
end

function Queue:GetConfig()
    return copy(self.Config)
end

----------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------

function Queue:Destroy()
    if self._destroyed then
        return
    end

    self.Events = {}
    self.Tracks = {}
    self.OriginalTracks = {}
    self.History = {}
    self._nextOverrides = {}
    self.CurrentIndex = 0
    self._destroyed = true
end

return Queue
