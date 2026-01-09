;;; eglot.el -*- lexical-binding: t -*-

;; Eglot is built into Emacs 29+
(require 'eglot)

;; Configure nixd for Nix files
(add-to-list 'eglot-server-programs
             '(nix-ts-mode . ("nixd")))

;; Configure pylsp for Python files with plugins
(add-to-list 'eglot-server-programs
             '((python-mode python-ts-mode) .
               ("pylsp" "-v"
                :initializationOptions
                (:plugins
                 (:pylsp_mypy (:enabled t :live_mode :json-false)
                  :ruff (:enabled t)
                  :rope_autoimport (:enabled t)
                  :rope_completion (:enabled t)
                  :pycodestyle (:enabled :json-false)
                  :mccabe (:enabled :json-false)
                  :pyflakes (:enabled :json-false))))))

;; Auto-start eglot for Nix files
(add-hook 'nix-ts-mode-hook 'eglot-ensure)

;; Auto-start eglot for Python files
(add-hook 'python-ts-mode-hook 'eglot-ensure)

;; Enable all LSP server capabilities including semantic tokens
(setq eglot-ignored-server-capabilities '())

;; Enable semantic tokens mode for richer highlighting (Emacs 30+)
(add-hook 'eglot-managed-mode-hook
          (lambda ()
            (when (fboundp 'eglot-semantic-tokens-mode)
              (eglot-semantic-tokens-mode 1))))
