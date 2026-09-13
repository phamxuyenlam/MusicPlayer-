--[[
    MusicPlayer.lua
    ------------------------------------------------------------
    Core for the lightweight Music Player project.

    Project layout:
        MusicPlayer/
        ├── MusicPlayer.lua
        ├── Queue.lua
        ├── Ui.lua
        ├── Misc.lua
        ├── Musics/
        ├── Videos/
        └── Local Audios/

    Design:
        - MusicPlayer.lua owns playback state and public API.
        - Queue.lua owns ordering.
        - Ui.lua displays state and invokes public methods.
        - Misc.lua may be used for helpers; it is optional.

    IMPORTANT:
        This core does NOT require users to paste a SoundId as its
        primary workflow. A resolver/backend can be attached through
        SetResolver() and SetBackend().

        The backend boundary exists because Roblox audio playback has
        platform/permission constraints. A resolver should only return
        audio that the current environment is legitimately allowed to
        obtain and play.
--]]

local MusicPlayer = {}
MusicPlayer.__index = MusicPlayer

local DEFAULTS = {
    Volume = 0.8,
    RepeatMode = "Off",       -- Off | One | All
    Shuffle = false,
    AutoPlay = true,
    AutoNext = true,
    SavePosition = true,
    HistoryLimit = 100,
    CacheFolder = "Musics",
    LocalFolder = "Local Audios",
}

local VALID_STATES = {
    Idle = true,
    Loading = true,
    Playing = true,
    Paused = true,
    Stopped = true,
    Buffering = true,
    Ended = true,
    Error = true,
}

local VALID_REPEAT = {
    Off = true,
    One = true,
    All = true,
}

local function copyTable(source)
    local result = {}
    for k, v in pairs(source) do
        if type(v) == "table" then
            local nested = {}
            for nk, nv in pairs(v) do
                nested[nk] = nv
            end
            result[k] = nested
        else
            result[k] = v
        end
    end
    return result
end

local function merge(base, overrides)
    local result = copyTable(base)
    if type(overrides) ~= "table" then
        return result
    end

    for k, v in pairs(overrides) do
        result[k] = v
    end

    return result
end

local function clamp(value, minimum, maximum)
    if value < minimum then
        return minimum
    end
    if value > maximum then
        return maximum
    end
    return value
end

local function now()
    return os.clock()
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

    local result = {}
    for k, v in pairs(track) do
        result[k] = v
    end

    result.id = result.id or result.videoId or result.url or result.path
    result.title = result.title or result.name or result.id or "Unknown Track"

    return result
end

local function fire(callback, ...)
    if type(callback) ~= "function" then
        return true
    end

    local ok, err = pcall(callback, ...)
    return ok, err
end

function MusicPlayer.new(options)
    local self = setmetatable({}, MusicPlayer)

    self.Config = merge(DEFAULTS, options)

    self.State = "Idle"
    self.CurrentTrack = nil
    self.CurrentIndex = nil

    self.Position = 0
    self.Duration = 0
    self.Volume = clamp(tonumber(self.Config.Volume) or 0.8, 0, 1)
    self.Muted = false
    self.VolumeBeforeMute = self.Volume

    self.RepeatMode = VALID_REPEAT[self.Config.RepeatMode]
        and self.Config.RepeatMode
        or "Off"

    self.ShuffleEnabled = self.Config.Shuffle == true
    self.AutoPlay = self.Config.AutoPlay ~= false
    self.AutoNext = self.Config.AutoNext ~= false
    self.SavePosition = self.Config.SavePosition ~= false

    self.Queue = nil
    self.UI = nil
    self.Misc = nil

    self.Resolver = nil
    self.Backend = nil
    self.Storage = nil

    self.History = {}
    self.SavedPositions = {}

    self.Events = {}
    self._loadingToken = 0
    self._destroyed = false
    self._lastUpdate = now()

    return self
end

----------------------------------------------------------------
-- Event system
----------------------------------------------------------------

function MusicPlayer:On(eventName, callback)
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

function MusicPlayer:Emit(eventName, ...)
    local listeners = self.Events[eventName]
    if not listeners then
        return
    end

    for i = #listeners, 1, -1 do
        local callback = listeners[i]

        if type(callback) ~= "function" then
            table.remove(listeners, i)
        else
            fire(callback, ...)
        end
    end
end

----------------------------------------------------------------
-- Module binding
----------------------------------------------------------------

function MusicPlayer:AttachQueue(queue)
    self.Queue = queue
    self:Emit("QueueAttached", queue)
    return self
end

function MusicPlayer:AttachUI(ui)
    self.UI = ui
    self:Emit("UIAttached", ui)
    return self
end

function MusicPlayer:AttachMisc(misc)
    self.Misc = misc
    return self
end

function MusicPlayer:SetResolver(resolver)
    self.Resolver = resolver
    return self
end

function MusicPlayer:SetBackend(backend)
    self.Backend = backend
    self:_syncBackendVolume()
    return self
end

function MusicPlayer:SetStorage(storage)
    self.Storage = storage
    return self
end

----------------------------------------------------------------
-- State
----------------------------------------------------------------

function MusicPlayer:GetState()
    return self.State
end

function MusicPlayer:IsPlaying()
    return self.State == "Playing"
end

function MusicPlayer:IsPaused()
    return self.State == "Paused"
end

function MusicPlayer:SetState(newState, reason)
    if not VALID_STATES[newState] then
        return false, "Invalid player state: " .. tostring(newState)
    end

    local oldState = self.State
    self.State = newState

    self:Emit("StateChanged", newState, oldState, reason)
    return true
end

----------------------------------------------------------------
-- Queue integration
--
-- Queue.lua can expose any of these common methods:
--   GetCurrent()
--   Current()
--   Peek()
--   Next()
--   Previous()
--   GetAll()
--   Add()
--
-- The adapter keeps MusicPlayer.lua independent from one exact
-- Queue implementation.
----------------------------------------------------------------

function MusicPlayer:_queueCall(methods, ...)
    if not self.Queue then
        return nil
    end

    for _, methodName in ipairs(methods) do
        local method = self.Queue[methodName]

        if type(method) == "function" then
            local ok, a, b, c = pcall(method, self.Queue, ...)
            if ok then
                return a, b, c
            end
        end
    end

    return nil
end

function MusicPlayer:_getQueueCurrent()
    return self:_queueCall({
        "GetCurrent",
        "Current",
        "Peek",
    })
end

function MusicPlayer:_getQueueNext()
    return self:_queueCall({
        "Next",
        "GetNext",
    })
end

function MusicPlayer:_getQueuePrevious()
    return self:_queueCall({
        "Previous",
        "GetPrevious",
    })
end

function MusicPlayer:_queueAdd(track)
    return self:_queueCall({
        "Add",
        "Enqueue",
        "Push",
    }, track)
end

function MusicPlayer:_queueRemove(index)
    return self:_queueCall({
        "Remove",
        "Delete",
    }, index)
end

function MusicPlayer:_queueClear()
    return self:_queueCall({
        "Clear",
        "Reset",
    })
end

function MusicPlayer:_queueGetAll()
    return self:_queueCall({
        "GetAll",
        "GetTracks",
    })
end

function MusicPlayer:Add(track, playNow)
    local normalized, err = normalizeTrack(track)
    if not normalized then
        return false, err
    end

    local result = self:_queueAdd(normalized)

    if self.Queue and result == nil then
        return false, "Queue.lua does not expose an Add/Enqueue/Push method"
    end

    self:Emit("TrackAdded", normalized)

    if playNow then
        return self:Play(normalized)
    end

    return true, normalized
end

function MusicPlayer:Remove(index)
    local result = self:_queueRemove(index)

    if self.Queue and result == nil then
        return false, "Queue.lua does not expose Remove/Delete"
    end

    self:Emit("TrackRemoved", index)
    return true
end

function MusicPlayer:ClearQueue()
    local result = self:_queueClear()

    if self.Queue and result == nil then
        return false, "Queue.lua does not expose Clear/Reset"
    end

    self:Stop()
    self:Emit("QueueCleared")
    return true
end

function MusicPlayer:GetQueue()
    return self:_queueGetAll() or {}
end

----------------------------------------------------------------
-- Resolver
--
-- Resolver contract:
--
-- resolver:Resolve(track, context)
--
-- returns either:
--   {
--       track = track,
--       audio = <backend-compatible audio reference>,
--       duration = number,
--       ...
--   }
--
-- or:
--   audioReference
--
-- The resolver is intentionally separate from playback.
----------------------------------------------------------------

function MusicPlayer:SetResolverEnabled(enabled)
    self.ResolverEnabled = enabled ~= false
    return self
end

function MusicPlayer:_resolve(track)
    if not self.Resolver then
        return track
    end

    local resolve = self.Resolver.Resolve or self.Resolver.resolve

    if type(resolve) ~= "function" then
        return nil, "Resolver has no Resolve/resolve method"
    end

    self:Emit("ResolveStarted", track)

    local ok, result, extra = pcall(resolve, self.Resolver, track, {
        player = self,
        cacheFolder = self.Config.CacheFolder,
        localFolder = self.Config.LocalFolder,
    })

    if not ok then
        self:Emit("ResolveFailed", track, result)
        return nil, tostring(result)
    end

    if result == nil then
        local message = extra or "Resolver returned no result"
        self:Emit("ResolveFailed", track, message)
        return nil, tostring(message)
    end

    self:Emit("ResolveCompleted", track, result)
    return result
end

----------------------------------------------------------------
-- Backend integration
--
-- Backend contract:
--
-- backend:Play(audio, track, player)
-- backend:Pause()
-- backend:Resume()
-- backend:Stop()
-- backend:Seek(seconds)
-- backend:SetVolume(0..1)
-- backend:GetTimePosition() [optional]
-- backend:GetLength()       [optional]
-- backend:IsPlaying()       [optional]
--
-- Optional event callbacks:
-- backend.OnEnded(callback)
-- backend.OnError(callback)
-- backend.OnLoaded(callback)
----------------------------------------------------------------

function MusicPlayer:_backendCall(methods, ...)
    if not self.Backend then
        return false, "No audio backend attached"
    end

    for _, methodName in ipairs(methods) do
        local method = self.Backend[methodName]

        if type(method) == "function" then
            local ok, a, b, c = pcall(method, self.Backend, ...)
            if not ok then
                return false, tostring(a)
            end
            return true, a, b, c
        end
    end

    return false, "Backend method missing: " .. table.concat(methods, "/")
end

function MusicPlayer:_syncBackendVolume()
    if not self.Backend then
        return
    end

    local volume = self.Muted and 0 or self.Volume
    self:_backendCall({"SetVolume", "setVolume"}, volume)
end

function MusicPlayer:_bindBackendEvents()
    if not self.Backend then
        return
    end

    local backend = self.Backend

    local onEnded = backend.OnEnded or backend.onEnded
    if type(onEnded) == "function" then
        pcall(onEnded, backend, function()
            self:HandleEnded()
        end)
    end

    local onError = backend.OnError or backend.onError
    if type(onError) == "function" then
        pcall(onError, backend, function(errorMessage)
            self:SetState("Error", errorMessage)
            self:Emit("Error", errorMessage, self.CurrentTrack)
        end)
    end
end

----------------------------------------------------------------
-- Playback
----------------------------------------------------------------

function MusicPlayer:Play(track, options)
    if self._destroyed then
        return false, "Player has been destroyed"
    end

    options = options or {}

    if track == nil then
        track = self:_getQueueCurrent()

        if not track then
            return false, "No track available"
        end
    end

    local normalized, normalizeError = normalizeTrack(track)
    if not normalized then
        return false, normalizeError
    end

    self._loadingToken += 1
    local token = self._loadingToken

    self.CurrentTrack = normalized
    self.Position = 0
    self.Duration = tonumber(normalized.duration) or 0

    self:SetState("Loading")
    self:Emit("TrackLoading", normalized)

    local resolved, resolveError = self:_resolve(normalized)

    if token ~= self._loadingToken then
        return false, "Playback request superseded"
    end

    if not resolved then
        self:SetState("Error", resolveError)
        self:Emit("Error", resolveError, normalized)
        return false, resolveError
    end

    local audioReference = resolved.audio
        or resolved.audioReference
        or resolved.asset
        or resolved.path
        or resolved.soundId
        or resolved.id

    local resolvedTrack = resolved.track or normalized

    if resolved.duration then
        self.Duration = tonumber(resolved.duration) or self.Duration
    elseif resolvedTrack.duration then
        self.Duration = tonumber(resolvedTrack.duration) or self.Duration
    end

    self.CurrentTrack = resolvedTrack

    if not self.Backend then
        self:SetState("Error", "No audio backend attached")
        self:Emit(
            "Error",
            "No audio backend attached",
            resolvedTrack
        )
        return false, "No audio backend attached"
    end

    if audioReference == nil then
        self:SetState("Error", "Resolver returned no playable audio reference")
        self:Emit(
            "Error",
            "Resolver returned no playable audio reference",
            resolvedTrack
        )
        return false, "Resolver returned no playable audio reference"
    end

    local ok, backendError = self:_backendCall(
        {"Play", "play"},
        audioReference,
        resolvedTrack,
        self
    )

    if not ok then
        self:SetState("Error", backendError)
        self:Emit("Error", backendError, resolvedTrack)
        return false, backendError
    end

    self:_syncBackendVolume()
    self:_bindBackendEvents()

    self:SetState("Playing")
    self:_pushHistory(resolvedTrack)
    self:_restorePosition(resolvedTrack)

    self:Emit("TrackChanged", resolvedTrack)
    self:Emit("Play", resolvedTrack)

    return true, resolvedTrack
end

function MusicPlayer:Pause()
    if self.State ~= "Playing" then
        return false, "Player is not playing"
    end

    local ok, err = self:_backendCall({"Pause", "pause"})

    if not ok then
        return false, err
    end

    self:_capturePosition()
    self:SetState("Paused")
    self:Emit("Pause", self.CurrentTrack)

    return true
end

function MusicPlayer:Resume()
    if self.State == "Playing" then
        return true
    end

    if not self.CurrentTrack then
        return self:Play()
    end

    local ok, err = self:_backendCall({"Resume", "resume"})

    if not ok then
        return false, err
    end

    self:SetState("Playing")
    self:Emit("Resume", self.CurrentTrack)

    return true
end

function MusicPlayer:TogglePlay()
    if self.State == "Playing" then
        return self:Pause()
    end

    return self:Resume()
end

function MusicPlayer:Stop()
    if self.Backend then
        self:_backendCall({"Stop", "stop"})
    end

    self:_capturePosition()

    self:SetState("Stopped")
    self:Emit("Stop", self.CurrentTrack)

    return true
end

function MusicPlayer:Restart()
    if not self.CurrentTrack then
        return self:Play()
    end

    local ok, err = self:Seek(0)
    if not ok then
        return false, err
    end

    if self.State ~= "Playing" then
        return self:Resume()
    end

    return true
end

----------------------------------------------------------------
-- Previous / next
----------------------------------------------------------------

function MusicPlayer:Next(force)
    local nextTrack = self:_getQueueNext()

    if nextTrack then
        return self:Play(nextTrack)
    end

    if self.RepeatMode == "All" or force then
        local all = self:GetQueue()

        if #all > 0 then
            return self:Play(all[1])
        end
    end

    self:SetState("Ended")
    self:Emit("QueueEnded")

    return false, "No next track"
end

function MusicPlayer:Previous()
    local previousTrack = self:_getQueuePrevious()

    if previousTrack then
        return self:Play(previousTrack)
    end

    -- If the current track is sufficiently far in, restart instead.
    if self.Position > 3 then
        return self:Seek(0)
    end

    return false, "No previous track"
end

function MusicPlayer:HandleEnded()
    self:_capturePosition()
    self:Emit("TrackEnded", self.CurrentTrack)

    if self.RepeatMode == "One" then
        self:Play(self.CurrentTrack)
        return
    end

    if self.AutoNext then
        local ok = self:Next()
        if ok then
            return
        end
    end

    self:SetState("Ended")
end

----------------------------------------------------------------
-- Seeking / position
----------------------------------------------------------------

function MusicPlayer:Seek(seconds)
    seconds = tonumber(seconds)

    if not seconds then
        return false, "Seek position must be a number"
    end

    if self.Duration > 0 then
        seconds = clamp(seconds, 0, self.Duration)
    else
        seconds = math.max(0, seconds)
    end

    local ok, err = self:_backendCall(
        {"Seek", "seek", "SetTimePosition"},
        seconds
    )

    if not ok then
        return false, err
    end

    self.Position = seconds
    self:Emit("Seek", seconds, self.Duration)

    return true, seconds
end

function MusicPlayer:GetPosition()
    if self.Backend then
        local ok, position = self:_backendCall(
            {"GetTimePosition", "getTimePosition", "GetPosition"}
        )

        if ok and type(position) == "number" then
            self.Position = position
        end
    end

    return self.Position
end

function MusicPlayer:GetDuration()
    if self.Backend then
        local ok, duration = self:_backendCall(
            {"GetLength", "getLength", "GetDuration"}
        )

        if ok and type(duration) == "number" and duration > 0 then
            self.Duration = duration
        end
    end

    return self.Duration
end

function MusicPlayer:GetProgress()
    local duration = self:GetDuration()
    local position = self:GetPosition()

    if duration <= 0 then
        return 0
    end

    return clamp(position / duration, 0, 1)
end

function MusicPlayer:Update()
    if self._destroyed then
        return
    end

    local currentTime = now()

    -- Avoid unnecessarily hammering backend/UI every call.
    if currentTime - self._lastUpdate < 0.05 then
        return
    end

    self._lastUpdate = currentTime

    self:GetPosition()
    self:GetDuration()

    self:Emit(
        "Progress",
        self.Position,
        self.Duration,
        self:GetProgress()
    )
end

----------------------------------------------------------------
-- Volume
----------------------------------------------------------------

function MusicPlayer:SetVolume(volume)
    volume = tonumber(volume)

    if not volume then
        return false, "Volume must be a number"
    end

    self.Volume = clamp(volume, 0, 1)

    if self.Volume > 0 then
        self.VolumeBeforeMute = self.Volume
        if self.Muted then
            self.Muted = false
        end
    end

    self:_syncBackendVolume()
    self:Emit("VolumeChanged", self.Volume, self.Muted)

    return true, self.Volume
end

function MusicPlayer:GetVolume()
    return self.Volume
end

function MusicPlayer:SetMuted(muted)
    muted = muted == true

    if muted and not self.Muted then
        self.VolumeBeforeMute = self.Volume
    end

    self.Muted = muted

    if not muted and self.Volume == 0 then
        self.Volume = self.VolumeBeforeMute > 0
            and self.VolumeBeforeMute
            or 0.8
    end

    self:_syncBackendVolume()
    self:Emit("VolumeChanged", self.Volume, self.Muted)

    return true
end

function MusicPlayer:ToggleMute()
    return self:SetMuted(not self.Muted)
end

function MusicPlayer:IsMuted()
    return self.Muted
end

----------------------------------------------------------------
-- Shuffle / repeat
----------------------------------------------------------------

function MusicPlayer:SetShuffle(enabled)
    self.ShuffleEnabled = enabled == true

    if self.Queue then
        self:_queueCall({"SetShuffle", "ShuffleEnabled"}, self.ShuffleEnabled)
    end

    self:Emit("ShuffleChanged", self.ShuffleEnabled)
    return true
end

function MusicPlayer:ToggleShuffle()
    return self:SetShuffle(not self.ShuffleEnabled)
end

function MusicPlayer:IsShuffleEnabled()
    return self.ShuffleEnabled
end

function MusicPlayer:SetRepeat(mode)
    if not VALID_REPEAT[mode] then
        return false, "Repeat mode must be Off, One, or All"
    end

    self.RepeatMode = mode

    if self.Queue then
        self:_queueCall({"SetRepeat", "SetRepeatMode"}, mode)
    end

    self:Emit("RepeatChanged", mode)
    return true
end

function MusicPlayer:CycleRepeat()
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

function MusicPlayer:GetRepeat()
    return self.RepeatMode
end

----------------------------------------------------------------
-- History
----------------------------------------------------------------

function MusicPlayer:_pushHistory(track)
    if not track then
        return
    end

    local id = track.id or track.url or track.title

    for i = #self.History, 1, -1 do
        local existing = self.History[i]
        if existing.id == id then
            table.remove(self.History, i)
        end
    end

    table.insert(self.History, 1, {
        id = id,
        title = track.title,
        artist = track.artist,
        source = track.source,
        url = track.url,
        timestamp = os.time(),
    })

    while #self.History > self.Config.HistoryLimit do
        table.remove(self.History)
    end

    self:Emit("HistoryChanged", self.History)
end

function MusicPlayer:GetHistory()
    return self.History
end

function MusicPlayer:ClearHistory()
    self.History = {}
    self:Emit("HistoryChanged", self.History)
end

----------------------------------------------------------------
-- Saved playback positions
----------------------------------------------------------------

function MusicPlayer:_capturePosition()
    if not self.SavePosition or not self.CurrentTrack then
        return
    end

    local id = self.CurrentTrack.id
        or self.CurrentTrack.url
        or self.CurrentTrack.title

    if id then
        self.SavedPositions[id] = self:GetPosition()
    end
end

function MusicPlayer:_restorePosition(track)
    if not self.SavePosition or not track then
        return
    end

    local id = track.id or track.url or track.title
    local saved = id and self.SavedPositions[id]

    if saved and saved > 0 then
        self:Seek(saved)
    end
end

function MusicPlayer:GetSavedPosition(track)
    if not track then
        return 0
    end

    local id = track.id or track.url or track.title
    return self.SavedPositions[id] or 0
end

----------------------------------------------------------------
-- Search / source hooks
----------------------------------------------------------------

function MusicPlayer:Search(query, options)
    options = options or {}

    if not self.Resolver then
        return false, "No resolver attached"
    end

    local search = self.Resolver.Search or self.Resolver.search

    if type(search) ~= "function" then
        return false, "Resolver has no Search/search method"
    end

    self:Emit("SearchStarted", query)

    local ok, results, err = pcall(
        search,
        self.Resolver,
        query,
        options,
        self
    )

    if not ok then
        self:Emit("SearchFailed", query, results)
        return false, tostring(results)
    end

    if results == nil then
        err = err or "Search returned no results"
        self:Emit("SearchFailed", query, err)
        return false, tostring(err)
    end

    self:Emit("SearchCompleted", query, results)
    return true, results
end

function MusicPlayer:Resolve(track)
    local normalized, err = normalizeTrack(track)

    if not normalized then
        return false, err
    end

    local resolved, resolveError = self:_resolve(normalized)

    if not resolved then
        return false, resolveError
    end

    return true, resolved
end

----------------------------------------------------------------
-- Cache hooks
----------------------------------------------------------------

function MusicPlayer:GetCached(track)
    if not self.Storage then
        return nil, "No storage attached"
    end

    local method = self.Storage.Get
        or self.Storage.GetCached
        or self.Storage.Find

    if type(method) ~= "function" then
        return nil, "Storage has no cache lookup method"
    end

    local normalized = normalizeTrack(track)

    local ok, result = pcall(
        method,
        self.Storage,
        normalized,
        self
    )

    if not ok then
        return nil, tostring(result)
    end

    return result
end

function MusicPlayer:ClearCache()
    if not self.Storage then
        return false, "No storage attached"
    end

    local method = self.Storage.Clear
        or self.Storage.ClearCache

    if type(method) ~= "function" then
        return false, "Storage has no Clear/ClearCache method"
    end

    local ok, result = pcall(method, self.Storage)

    if not ok then
        return false, tostring(result)
    end

    self:Emit("CacheCleared")
    return true, result
end

----------------------------------------------------------------
-- UI helpers
----------------------------------------------------------------

function MusicPlayer:Notify(message, level)
    self:Emit("Notification", {
        message = tostring(message),
        level = level or "Info",
    })

    if self.UI then
        local notify = self.UI.Notify or self.UI.notify
        if type(notify) == "function" then
            pcall(notify, self.UI, tostring(message), level or "Info")
        end
    end
end

function MusicPlayer:GetSnapshot()
    return {
        state = self.State,
        track = self.CurrentTrack,
        position = self:GetPosition(),
        duration = self:GetDuration(),
        progress = self:GetProgress(),

        volume = self.Volume,
        muted = self.Muted,

        repeatMode = self.RepeatMode,
        shuffle = self.ShuffleEnabled,

        queue = self:GetQueue(),
    }
end

----------------------------------------------------------------
-- Configuration
----------------------------------------------------------------

function MusicPlayer:SetAutoNext(enabled)
    self.AutoNext = enabled ~= false
    self:Emit("SettingChanged", "AutoNext", self.AutoNext)
    return true
end

function MusicPlayer:SetAutoPlay(enabled)
    self.AutoPlay = enabled ~= false
    self:Emit("SettingChanged", "AutoPlay", self.AutoPlay)
    return true
end

function MusicPlayer:SetSavePosition(enabled)
    self.SavePosition = enabled ~= false
    self:Emit("SettingChanged", "SavePosition", self.SavePosition)
    return true
end

function MusicPlayer:GetConfig()
    return copyTable(self.Config)
end

----------------------------------------------------------------
-- Lifecycle
----------------------------------------------------------------

function MusicPlayer:Destroy()
    if self._destroyed then
        return
    end

    self:_capturePosition()

    if self.Backend then
        self:_backendCall({"Stop", "stop"})
    end

    self.Events = {}
    self.Queue = nil
    self.UI = nil
    self.Misc = nil
    self.Resolver = nil
    self.Backend = nil
    self.Storage = nil

    self.CurrentTrack = nil
    self.State = "Idle"
    self._destroyed = true
end

return MusicPlayer
