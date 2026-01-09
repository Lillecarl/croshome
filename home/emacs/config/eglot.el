;;; eglot.el -*- lexical-binding: t -*-

;; Eglot is built into Emacs 29+
(require 'eglot)

;; Configure nixd for Nix files
(add-to-list 'eglot-server-programs
             '(nix-ts-mode . ("nixd")))

;; Auto-start eglot for Nix files
(add-hook 'nix-ts-mode-hook 'eglot-ensure)

;; Enable all LSP server capabilities including semantic tokens
(setq eglot-ignored-server-capabilities '())

;; Enable semantic tokens mode for richer highlighting (Emacs 30+)
(add-hook 'eglot-managed-mode-hook
          (lambda ()
            (when (fboundp 'eglot-semantic-tokens-mode)
              (eglot-semantic-tokens-mode 1))))
