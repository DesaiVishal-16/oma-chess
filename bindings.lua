-- OMA-CHESS — optional keybinding (Super + Ctrl + Alt + C)
--
-- To enable: copy the o.bind(...) line below into your
-- ~/.config/hypr/bindings.lua, then run:  hyprctl reload
--
-- Requires oma.chess to be installed and enabled.

o.bind("SUPER + CTRL + ALT + C", "Chess", "omarchy-shell oma.chess toggle")
