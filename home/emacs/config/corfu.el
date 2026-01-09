;;; corfu.el -*- lexical-binding: t -*-

;; Corfu provides in-buffer completion popup
(require 'corfu)

;; Corfu configuration - must be set before enabling
(setq corfu-auto t                 ; Enable auto completion
      corfu-auto-delay 0.2         ; Delay before showing completions
      corfu-auto-prefix 2          ; Start after 2 characters
      corfu-cycle t                ; Enable cycling through candidates
      corfu-quit-at-boundary nil   ; Don't quit at completion boundary
      corfu-quit-no-match t        ; Quit if no match (don't interfere)
      corfu-preview-current nil    ; Don't preview current candidate
      corfu-preselect 'prompt      ; Preselect the prompt
      corfu-on-exact-match nil)    ; Don't auto-insert exact matches

;; Enable corfu globally
(global-corfu-mode 1)

;; Enable corfu-terminal for terminal Emacs (GUI has native child frame support)
(unless (display-graphic-p)
  (when (require 'corfu-terminal nil t)
    (funcall (intern "corfu-terminal-mode") 1)))

;; Disable default completion UI
(setq completion-auto-help nil
      completion-auto-select nil)

;; When corfu popup is showing, these bindings apply
(define-key corfu-map (kbd "TAB") 'corfu-insert)
(define-key corfu-map (kbd "<tab>") 'corfu-insert)
(define-key corfu-map (kbd "RET") 'corfu-insert)
(define-key corfu-map (kbd "C-n") 'corfu-next)
(define-key corfu-map (kbd "C-p") 'corfu-previous)

;; Manual completion trigger - use C-SPC to manually show completions
(global-set-key (kbd "C-SPC") 'completion-at-point)

;; Cape provides extra completion-at-point functions
(require 'cape)

;; Add useful completion sources
(add-to-list 'completion-at-point-functions #'cape-dabbrev)
(add-to-list 'completion-at-point-functions #'cape-file)
