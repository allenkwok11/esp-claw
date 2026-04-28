local bm = require("board_manager")
local display = require("display")
local delay = require("delay")

local function value_or(default_value, value)
    if value == nil then
        return default_value
    end
    return value
end

local function cleanup()
    pcall(display.end_frame)
    pcall(display.deinit)
end

local panel_handle, io_handle, width, height, panel_if = bm.get_display_lcd_params("display_lcd")
if not panel_handle then
    print("[basic_display_message] ERROR: get_display_lcd_params(display_lcd) failed: " .. tostring(io_handle))
    return
end

local ok, err = pcall(display.init, panel_handle, io_handle, width, height, panel_if)
if not ok then
    print("[basic_display_message] ERROR: init failed: " .. tostring(err))
    return
end

local bg_r = value_or(0, args.r)
local bg_g = value_or(0, args.g)
local bg_b = value_or(0, args.b)
local fg_r = value_or(255, args.text_r)
local fg_g = value_or(255, args.text_g)
local fg_b = value_or(255, args.text_b)
local text = value_or("", args.text)
local font_size = value_or(24, args.font_size)
local hold_ms = value_or(0, args.hold_ms)
local screen_w = display.width()
local screen_h = display.height()

local run_ok, run_err = xpcall(function()
    display.begin_frame({ clear = true, r = bg_r, g = bg_g, b = bg_b })

    if text ~= "" then
        local text_w, text_h = display.measure_text(text, { font_size = font_size })
        local x = math.floor((screen_w - text_w) / 2)
        local y = math.floor((screen_h - text_h) / 2)

        if x < 0 then
            x = 0
        end
        if y < 0 then
            y = 0
        end

        display.draw_text(x, y, text, {
            r = fg_r,
            g = fg_g,
            b = fg_b,
            font_size = font_size,
        })
    end

    display.present()
    if hold_ms > 0 then
        delay.delay_ms(hold_ms)
    end
    display.end_frame()
end, debug.traceback)

cleanup()
if not run_ok then
    error(run_err)
end

print(string.format("[basic_display_message] rendered %dx%d bg=(%d,%d,%d) text=%s",
    screen_w, screen_h, bg_r, bg_g, bg_b, text))
