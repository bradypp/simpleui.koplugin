-- sui_recent_window.lua — SimpleUI ▸ Recent Window
--
-- Standalone SUIWindow for the "Recent" quickaction: shows a covers-only
-- grid of the most recently read books (no title/author/progress — just
-- the cover art, tap to open). Data comes directly from
-- module_books_shared.prefetchBooks(), independent of the homescreen ctx,
-- so it can be opened from anywhere (FileManager, ReaderUI) via the
-- quickaction system or a gesture, exactly like sui_settings_window /
-- sui_stats_windows.
--
-- Finished books are always excluded (no toggle) — mirrors module_recent's
-- default before its "Show finished books" option is turned on.
--
-- The window uses auto_height (like the custom Quick Action group folder
-- window in sui_quickactions.lua's showQAFolderDialog) so it shrinks to fit
-- its content instead of always reserving 75% of the screen height.
--
-- Usage:
--   local ok, RW = pcall(require, "sui_recent_window")
--   if ok and RW then RW.show(on_close_extra) end
--   -- on_close_extra is optional — omit it when calling from a gesture.

local BD              = require("ui/bidi")
local Device          = require("device")
local Geom            = require("ui/geometry")
local GestureRange    = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InputContainer  = require("ui/widget/container/inputcontainer")
local UIManager       = require("ui/uimanager")
local VerticalSpan    = require("ui/widget/verticalspan")
local Screen          = Device.screen
local logger          = require("logger")
local _               = require("sui_i18n").translate

local RW = {}

-- ---------------------------------------------------------------------------
-- Layout constants
-- ---------------------------------------------------------------------------

local NUM_COLS    = 4
local MAX_RECENT  = 24  -- 6 rows of 4 at the default column count

-- ---------------------------------------------------------------------------
-- Kobo virtual-path normalisation + open — mirrors sui_homescreen.lua's
-- openBook()/_normalizeKoboPath() so covers sourced the same way (via
-- module_books_shared/ReadHistory) open identically on Kobo devices.
-- ---------------------------------------------------------------------------

local function _normalizeKoboPath(filepath)
    if not filepath then return filepath end
    local ok, PluginLoader = pcall(require, "pluginloader")
    if not ok or not PluginLoader then return filepath end
    local kobo = PluginLoader:getPluginInstance("kobo_plugin")
    if not kobo or not kobo.virtual_library then return filepath end
    local vl = kobo.virtual_library
    if not next(vl.virtual_to_real) then
        local ok2, err = pcall(function() vl:buildPathMappings() end)
        if not ok2 then
            logger.warn("sui_recent_window: kobo buildPathMappings failed:", err)
            return filepath
        end
    end
    if vl:isVirtualPath(filepath) then return filepath end
    local virtual = vl:getVirtualPath(filepath)
    return virtual or filepath
end

local function _openBook(filepath)
    local doOpen = function()
        local ReaderUI = package.loaded["apps/reader/readerui"]
            or require("apps/reader/readerui")
        ReaderUI:showReader(_normalizeKoboPath(filepath))
    end
    if G_reader_settings:isTrue("file_ask_to_open") then
        local ConfirmBox = require("ui/widget/confirmbox")
        UIManager:show(ConfirmBox:new{
            text        = _("Open this file?") .. "\n\n" .. BD.filename(filepath:match("([^/]+)$")),
            ok_text     = _("Open"),
            cancel_text = _("Cancel"),
            ok_callback = doOpen,
        })
    else
        doOpen()
    end
end

-- ---------------------------------------------------------------------------
-- Grid cell
-- ---------------------------------------------------------------------------

local function _makeCoverCell(SH, fp, bd, cw, ch)
    local cover = SH.getBookCover(fp, cw, ch, nil, 0.10)
        or SH.coverPlaceholder(bd.title, bd.authors, cw, ch)

    local ic = InputContainer:new{
        dimen = Geom:new{ w = cw, h = ch },
        cover,
    }
    ic.ges_events = {
        Tap = { GestureRange:new{
            ges   = "tap",
            range = function() return ic.dimen end,
        }},
    }
    function ic:onTap()
        _openBook(fp)
        return true
    end
    return ic
end

-- ---------------------------------------------------------------------------
-- Root screen
-- ---------------------------------------------------------------------------

local function _buildRootScreen(ctx)
    local SUI = require("sui_window")
    local SH  = require("desktop_modules/module_books_shared")

    local inner_w = ctx.inner_w
    local state   = SH.prefetchBooks(false, true, MAX_RECENT)
    local all_fps = state.recent_fps or {}

    if #all_fps == 0 then
        return {
            SUI.ListRow{
                inner_w = inner_w,
                title   = _("No recent books."),
            },
        }
    end

    -- Finished books are always excluded — no toggle, matches the default
    -- (off) state of module_recent's own "Show finished books" setting.
    local fps = {}
    for _, fp in ipairs(all_fps) do
        local pd  = state.prefetched_data[fp]
        local pct = pd and pd.percent or 0
        local is_done = (pct >= 1.0) or
                        (type(pd) == "table" and type(pd.summary) == "table"
                         and pd.summary.status == "complete")
        if not is_done then
            fps[#fps + 1] = fp
        end
    end

    if #fps == 0 then
        return {
            SUI.ListRow{
                inner_w = inner_w,
                title   = _("All recent books are finished."),
            },
        }
    end

    local rows = {}
    local gap  = Screen:scaleBySize(10)
    local cw   = math.floor((inner_w - (NUM_COLS - 1) * gap) / NUM_COLS)
    local ch   = math.floor(cw * 3 / 2)

    local i = 1
    while i <= #fps do
        local hg = HorizontalGroup:new{ align = "top" }
        for c = 1, NUM_COLS do
            local fp = fps[i]
            if fp then
                local pd = state.prefetched_data[fp]
                local bd = SH.getBookData(fp, pd)
                hg[#hg + 1] = _makeCoverCell(SH, fp, bd, cw, ch)
                i = i + 1
                if c < NUM_COLS and fps[i] then
                    hg[#hg + 1] = HorizontalSpan:new{ width = gap }
                end
            end
        end
        rows[#rows + 1] = hg
        if i <= #fps then
            rows[#rows + 1] = VerticalSpan:new{ width = gap }
        end
    end

    return rows
end

-- ---------------------------------------------------------------------------
-- Entry point
-- ---------------------------------------------------------------------------

function RW.show(on_close_extra)
    local SUI     = require("sui_window")
    local Config  = require("sui_config")

    local win = SUI:new{
        name          = "sui_win_recent",
        title         = _("Recent"),
        position      = "bottom",
        auto_height   = true,
        navpager_mode = Config.isNavpagerEnabled and Config.isNavpagerEnabled() or false,
        screens       = {
            __root__ = _buildRootScreen,
        },
        on_close = function()
            if on_close_extra then on_close_extra() end
        end,
    }
    win:show()
end

return RW
