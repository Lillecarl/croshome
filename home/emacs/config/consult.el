;;; consult.el -*- lexical-binding: t -*-

(require 'consult)

;; Buffer switching with recent files, bookmarks
(global-set-key (kbd "C-x b") 'consult-buffer)

;; Search in current buffer
(global-set-key (kbd "C-s") 'consult-line)

;; Yank (paste) from kill ring with preview
(global-set-key (kbd "M-y") 'consult-yank-pop)

;; Project-wide search (requires ripgrep)
(global-set-key (kbd "C-c g") 'consult-ripgrep)

;; Navigate symbols in current buffer (functions, variables)
(global-set-key (kbd "C-c i") 'consult-imenu)

;; Preview delay (instant feedback)
(setq consult-preview-key 'any)
