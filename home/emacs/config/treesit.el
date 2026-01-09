;;; treesit.el -*- lexical-binding: t -*-

;; Load base modes so their auto-mode-alist entries get registered
(require 'nix-mode)
(require 'nix-ts-mode)

;; Remap all common modes - emacs falls back if grammar unavailable
(setq major-mode-remap-alist
      '((bash-mode . bash-ts-mode)
        (nix-mode . nix-ts-mode)
        (c-mode . c-ts-mode)
        (c++-mode . c++-ts-mode)
        (cmake-mode . cmake-ts-mode)
        (css-mode . css-ts-mode)
        (dockerfile-mode . dockerfile-ts-mode)
        (go-mode . go-ts-mode)
        (java-mode . java-ts-mode)
        (js-mode . js-ts-mode)
        (json-mode . json-ts-mode)
        (python-mode . python-ts-mode)
        (rust-mode . rust-ts-mode)
        (toml-mode . toml-ts-mode)
        (tsx-mode . tsx-ts-mode)
        (typescript-mode . typescript-ts-mode)
        (yaml-mode . yaml-ts-mode)))
