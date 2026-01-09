;;; init.el -*- lexical-binding: t -*-

;; Custom file
(setq custom-file (expand-file-name "custom.el" user-emacs-directory))
(load custom-file 'noerror)

;; Sensible defaults
(setq-default indent-tabs-mode nil
              require-final-newline t)

(setq create-lockfiles nil
      make-backup-files nil
      auto-save-default nil
      scroll-conservatively 101)

;; Load config modules
(defun load-config (filename)
  "Load configuration file from config directory."
  (load (expand-file-name filename (concat user-emacs-directory "config/"))))

(require 'clipetty)
(global-clipetty-mode)

;; Enable line numbers globally
(global-display-line-numbers-mode 1)

(load-config "meow.el")
(load-config "which-key.el")
(load-config "vterm.el")
(load-config "vertico.el")
(load-config "consult.el")
(load-config "treesit.el")
(load-config "eglot.el")
(load-config "theme.el")
