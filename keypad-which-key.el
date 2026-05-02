;;; keypad-which-key.el --- Which-key integration for keypad -*- lexical-binding: t; -*-

;; Author: jixiuf
;; Keywords: convenience
;; Version: 0.2.0
;; URL: https://github.com/jixiuf/emacs-keypad
;; Package-Requires: ((emacs "30.1"))

;; Copyright (C) 2026, jixiuf, all rights reserved.

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;;
;; Optional module that adds which-key popup support to leader.
;; Load this after both `keypad' and `which-key':
;;
;;;;   (require 'keypad-which-key)
;;
;; Provides visual key binding hints during leader key sequences,
;; including modifier-prefix contexts (M-, C-M- dispatch targets).

;;; Code:

(require 'which-key)

(declare-function keypad--collect-modifier-bindings "keypad")
(declare-function keypad--binding-sort "keypad")
(declare-function keypad--prompt "keypad")

(defvar keypad--event-reader)
(defvar keypad--which-key-show-fn)
(defvar keypad--which-key-modifier-read-fn)
(defvar keypad--which-key-read-event-fn)

(defcustom keypad-which-key-modifier-max-bindings 150
  "Maximum number of bindings to show in modifier-prefix which-key popups.
Set to nil for unlimited."
  :type '(choice (const :tag "Unlimited" nil) integer)
  :group 'keypad)

(defun keypad-which-key--modifier-bindings (target)
  "Call `keypad--collect-modifier-bindings' for TARGET with display limit applied."
  (let ((all (keypad--collect-modifier-bindings target)))
    (if (and keypad-which-key-modifier-max-bindings
             (> (length all) keypad-which-key-modifier-max-bindings))
        (cl-subseq all 0 keypad-which-key-modifier-max-bindings)
      all)))

(defun keypad-which-key--collect-prefix-bindings (keys modifier)
  "Collect bindings for prefix KEYS with MODIFIER bias in sorting.
MODIFIER non-nil sorts modified keys first; nil sorts plain keys first."
  (let* ((map (key-binding (kbd keys)))
         (bindings
          (when (keymapp map)
            (let (result)
              (map-keymap
               (lambda (ev def)
                 (unless (or (eq def 'undefined) (eq ev 'which-key)
                             (eq ev 'menu-bar))
                   (cond
                    ((and (eq ev 27) (keymapp def))
                     (map-keymap
                      (lambda (sub-ev sub-def)
                        (unless (eq sub-def 'undefined)
                          (let* ((meta-ev (event-apply-modifier
                                           sub-ev 'meta 27 "M-"))
                                 (key-desc (key-description (vector meta-ev)))
                                 (full-desc (concat keys " " key-desc)))
                            (unless (string-match-p
                                     "\\(?:<mouse\\|<wheel\\|<drag\\|<down-\\)"
                                     full-desc)
                              (push (cons full-desc
                                          (cond ((keymapp sub-def) "prefix")
                                                ((symbolp sub-def)
                                                 (symbol-name sub-def))
                                                (t (format "%s" sub-def))))
                                    result)))))
                      def))
                    (t
                     (let* ((key-desc (key-description (vector ev)))
                            (full-desc (concat keys " " key-desc)))
                       (unless (string-match-p
                                "\\(?:<mouse\\|<wheel\\|<drag\\|<down-\\)"
                                full-desc)
                         (push (cons full-desc
                                     (cond ((keymapp def) "prefix")
                                           ((symbolp def) (symbol-name def))
                                           (t (format "%s" def))))
                               result)))))))
               map)
              result))))
    (when bindings
      (let* ((prefix-len (1+ (length keys)))
             (mod-match-p
              (lambda (b)
                (string-match-p "[ACHMSs]-"
                                (substring (car b) prefix-len))))
             (modified (cl-remove-if-not mod-match-p bindings))
             (plain (cl-remove-if mod-match-p bindings))
             (sorted-mod (sort modified #'keypad--binding-sort))
             (sorted-plain (sort plain #'keypad--binding-sort))
             (sorted (if modifier
                         (append sorted-mod sorted-plain)
                       (append sorted-plain sorted-mod))))
        sorted))))

(defun keypad-which-key--next-page (delta)
  "Advance which-key page by DELTA, re-render."
  (when (and which-key--pages-obj
             (> (which-key--pages-num-pages which-key--pages-obj) 1))
    (setq which-key--pages-obj
          (which-key--pages-set-current-page which-key--pages-obj delta))
    (let ((which-key--automatic-display t))
      (which-key--show-page))))

(defun keypad-which-key--show-popup (&optional force)
  "Show which-key popup if not already visible.  FORCE forces refresh."
  (when (and which-key--pages-obj
             (or force (not (which-key--popup-showing-p))))
    (let ((which-key--automatic-display t))
      (which-key--show-page))))

(defun keypad-which-key--hide ()
  "Hide our which-key popup."
  (ignore-errors (which-key--hide-popup))
  (setq which-key--pages-obj nil))

(defun keypad-which-key--page-hint ()
  "Return echo-area paging hint string."
  (when which-key--pages-obj
    (let* ((n (which-key--pages-num-pages which-key--pages-obj))
           (page (car (which-key--pages-page-nums which-key--pages-obj))))
      (when (> n 1)
        (format "  page %d/%d  %s n/p"
                page n (key-description (vector help-char)))))))

(defun keypad-which-key--read-event (prompt-fn)
  "Read an event with paging support.
PROMPT-FN is a function of no arguments that returns the prompt string."
  (let ((paging-key (and which-key-paging-key (kbd which-key-paging-key)))
        char)
    (while (not char)
      (setq char (funcall keypad--event-reader
                          (concat (funcall prompt-fn)
                                  (or (keypad-which-key--page-hint) ""))))
      (if (and which-key-use-C-h-commands
               (numberp char) (= char help-char)
               which-key--pages-obj
               (> (which-key--pages-num-pages which-key--pages-obj) 1))
          (let ((ch (funcall keypad--event-reader (keypad-which-key--page-hint))))
            (cond ((eq ch ?n) (keypad-which-key--next-page 1))
                  ((eq ch ?p) (keypad-which-key--next-page -1)))
            (setq char nil))
        (when (and paging-key (equal (vector char) paging-key))
          (keypad-which-key--show-popup t)
          (keypad-which-key--next-page 1)
          (setq char nil))))
    char))

(defun keypad-which-key--show (keys modifier)
  "Show which-key popup for KEYS with MODIFIER bias.
Installed as `keypad--which-key-show-fn'."
  (let* ((modifier-only (and (or (null keys) (string-empty-p keys))
                             modifier))
         (bindings (if modifier-only
                       (keypad-which-key--modifier-bindings modifier)
                     (keypad-which-key--collect-prefix-bindings keys modifier)))
         (pages (and bindings (which-key--format-and-replace bindings)))
         (prefix (if modifier-only modifier keys)))
    (message "%s" (keypad--prompt keys modifier))
    (when pages
      (setq which-key--pages-obj
            (which-key--create-pages pages nil prefix))
      (when (sit-for which-key-idle-delay)
        (keypad-which-key--show-popup t)))))

(defun keypad-which-key--modifier-read (target prefix)
  "Read a key with modifier-prefix which-key for TARGET.
PREFIX is the current accumulated prefix string.
Installed as `keypad--which-key-modifier-read-fn'."
  (keypad-which-key--hide)
  (let* ((continuation-p (and prefix (not (string-empty-p prefix))))
         (page-prefix (if continuation-p (concat prefix " " target) target))
         (raw (keypad-which-key--modifier-bindings target))
         (bindings
          (if (not continuation-p)
              raw
            ;; Continuation: rebuild full key paths (prefix + mod-key)
            ;; and filter to those reachable under the current prefix.
            (delq nil
                  (mapcar
                   (lambda (b)
                     (let* ((mod-key (car b))
                            (full-key (concat prefix " " mod-key))
                            (binding (key-binding (kbd full-key))))
                       (when binding
                         (cons full-key
                               (cond ((keymapp binding) "prefix")
                                     ((symbolp binding)
                                      (symbol-name binding))
                                     (t (format "%s" binding)))))))
                   raw)))))
    (message "%s" (concat (if continuation-p (concat prefix " ") "")
                          target "-"))
    (when bindings
      (let ((pages (which-key--format-and-replace bindings)))
        (when pages
          (setq which-key--pages-obj
                (which-key--create-pages pages nil page-prefix))
          (sit-for which-key-idle-delay)
          (keypad-which-key--show-popup t))))
    (unwind-protect
        (keypad-which-key--read-event
         (lambda ()
           (concat (if continuation-p (concat prefix " ") "")
                   target "-")))
      (keypad-which-key--hide))))

;;;###autoload
(defun keypad-which-key-setup ()
  "Set up which-key integration hooks into keypad."
  (setq keypad--which-key-show-fn #'keypad-which-key--show)
  (setq keypad--which-key-modifier-read-fn #'keypad-which-key--modifier-read)
  (setq keypad--which-key-read-event-fn #'keypad-which-key--read-event))

(defun keypad-which-key-teardown ()
  "Remove which-key integration hooks."
  (setq keypad--which-key-show-fn nil
        keypad--which-key-modifier-read-fn nil
        keypad--which-key-read-event-fn nil))

(when (featurep 'keypad)
  (keypad-which-key-setup))
(add-hook 'keypad-mode-hook #'keypad-which-key-setup)

(provide 'keypad-which-key)

;; Local Variables:
;; coding: utf-8
;; End:
;;; keypad-which-key.el ends here
