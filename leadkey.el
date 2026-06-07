;;; leadkey.el --- Translate leader keys to key sequences -*- lexical-binding: t; -*-

;; Author: jixiuf <https://github.com/jixiuf>
;; Keywords: convenience
;; Version: 0.2.0
;; URL: https://github.com/jixiuf/emacs-leadkey
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

;; leadkey.el — a modal leader-key package for Emacs.
;;
;; It intercepts one or more "leader keys" via `key-translation-map' and
;; translates subsequent keystrokes into standard Emacs key sequences.
;; This means you can type SPC f and have it arrive at Emacs as C-c C-f,
;; using all your existing keybindings with zero rebinding.
;;
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;  Quick start
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;
;;   (require 'leadkey)
;;   (leadkey-mode 1)
;;
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;  Configuration (keyword format)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;
;;   (setq leadkey-keys
;;    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
;;       :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
;;                  (?h . (:prefix "C-h" :modifier nil  :fallback "C-"))
;;                  (?m . (:prefix nil  :modifier "M-" :fallback nil))))
;;      (:key "," :prefix nil :modifier "C-M-" :fallback nil)))
;;
;; Each entry is a plist:
;;   :key       - leader key string ("<SPC>", ",")
;;   :prefix    - target prefix string ("C-c", "C-x", nil for modifier-only)
;;   :modifier  - default modifier ("C-", "M-", nil)
;;   :fallback  - fallback modifier (nil = plain only)
;;   :toggle    - toggle target modifier (default: inferred)
;;   :dispatch  - alist (CHAR . PLIST) or (CHAR . :toggle)
;;   :pass-through-predicates - per-key override, nil = use global
;;
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;  How it works
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;
;; Unlike packages that bind commands under a custom keymap (general.el,
;; evil-leader, etc.), leadkey translates keystrokes in
;; `key-translation-map' — BEFORE they hit any keymap.  This means:
;;
;;   SPC f  →  C-c C-f    (if C-c C-f is bound, it Just Works™)
;;   SPC x  →  C-x        (enters the standard C-x prefix)
;;   , a    →  M-a        (comma becomes M- leader)
;;
;; No need to manually rebind every command — all your existing C-c,
;; C-x, M-, etc. bindings work automatically through the leader key.

;;; Code:

(require 'cl-lib)

(defgroup leadkey nil
  "Leader key configuration."
  :group 'convenience)

(defcustom leadkey-keys
  '((:key "<SPC>" :prefix "C-c" :modifier "" :fallback "C-"
          :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                     (?h . (:prefix "<f1>" :modifier nil  :fallback "C-"))
                     (?s . (:prefix "M-s" :modifier nil  :fallback "M-")))))
  "List of leader key configurations.
Each element is a plist — see file commentary for keys."
  :type '(repeat sexp)
  :group 'leadkey
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (bound-and-true-p leadkey-mode)
                    (fboundp 'leadkey--normalize-config))
           (leadkey--install))))

(defcustom leadkey-pass-through-predicates '(minibufferp isearch-mode)
  "Predicates determining when the leader key passes through as is.
Each element can be:
- A function (or lambda): called with no arguments, pass-through if non-nil.
- A symbol: checked in order:
  1. Variable binding (boundp) → non-nil value.
  2. If commandp and matches major-mode → t.
  3. If fboundp and NOT commandp → funcall.
  Commands are never called (avoids accidentally toggling modes)."
  :type '(repeat (choice function symbol))
  :group 'leadkey)

(defcustom leadkey-dispatch-priority nil
  "How to resolve dispatch vs. bound-command conflicts.
nil      — dispatch entries always win.
t        — bound commands always win (including fallback matches).
:primary — bound commands win only for primary matches (not fallback)."
  :type '(choice (const :tag "Dispatch wins" nil)
                 (const :tag "Command wins" t)
                 (const :tag "Command wins (primary only)" :primary))
  :group 'leadkey)

(defcustom leadkey-toggle-priority nil
  "How to resolve toggle vs. bound-command conflicts.
nil      — toggle always wins (default).
t        — bound command wins over toggle.
:primary — primary command wins over toggle, fallback toggle wins."
  :type '(choice (const :tag "Toggle wins" nil)
                 (const :tag "Command wins" t)
                 (const :tag "Command wins (primary only)" :primary))
  :group 'leadkey)


;;; Internal state

(defvar leadkey--event-reader #'read-event
  "Function to read events.  Override for testing.")

(defvar leadkey--key-lookup-fn nil
  "If non-nil, a function (KEY-STRING) used instead of `key-binding'/`kbd'.")

(defvar leadkey--which-key-show-fn nil
  "Hook set by `leadkey-which-key' to show which-key popup for a prefix.")

(defvar leadkey--which-key-modifier-read-fn nil
  "Hook set by `leadkey-which-key' to read a key with modifier-filtered popup.")

(defvar leadkey--which-key-read-event-fn nil
  "Hook set by `leadkey-which-key' to read an event with paging support.
Called as (PROMPT-FN) where PROMPT-FN returns the echo-area prompt.
Should return the event character.")

(defvar which-key-this-command-keys-function)
(defvar which-key-inhibit)
(defvar which-key--pages-obj)

(defvar leadkey--normalized-config nil
  "Cached normalized configuration.")

(defvar leadkey--installed nil
  "Non-nil when leader key handlers are installed in `key-translation-map'.")


;;; Data structures

(cl-defstruct leadkey-context
  "Normalized context for a leader key or dispatch entry.
All fields are fully resolved at config-normalize time; no runtime
default-filling or conditional logic is needed."
  prefix                        ; "C-x", "C-c", nil (modifier-only)
  modifier                      ; "C-", "M-", nil
  fallback                      ; "C-", nil (always explicit)
  toggle-target                 ; "C-", nil
  dispatch-alist                ; ((char . context) ...)  ; root-level
  local-dispatch-alist          ; ((char . context) ...) ; continuations only
  leadkey-char                   ; integer: leader key event
  pass-through-predicates       ; nil=use global, list=per-key override
  self)                         ; t: leader key itself is the first char


;;; Normalization

(defun leadkey--infer-toggle (modifier fallback)
  "Infer toggle target from MODIFIER and FALLBACK.
If FALLBACK differs from MODIFIER, toggle to FALLBACK.
Otherwise, toggle MODIFIER on/off (non-nil → nil, nil → \"C-\")."
  (cond ((and fallback (not (equal modifier fallback))) fallback)
        (modifier nil)
        (t "C-")))

(defun leadkey--normalize-prefix-plist (plist)
  "Normalize a prefix PLIST into:
\(PREFIX MODIFIER FALLBACK TOGGLE LOCAL-DISPATCH)."
  (let* ((prefix (plist-get plist :prefix))
         (modifier (plist-get plist :modifier))
         (fallback (plist-get plist :fallback))
         (has-fb (plist-member plist :fallback))
         (toggle (plist-get plist :toggle))
         (local-dispatch (plist-get plist :dispatch)))
    ;; Normalize empty-string to nil
    (when (and prefix (string-empty-p prefix))
      (setq prefix nil))
    (when (and modifier (string-empty-p modifier))
      (setq modifier nil))
    (when (and fallback (string-empty-p fallback))
      (setq fallback nil))
    (when (and toggle (string-empty-p toggle))
      (setq toggle nil))
    (list prefix
          modifier
          (if has-fb fallback
            (if (null prefix) nil modifier))
          (or toggle (leadkey--infer-toggle modifier fallback))
          local-dispatch)))

(defun leadkey--normalize-dispatch (alist)
  "Normalize dispatch ALIST into ((CHAR . leadkey-context) ...)."
  (mapcar
   (lambda (entry)
     (let ((char (car entry))
           (val (cdr entry)))
       (cond
        ((eq val :toggle)
         (cons char (make-leadkey-context
                     :prefix nil :modifier nil :fallback nil
                     :toggle-target "C-"
                     :dispatch-alist nil
                     :local-dispatch-alist nil
                     :pass-through-predicates nil)))
        ((and (consp val) (keywordp (car val)))
         (let* ((norm (leadkey--normalize-prefix-plist val))
                (prefix (nth 0 norm))
                (modifier (nth 1 norm))
                (fallback (nth 2 norm))
                (toggle (nth 3 norm))
                (local-dispatch
                 (let ((sub (nth 4 norm)))
                   (when sub (leadkey--normalize-dispatch sub)))))
           (cons char (make-leadkey-context
                       :prefix prefix :modifier modifier
                       :fallback fallback :toggle-target toggle
                       :dispatch-alist nil
                       :local-dispatch-alist local-dispatch
                       :pass-through-predicates
                       (plist-get val :pass-through-predicates)
                       :self (plist-get val :self)))))
        (t (error "Invalid dispatch value: %S" val)))))
   alist))

(defun leadkey--normalize-config ()
  "Normalize `leadkey-keys' into a list of `leadkey-context' structs."
  (setq leadkey--normalized-config
        (mapcar
         (lambda (entry)
           (let* ((key-str (plist-get entry :key))
                  (prefix-plist
                   (list :prefix (plist-get entry :prefix)
                         :modifier (plist-get entry :modifier)
                         :fallback (plist-get entry :fallback)
                         :toggle (plist-get entry :toggle)))
                  (norm (leadkey--normalize-prefix-plist prefix-plist))
                  (prefix (nth 0 norm))
                  (modifier (nth 1 norm))
                  (fallback (nth 2 norm))
                  (toggle (nth 3 norm))
                  (disp (leadkey--normalize-dispatch
                         (plist-get entry :dispatch))))
             (make-leadkey-context
              :prefix prefix
              :modifier modifier
              :fallback fallback
              :toggle-target toggle
              :dispatch-alist disp
              :local-dispatch-alist nil
              :leadkey-char (aref (kbd key-str) 0)
              :pass-through-predicates
              (plist-get entry :pass-through-predicates)
               :self (plist-get entry :self))))
          leadkey-keys)))


;;; Key building

(defun leadkey--empty-p (s)
  "Return non-nil if S is nil or the empty string."
  (or (null s) (string-empty-p s)))

(defun leadkey--lookup-key (keystr)
  "Look up KEYSTR.  Uses `leadkey--key-lookup-fn' if set."
  (if leadkey--key-lookup-fn
      (funcall leadkey--key-lookup-fn keystr)
    (key-binding (kbd keystr))))

(defun leadkey--resolve-key (prefix modifier fallback char)
  "Resolve CHAR to (KEY-STRING . FALLBACK-P).
Uses PREFIX, MODIFIER, and FALLBACK.  Resolution order:
- modifier non-nil: try MODIFIER+CHAR, else plain CHAR.
- modifier nil: try plain CHAR, else FALLBACK+CHAR."
  (let* ((desc (single-key-description char))
         (pref-str (if (leadkey--empty-p prefix) "" (concat prefix " ")))
         (plain-key (concat pref-str desc))
         (mod-key (when modifier (concat pref-str modifier desc)))
         (fb-key (when fallback (concat pref-str fallback desc))))
    (cond ((and modifier mod-key (leadkey--lookup-key mod-key))
           (cons mod-key nil))
          (modifier (cons plain-key t))
          ((leadkey--lookup-key plain-key) (cons plain-key nil))
          ((and fb-key (leadkey--lookup-key fb-key)) (cons fb-key t))
          (t (cons plain-key t)))))

(defun leadkey--binding-is-prefix-keymap-p (binding)
  "Non-nil if BINDING is a prefix keymap.
Handles keymap objects and symbol variables holding keymaps."
  (or (keymapp binding)
      (and (symbolp binding)
            (boundp binding)
            (keymapp (symbol-value binding)))))

(defun leadkey--binding-sort (a b)
  "Sort A and B: plain before angle-bracket, shorter first, alphabetical."
  (let* ((ka (car a)) (kb (car b))
         (ba (if (string-match-p "[<>]" ka) 1 0))
         (bb (if (string-match-p "[<>]" kb) 1 0)))
    (or (< ba bb)
        (and (= ba bb) (< (string-width ka) (string-width kb)))
        (and (= ba bb) (= (string-width ka) (string-width kb))
             (string< ka kb)))))

;;; Meta keymap traversal helper

(defun leadkey--walk-esc-keymap (esc-def fn)
  "Call FN (DESC DEF) for each M-* binding in ESC keymap ESC-DEF.
FN is called with (key-description-string . binding-definition)
for every binding reachable via the M- modifier prefix."
  (when (keymapp esc-def)
    (map-keymap
     (lambda (sub-ev sub-def)
       (cond
        ((integerp sub-ev)
         (let* ((meta-ev (event-apply-modifier sub-ev 'meta 27 "M-"))
                (desc (key-description (vector meta-ev))))
           (funcall fn desc sub-def)))
        ((consp sub-ev)
         (cl-loop for i from (car sub-ev) to (cdr sub-ev)
                  for mev = (event-apply-modifier i 'meta 27 "M-")
                  for desc = (key-description (vector mev))
                  do (funcall fn desc sub-def)))))
     esc-def)))

(defun leadkey--collect-modifier-bindings (target)
  "Collect bindings from all active keymaps matching TARGET modifier prefix."
  (let ((bindings nil)
        (seen (make-hash-table :test 'equal)))
    (cl-flet ((push-binding
                (desc def)
                (when (and (string-prefix-p target desc)
                           (not (eq def 'undefined))
                           (not (gethash desc seen)))
                  (let ((rest (substring desc (length target))))
                    (when (and (not (string-match-p "[ACHMSs]-" rest))
                               (not (and (member target '("M-" "C-M-"))
                                         (string-match-p "\\`[1-9]\\'" rest)
                                         (eq def 'digit-argument))))
                      (puthash desc t seen)
                      (push (cons desc
                                  (cond ((keymapp def) "prefix")
                                        ((symbolp def) (symbol-name def))
                                        (t (format "%s" def))))
                            bindings))))))
      (dolist (map (current-active-maps t))
        (map-keymap
         (lambda (ev def)
           (cond
            ((eq ev 27) (leadkey--walk-esc-keymap def #'push-binding))
            (t
             (let ((desc (key-description (vector ev))))
               (push-binding desc def)))))
         map)))
    (sort (nreverse bindings) #'leadkey--binding-sort)))

(defun leadkey--modifier-has-completions-p (prefix target)
  "Non-nil if TARGET has modifier-prefix completions under PREFIX.
Iterates active keymaps directly and returns on first match."
  (catch 'found
    (cl-flet ((check (desc _def)
                (when (string-prefix-p target desc)
                  (when (leadkey--lookup-key (concat prefix " " desc))
                    (throw 'found t)))))
      (dolist (map (current-active-maps t))
        (map-keymap
         (lambda (ev def)
           (when (and (not (eq def 'undefined)) (not (eq ev 'which-key)))
             (check (key-description (vector ev)) def)
             (when (eq ev 27)
               (leadkey--walk-esc-keymap def #'check))))
         map)))
    nil))

(defun leadkey--pass-through-p (&optional predicates)
  "Return non-nil if the leader key should pass through.
Uses PREDICATES if non-nil, otherwise `leadkey-pass-through-predicates'."
  (cl-some
   (lambda (leadkey--pred)
     (cond
       ((symbolp leadkey--pred)
        (cond ((eq major-mode leadkey--pred) t)
              ((and (string-suffix-p "-mode" (symbol-name leadkey--pred))
                    (bound-and-true-p leadkey--pred)) t)
              ((boundp leadkey--pred) (symbol-value leadkey--pred))
              ((and (fboundp leadkey--pred)
                     (not (commandp leadkey--pred))
                     (not (string-suffix-p "-mode" (symbol-name leadkey--pred))))
               (funcall leadkey--pred))
              (t nil)))
      ((functionp leadkey--pred) (funcall leadkey--pred))
      (t nil)))
   (or predicates leadkey-pass-through-predicates)))


;;; Prompt

(defun leadkey--prompt (keys modifier)
  "Build echo-area prompt string from KEYS and MODIFIER."
  (let ((keys (if (or (null keys) (and (stringp keys) (string-empty-p keys)))
                  ""
                keys)))
    (if modifier
        (format "%s [%s]-" keys modifier)
      (format "%s -" keys))))

(defun leadkey--modifier-prefix-prompt (target prefix)
  "Build prompt for TARGET modifier-prefix reading with PREFIX."
  (concat (if (and prefix (not (string-empty-p prefix)))
              (concat prefix " ") "")
          target "-"))


;;; Event reading

(defun leadkey--read-event-with-which-key (prompt modifier prefix)
  "Read an event with PROMPT, optionally showing which-key popup.
When `leadkey--which-key-read-event-fn' is set, delegates event
reading to it for paging support (C-h n/p).  MODIFIER and PREFIX are
passed to the which-key show function."
  (when leadkey--which-key-show-fn
    (funcall leadkey--which-key-show-fn prefix modifier))
  (if leadkey--which-key-read-event-fn
      (funcall leadkey--which-key-read-event-fn (lambda () prompt))
    (funcall leadkey--event-reader prompt)))

(defun leadkey--read-modifier-event (target prefix)
  "Read a second key after a TARGET modifier-prefix dispatch with PREFIX."
  ;; Temporarily override which-key's command-keys tracking during
  ;; modifier-prefix read so it doesn't show the old C-c bindings.
  (let ((which-key-this-command-keys-function (lambda () [])))
    (if leadkey--which-key-modifier-read-fn
        (funcall leadkey--which-key-modifier-read-fn target prefix)
      (progn
        (message "%s" (leadkey--modifier-prefix-prompt target prefix))
        (funcall leadkey--event-reader
                 (leadkey--modifier-prefix-prompt target prefix))))))


;;; Core handler

(defun leadkey--command-wins-p (priority fallback-p)
  "Return non-nil if a bound command should win under PRIORITY with FALLBACK-P."
  (cond ((null priority) nil)
        ((eq priority :primary) (not fallback-p))
        (t t)))

(defun leadkey--classify-dispatch (dispatch-ctx)
  "Classify DISPATCH-CTX as :toggle, :direct, or :modifier.  Returns nil if none."
  (when dispatch-ctx
    (let ((pref (leadkey-context-prefix dispatch-ctx))
          (mod (leadkey-context-modifier dispatch-ctx))
          (toggle (leadkey-context-toggle-target dispatch-ctx)))
      (cond ((and (leadkey--empty-p pref) (null mod) toggle) :toggle)
            ((not (leadkey--empty-p pref)) :direct)
            ((and (leadkey--empty-p pref) mod) :modifier)))))

(defun leadkey--try-command-override (char acc modifier fallback priority ctx prefix-keys)
  "If a bound command should win, apply it and return :done or :continue.
CHAR is the pressed character, ACC is the accumulated prefix string,
MODIFIER and FALLBACK for key resolution, PRIORITY the priority value,
CTX the current leadkey-context.
Mutates PREFIX-KEYS and returns nil if no override."
  (let* ((resolved (leadkey--resolve-key acc modifier fallback char))
         (key-str (car resolved))
         (fallback-p (cdr resolved))
         (binding (leadkey--lookup-key key-str)))
    (when (and binding (commandp binding t)
               (leadkey--command-wins-p priority fallback-p))
      (setcar prefix-keys key-str)
      (setcdr prefix-keys (leadkey-context-modifier ctx))
      (if (and (not (string-empty-p key-str))
               (leadkey--binding-is-prefix-keymap-p binding))
          :continue :done))))

(defun leadkey--try-dispatch-command-override
    (char acc modifier fallback ctx prefix-keys)
  "Check if a bound command overrides dispatch for CHAR.
ACC, MODIFIER, FALLBACK, CTX, PREFIX-KEYS passed through.
Returns :done, :continue, or nil."
  (when leadkey-dispatch-priority
    (leadkey--try-command-override char acc modifier fallback
                                  leadkey-dispatch-priority ctx prefix-keys)))

(defun leadkey--try-toggle-command-override
    (char acc modifier fallback ctx prefix-keys)
  "Check if a bound command overrides toggle for CHAR.
ACC, MODIFIER, FALLBACK, CTX, PREFIX-KEYS passed through.
Returns :done, :continue, or nil."
  (when leadkey-toggle-priority
    (leadkey--try-command-override char acc modifier fallback
                                  leadkey-toggle-priority ctx prefix-keys)))

(defun leadkey--apply-modifier-dispatch (ctx dispatch-ctx prefix-keys
                                        acc continuation-p char)
  "Handle a modifier-prefix dispatch for CHAR.
DISPATCH-CTX provides the modifier/fallback/toggle target.
Mutates CTX and PREFIX-KEYS (ACC as prefix).
CONTINUATION-P is non-nil inside a prefix keymap continuation.
Returns :done."
  (let* ((new-modifier (leadkey-context-modifier dispatch-ctx))
         (target (or new-modifier ""))
         (fallback-check
          (and continuation-p
               (not (leadkey--modifier-has-completions-p acc target)))))
    (if fallback-check
        ;; No completions under prefix — resolve as plain key
        (let ((resolved (leadkey--resolve-key
                         acc (cdr prefix-keys)
                         (leadkey-context-fallback ctx) char)))
          (setcar prefix-keys (car resolved))
          (setcdr prefix-keys (leadkey-context-modifier ctx))
          :done)
      ;; Read second key and build the new key string
      (let ((char2 (leadkey--read-modifier-event
                    target (if continuation-p acc ""))))
        (setcar
         prefix-keys
         (if continuation-p
             (concat acc " " target (single-key-description char2))
           (concat target (single-key-description char2))))
        (setcdr prefix-keys (leadkey-context-modifier ctx))
        (setf (leadkey-context-fallback ctx)
              (leadkey-context-fallback dispatch-ctx)
              (leadkey-context-modifier ctx)
              (leadkey-context-modifier dispatch-ctx)
              (leadkey-context-toggle-target ctx)
              (leadkey-context-toggle-target dispatch-ctx))
        :done))))

(defun leadkey--apply-direct-dispatch (ctx dispatch-ctx prefix-keys)
  "Apply a direct (prefix-switch) dispatch.
DISPATCH-CTX provides the new prefix/modifier/fallback/toggle.
Mutates CTX and PREFIX-KEYS."
  (let ((new-prefix (leadkey-context-prefix dispatch-ctx))
        (new-modifier (leadkey-context-modifier dispatch-ctx)))
    (setcar prefix-keys new-prefix)
    (setcdr prefix-keys new-modifier)
    (setf (leadkey-context-fallback ctx)
          (leadkey-context-fallback dispatch-ctx)
          (leadkey-context-modifier ctx)
          (leadkey-context-modifier dispatch-ctx)
          (leadkey-context-prefix ctx)
          (leadkey-context-prefix dispatch-ctx)
          (leadkey-context-toggle-target ctx)
          (leadkey-context-toggle-target dispatch-ctx)
          (leadkey-context-local-dispatch-alist ctx)
          (leadkey-context-local-dispatch-alist dispatch-ctx))))

(defun leadkey--process-char (ctx char prefix-keys continuation-p)
  "Process CHAR in CTX, mutating CTX and PREFIX-KEYS in place.
CTX is a `leadkey-context', PREFIX-KEYS is (ACCUMULATED . MODIFIER).
CONTINUATION-P is non-nil inside a prefix keymap continuation.
Returns :done, :continue, or nil (toggle, re-read)."
  (cl-block leadkey--process-char
    (let* ((acc (car prefix-keys))
           (current-modifier (cdr prefix-keys))
           (alist (if continuation-p
                      (or (leadkey-context-local-dispatch-alist ctx)
                          (leadkey-context-dispatch-alist ctx))
                    (leadkey-context-dispatch-alist ctx)))
           (dispatch (assq char alist))
           (dispatch-ctx (cdr dispatch))
           (dispatch-type (leadkey--classify-dispatch dispatch-ctx))
           (suppressed (and continuation-p (eq dispatch-type :direct))))

      (when suppressed
        (setq dispatch nil dispatch-ctx nil dispatch-type nil))

      ;; Prefer-command: check if bound command should win over dispatch
      (when (and dispatch (not (eq dispatch-type :toggle)))
        (let ((result (leadkey--try-dispatch-command-override
                       char acc current-modifier
                       (leadkey-context-fallback ctx) ctx prefix-keys)))
          (when result
            (cl-return-from leadkey--process-char result))))

      (cond
       ;; Toggle
       ((or (eq dispatch-type :toggle)
            (and (null dispatch)
                 (eq char (leadkey-context-leadkey-char ctx))))
        (let ((result (leadkey--try-toggle-command-override
                       char acc current-modifier
                       (leadkey-context-fallback ctx) ctx prefix-keys)))
          (when result
            (cl-return-from leadkey--process-char result)))
        (setcdr prefix-keys
                (if current-modifier nil
                  (if (and dispatch-ctx)
                      (leadkey-context-toggle-target dispatch-ctx)
                    (leadkey-context-toggle-target ctx))))
        nil)

       ;; Modifier-prefix dispatch: read second key
       ((eq dispatch-type :modifier)
        (cl-return-from leadkey--process-char
          (leadkey--apply-modifier-dispatch
           ctx dispatch-ctx prefix-keys acc continuation-p char)))

       ;; Direct dispatch (prefix switch) or no dispatch
       (t
        (if dispatch-ctx
            (leadkey--apply-direct-dispatch ctx dispatch-ctx prefix-keys)
          (let ((resolved (leadkey--resolve-key
                           acc current-modifier
                           (leadkey-context-fallback ctx) char)))
            (setcar prefix-keys (car resolved))
            (setcdr prefix-keys (leadkey-context-modifier ctx))))
        (let* ((resolved-key (car prefix-keys))
               (binding (leadkey--lookup-key resolved-key)))
          (if (and (not (string-empty-p resolved-key))
                   (leadkey--binding-is-prefix-keymap-p binding))
              :continue :done)))))))

(defun leadkey--run-handler (vkeys ctx)
  "Process leader key event VKEYS using CTX, return translated key vector."
  (let* ((len (length vkeys))
         (leader (aref vkeys (1- len))))
    (setf (leadkey-context-leadkey-char ctx) leader)
    (cond
     ((leadkey--pass-through-p (leadkey-context-pass-through-predicates ctx))
      (vector leader))
     ((= len 1)
      (let ((which-key-inhibit t))
        (condition-case nil
            (let* ((prefix-keys (cons (leadkey-context-prefix ctx)
                                      (leadkey-context-modifier ctx)))
                   (continuation-p nil)
                   (state :read)
                   (first-char-p (leadkey-context-self ctx))
                   (which-key-this-command-keys-function
                    (lambda () (kbd (car prefix-keys)))))
              (when first-char-p
                (setf (leadkey-context-leadkey-char ctx) nil))
              (while (not (eq state :done))
                (let ((char (if first-char-p
                                (progn (setq first-char-p nil) leader)
                              (leadkey--read-event-with-which-key
                               (leadkey--prompt (car prefix-keys)
                                               (cdr prefix-keys))
                               (cdr prefix-keys) (car prefix-keys)))))
                  (setq state (leadkey--process-char
                               ctx char prefix-keys continuation-p))
                  (when (eq state :continue)
                    (setq continuation-p t state :read))))
              (kbd (car prefix-keys)))
          (quit
           (when (fboundp 'which-key--hide-popup)
             (ignore-errors (which-key--hide-popup)))
           (setq which-key--pages-obj nil)
           nil))))
     (t (vector leader)))))

(defun leadkey--make-handler (ctx)
  "Return a `key-translation-map' handler closure for CTX."
  (lambda (_)
    (leadkey--run-handler (this-command-keys-vector) (copy-leadkey-context ctx))))


;;; Install / uninstall

(defun leadkey--uninstall ()
  "Remove all leader key handlers from `key-translation-map'."
  (when leadkey--installed
    (dolist (ctx leadkey--normalized-config)
      (let ((char (leadkey-context-leadkey-char ctx)))
        (define-key key-translation-map
                    (kbd (key-description (vector char)))
                    nil))))
  (setq leadkey--installed nil))

(defun leadkey--install ()
  "Install all leader key handlers into `key-translation-map'."
  (leadkey--uninstall)
  (leadkey--normalize-config)
  (dolist (ctx leadkey--normalized-config)
    (let ((char (leadkey-context-leadkey-char ctx)))
      (define-key key-translation-map
                  (kbd (key-description (vector char)))
                  (leadkey--make-handler ctx))))
  (setq leadkey--installed t))

;;;###autoload
(define-minor-mode leadkey-mode
  "Global minor mode for leader key support.
When enabled, leader keys defined in `leadkey-keys' are activated
in `key-translation-map'."
  :global t
  :group 'leadkey
  (if leadkey-mode (leadkey--install) (leadkey--uninstall)))

(provide 'leadkey)

;; Local Variables:
;; coding: utf-8
;; End:
;;; leadkey.el ends here
