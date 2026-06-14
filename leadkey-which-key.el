;;; leadkey-which-key.el --- Which-key integration for leadkey -*- lexical-binding: t; -*-

;; Author: jixiuf <https://github.com/jixiuf>
;; Assisted-by: deepseek-v4-pro
;; Keywords: convenience
;; Version: 0.2.0
;; URL: https://github.com/jixiuf/emacs-leadkey

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
;; Load this after both `leadkey' and `which-key':
;;
;;;;   (require 'leadkey-which-key)
;;
;; Provides visual key binding hints during leader key sequences,
;; including modifier-prefix contexts (M-, C-M- dispatch targets).

;;; Code:

(require 'which-key)

(declare-function leadkey--collect-modifier-bindings "leadkey")
(declare-function leadkey--binding-sort "leadkey")
(declare-function leadkey--prompt "leadkey")

(defvar leadkey--event-reader)
(defvar leadkey--which-key-show-fn)
(defvar leadkey--which-key-modifier-read-fn)
(defvar leadkey--which-key-read-event-fn)

(defcustom leadkey-which-key-modifier-max-bindings 150
  "Maximum number of bindings to show in modifier-prefix which-key popups.
Set to nil for unlimited."
  :type '(choice (const :tag "Unlimited" nil) integer)
  :group 'leadkey)

(defun leadkey-which-key--modifier-bindings (target)
  "Call `leadkey--collect-modifier-bindings' for TARGET with display limit applied."
  (let ((all (leadkey--collect-modifier-bindings target)))
    (if (and leadkey-which-key-modifier-max-bindings
             (> (length all) leadkey-which-key-modifier-max-bindings))
        (cl-subseq all 0 leadkey-which-key-modifier-max-bindings)
      all)))

(defun leadkey-which-key--collect-prefix-bindings (keys modifier)
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
             (sorted-mod (sort modified #'leadkey--binding-sort))
             (sorted-plain (sort plain #'leadkey--binding-sort))
             (sorted (if modifier
                         (append sorted-mod sorted-plain)
                       (append sorted-plain sorted-mod))))
        sorted))))

(defun leadkey-which-key--next-page (delta)
  "Advance which-key page by DELTA, re-render."
  (when (and which-key--pages-obj
             (> (which-key--pages-num-pages which-key--pages-obj) 1))
    (setq which-key--pages-obj
          (which-key--pages-set-current-page which-key--pages-obj delta))
    (let ((which-key--automatic-display t))
      (which-key--show-page))))

(defun leadkey-which-key--show-popup (&optional force)
  "Show which-key popup if not already visible.  FORCE forces refresh."
  (when (and which-key--pages-obj
             (or force (not (which-key--popup-showing-p))))
    (let ((which-key--automatic-display t))
      (which-key--show-page))))

(defun leadkey-which-key--hide ()
  "Hide our which-key popup."
  (ignore-errors (which-key--hide-popup))
  (setq which-key--pages-obj nil))

(defun leadkey-which-key--page-hint ()
  "Return echo-area paging hint string."
  (when which-key--pages-obj
    (let* ((n (which-key--pages-num-pages which-key--pages-obj))
           (page (car (which-key--pages-page-nums which-key--pages-obj))))
      (when (> n 1)
        (format "  page %d/%d  %s n/p"
                page n (key-description (vector help-char)))))))

(defun leadkey-which-key--read-event (prompt-fn)
  "Read an event with paging support.
PROMPT-FN is a function of no arguments that returns the prompt string."
  (let ((paging-key (and which-key-paging-key (kbd which-key-paging-key)))
        char)
    (while (not char)
      (setq char (funcall leadkey--event-reader
                          (concat (funcall prompt-fn)
                                  (or (leadkey-which-key--page-hint) ""))))
      (if (and which-key-use-C-h-commands
               (numberp char) (= char help-char)
               which-key--pages-obj
               (> (which-key--pages-num-pages which-key--pages-obj) 1))
          (let ((ch (funcall leadkey--event-reader (leadkey-which-key--page-hint))))
            (cond ((eq ch ?n) (leadkey-which-key--next-page 1))
                  ((eq ch ?p) (leadkey-which-key--next-page -1)))
            (setq char nil))
        (when (and paging-key (equal (vector char) paging-key))
          (leadkey-which-key--show-popup t)
          (leadkey-which-key--next-page 1)
          (setq char nil))))
    char))

(defun leadkey-which-key--show (keys modifier)
  "Show which-key popup for KEYS with MODIFIER bias.
Installed as `leadkey--which-key-show-fn'."
  (let* ((modifier-only (and (or (null keys) (string-empty-p keys))
                             modifier))
         (bindings (if modifier-only
                       (leadkey-which-key--modifier-bindings modifier)
                     (leadkey-which-key--collect-prefix-bindings keys modifier)))
         (pages (and bindings (which-key--format-and-replace bindings)))
         (prefix (if modifier-only modifier keys)))
    (message "%s" (leadkey--prompt keys modifier))
    (when pages
      (setq which-key--pages-obj
            (which-key--create-pages pages nil prefix))
      (when (sit-for which-key-idle-delay)
        (leadkey-which-key--show-popup t)))))

(defun leadkey-which-key--modifier-read (target prefix)
  "Read a key with modifier-prefix which-key for TARGET.
PREFIX is the current accumulated prefix string.
Installed as `leadkey--which-key-modifier-read-fn'."
  (leadkey-which-key--hide)
  (let* ((continuation-p (and prefix (not (string-empty-p prefix))))
         (page-prefix (if continuation-p (concat prefix " " target) target))
         (raw (leadkey-which-key--modifier-bindings target))
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
          (leadkey-which-key--show-popup t))))
    (unwind-protect
        (leadkey-which-key--read-event
         (lambda ()
           (concat (if continuation-p (concat prefix " ") "")
                   target "-")))
      (leadkey-which-key--hide))))

;;;###autoload
(defun leadkey-which-key-setup ()
  "Set up which-key integration hooks into leadkey."
  (setq leadkey--which-key-show-fn #'leadkey-which-key--show)
  (setq leadkey--which-key-modifier-read-fn #'leadkey-which-key--modifier-read)
  (setq leadkey--which-key-read-event-fn #'leadkey-which-key--read-event))

(defun leadkey-which-key-unload-function ()
  "Clean up which-key integration for `unload-feature'."
  (remove-hook 'leadkey-mode-hook #'leadkey-which-key-setup)
  (setq leadkey--which-key-show-fn nil
        leadkey--which-key-modifier-read-fn nil
        leadkey--which-key-read-event-fn nil)
  ;; Return non-nil so `unload-feature' proceeds.
  t)

(when (featurep 'leadkey)
  (leadkey-which-key-setup))
(add-hook 'leadkey-mode-hook #'leadkey-which-key-setup)

(provide 'leadkey-which-key)

;; Local Variables:
;; coding: utf-8
;; End:
;;; leadkey-which-key.el ends here
