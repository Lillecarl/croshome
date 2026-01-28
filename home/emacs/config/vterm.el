;;; vterm-config.el -*- lexical-binding: t -*-

(setq vterm-keymap-exceptions '("C-c"))

(require 'vterm)
(require 'meow-vterm)

(setq vterm-max-scrollback 10000)

(meow-vterm-enable)

;; Send literal ESC to terminal applications (e.g., vim inside vterm)
(define-key vterm-mode-map (kbd "C-c C-e") #'vterm-send-escape)

(global-set-key (kbd "C-c t") 'vterm)
