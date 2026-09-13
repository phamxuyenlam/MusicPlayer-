--[[
    Ui.lua
    ------------------------------------------------------------
    Premium Music Player UI
    Built to work with the project's MusicPlayer.lua + Queue.lua,
    while keeping the visual layer independent from their internals.

    UI goals:
        - Clean, modern music-app look.
        - Strong hierarchy: Search -> Content -> Queue -> Player.
        - Desktop + mobile responsive layout.
        - Compact mini-player when the main panel is minimized.
        - Smooth tweens, subtle hover/press feedback, no noisy effects.
        - Queue can be rendered even if a full MusicPlayer controller
          has not been bound yet.
        - Supports controller/queue objects through small adapters.

    Public API (high level):
        local Ui = require(...)
        local ui = Ui.new({
            Parent = playerGui,
            Title = "Music Player",
        })

        ui:BindPlayer(MusicPlayer)
        ui:BindQueue(Queue)
        ui:SetSearchCallback(function(query) ... end)
        ui:Show()

    The UI does not create or require an audio backend.
--]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local GuiService = game:GetService("GuiService")

local LOCAL_PLAYER = Players.LocalPlayer

local Ui = {}
Ui.__index = Ui

----------------------------------------------------------------
-- Design system
----------------------------------------------------------------

local COLORS = {
    Background = Color3.fromRGB(10, 11, 14),
    Surface = Color3.fromRGB(17, 18, 23),
    Surface2 = Color3.fromRGB(23, 24, 30),
    Surface3 = Color3.fromRGB(30, 31, 38),

    Text = Color3.fromRGB(247, 247, 250),
    TextSecondary = Color3.fromRGB(164, 166, 177),
    TextMuted = Color3.fromRGB(105, 108, 121),

    Accent = Color3.fromRGB(154, 116, 255),
    AccentSoft = Color3.fromRGB(82, 62, 135),
    AccentGlow = Color3.fromRGB(184, 152, 255),

    Success = Color3.fromRGB(95, 211, 139),
    Warning = Color3.fromRGB(243, 191, 91),
    Error = Color3.fromRGB(244, 104, 104),

    White = Color3.fromRGB(255, 255, 255),
    Black = Color3.fromRGB(0, 0, 0),
}

local FONT = Enum.Font.Gotham

local SPRING = TweenInfo.new(
    0.22,
    Enum.EasingStyle.Quint,
    Enum.EasingDirection.Out
)

local FAST = TweenInfo.new(
    0.12,
    Enum.EasingStyle.Quad,
    Enum.EasingDirection.Out
)

local SLOW = TweenInfo.new(
    0.36,
    Enum.EasingStyle.Quint,
    Enum.EasingDirection.Out
)

local function tween(instance, info, properties)
    if not instance or not instance.Parent then
        return nil
    end

    local tw = TweenService:Create(instance, info, properties)
    tw:Play()
    return tw
end

local function safeCall(callback, ...)
    if type(callback) ~= "function" then
        return false
    end

    local ok, result = pcall(callback, ...)
    if not ok then
        warn("[MusicPlayer UI]", result)
    end

    return ok, result
end

local function make(className, properties)
    local object = Instance.new(className)

    for key, value in pairs(properties or {}) do
        object[key] = value
    end

    return object
end

local function corner(parent, radius)
    return make("UICorner", {
        Parent = parent,
        CornerRadius = UDim.new(0, radius),
    })
end

local function stroke(parent, color, transparency, thickness)
    return make("UIStroke", {
        Parent = parent,
        Color = color or COLORS.White,
        Transparency = transparency == nil and 0.9 or transparency,
        Thickness = thickness or 1,
    })
end

local function padding(parent, left, top, right, bottom)
    return make("UIPadding", {
        Parent = parent,
        PaddingLeft = UDim.new(0, left or 0),
        PaddingTop = UDim.new(0, top or 0),
        PaddingRight = UDim.new(0, right or 0),
        PaddingBottom = UDim.new(0, bottom or 0),
    })
end

local function label(parent, text, size, color, font)
    return make("TextLabel", {
        Parent = parent,
        BackgroundTransparency = 1,
        Text = text or "",
        TextColor3 = color or COLORS.Text,
        Font = font or FONT,
        TextSize = size or 14,
        TextXAlignment = Enum.TextXAlignment.Left,
        TextYAlignment = Enum.TextYAlignment.Center,
        BorderSizePixel = 0,
    })
end

local function button(parent, text, size, bg)
    local b = make("TextButton", {
        Parent = parent,
        AutoButtonColor = false,
        BackgroundColor3 = bg or COLORS.Surface2,
        BorderSizePixel = 0,
        Text = text or "",
        TextColor3 = COLORS.Text,
        Font = FONT,
        TextSize = size or 14,
        Selectable = true,
    })

    corner(b, 10)
    return b
end

local function formatTime(seconds)
    seconds = tonumber(seconds) or 0
    seconds = math.max(0, math.floor(seconds))

    local minutes = math.floor(seconds / 60)
    local remainder = seconds % 60

    return string.format("%d:%02d", minutes, remainder)
end

local function safeString(value, fallback)
    if value == nil then
        return fallback or ""
    end

    return tostring(value)
end

local function getTrackArt(track)
    if type(track) ~= "table" then
        return ""
    end

    return safeString(
        track.thumbnail
        or track.image
        or track.art
        or track.cover,
        ""
    )
end

local function getTrackTitle(track)
    if type(track) ~= "table" then
        return "Unknown Track"
    end

    return safeString(
        track.title
        or track.name
        or track.id,
        "Unknown Track"
    )
end

local function getTrackArtist(track)
    if type(track) ~= "table" then
        return "Unknown Artist"
    end

    return safeString(
        track.artist
        or track.author
        or track.channel
        or track.uploader,
        "Unknown Artist"
    )
end

----------------------------------------------------------------
-- Constructor
----------------------------------------------------------------

function Ui.new(options)
    options = options or {}

    local self = setmetatable({}, Ui)

    self.Parent = options.Parent
        or (LOCAL_PLAYER and LOCAL_PLAYER:FindFirstChildOfClass("PlayerGui"))

    self.Title = options.Title or "Music Player"
    self.Controller = nil
    self.Queue = nil

    self.SearchCallback = nil
    self.ActionCallback = nil

    self.Visible = false
    self.Minimized = false
    self.Mobile = false

    self.CurrentTrack = nil
    self.CurrentState = "Idle"
    self.CurrentPosition = 0
    self.CurrentDuration = 0
    self.CurrentVolume = 0.8
    self.CurrentMuted = false
    self.CurrentRepeat = "Off"
    self.CurrentShuffle = false

    self._connections = {}
    self._controllerConnections = {}
    self._queueConnections = {}
    self._toastToken = 0

    self:_build()
    self:_bindResponsive()
    self:_bindWindowDragging()

    return self
end

----------------------------------------------------------------
-- Build root
----------------------------------------------------------------

function Ui:_build()
    assert(self.Parent, "Ui.new requires a PlayerGui/GuiObject parent")

    local old = self.Parent:FindFirstChild("MusicPlayerUI")
    if old then
        old:Destroy()
    end

    self.Gui = make("ScreenGui", {
        Parent = self.Parent,
        Name = "MusicPlayerUI",
        ResetOnSpawn = false,
        IgnoreGuiInset = true,
        ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
        DisplayOrder = 50,
    })

    self.Root = make("Frame", {
        Parent = self.Gui,
        Name = "Root",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.fromScale(1, 1),
    })

    self:_buildShade()
    self:_buildWindow()
    self:_buildHeader()
    self:_buildBody()
    self:_buildPlayerBar()
    self:_buildQueuePanel()
    self:_buildMiniPlayer()
    self:_buildSearchOverlay()
    self:_buildToast()
    self:_buildSettings()
end

function Ui:_buildShade()
    self.Shade = make("TextButton", {
        Parent = self.Root,
        Name = "Shade",
        BackgroundColor3 = COLORS.Black,
        BackgroundTransparency = 0.4,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Visible = false,
        ZIndex = 5,
    })

    self.Shade.Size = UDim2.fromScale(1, 1)

    self._connections[#self._connections + 1] =
        self.Shade.MouseButton1Click:Connect(function()
            self:CloseOverlays()
        end)
end

function Ui:_buildWindow()
    self.Window = make("Frame", {
        Parent = self.Root,
        Name = "Window",
        BackgroundColor3 = COLORS.Background,
        BorderSizePixel = 0,
        Size = UDim2.new(0.78, 0, 0.78, 0),
        Position = UDim2.new(0.5, 0, 0.49, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        ClipsDescendants = true,
        ZIndex = 10,
    })

    corner(self.Window, 18)
    stroke(self.Window, COLORS.White, 0.91, 1)

    self.WindowScale = make("UIScale", {
        Parent = self.Window,
        Scale = 0.96,
    })
end

function Ui:_buildHeader()
    self.Header = make("Frame", {
        Parent = self.Window,
        Name = "Header",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 62),
        ZIndex = 20,
    })

    padding(self.Header, 20, 0, 16, 0)

    self.BrandDot = make("Frame", {
        Parent = self.Header,
        BackgroundColor3 = COLORS.Accent,
        BorderSizePixel = 0,
        Size = UDim2.fromOffset(9, 9),
        Position = UDim2.new(0, 2, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        ZIndex = 21,
    })
    corner(self.BrandDot, 9)

    self.TitleLabel = label(
        self.Header,
        self.Title,
        18,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.TitleLabel.Position = UDim2.new(0, 22, 0, 0)
    self.TitleLabel.Size = UDim2.new(0, 190, 1, 0)
    self.TitleLabel.ZIndex = 21

    self.SearchButton = button(
        self.Header,
        "Search",
        13,
        COLORS.Surface2
    )
    self.SearchButton.Size = UDim2.new(0, 190, 0, 36)
    self.SearchButton.Position = UDim2.new(0.5, -95, 0.5, 0)
    self.SearchButton.AnchorPoint = Vector2.new(0.5, 0.5)
    self.SearchButton.TextColor3 = COLORS.TextSecondary
    self.SearchButton.ZIndex = 21
    corner(self.SearchButton, 10)

    self.SearchIcon = label(
        self.SearchButton,
        "⌕",
        19,
        COLORS.TextMuted
    )
    self.SearchIcon.Size = UDim2.fromOffset(26, 36)
    self.SearchIcon.Position = UDim2.fromOffset(8, 0)
    self.SearchIcon.ZIndex = 22

    self.SearchText = label(
        self.SearchButton,
        "Search music or paste a URL...",
        12,
        COLORS.TextMuted
    )
    self.SearchText.Position = UDim2.fromOffset(34, 0)
    self.SearchText.Size = UDim2.new(1, -40, 1, 0)
    self.SearchText.ZIndex = 22

    self.MinimizeButton = button(
        self.Header,
        "—",
        17,
        COLORS.Surface2
    )
    self.MinimizeButton.Size = UDim2.fromOffset(38, 36)
    self.MinimizeButton.Position = UDim2.new(1, -94, 0.5, 0)
    self.MinimizeButton.AnchorPoint = Vector2.new(0, 0.5)
    self.MinimizeButton.ZIndex = 21

    self.CloseButton = button(
        self.Header,
        "×",
        22,
        COLORS.Surface2
    )
    self.CloseButton.Size = UDim2.fromOffset(38, 36)
    self.CloseButton.Position = UDim2.new(1, -48, 0.5, 0)
    self.CloseButton.AnchorPoint = Vector2.new(0, 0.5)
    self.CloseButton.TextColor3 = COLORS.Text
    self.CloseButton.ZIndex = 21

    self._connections[#self._connections + 1] =
        self.SearchButton.MouseButton1Click:Connect(function()
            self:OpenSearch()
        end)

    self._connections[#self._connections + 1] =
        self.MinimizeButton.MouseButton1Click:Connect(function()
            self:SetMinimized(true)
        end)

    self._connections[#self._connections + 1] =
        self.CloseButton.MouseButton1Click:Connect(function()
            self:Hide()
        end)
end

function Ui:_buildBody()
    self.Body = make("Frame", {
        Parent = self.Window,
        Name = "Body",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 62),
        Size = UDim2.new(1, 0, 1, -150),
        ZIndex = 15,
    })

    self.Content = make("ScrollingFrame", {
        Parent = self.Body,
        Name = "Content",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 0),
        Size = UDim2.new(1, -36, 1, 0),
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.Surface3,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        ZIndex = 16,
    })

    padding(self.Content, 2, 12, 2, 22)

    self.ContentLayout = make("UIListLayout", {
        Parent = self.Content,
        Padding = UDim.new(0, 14),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    self:_buildHeroCard()
    self:_buildRecentlySection()
    self:_buildQuickActions()
end

function Ui:_buildHeroCard()
    self.Hero = make("Frame", {
        Parent = self.Content,
        Name = "Hero",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 170),
        LayoutOrder = 1,
    })

    corner(self.Hero, 16)
    stroke(self.Hero, COLORS.White, 0.94, 1)

    self.HeroGlow = make("Frame", {
        Parent = self.Hero,
        BackgroundColor3 = COLORS.AccentSoft,
        BackgroundTransparency = 0.82,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -220, 0, -40),
        Size = UDim2.fromOffset(260, 260),
        Rotation = 18,
    })
    corner(self.HeroGlow, 100)

    self.HeroArt = make("ImageLabel", {
        Parent = self.Hero,
        BackgroundColor3 = COLORS.Surface2,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 18, 0.5, 0),
        AnchorPoint = Vector2.new(0, 0.5),
        Size = UDim2.fromOffset(126, 126),
        Image = "",
        ScaleType = Enum.ScaleType.Crop,
    })
    corner(self.HeroArt, 14)

    self.HeroEyebrow = label(
        self.Hero,
        "NOW PLAYING",
        10,
        COLORS.AccentGlow,
        Enum.Font.GothamBold
    )
    self.HeroEyebrow.Position = UDim2.new(0, 162, 0, 27)
    self.HeroEyebrow.Size = UDim2.new(1, -180, 0, 18)

    self.HeroTitle = label(
        self.Hero,
        "Nothing playing",
        23,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.HeroTitle.Position = UDim2.new(0, 162, 0, 48)
    self.HeroTitle.Size = UDim2.new(1, -190, 0, 32)
    self.HeroTitle.TextTruncate = Enum.TextTruncate.AtEnd

    self.HeroArtist = label(
        self.Hero,
        "Pick a track to get started",
        13,
        COLORS.TextSecondary
    )
    self.HeroArtist.Position = UDim2.new(0, 162, 0, 82)
    self.HeroArtist.Size = UDim2.new(1, -190, 0, 24)

    self.HeroState = label(
        self.Hero,
        "IDLE",
        10,
        COLORS.TextMuted,
        Enum.Font.GothamBold
    )
    self.HeroState.Position = UDim2.new(0, 162, 1, -38)
    self.HeroState.Size = UDim2.new(0, 100, 0, 18)

    self.HeroPlay = button(
        self.Hero,
        "▶",
        17,
        COLORS.Accent
    )
    self.HeroPlay.Size = UDim2.fromOffset(48, 48)
    self.HeroPlay.Position = UDim2.new(1, -68, 1, -64)
    self.HeroPlay.ZIndex = 20
    corner(self.HeroPlay, 14)

    self._connections[#self._connections + 1] =
        self.HeroPlay.MouseButton1Click:Connect(function()
            self:_controllerCall("TogglePlay")
        end)
end

function Ui:_buildRecentlySection()
    self.RecentSection = make("Frame", {
        Parent = self.Content,
        Name = "Recently",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 172),
        LayoutOrder = 2,
    })

    self.RecentTitle = label(
        self.RecentSection,
        "Recently Played",
        15,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.RecentTitle.Size = UDim2.new(1, 0, 0, 24)

    self.RecentSubtitle = label(
        self.RecentSection,
        "Jump back into your latest tracks",
        11,
        COLORS.TextMuted
    )
    self.RecentSubtitle.Position = UDim2.fromOffset(0, 22)
    self.RecentSubtitle.Size = UDim2.new(1, 0, 0, 18)

    self.RecentScroll = make("ScrollingFrame", {
        Parent = self.RecentSection,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(0, 48),
        Size = UDim2.new(1, 0, 1, -48),
        ScrollBarThickness = 0,
        CanvasSize = UDim2.fromOffset(0, 0),
        AutomaticCanvasSize = Enum.AutomaticSize.X,
        ScrollingDirection = Enum.ScrollingDirection.X,
    })

    self.RecentLayout = make("UIListLayout", {
        Parent = self.RecentScroll,
        FillDirection = Enum.FillDirection.Horizontal,
        Padding = UDim.new(0, 10),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })
end

function Ui:_buildQuickActions()
    self.ActionsSection = make("Frame", {
        Parent = self.Content,
        Name = "QuickActions",
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 86),
        LayoutOrder = 3,
    })

    self.ActionsTitle = label(
        self.ActionsSection,
        "Quick Actions",
        15,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.ActionsTitle.Size = UDim2.new(1, 0, 0, 22)

    self.ActionSearch = button(
        self.ActionsSection,
        "＋  Search",
        12,
        COLORS.Surface
    )
    self.ActionSearch.Position = UDim2.fromOffset(0, 30)
    self.ActionSearch.Size = UDim2.new(0.31, -8, 0, 42)

    self.ActionQueue = button(
        self.ActionsSection,
        "≡  Queue",
        12,
        COLORS.Surface
    )
    self.ActionQueue.Position = UDim2.new(0.33, 0, 0, 30)
    self.ActionQueue.Size = UDim2.new(0.31, -8, 0, 42)

    self.ActionSettings = button(
        self.ActionsSection,
        "⚙  Settings",
        12,
        COLORS.Surface
    )
    self.ActionSettings.Position = UDim2.new(0.66, 0, 0, 30)
    self.ActionSettings.Size = UDim2.new(0.34, -2, 0, 42)

    for _, b in ipairs({
        self.ActionSearch,
        self.ActionQueue,
        self.ActionSettings,
    }) do
        stroke(b, COLORS.White, 0.95, 1)
    end

    self._connections[#self._connections + 1] =
        self.ActionSearch.MouseButton1Click:Connect(function()
            self:OpenSearch()
        end)

    self._connections[#self._connections + 1] =
        self.ActionQueue.MouseButton1Click:Connect(function()
            self:SetQueueVisible(true)
        end)

    self._connections[#self._connections + 1] =
        self.ActionSettings.MouseButton1Click:Connect(function()
            self:OpenSettings()
        end)
end

----------------------------------------------------------------
-- Bottom player bar
----------------------------------------------------------------

function Ui:_buildPlayerBar()
    self.PlayerBar = make("Frame", {
        Parent = self.Window,
        Name = "PlayerBar",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(0, 0, 1, -88),
        Size = UDim2.new(1, 0, 0, 88),
        ZIndex = 30,
    })

    stroke(self.PlayerBar, COLORS.White, 0.93, 1)

    self.TrackThumb = make("ImageLabel", {
        Parent = self.PlayerBar,
        BackgroundColor3 = COLORS.Surface2,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(14, 16),
        Size = UDim2.fromOffset(56, 56),
        Image = "",
        ScaleType = Enum.ScaleType.Crop,
    })
    corner(self.TrackThumb, 10)

    self.TrackTitle = label(
        self.PlayerBar,
        "Nothing playing",
        13,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.TrackTitle.Position = UDim2.fromOffset(82, 15)
    self.TrackTitle.Size = UDim2.new(0.27, 0, 0, 21)
    self.TrackTitle.TextTruncate = Enum.TextTruncate.AtEnd

    self.TrackArtist = label(
        self.PlayerBar,
        "—",
        11,
        COLORS.TextSecondary
    )
    self.TrackArtist.Position = UDim2.fromOffset(82, 37)
    self.TrackArtist.Size = UDim2.new(0.27, 0, 0, 18)
    self.TrackArtist.TextTruncate = Enum.TextTruncate.AtEnd

    self.ProgressBack = make("Frame", {
        Parent = self.PlayerBar,
        BackgroundColor3 = COLORS.Surface3,
        BorderSizePixel = 0,
        Position = UDim2.new(0.39, 0, 1, -19),
        Size = UDim2.new(0.40, 0, 0, 4),
        ZIndex = 31,
    })
    corner(self.ProgressBack, 4)

    self.ProgressFill = make("Frame", {
        Parent = self.ProgressBack,
        BackgroundColor3 = COLORS.Accent,
        BorderSizePixel = 0,
        Size = UDim2.new(0, 0, 1, 0),
        ZIndex = 32,
    })
    corner(self.ProgressFill, 4)

    self.ProgressButton = make("TextButton", {
        Parent = self.PlayerBar,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Text = "",
        AutoButtonColor = false,
        Position = UDim2.new(0.39, 0, 1, -30),
        Size = UDim2.new(0.40, 0, 0, 22),
        ZIndex = 33,
    })

    self.TimeLabel = label(
        self.PlayerBar,
        "0:00 / 0:00",
        10,
        COLORS.TextMuted
    )
    self.TimeLabel.Position = UDim2.new(0.39, 0, 1, -47)
    self.TimeLabel.Size = UDim2.new(0.40, 0, 0, 15)
    self.TimeLabel.TextXAlignment = Enum.TextXAlignment.Right
    self.TimeLabel.ZIndex = 33

    self.PreviousButton = button(self.PlayerBar, "◀", 14, COLORS.Surface2)
    self.PreviousButton.Size = UDim2.fromOffset(38, 38)
    self.PreviousButton.Position = UDim2.new(0.80, 0, 0.5, 0)
    self.PreviousButton.AnchorPoint = Vector2.new(0, 0.5)
    self.PreviousButton.ZIndex = 32

    self.PlayButton = button(self.PlayerBar, "▶", 16, COLORS.Accent)
    self.PlayButton.Size = UDim2.fromOffset(46, 46)
    self.PlayButton.Position = UDim2.new(0.845, 0, 0.5, 0)
    self.PlayButton.AnchorPoint = Vector2.new(0, 0.5)
    self.PlayButton.ZIndex = 32
    corner(self.PlayButton, 13)

    self.NextButton = button(self.PlayerBar, "▶", 14, COLORS.Surface2)
    self.NextButton.Size = UDim2.fromOffset(38, 38)
    self.NextButton.Position = UDim2.new(0.90, 0, 0.5, 0)
    self.NextButton.AnchorPoint = Vector2.new(0, 0.5)
    self.NextButton.ZIndex = 32

    self.MoreButton = button(self.PlayerBar, "⋮", 18, COLORS.Surface2)
    self.MoreButton.Size = UDim2.fromOffset(34, 38)
    self.MoreButton.Position = UDim2.new(1, -42, 0.5, 0)
    self.MoreButton.AnchorPoint = Vector2.new(0, 0.5)
    self.MoreButton.ZIndex = 32

    self.VolumeButton = button(self.PlayerBar, "🔊", 12, COLORS.Surface2)
    self.VolumeButton.Size = UDim2.fromOffset(42, 38)
    self.VolumeButton.Position = UDim2.new(1, -92, 0.5, 0)
    self.VolumeButton.AnchorPoint = Vector2.new(0, 0.5)
    self.VolumeButton.ZIndex = 32

    self._connections[#self._connections + 1] =
        self.PreviousButton.MouseButton1Click:Connect(function()
            self:_controllerCall("Previous")
        end)

    self._connections[#self._connections + 1] =
        self.PlayButton.MouseButton1Click:Connect(function()
            self:_controllerCall("TogglePlay")
        end)

    self._connections[#self._connections + 1] =
        self.NextButton.MouseButton1Click:Connect(function()
            self:_controllerCall("Next")
        end)

    self._connections[#self._connections + 1] =
        self.VolumeButton.MouseButton1Click:Connect(function()
            self:_controllerCall("ToggleMute")
        end)

    self._connections[#self._connections + 1] =
        self.MoreButton.MouseButton1Click:Connect(function()
            self:SetQueueVisible(true)
        end)

    self._connections[#self._connections + 1] =
        self.ProgressButton.MouseButton1Click:Connect(function()
            self:_seekFromMouse(self.ProgressButton)
        end)
end

function Ui:_seekFromMouse(buttonObject)
    if not self.Controller or not self.CurrentDuration or self.CurrentDuration <= 0 then
        return
    end

    local mouse = UserInputService:GetMouseLocation()
    local absolutePosition = buttonObject.AbsolutePosition
    local absoluteSize = buttonObject.AbsoluteSize

    local relative = clamp(
        (mouse.X - absolutePosition.X) / math.max(absoluteSize.X, 1),
        0,
        1
    )

    local target = relative * self.CurrentDuration
    self:_controllerCall("Seek", target)
end

----------------------------------------------------------------
-- Queue panel
----------------------------------------------------------------

function Ui:_buildQueuePanel()
    self.QueuePanel = make("Frame", {
        Parent = self.Window,
        Name = "QueuePanel",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(1, 8, 0, 62),
        Size = UDim2.new(0.34, 0, 1, -150),
        ZIndex = 40,
        ClipsDescendants = true,
    })

    corner(self.QueuePanel, 14)
    stroke(self.QueuePanel, COLORS.White, 0.93, 1)

    self.QueueHeader = label(
        self.QueuePanel,
        "Queue",
        16,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.QueueHeader.Position = UDim2.fromOffset(16, 16)
    self.QueueHeader.Size = UDim2.new(1, -60, 0, 25)

    self.QueueCount = label(
        self.QueuePanel,
        "0 tracks",
        10,
        COLORS.TextMuted
    )
    self.QueueCount.Position = UDim2.fromOffset(16, 41)
    self.QueueCount.Size = UDim2.new(1, -32, 0, 18)

    self.QueueClose = button(
        self.QueuePanel,
        "×",
        20,
        COLORS.Surface2
    )
    self.QueueClose.Size = UDim2.fromOffset(34, 34)
    self.QueueClose.Position = UDim2.new(1, -48, 0, 13)
    self.QueueClose.ZIndex = 42

    self.QueueScroll = make("ScrollingFrame", {
        Parent = self.QueuePanel,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(10, 70),
        Size = UDim2.new(1, -20, 1, -80),
        ScrollBarThickness = 3,
        ScrollBarImageColor3 = COLORS.Surface3,
        AutomaticCanvasSize = Enum.AutomaticSize.Y,
        CanvasSize = UDim2.fromOffset(0, 0),
        ZIndex = 41,
    })

    padding(self.QueueScroll, 0, 0, 0, 10)

    self.QueueLayout = make("UIListLayout", {
        Parent = self.QueueScroll,
        Padding = UDim.new(0, 6),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    self._connections[#self._connections + 1] =
        self.QueueClose.MouseButton1Click:Connect(function()
            self:SetQueueVisible(false)
        end)
end

function Ui:_clearQueueRows()
    for _, child in ipairs(self.QueueScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end
end

function Ui:_renderQueue()
    self:_clearQueueRows()

    local tracks = self.Queue and self:_queueCall(
        {"GetAll", "GetTracks"}
    ) or {}

    if type(tracks) ~= "table" then
        tracks = {}
    end

    local currentIndex = self.Queue and self:_queueCall(
        {"GetCurrentIndex", "GetCurrentPosition"}
    ) or nil

    self.QueueCount.Text = string.format("%d tracks", #tracks)

    for index, track in ipairs(tracks) do
        local isCurrent = index == currentIndex

        local row = make("Frame", {
            Parent = self.QueueScroll,
            BackgroundColor3 = isCurrent and COLORS.Surface3 or COLORS.Surface2,
            BackgroundTransparency = isCurrent and 0 or 0.28,
            BorderSizePixel = 0,
            Size = UDim2.new(1, 0, 0, 60),
            LayoutOrder = index,
        })

        corner(row, 11)

        local art = make("ImageLabel", {
            Parent = row,
            BackgroundColor3 = COLORS.Surface3,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(7, 7),
            Size = UDim2.fromOffset(46, 46),
            Image = getTrackArt(track),
            ScaleType = Enum.ScaleType.Crop,
        })
        corner(art, 8)

        local title = label(
            row,
            getTrackTitle(track),
            11,
            isCurrent and COLORS.AccentGlow or COLORS.Text,
            Enum.Font.GothamBold
        )
        title.Position = UDim2.fromOffset(61, 9)
        title.Size = UDim2.new(1, -100, 0, 20)
        title.TextTruncate = Enum.TextTruncate.AtEnd

        local artist = label(
            row,
            getTrackArtist(track),
            10,
            COLORS.TextMuted
        )
        artist.Position = UDim2.fromOffset(61, 29)
        artist.Size = UDim2.new(1, -100, 0, 17)
        artist.TextTruncate = Enum.TextTruncate.AtEnd

        local indexLabel = label(
            row,
            tostring(index),
            10,
            isCurrent and COLORS.Accent or COLORS.TextMuted,
            Enum.Font.GothamBold
        )
        indexLabel.Position = UDim2.new(1, -31, 0, 0)
        indexLabel.Size = UDim2.fromOffset(24, 60)
        indexLabel.TextXAlignment = Enum.TextXAlignment.Center

        local click = make("TextButton", {
            Parent = row,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 5,
        })

        click.MouseButton1Click:Connect(function()
            local queue = self.Queue

            if queue then
                local ok = self:_queueCall(
                    {"SetCurrentIndex", "Jump", "PlayIndex"},
                    index
                )

                if ok ~= false then
                    self:_controllerCall("Play", track)
                end
            else
                self:_controllerCall("Play", track)
            end

            self:_renderQueue()
        end)

        click.MouseEnter:Connect(function()
            tween(row, FAST, {
                BackgroundTransparency = isCurrent and 0 or 0.08,
            })
        end)

        click.MouseLeave:Connect(function()
            tween(row, FAST, {
                BackgroundTransparency = isCurrent and 0 or 0.28,
            })
        end)
    end
end

----------------------------------------------------------------
-- Mini player
----------------------------------------------------------------

function Ui:_buildMiniPlayer()
    self.Mini = make("Frame", {
        Parent = self.Root,
        Name = "MiniPlayer",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(1, -18, 1, -18),
        AnchorPoint = Vector2.new(1, 1),
        Size = UDim2.fromOffset(330, 70),
        Visible = false,
        ZIndex = 80,
    })

    corner(self.Mini, 16)
    stroke(self.Mini, COLORS.White, 0.90, 1)

    self.MiniArt = make("ImageLabel", {
        Parent = self.Mini,
        BackgroundColor3 = COLORS.Surface2,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(8, 8),
        Size = UDim2.fromOffset(54, 54),
        Image = "",
        ScaleType = Enum.ScaleType.Crop,
        ZIndex = 81,
    })
    corner(self.MiniArt, 11)

    self.MiniTitle = label(
        self.Mini,
        "Nothing playing",
        11,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.MiniTitle.Position = UDim2.fromOffset(72, 10)
    self.MiniTitle.Size = UDim2.new(1, -180, 0, 20)
    self.MiniTitle.TextTruncate = Enum.TextTruncate.AtEnd
    self.MiniTitle.ZIndex = 81

    self.MiniArtist = label(
        self.Mini,
        "—",
        9,
        COLORS.TextMuted
    )
    self.MiniArtist.Position = UDim2.fromOffset(72, 31)
    self.MiniArtist.Size = UDim2.new(1, -180, 0, 17)
    self.MiniArtist.TextTruncate = Enum.TextTruncate.AtEnd
    self.MiniArtist.ZIndex = 81

    self.MiniPlay = button(
        self.Mini,
        "▶",
        13,
        COLORS.Accent
    )
    self.MiniPlay.Size = UDim2.fromOffset(38, 38)
    self.MiniPlay.Position = UDim2.new(1, -82, 0.5, 0)
    self.MiniPlay.AnchorPoint = Vector2.new(0, 0.5)
    self.MiniPlay.ZIndex = 82
    corner(self.MiniPlay, 12)

    self.MiniOpen = button(
        self.Mini,
        "↗",
        13,
        COLORS.Surface2
    )
    self.MiniOpen.Size = UDim2.fromOffset(30, 30)
    self.MiniOpen.Position = UDim2.new(1, -40, 0.5, 0)
    self.MiniOpen.AnchorPoint = Vector2.new(0, 0.5)
    self.MiniOpen.ZIndex = 82

    self._connections[#self._connections + 1] =
        self.MiniPlay.MouseButton1Click:Connect(function()
            self:_controllerCall("TogglePlay")
        end)

    self._connections[#self._connections + 1] =
        self.MiniOpen.MouseButton1Click:Connect(function()
            self:SetMinimized(false)
        end)
end

----------------------------------------------------------------
-- Search overlay
----------------------------------------------------------------

function Ui:_buildSearchOverlay()
    self.SearchOverlay = make("Frame", {
        Parent = self.Root,
        Name = "SearchOverlay",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(0.5, 0, -0.2, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.new(0.76, 0, 0, 260),
        Visible = false,
        ZIndex = 100,
    })

    corner(self.SearchOverlay, 16)
    stroke(self.SearchOverlay, COLORS.White, 0.89, 1)

    self.SearchHeader = label(
        self.SearchOverlay,
        "Search",
        17,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    self.SearchHeader.Position = UDim2.fromOffset(18, 14)
    self.SearchHeader.Size = UDim2.new(1, -72, 0, 28)
    self.SearchHeader.ZIndex = 101

    self.SearchClose = button(
        self.SearchOverlay,
        "×",
        20,
        COLORS.Surface2
    )
    self.SearchClose.Size = UDim2.fromOffset(34, 34)
    self.SearchClose.Position = UDim2.new(1, -48, 0, 10)
    self.SearchClose.ZIndex = 102

    self.SearchBox = make("TextBox", {
        Parent = self.SearchOverlay,
        BackgroundColor3 = COLORS.Surface2,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 55),
        Size = UDim2.new(1, -36, 0, 46),
        ClearTextOnFocus = false,
        Font = FONT,
        Text = "",
        PlaceholderText = "Song name, YouTube URL, or supported source URL...",
        PlaceholderColor3 = COLORS.TextMuted,
        TextColor3 = COLORS.Text,
        TextSize = 12,
        TextXAlignment = Enum.TextXAlignment.Left,
        ZIndex = 101,
    })
    corner(self.SearchBox, 11)
    padding(self.SearchBox, 14, 0, 14, 0)

    self.SearchSubmit = button(
        self.SearchOverlay,
        "Search",
        12,
        COLORS.Accent
    )
    self.SearchSubmit.Position = UDim2.new(1, -120, 0, 116)
    self.SearchSubmit.Size = UDim2.fromOffset(102, 38)
    self.SearchSubmit.ZIndex = 102

    self.SearchHint = label(
        self.SearchOverlay,
        "Tip: paste a URL or search normally.",
        10,
        COLORS.TextMuted
    )
    self.SearchHint.Position = UDim2.fromOffset(18, 117)
    self.SearchHint.Size = UDim2.new(1, -140, 0, 36)
    self.SearchHint.TextWrapped = true
    self.SearchHint.ZIndex = 101

    self.SearchStatus = label(
        self.SearchOverlay,
        "",
        10,
        COLORS.TextSecondary
    )
    self.SearchStatus.Position = UDim2.fromOffset(18, 165)
    self.SearchStatus.Size = UDim2.new(1, -36, 0, 22)
    self.SearchStatus.ZIndex = 101

    self._connections[#self._connections + 1] =
        self.SearchClose.MouseButton1Click:Connect(function()
            self:CloseSearch()
        end)

    self._connections[#self._connections + 1] =
        self.SearchSubmit.MouseButton1Click:Connect(function()
            self:_submitSearch()
        end)

    self._connections[#self._connections + 1] =
        self.SearchBox.FocusLost:Connect(function(enterPressed)
            if enterPressed then
                self:_submitSearch()
            end
        end)
end

function Ui:_submitSearch()
    local query = self.SearchBox.Text

    if query:gsub("%s+", "") == "" then
        self.SearchStatus.Text = "Enter something to search."
        self.SearchStatus.TextColor3 = COLORS.Warning
        return
    end

    self.SearchStatus.Text = "Searching..."
    self.SearchStatus.TextColor3 = COLORS.TextSecondary

    local ok, result = safeCall(self.SearchCallback, query)

    if ok then
        self.SearchStatus.Text = "Search request sent."
        self.SearchStatus.TextColor3 = COLORS.Success
    elseif self.Controller then
        local called, searchResult = self:_controllerCall("Search", query)

        if called then
            self.SearchStatus.Text = "Search request sent."
            self.SearchStatus.TextColor3 = COLORS.Success
        else
            self.SearchStatus.Text = "Search is not connected yet."
            self.SearchStatus.TextColor3 = COLORS.Warning
        end
    else
        self.SearchStatus.Text = "Search is not connected yet."
        self.SearchStatus.TextColor3 = COLORS.Warning
    end
end

----------------------------------------------------------------
-- Settings
----------------------------------------------------------------

function Ui:_buildSettings()
    self.Settings = make("Frame", {
        Parent = self.Root,
        Name = "Settings",
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(0.5, 0, -0.2, 0),
        AnchorPoint = Vector2.new(0.5, 0.5),
        Size = UDim2.new(0.56, 0, 0, 340),
        Visible = false,
        ZIndex = 110,
    })

    corner(self.Settings, 16)
    stroke(self.Settings, COLORS.White, 0.89, 1)

    local title = label(
        self.Settings,
        "Settings",
        17,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    title.Position = UDim2.fromOffset(18, 14)
    title.Size = UDim2.new(1, -70, 0, 30)
    title.ZIndex = 111

    self.SettingsClose = button(
        self.Settings,
        "×",
        20,
        COLORS.Surface2
    )
    self.SettingsClose.Size = UDim2.fromOffset(34, 34)
    self.SettingsClose.Position = UDim2.new(1, -48, 0, 10)
    self.SettingsClose.ZIndex = 112

    self.SettingsList = make("Frame", {
        Parent = self.Settings,
        BackgroundTransparency = 1,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(18, 58),
        Size = UDim2.new(1, -36, 1, -70),
        ZIndex = 111,
    })

    local layout = make("UIListLayout", {
        Parent = self.SettingsList,
        Padding = UDim.new(0, 7),
        SortOrder = Enum.SortOrder.LayoutOrder,
    })

    self.RepeatSetting = self:_createSettingButton(
        "Repeat",
        "Off",
        1
    )

    self.ShuffleSetting = self:_createSettingButton(
        "Shuffle",
        "Off",
        2
    )

    self.AutoNextSetting = self:_createSettingButton(
        "Auto Next",
        "On",
        3
    )

    self.MuteSetting = self:_createSettingButton(
        "Mute",
        "Off",
        4
    )

    self.CacheSetting = self:_createSettingButton(
        "Cache",
        "Clear",
        5
    )

    self._connections[#self._connections + 1] =
        self.SettingsClose.MouseButton1Click:Connect(function()
            self:CloseSettings()
        end)

    self._connections[#self._connections + 1] =
        self.RepeatSetting.Button.MouseButton1Click:Connect(function()
            self:_controllerCall("CycleRepeat")
        end)

    self._connections[#self._connections + 1] =
        self.ShuffleSetting.Button.MouseButton1Click:Connect(function()
            self:_controllerCall("ToggleShuffle")
        end)

    self._connections[#self._connections + 1] =
        self.AutoNextSetting.Button.MouseButton1Click:Connect(function()
            local enabled = self.Controller and self.Controller.AutoNext
            self:_controllerCall("SetAutoNext", not enabled)
        end)

    self._connections[#self._connections + 1] =
        self.MuteSetting.Button.MouseButton1Click:Connect(function()
            self:_controllerCall("ToggleMute")
        end)

    self._connections[#self._connections + 1] =
        self.CacheSetting.Button.MouseButton1Click:Connect(function()
            local ok = self:_controllerCall("ClearCache")

            if ok then
                self:Notify("Cache cleared", "Success")
            else
                self:Notify("Cache is not connected", "Warning")
            end
        end)
end

function Ui:_createSettingButton(title, value, order)
    local row = make("Frame", {
        Parent = self.SettingsList,
        BackgroundColor3 = COLORS.Surface2,
        BorderSizePixel = 0,
        Size = UDim2.new(1, 0, 0, 50),
        LayoutOrder = order,
        ZIndex = 111,
    })

    corner(row, 10)

    local nameLabel = label(
        row,
        title,
        12,
        COLORS.Text,
        Enum.Font.GothamBold
    )
    nameLabel.Position = UDim2.fromOffset(13, 0)
    nameLabel.Size = UDim2.new(0.55, 0, 1, 0)

    local actionButton = button(
        row,
        value,
        11,
        COLORS.Surface3
    )
    actionButton.Size = UDim2.fromOffset(100, 34)
    actionButton.Position = UDim2.new(1, -111, 0.5, 0)
    actionButton.AnchorPoint = Vector2.new(0, 0.5)
    actionButton.ZIndex = 113

    return {
        Row = row,
        Label = nameLabel,
        Button = actionButton,
    }
end

----------------------------------------------------------------
-- Toast
----------------------------------------------------------------

function Ui:_buildToast()
    self.Toast = make("Frame", {
        Parent = self.Root,
        BackgroundColor3 = COLORS.Surface,
        BorderSizePixel = 0,
        Position = UDim2.new(0.5, 0, 1, -26),
        AnchorPoint = Vector2.new(0.5, 1),
        Size = UDim2.fromOffset(330, 48),
        Visible = false,
        ZIndex = 200,
    })

    corner(self.Toast, 12)
    stroke(self.Toast, COLORS.White, 0.9, 1)

    self.ToastDot = make("Frame", {
        Parent = self.Toast,
        BackgroundColor3 = COLORS.Accent,
        BorderSizePixel = 0,
        Position = UDim2.fromOffset(12, 17),
        Size = UDim2.fromOffset(14, 14),
        ZIndex = 201,
    })
    corner(self.ToastDot, 14)

    self.ToastText = label(
        self.Toast,
        "",
        11,
        COLORS.Text
    )
    self.ToastText.Position = UDim2.fromOffset(37, 0)
    self.ToastText.Size = UDim2.new(1, -49, 1, 0)
    self.ToastText.TextTruncate = Enum.TextTruncate.AtEnd
    self.ToastText.ZIndex = 201
end

function Ui:Notify(message, level)
    self._toastToken += 1

    local token = self._toastToken

    local color = COLORS.Accent

    if level == "Success" then
        color = COLORS.Success
    elseif level == "Warning" then
        color = COLORS.Warning
    elseif level == "Error" then
        color = COLORS.Error
    end

    self.ToastDot.BackgroundColor3 = color
    self.ToastText.Text = tostring(message)
    self.Toast.Visible = true
    self.Toast.Position = UDim2.new(0.5, 0, 1, 12)

    tween(self.Toast, SPRING, {
        Position = UDim2.new(0.5, 0, 1, -26),
    })

    task.delay(2.8, function()
        if token ~= self._toastToken then
            return
        end

        local out = tween(self.Toast, FAST, {
            Position = UDim2.new(0.5, 0, 1, 12),
        })

        if out then
            out.Completed:Wait()
        end

        if token == self._toastToken then
            self.Toast.Visible = false
        end
    end)
end

----------------------------------------------------------------
-- Controller adapter
----------------------------------------------------------------

function Ui:_controllerCall(methodName, ...)
    local controller = self.Controller

    if not controller then
        return false, "No controller attached"
    end

    local method = controller[methodName]

    if type(method) ~= "function" then
        return false, "Controller method missing: " .. methodName
    end

    local ok, a, b, c = pcall(
        method,
        controller,
        ...
    )

    if not ok then
        self:Notify("Player error", "Error")
        warn("[MusicPlayer UI]", a)
        return false, tostring(a)
    end

    return true, a, b, c
end

function Ui:_queueCall(methods, ...)
    local queue = self.Queue

    if not queue then
        return nil
    end

    for _, methodName in ipairs(methods) do
        local method = queue[methodName]

        if type(method) == "function" then
            local ok, a, b, c = pcall(
                method,
                queue,
                ...
            )

            if ok then
                return a, b, c
            end
        end
    end

    return nil
end

----------------------------------------------------------------
-- Bind MusicPlayer / Queue
----------------------------------------------------------------

function Ui:BindPlayer(controller)
    self:UnbindPlayer()

    self.Controller = controller

    if not controller then
        return self
    end

    local function connectEvent(name, callback)
        if type(controller.On) ~= "function" then
            return
        end

        local ok, connection = pcall(
            controller.On,
            controller,
            name,
            callback
        )

        if ok and connection then
            table.insert(self._controllerConnections, connection)
        end
    end

    connectEvent("TrackChanged", function(track)
        self:SetTrack(track)
    end)

    connectEvent("TrackLoading", function(track)
        self:SetTrack(track)
        self:SetState("Loading")
    end)

    connectEvent("StateChanged", function(state)
        self:SetState(state)
    end)

    connectEvent("Progress", function(position, duration)
        self:SetProgress(position, duration)
    end)

    connectEvent("VolumeChanged", function(volume, muted)
        self:SetVolumeState(volume, muted)
    end)

    connectEvent("RepeatChanged", function(mode)
        self.CurrentRepeat = mode
        self:_refreshSettings()
    end)

    connectEvent("ShuffleChanged", function(enabled)
        self.CurrentShuffle = enabled == true
        self:_refreshSettings()
    end)

    connectEvent("Notification", function(payload)
        if type(payload) == "table" then
            self:Notify(payload.message, payload.level)
        else
            self:Notify(payload)
        end
    end)

    connectEvent("QueueEnded", function()
        self:Notify("Queue finished", "Success")
    end)

    -- Initial state sync.
    local snapshotMethod = controller.GetSnapshot

    if type(snapshotMethod) == "function" then
        local ok, snapshot = pcall(snapshotMethod, controller)

        if ok and type(snapshot) == "table" then
            self:SetTrack(snapshot.track)
            self:SetState(snapshot.state)
            self:SetProgress(snapshot.position, snapshot.duration)
            self:SetVolumeState(snapshot.volume, snapshot.muted)

            self.CurrentRepeat = snapshot.repeatMode or "Off"
            self.CurrentShuffle = snapshot.shuffle == true
        end
    end

    self:_refreshSettings()

    return self
end

function Ui:UnbindPlayer()
    for _, connection in ipairs(self._controllerConnections) do
        if connection and type(connection.Disconnect) == "function" then
            pcall(connection.Disconnect, connection)
        end
    end

    self._controllerConnections = {}
    self.Controller = nil

    return self
end

function Ui:BindQueue(queue)
    self:UnbindQueue()

    self.Queue = queue

    if not queue then
        self:_renderQueue()
        return self
    end

    local function connectEvent(name, callback)
        if type(queue.On) ~= "function" then
            return
        end

        local ok, connection = pcall(
            queue.On,
            queue,
            name,
            callback
        )

        if ok and connection then
            table.insert(self._queueConnections, connection)
        end
    end

    for _, eventName in ipairs({
        "Changed",
        "Added",
        "Removed",
        "Cleared",
        "CurrentChanged",
        "ShuffleChanged",
        "RepeatChanged",
    }) do
        connectEvent(eventName, function()
            self:_renderQueue()
        end)
    end

    self:_renderQueue()

    return self
end

function Ui:UnbindQueue()
    for _, connection in ipairs(self._queueConnections) do
        if connection and type(connection.Disconnect) == "function" then
            pcall(connection.Disconnect, connection)
        end
    end

    self._queueConnections = {}
    self.Queue = nil

    return self
end

function Ui:SetSearchCallback(callback)
    self.SearchCallback = callback
    return self
end

function Ui:SetActionCallback(callback)
    self.ActionCallback = callback
    return self
end

----------------------------------------------------------------
-- Track / playback UI
----------------------------------------------------------------

function Ui:SetTrack(track)
    self.CurrentTrack = track

    local title = getTrackTitle(track)
    local artist = getTrackArtist(track)
    local art = getTrackArt(track)

    self.TrackTitle.Text = title
    self.TrackArtist.Text = artist

    self.HeroTitle.Text = title
    self.HeroArtist.Text = artist

    self.TrackThumb.Image = art
    self.HeroArt.Image = art

    self.MiniTitle.Text = title
    self.MiniArtist.Text = artist
    self.MiniArt.Image = art

    self:EmitAction("TrackChanged", track)
end

function Ui:SetState(state)
    self.CurrentState = state or "Idle"

    local stateText = string.upper(tostring(self.CurrentState))

    self.HeroState.Text = stateText

    if self.CurrentState == "Playing" then
        self.HeroPlay.Text = "Ⅱ"
        self.PlayButton.Text = "Ⅱ"
        self.MiniPlay.Text = "Ⅱ"

        if not self.Minimized then
            self.HeroPlay.BackgroundColor3 = COLORS.Accent
        end
    elseif self.CurrentState == "Loading" or self.CurrentState == "Buffering" then
        self.HeroPlay.Text = "…"
        self.PlayButton.Text = "…"
        self.MiniPlay.Text = "…"
    else
        self.HeroPlay.Text = "▶"
        self.PlayButton.Text = "▶"
        self.MiniPlay.Text = "▶"
    end
end

function Ui:SetProgress(position, duration)
    self.CurrentPosition = tonumber(position) or 0
    self.CurrentDuration = tonumber(duration) or 0

    local progress = 0

    if self.CurrentDuration > 0 then
        progress = math.clamp(
            self.CurrentPosition / self.CurrentDuration,
            0,
            1
        )
    end

    self.ProgressFill.Size = UDim2.new(progress, 0, 1, 0)

    self.TimeLabel.Text =
        formatTime(self.CurrentPosition)
        .. " / "
        .. formatTime(self.CurrentDuration)
end

function Ui:SetVolumeState(volume, muted)
    self.CurrentVolume = tonumber(volume) or self.CurrentVolume
    self.CurrentMuted = muted == true

    if self.CurrentMuted then
        self.VolumeButton.Text = "×"
        self.MuteSetting.Button.Text = "On"
    else
        self.VolumeButton.Text = self.CurrentVolume <= 0
            and "×"
            or "🔊"

        self.MuteSetting.Button.Text = "Off"
    end
end

function Ui:_refreshSettings()
    self.RepeatSetting.Button.Text =
        self.CurrentRepeat or "Off"

    self.ShuffleSetting.Button.Text =
        self.CurrentShuffle and "On" or "Off"

    local autoNext = self.Controller
        and self.Controller.AutoNext ~= false

    self.AutoNextSetting.Button.Text =
        autoNext and "On" or "Off"

    self.MuteSetting.Button.Text =
        self.CurrentMuted and "On" or "Off"
end

----------------------------------------------------------------
-- Recent cards
----------------------------------------------------------------

function Ui:SetRecent(tracks)
    for _, child in ipairs(self.RecentScroll:GetChildren()) do
        if child:IsA("Frame") then
            child:Destroy()
        end
    end

    if type(tracks) ~= "table" then
        return
    end

    for index, track in ipairs(tracks) do
        if index > 12 then
            break
        end

        local card = make("Frame", {
            Parent = self.RecentScroll,
            BackgroundColor3 = COLORS.Surface,
            BorderSizePixel = 0,
            Size = UDim2.fromOffset(118, 116),
            LayoutOrder = index,
        })

        corner(card, 12)

        local art = make("ImageLabel", {
            Parent = card,
            BackgroundColor3 = COLORS.Surface2,
            BorderSizePixel = 0,
            Position = UDim2.fromOffset(7, 7),
            Size = UDim2.fromOffset(104, 68),
            Image = getTrackArt(track),
            ScaleType = Enum.ScaleType.Crop,
        })
        corner(art, 9)

        local title = label(
            card,
            getTrackTitle(track),
            10,
            COLORS.Text,
            Enum.Font.GothamBold
        )
        title.Position = UDim2.fromOffset(8, 78)
        title.Size = UDim2.new(1, -16, 0, 17)
        title.TextTruncate = Enum.TextTruncate.AtEnd

        local artist = label(
            card,
            getTrackArtist(track),
            9,
            COLORS.TextMuted
        )
        artist.Position = UDim2.fromOffset(8, 95)
        artist.Size = UDim2.new(1, -16, 0, 15)
        artist.TextTruncate = Enum.TextTruncate.AtEnd

        local click = make("TextButton", {
            Parent = card,
            BackgroundTransparency = 1,
            BorderSizePixel = 0,
            Text = "",
            AutoButtonColor = false,
            Size = UDim2.fromScale(1, 1),
            ZIndex = 10,
        })

        click.MouseButton1Click:Connect(function()
            self:_controllerCall("Play", track)
        end)

        click.MouseEnter:Connect(function()
            tween(card, FAST, {
                BackgroundColor3 = COLORS.Surface3,
            })
        end)

        click.MouseLeave:Connect(function()
            tween(card, FAST, {
                BackgroundColor3 = COLORS.Surface,
            })
        end)
    end
end

----------------------------------------------------------------
-- Window controls
----------------------------------------------------------------

function Ui:Show()
    self.Visible = true

    self.Window.Visible = true

    self.WindowScale.Scale = 0.96

    tween(self.WindowScale, SLOW, {
        Scale = 1,
    })

    return self
end

function Ui:Hide()
    self.Visible = false

    tween(self.WindowScale, FAST, {
        Scale = 0.96,
    })

    task.delay(0.13, function()
        if not self.Visible and self.Window then
            self.Window.Visible = false
        end
    end)

    return self
end

function Ui:Toggle()
    if self.Visible then
        return self:Hide()
    end

    return self:Show()
end

function Ui:SetMinimized(minimized)
    minimized = minimized == true

    self.Minimized = minimized

    if minimized then
        self.Window.Visible = false
        self.Mini.Visible = true
        self:CloseOverlays()
    else
        self.Mini.Visible = false

        if self.Visible then
            self.Window.Visible = true
        end
    end

    return self
end

function Ui:IsMinimized()
    return self.Minimized
end

----------------------------------------------------------------
-- Queue panel
----------------------------------------------------------------

function Ui:SetQueueVisible(visible)
    visible = visible == true

    self.QueuePanel.Visible = true

    local targetX

    if visible then
        targetX = UDim2.new(1, -10, 0, 62)
    else
        targetX = UDim2.new(1, 8, 0, 62)
    end

    tween(self.QueuePanel, SPRING, {
        Position = targetX,
    })

    if not visible then
        task.delay(0.25, function()
            if not visible then
                self.QueuePanel.Visible = false
            end
        end)
    end

    return self
end

----------------------------------------------------------------
-- Search/settings overlays
----------------------------------------------------------------

function Ui:_setShadeVisible(visible)
    self.Shade.Visible = visible
end

function Ui:OpenSearch()
    self:CloseSettings()
    self:CloseQueueOverlay()
    self:_setShadeVisible(true)

    self.SearchOverlay.Visible = true
    self.SearchOverlay.Position = UDim2.new(0.5, 0, -0.2, 0)

    tween(self.SearchOverlay, SPRING, {
        Position = UDim2.new(0.5, 0, 0.50, 0),
    })

    task.defer(function()
        self.SearchBox:CaptureFocus()
    end)
end

function Ui:CloseSearch()
    if not self.SearchOverlay.Visible then
        return
    end

    tween(self.SearchOverlay, FAST, {
        Position = UDim2.new(0.5, 0, -0.2, 0),
    })

    task.delay(0.13, function()
        if self.SearchOverlay then
            self.SearchOverlay.Visible = false
        end
    end)

    self:_setShadeVisible(false)
end

function Ui:OpenSettings()
    self:CloseSearch()
    self:CloseQueueOverlay()
    self:_setShadeVisible(true)

    self.Settings.Visible = true
    self.Settings.Position = UDim2.new(0.5, 0, -0.2, 0)

    tween(self.Settings, SPRING, {
        Position = UDim2.new(0.5, 0, 0.50, 0),
    })

    self:_refreshSettings()
end

function Ui:CloseSettings()
    if not self.Settings.Visible then
        return
    end

    tween(self.Settings, FAST, {
        Position = UDim2.new(0.5, 0, -0.2, 0),
    })

    task.delay(0.13, function()
        if self.Settings then
            self.Settings.Visible = false
        end
    end)

    self:_setShadeVisible(false)
end

function Ui:CloseQueueOverlay()
    -- Queue is an attached side panel rather than a modal.
    self:SetQueueVisible(false)
end

function Ui:CloseOverlays()
    self:CloseSearch()
    self:CloseSettings()
    self:SetQueueVisible(false)
end

----------------------------------------------------------------
-- Responsive layout
----------------------------------------------------------------

function Ui:_bindResponsive()
    local function update()
        if not self.Window or not self.Window.Parent then
            return
        end

        local camera = workspace.CurrentCamera
        if not camera then
            return
        end

        local viewport = camera.ViewportSize
        local width = viewport.X
        local height = viewport.Y

        self.Mobile = width < 700

        if self.Mobile then
            self.Window.Size = UDim2.new(
                1,
                -16,
                1,
                -32
            )

            self.Window.Position = UDim2.new(
                0.5,
                0,
                0.5,
                0
            )

            self.SearchButton.Visible = false

            self.QueuePanel.Size = UDim2.new(
                0.90,
                0,
                1,
                -150
            )

            self.QueuePanel.Position = UDim2.new(
                1,
                8,
                0,
                62
            )

            self.Hero.Size = UDim2.new(
                1,
                0,
                0,
                154
            )

            self.HeroArt.Size = UDim2.fromOffset(106, 106)
            self.HeroTitle.TextSize = 19
            self.HeroArtist.TextSize = 12

            self.HeroEyebrow.Position = UDim2.new(0, 136, 0, 20)
            self.HeroTitle.Position = UDim2.new(0, 136, 0, 42)
            self.HeroArtist.Position = UDim2.new(0, 136, 0, 74)
            self.HeroState.Position = UDim2.new(0, 136, 1, -32)

            self.PlayerBar.Size = UDim2.new(1, 0, 0, 94)
            self.PlayerBar.Position = UDim2.new(0, 0, 1, -94)

            self.TrackTitle.Size = UDim2.new(0.42, 0, 0, 20)
            self.TrackArtist.Size = UDim2.new(0.42, 0, 0, 17)

            self.ProgressBack.Position = UDim2.new(
                0.06,
                0,
                1,
                -10
            )
            self.ProgressBack.Size = UDim2.new(
                0.59,
                0,
                0,
                3
            )

            self.TimeLabel.Visible = false

            self.PreviousButton.Position = UDim2.new(
                0.57, 0, 0.5, 0
            )
            self.PlayButton.Position = UDim2.new(
                0.68, 0, 0.5, 0
            )
            self.NextButton.Position = UDim2.new(
                0.81, 0, 0.5, 0
            )
            self.VolumeButton.Position = UDim2.new(
                1, -48, 0.5, 0
            )
            self.MoreButton.Visible = false

            self.HeroPlay.Visible = false

            self.Settings.Size = UDim2.new(0.90, 0, 0, 340)
            self.SearchOverlay.Size = UDim2.new(0.90, 0, 0, 260)
        else
            self.Window.Size = UDim2.new(
                0.78,
                0,
                0.78,
                0
            )

            self.SearchButton.Visible = true
            self.QueuePanel.Size = UDim2.new(
                0.34,
                0,
                1,
                -150
            )

            self.Hero.Size = UDim2.new(
                1,
                0,
                0,
                170
            )

            self.HeroArt.Size = UDim2.fromOffset(126, 126)
            self.HeroTitle.TextSize = 23
            self.HeroArtist.TextSize = 13

            self.HeroEyebrow.Position = UDim2.new(0, 162, 0, 27)
            self.HeroTitle.Position = UDim2.new(0, 162, 0, 48)
            self.HeroArtist.Position = UDim2.new(0, 162, 0, 82)
            self.HeroState.Position = UDim2.new(0, 162, 1, -38)

            self.PlayerBar.Size = UDim2.new(1, 0, 0, 88)
            self.PlayerBar.Position = UDim2.new(0, 0, 1, -88)

            self.TrackTitle.Size = UDim2.new(0.27, 0, 0, 21)
            self.TrackArtist.Size = UDim2.new(0.27, 0, 0, 18)

            self.ProgressBack.Position = UDim2.new(
                0.39, 0, 1, -19
            )
            self.ProgressBack.Size = UDim2.new(
                0.40, 0, 0, 4
            )

            self.TimeLabel.Visible = true

            self.PreviousButton.Position = UDim2.new(
                0.80, 0, 0.5, 0
            )
            self.PlayButton.Position = UDim2.new(
                0.845, 0, 0.5, 0
            )
            self.NextButton.Position = UDim2.new(
                0.90, 0, 0.5, 0
            )
            self.VolumeButton.Position = UDim2.new(
                1, -92, 0.5, 0
            )
            self.MoreButton.Visible = true

            self.HeroPlay.Visible = true

            self.Settings.Size = UDim2.new(0.56, 0, 0, 340)
            self.SearchOverlay.Size = UDim2.new(0.76, 0, 0, 260)
        end

        self:EmitAction("ResponsiveChanged", self.Mobile, width, height)
    end

    self._connections[#self._connections + 1] =
        workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(update)

    local camera = workspace.CurrentCamera
    if camera then
        self._connections[#self._connections + 1] =
            camera:GetPropertyChangedSignal("ViewportSize"):Connect(update)
    end

    update()
end

----------------------------------------------------------------
-- Window dragging
----------------------------------------------------------------

function Ui:_bindWindowDragging()
    local dragging = false
    local dragStart
    local startPosition

    local function update(input)
        local delta = input.Position - dragStart

        self.Window.Position = UDim2.new(
            startPosition.X.Scale,
            startPosition.X.Offset + delta.X,
            startPosition.Y.Scale,
            startPosition.Y.Offset + delta.Y
        )
    end

    self.Header.InputBegan:Connect(function(input)
        if self.Mobile then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then

            dragging = true
            dragStart = input.Position
            startPosition = self.Window.Position

            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    UserInputService.InputChanged:Connect(function(input)
        if not dragging then
            return
        end

        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            update(input)
        end
    end)
end

----------------------------------------------------------------
-- External hooks
----------------------------------------------------------------

function Ui:EmitAction(name, ...)
    safeCall(self.ActionCallback, name, ...)
end

function Ui:Refresh()
    self:_renderQueue()
    self:_refreshSettings()

    if self.Controller and type(self.Controller.GetSnapshot) == "function" then
        local ok, snapshot = pcall(
            self.Controller.GetSnapshot,
            self.Controller
        )

        if ok and type(snapshot) == "table" then
            self:SetTrack(snapshot.track)
            self:SetState(snapshot.state)
            self:SetProgress(snapshot.position, snapshot.duration)
            self:SetVolumeState(snapshot.volume, snapshot.muted)

            self.CurrentRepeat = snapshot.repeatMode or "Off"
            self.CurrentShuffle = snapshot.shuffle == true
            self:_refreshSettings()
        end
    end

    return self
end

function Ui:SetTitle(title)
    self.Title = tostring(title)
    self.TitleLabel.Text = self.Title
    return self
end

----------------------------------------------------------------
-- Cleanup
----------------------------------------------------------------

function Ui:Destroy()
    self:UnbindPlayer()
    self:UnbindQueue()

    for _, connection in ipairs(self._connections) do
        if connection then
            pcall(function()
                connection:Disconnect()
            end)
        end
    end

    self._connections = {}

    if self.Gui then
        self.Gui:Destroy()
    end

    self.Gui = nil
    self.Window = nil
    self.Root = nil
end

return Ui
