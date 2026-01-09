;;; theme.el -*- lexical-binding: t -*-

;; Load and configure Catppuccin theme
(require 'catppuccin-theme)

;; Set flavor to mocha (default)
(setq catppuccin-flavor 'mocha)

;; Load the theme
(load-theme 'catppuccin :no-confirm)
