;;; vterm-config.el -*- lexical-binding: t -*-

(require 'vterm)

(setq vterm-max-scrollback 10000)

(global-set-key (kbd "C-c t") 'vterm)
