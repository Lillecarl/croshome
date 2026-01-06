;;; early-init.el -*- lexical-binding: t -*-

(setq package-enable-at-startup nil)

;; Performance
(setq gc-cons-threshold 100000000
      read-process-output-max (* 1024 1024))

;; UI
(setq inhibit-startup-screen t)
(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))
(when (fboundp 'scroll-bar-mode) (scroll-bar-mode -1))
