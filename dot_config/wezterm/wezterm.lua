-- Pull in the wezterm API
local wezterm = require("wezterm")

-- This will hold the configuration.
local config = wezterm.config_builder()

-- This is where you actually apply your config choices

-- config.default_prog = { 'tmux', 'new-session', '-A', '-s', 'main' }

-- For example, changing the color scheme:
config.color_scheme = "Dracula (Official)"

config.font = wezterm.font("Hack Nerd Font")
config.font_size = 15
config.line_height = 1.1

config.inactive_pane_hsb = {
	saturation = 0.9,
	brightness = 0.8,
}

config.enable_tab_bar = false
config.tab_bar_at_bottom = true
config.use_fancy_tab_bar = false

config.window_decorations = "RESIZE"

config.enable_scroll_bar = false -- doesn't work with tmux
config.window_padding = {
	left = "1cell",
	right = "1cell",
	top = "0.5cell",
	bottom = 0,
}

-- https://wezfurlong.org/wezterm/config/keyboard-concepts.html#macos-left-and-right-option-key
config.send_composed_key_when_left_alt_is_pressed = false -- Left Option as Alt (for modifiers)
config.send_composed_key_when_right_alt_is_pressed = true -- Right Option as Option (for diacritics)

-- and finally, return the configuration to wezterm
return config
