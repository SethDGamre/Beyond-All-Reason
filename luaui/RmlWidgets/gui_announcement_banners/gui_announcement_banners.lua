if not RmlUi then
	return
end

local widget = widget ---@type Widget

function widget:GetInfo()
	return {
		name = "Announcement Banners",
		desc = "Center-screen banners other widgets show through WG.announcementBanners",
		author = "SethDGamre",
		date = "2026-10",
		license = "GNU GPL, v2 or later",
		layer = 1,
		enabled = true,
	}
end

local DATA_MODEL_NAME = "announcement_banners_model"
local RML_PATH = "luaui/RmlWidgets/gui_announcement_banners/gui_announcement_banners.rml"
local EMOJI_FONT_PATH = "fonts/fallbacks/NotoEmoji-VariableFont_wght.ttf"
local DEFAULT_DURATION_SECONDS = 5
local MAX_ANNOUNCEMENT_LINES = 6
local MAX_QUEUED_ANNOUNCEMENTS = 8
local DEFAULT_ANNOUNCEMENT_SOUNDS = {
	{ path = "sounds/global-events/scavlootdrop.wav", volume = 0.8 },
	{ path = "sounds/replies/servlrg3.wav", volume = 1 },
}

---@class AnnouncementBanner
---@field title string
---@field subtitle string|nil
---@field detail string|nil
---@field lines string[]|nil
---@field durationSeconds number|nil
---@field playSound boolean|nil
---@field sound string|nil
---@field soundVolume number|nil

local widgetState = {
	rmlContext = nil,
	document = nil,
	dataModel = nil,
	hiddenByLobby = false,
	bannerActive = false,
	bannerElapsedSeconds = 0,
	bannerDurationSeconds = 0,
	soundPending = false,
	currentAnnouncement = nil,
	queuedAnnouncements = {},
}

local function appendLine(lines, value)
	if #lines >= MAX_ANNOUNCEMENT_LINES then
		return
	end
	if type(value) ~= "string" or value == "" then
		return
	end
	lines[#lines + 1] = { text = value }
end

local function buildLines(announcement)
	local lines = {}
	appendLine(lines, announcement.subtitle)
	appendLine(lines, announcement.detail)
	local extraLines = announcement.lines
	if type(extraLines) ~= "table" then
		return lines
	end
	for lineIndex = 1, #extraLines do
		local line = extraLines[lineIndex]
		if type(line) == "table" then
			appendLine(lines, line.text)
		else
			appendLine(lines, line)
		end
	end
	return lines
end

local function normalizeAnnouncement(announcement)
	if type(announcement) == "string" then
		announcement = { title = announcement }
	end
	if type(announcement) ~= "table" then
		return nil
	end

	local title = announcement.title
	if type(title) ~= "string" or title == "" then
		return nil
	end

	local durationSeconds = DEFAULT_DURATION_SECONDS
	if announcement.durationSeconds ~= nil then
		durationSeconds = tonumber(announcement.durationSeconds) or DEFAULT_DURATION_SECONDS
		if durationSeconds < 0 then
			durationSeconds = DEFAULT_DURATION_SECONDS
		end
	end

	local sound = announcement.sound
	if type(sound) ~= "string" or sound == "" then
		sound = nil
	end

	return {
		title = title,
		lines = buildLines(announcement),
		durationSeconds = durationSeconds,
		playSound = announcement.playSound ~= false,
		sound = sound,
		soundVolume = tonumber(announcement.soundVolume) or 1,
	}
end

local function playAnnouncementSound(announcement)
	if not announcement or announcement.playSound == false then
		return
	end
	if announcement.sound then
		Spring.PlaySoundFile(announcement.sound, announcement.soundVolume, "ui")
		return
	end
	for soundIndex = 1, #DEFAULT_ANNOUNCEMENT_SOUNDS do
		local announcementSound = DEFAULT_ANNOUNCEMENT_SOUNDS[soundIndex]
		Spring.PlaySoundFile(announcementSound.path, announcementSound.volume, "ui")
	end
end

local function getCanDisplay()
	local _, _, isClientPaused = Spring.GetGameState()
	local isGUIHidden = Spring.IsGUIHidden and Spring.IsGUIHidden()
	return not isClientPaused and not isGUIHidden and not widgetState.hiddenByLobby
end

local function bringDocumentToFront()
	local document = widgetState.document
	if not document or not document.PullToFront then
		return
	end
	pcall(document.PullToFront, document)
end

local function showDocument()
	local document = widgetState.document
	if not document then
		return
	end
	local modalFlags = RmlUi.RmlModalFlag
	local focusFlags = RmlUi.RmlFocusFlag
	local showedWithoutFocus = modalFlags
		and focusFlags
		and pcall(document.Show, document, modalFlags.None, focusFlags.None)
	if not showedWithoutFocus then
		document:Show()
	end
	bringDocumentToFront()
end

local function hideDocument()
	local document = widgetState.document
	if not document or not document.Hide then
		return
	end
	pcall(document.Hide, document)
end

local function synchronizeVisibility()
	local dataModel = widgetState.dataModel
	if not dataModel then
		return
	end

	local isVisible = widgetState.bannerActive and getCanDisplay()
	if dataModel.isVisible == isVisible then
		return
	end

	dataModel.isVisible = isVisible
	if isVisible then
		showDocument()
	else
		hideDocument()
	end
end

local function playPendingSound()
	if not widgetState.soundPending then
		return
	end
	local dataModel = widgetState.dataModel
	if not dataModel or not dataModel.isVisible then
		return
	end
	widgetState.soundPending = false
	playAnnouncementSound(widgetState.currentAnnouncement)
end

local function hideCurrentBanner()
	widgetState.bannerActive = false
	widgetState.bannerElapsedSeconds = 0
	widgetState.bannerDurationSeconds = 0
	widgetState.soundPending = false
	widgetState.currentAnnouncement = nil
	local dataModel = widgetState.dataModel
	if not dataModel then
		return
	end
	dataModel.title = ""
	dataModel.lines = {}
	if dataModel.isVisible then
		dataModel.isVisible = false
		hideDocument()
	end
end

local function enqueueNormalized(announcement)
	local queuedAnnouncements = widgetState.queuedAnnouncements
	if #queuedAnnouncements >= MAX_QUEUED_ANNOUNCEMENTS then
		table.remove(queuedAnnouncements, 1)
	end
	queuedAnnouncements[#queuedAnnouncements + 1] = announcement
end

local function presentAnnouncement(announcement)
	local dataModel = widgetState.dataModel
	if not dataModel then
		enqueueNormalized(announcement)
		return
	end

	dataModel.title = announcement.title
	dataModel.lines = announcement.lines
	widgetState.bannerActive = true
	widgetState.bannerElapsedSeconds = 0
	widgetState.bannerDurationSeconds = announcement.durationSeconds
	widgetState.currentAnnouncement = announcement
	widgetState.soundPending = true
	synchronizeVisibility()
	playPendingSound()
end

local function showNextQueuedAnnouncement()
	if widgetState.hiddenByLobby or widgetState.bannerActive then
		return
	end
	local nextAnnouncement = table.remove(widgetState.queuedAnnouncements, 1)
	if not nextAnnouncement then
		return
	end
	presentAnnouncement(nextAnnouncement)
end

---@param announcement AnnouncementBanner|string
---@return boolean
local function announce(announcement)
	local normalizedAnnouncement = normalizeAnnouncement(announcement)
	if not normalizedAnnouncement then
		return false
	end
	presentAnnouncement(normalizedAnnouncement)
	return true
end

---@param announcement AnnouncementBanner|string
---@return boolean
local function enqueue(announcement)
	local normalizedAnnouncement = normalizeAnnouncement(announcement)
	if not normalizedAnnouncement then
		return false
	end
	if widgetState.bannerActive or widgetState.hiddenByLobby then
		enqueueNormalized(normalizedAnnouncement)
		return true
	end
	presentAnnouncement(normalizedAnnouncement)
	return true
end

local function isBannerActive()
	return widgetState.bannerActive
end

local function dismiss()
	hideCurrentBanner()
	showNextQueuedAnnouncement()
end

local function clear()
	widgetState.queuedAnnouncements = {}
	hideCurrentBanner()
end

local function initializeModel()
	return {
		isVisible = false,
		title = "",
		lines = {},
	}
end

function widget:Initialize()
	widgetState.rmlContext = RmlUi.GetContext("shared")
	if not widgetState.rmlContext then
		return false
	end

	RmlUi.LoadFontFace(EMOJI_FONT_PATH, true)
	widgetState.dataModel = widgetState.rmlContext:OpenDataModel(DATA_MODEL_NAME, initializeModel(), self)
	if not widgetState.dataModel then
		widgetState.rmlContext = nil
		return false
	end

	widgetState.document = widgetState.rmlContext:LoadDocument(RML_PATH, self)
	if not widgetState.document then
		widgetState.rmlContext:RemoveDataModel(DATA_MODEL_NAME)
		widgetState.dataModel = nil
		widgetState.rmlContext = nil
		return false
	end

	widgetState.document:ReloadStyleSheet()
	hideDocument()

	WG.announcementBanners = {
		announce = announce,
		enqueue = enqueue,
		isActive = isBannerActive,
		dismiss = dismiss,
		clear = clear,
	}

	synchronizeVisibility()
	return true
end

function widget:Shutdown()
	WG.announcementBanners = nil
	hideCurrentBanner()
	widgetState.queuedAnnouncements = {}

	if widgetState.document then
		widgetState.document:Close()
		widgetState.document = nil
	end
	if widgetState.rmlContext and widgetState.dataModel then
		widgetState.rmlContext:RemoveDataModel(DATA_MODEL_NAME)
	end

	widgetState.dataModel = nil
	widgetState.rmlContext = nil
end

function widget:Update(deltaTime)
	local dataModel = widgetState.dataModel
	if dataModel and widgetState.bannerActive and dataModel.isVisible and widgetState.bannerDurationSeconds > 0 then
		widgetState.bannerElapsedSeconds = widgetState.bannerElapsedSeconds + (tonumber(deltaTime) or 0)
		if widgetState.bannerElapsedSeconds >= widgetState.bannerDurationSeconds then
			hideCurrentBanner()
			showNextQueuedAnnouncement()
		end
	end

	synchronizeVisibility()
	playPendingSound()
	if dataModel and dataModel.isVisible then
		bringDocumentToFront()
	end
end

function widget:RecvLuaMsg(message)
	if type(message) ~= "string" then
		return
	end
	if message:sub(1, 19) == "LobbyOverlayActive0" then
		widgetState.hiddenByLobby = false
		if not widgetState.bannerActive then
			showNextQueuedAnnouncement()
		end
	elseif message:sub(1, 19) == "LobbyOverlayActive1" then
		widgetState.hiddenByLobby = true
		hideCurrentBanner()
	end
	synchronizeVisibility()
end

function widget:GamePaused(playerID, isPaused)
	synchronizeVisibility()
end
