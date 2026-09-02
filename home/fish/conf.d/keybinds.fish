#! /usr/bin/env fish

fish_vi_key_bindings
# bind \cr __call_keep_cursor_pos

# fish_vi_key_bindings sets a steady (non-blinking) DECSCUSR shape per mode by
# default. Add "blink" so the terminal cursor keeps blinking in every vi mode,
# local or over SSH.
set -g fish_cursor_default block blink
set -g fish_cursor_insert line blink
set -g fish_cursor_replace_one underscore blink
set -g fish_cursor_visual block blink
