;;; keypad.el --- Translate leader keys to key sequences -*- lexical-binding: t; -*-

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

;; keypad.el — a modal leader-key package for Emacs.
;;
;; It intercepts one or more "leader keys" via `key-translation-map' and
;; translates subsequent keystrokes into standard Emacs key sequences.
;;
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;  Quick start
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;
;;   (require 'keypad)
;;   (keypad-mode 1)
;;
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;  Configuration (keyword format)
;; ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
;;
;;   (setq keypad-keys
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

;;; Code:

(require 'cl-lib)

(defgroup keypad nil
  "Leader key configuration."
  :group 'convenience)

(defcustom keypad-keys nil
  "List of leader key configurations.
Each element is a plist — see file commentary for keys."
  :type '(repeat sexp)
  :group 'keypad
  :set (lambda (sym val)
         (set-default sym val)
         (when (and (bound-and-true-p keypad-mode)
                    (fboundp 'keypad--normalize-config))
           (keypad--install))))

(defcustom keypad-pass-through-predicates '(minibufferp isearch-mode)
  "Predicates determining when the leader key passes through as is.
Each element can be:
- A function (or lambda): called with no arguments, pass-through if non-nil.
- A symbol: checked in order:
  1. Variable binding (boundp) → non-nil value.
  2. If commandp and matches major-mode → t.
  3. If fboundp and NOT commandp → funcall.
  Commands are never called (avoids accidentally toggling modes)."
  :type '(repeat (choice function symbol))
  :group 'keypad)

(defcustom keypad-dispatch-priority nil
  "How to resolve dispatch vs. bound-command conflicts.
nil      — dispatch entries always win.
t        — bound commands always win (including fallback matches).
:primary — bound commands win only for primary matches (not fallback)."
  :type '(choice (const :tag "Dispatch wins" nil)
                 (const :tag "Command wins" t)
                 (const :tag "Command wins (primary only)" :primary))
  :group 'keypad)

(defcustom keypad-toggle-priority nil
  "How to resolve toggle vs. bound-command conflicts.
nil      — toggle always wins (default).
t        — bound command wins over toggle.
:primary — primary command wins over toggle, fallback toggle wins."
  :type '(choice (const :tag "Toggle wins" nil)
                 (const :tag "Command wins" t)
                 (const :tag "Command wins (primary only)" :primary))
  :group 'keypad)


;;; Internal state

(defvar keypad--event-reader #'read-event
  "Function to read events.  Override for testing.")

(defvar keypad--key-lookup-fn nil
  "If non-nil, a function (KEY-STRING) used instead of `key-binding'/`kbd'.")

(defvar keypad--which-key-show-fn nil
  "Hook set by `keypad-which-key' to show which-key popup for a prefix.")

(defvar keypad--which-key-modifier-read-fn nil
  "Hook set by `keypad-which-key' to read a key with modifier-filtered popup.")

(defvar keypad--which-key-read-event-fn nil
  "Hook set by `keypad-which-key' to read an event with paging support.
Called as (PROMPT-FN) where PROMPT-FN returns the echo-area prompt.
Should return the event character.")

(defvar which-key-this-command-keys-function)
(defvar which-key-inhibit)
(defvar which-key--pages-obj)

(defvar keypad--normalized-config nil
  "Cached normalized configuration.")

(defvar keypad--installed nil
  "Non-nil when leader key handlers are installed in `key-translation-map'.")


;;; Data structures

(cl-defstruct keypad-context
  "Normalized context for a leader key or dispatch entry.
All fields are fully resolved at config-normalize time; no runtime
default-filling or conditional logic is needed."
  prefix                        ; "C-x", "C-c", nil (modifier-only)
  modifier                      ; "C-", "M-", nil
  fallback                      ; "C-", nil (always explicit)
  toggle-target                 ; "C-", nil
  dispatch-alist                ; ((char . context) ...)  ; root-level
  local-dispatch-alist          ; ((char . context) ...) ; continuations only
  keypad-char                   ; integer: leader key event
  pass-through-predicates       ; nil=use global, list=per-key override
  self)                         ; t: leader key itself is the first char


;;; Normalization

(defun keypad--infer-toggle (modifier fallback)
  "Infer toggle target from MODIFIER and FALLBACK.
If FALLBACK differs from MODIFIER, toggle to FALLBACK.
Otherwise, toggle MODIFIER on/off (non-nil → nil, nil → \"C-\")."
  (cond ((and fallback (not (equal modifier fallback))) fallback)
        (modifier nil)
        (t "C-")))

(defun keypad--normalize-prefix-plist (plist)
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
          (or toggle (keypad--infer-toggle modifier fallback))
          local-dispatch)))

(defun keypad--normalize-dispatch (alist)
  "Normalize dispatch ALIST into ((CHAR . keypad-context) ...)."
  (mapcar
   (lambda (entry)
     (let ((char (car entry))
           (val (cdr entry)))
       (cond
        ((eq val :toggle)
         (cons char (make-keypad-context
                     :prefix nil :modifier nil :fallback nil
                     :toggle-target "C-"
                     :dispatch-alist nil
                     :local-dispatch-alist nil
                     :pass-through-predicates nil)))
        ((and (consp val) (keywordp (car val)))
         (let* ((norm (keypad--normalize-prefix-plist val))
                (prefix (nth 0 norm))
                (modifier (nth 1 norm))
                (fallback (nth 2 norm))
                (toggle (nth 3 norm))
                (local-dispatch
                 (let ((sub (nth 4 norm)))
                   (when sub (keypad--normalize-dispatch sub)))))
           (cons char (make-keypad-context
                       :prefix prefix :modifier modifier
                       :fallback fallback :toggle-target toggle
                       :dispatch-alist nil
                       :local-dispatch-alist local-dispatch
                       :pass-through-predicates
                       (plist-get val :pass-through-predicates)
                       :self (plist-get val :self)))))
        (t (error "Invalid dispatch value: %S" val)))))
   alist))

(defun keypad--normalize-config ()
  "Normalize `keypad-keys' into a list of `keypad-context' structs."
  (setq keypad--normalized-config
        (mapcar
         (lambda (entry)
           (let* ((key-str (plist-get entry :key))
                  (prefix-plist
                   (list :prefix (plist-get entry :prefix)
                         :modifier (plist-get entry :modifier)
                         :fallback (plist-get entry :fallback)
                         :toggle (plist-get entry :toggle)))
                  (norm (keypad--normalize-prefix-plist prefix-plist))
                  (prefix (nth 0 norm))
                  (modifier (nth 1 norm))
                  (fallback (nth 2 norm))
                  (toggle (nth 3 norm))
                  (disp (keypad--normalize-dispatch
                         (plist-get entry :dispatch))))
             (make-keypad-context
              :prefix prefix
              :modifier modifier
              :fallback fallback
              :toggle-target toggle
              :dispatch-alist disp
              :local-dispatch-alist nil
              :keypad-char (aref (kbd key-str) 0)
              :pass-through-predicates
              (plist-get entry :pass-through-predicates)
               :self (plist-get entry :self))))
          keypad-keys)))


;;; Key building

(defun keypad--empty-p (s)
  "Return non-nil if S is nil or the empty string."
  (or (null s) (string-empty-p s)))

(defun keypad--lookup-key (keystr)
  "Look up KEYSTR.  Uses `keypad--key-lookup-fn' if set."
  (if keypad--key-lookup-fn
      (funcall keypad--key-lookup-fn keystr)
    (key-binding (kbd keystr))))

(defun keypad--resolve-key (prefix modifier fallback char)
  "Resolve CHAR to (KEY-STRING . FALLBACK-P).
Uses PREFIX, MODIFIER, and FALLBACK.  Resolution order:
- modifier non-nil: try MODIFIER+CHAR, else plain CHAR.
- modifier nil: try plain CHAR, else FALLBACK+CHAR."
  (let* ((desc (single-key-description char))
         (pref-str (if (keypad--empty-p prefix) "" (concat prefix " ")))
         (plain-key (concat pref-str desc))
         (mod-key (when modifier (concat pref-str modifier desc)))
         (fb-key (when fallback (concat pref-str fallback desc))))
    (cond ((and modifier mod-key (keypad--lookup-key mod-key))
           (cons mod-key nil))
          (modifier (cons plain-key t))
          ((keypad--lookup-key plain-key) (cons plain-key nil))
          ((and fb-key (keypad--lookup-key fb-key)) (cons fb-key t))
          (t (cons plain-key t)))))

(defun keypad--binding-is-prefix-keymap-p (binding)
  "Non-nil if BINDING is a prefix keymap.
Handles keymap objects and symbol variables holding keymaps."
  (or (keymapp binding)
      (and (symbolp binding)
            (boundp binding)
            (keymapp (symbol-value binding)))))

(defun keypad--binding-sort (a b)
  "Sort A and B: plain before angle-bracket, shorter first, alphabetical."
  (let* ((ka (car a)) (kb (car b))
         (ba (if (string-match-p "[<>]" ka) 1 0))
         (bb (if (string-match-p "[<>]" kb) 1 0)))
    (or (< ba bb)
        (and (= ba bb) (< (string-width ka) (string-width kb)))
        (and (= ba bb) (= (string-width ka) (string-width kb))
             (string< ka kb)))))

;;; Meta keymap traversal helper

(defun keypad--walk-esc-keymap (esc-def fn)
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

(defun keypad--collect-modifier-bindings (target)
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
            ((eq ev 27) (keypad--walk-esc-keymap def #'push-binding))
            (t
             (let ((desc (key-description (vector ev))))
               (push-binding desc def)))))
         map)))
    (sort (nreverse bindings) #'keypad--binding-sort)))

(defun keypad--modifier-has-completions-p (prefix target)
  "Non-nil if TARGET has modifier-prefix completions under PREFIX.
Iterates active keymaps directly and returns on first match."
  (catch 'found
    (cl-flet ((check (desc _def)
                (when (string-prefix-p target desc)
                  (when (keypad--lookup-key (concat prefix " " desc))
                    (throw 'found t)))))
      (dolist (map (current-active-maps t))
        (map-keymap
         (lambda (ev def)
           (when (and (not (eq def 'undefined)) (not (eq ev 'which-key)))
             (check (key-description (vector ev)) def)
             (when (eq ev 27)
               (keypad--walk-esc-keymap def #'check))))
         map)))
    nil))

(defun keypad--pass-through-p (&optional predicates)
  "Return non-nil if the leader key should pass through.
Uses PREDICATES if non-nil, otherwise `keypad-pass-through-predicates'."
  (cl-some
   (lambda (keypad--pred)
     (cond
       ((symbolp keypad--pred)
        (cond ((eq major-mode keypad--pred) t)
              ((and (string-suffix-p "-mode" (symbol-name keypad--pred))
                    (bound-and-true-p keypad--pred)) t)
              ((boundp keypad--pred) (symbol-value keypad--pred))
              ((and (fboundp keypad--pred)
                     (not (commandp keypad--pred))
                     (not (string-suffix-p "-mode" (symbol-name keypad--pred))))
               (funcall keypad--pred))
              (t nil)))
      ((functionp keypad--pred) (funcall keypad--pred))
      (t nil)))
   (or predicates keypad-pass-through-predicates)))


;;; Prompt

(defun keypad--prompt (keys modifier)
  "Build echo-area prompt string from KEYS and MODIFIER."
  (let ((keys (if (or (null keys) (and (stringp keys) (string-empty-p keys)))
                  ""
                keys)))
    (if modifier
        (format "%s [%s]-" keys modifier)
      (format "%s -" keys))))

(defun keypad--modifier-prefix-prompt (target prefix)
  "Build prompt for TARGET modifier-prefix reading with PREFIX."
  (concat (if (and prefix (not (string-empty-p prefix)))
              (concat prefix " ") "")
          target "-"))


;;; Event reading

(defun keypad--read-event-with-which-key (prompt modifier prefix)
  "Read an event with PROMPT, optionally showing which-key popup.
When `keypad--which-key-read-event-fn' is set, delegates event
reading to it for paging support (C-h n/p).  MODIFIER and PREFIX are
passed to the which-key show function."
  (when keypad--which-key-show-fn
    (funcall keypad--which-key-show-fn prefix modifier))
  (if keypad--which-key-read-event-fn
      (funcall keypad--which-key-read-event-fn (lambda () prompt))
    (funcall keypad--event-reader prompt)))

(defun keypad--read-modifier-event (target prefix)
  "Read a second key after a TARGET modifier-prefix dispatch with PREFIX."
  ;; Temporarily override which-key's command-keys tracking during
  ;; modifier-prefix read so it doesn't show the old C-c bindings.
  (let ((which-key-this-command-keys-function (lambda () [])))
    (if keypad--which-key-modifier-read-fn
        (funcall keypad--which-key-modifier-read-fn target prefix)
      (progn
        (message "%s" (keypad--modifier-prefix-prompt target prefix))
        (funcall keypad--event-reader
                 (keypad--modifier-prefix-prompt target prefix))))))


;;; Core handler

(defun keypad--command-wins-p (priority fallback-p)
  "Return non-nil if a bound command should win under PRIORITY with FALLBACK-P."
  (cond ((null priority) nil)
        ((eq priority :primary) (not fallback-p))
        (t t)))

(defun keypad--classify-dispatch (dispatch-ctx)
  "Classify DISPATCH-CTX as :toggle, :direct, or :modifier.  Returns nil if none."
  (when dispatch-ctx
    (let ((pref (keypad-context-prefix dispatch-ctx))
          (mod (keypad-context-modifier dispatch-ctx))
          (toggle (keypad-context-toggle-target dispatch-ctx)))
      (cond ((and (keypad--empty-p pref) (null mod) toggle) :toggle)
            ((not (keypad--empty-p pref)) :direct)
            ((and (keypad--empty-p pref) mod) :modifier)))))

(defun keypad--try-command-override (char acc modifier fallback priority ctx prefix-keys)
  "If a bound command should win, apply it and return :done or :continue.
CHAR is the pressed character, ACC is the accumulated prefix string,
MODIFIER and FALLBACK for key resolution, PRIORITY the priority value,
CTX the current keypad-context.
Mutates PREFIX-KEYS and returns nil if no override."
  (let* ((resolved (keypad--resolve-key acc modifier fallback char))
         (key-str (car resolved))
         (fallback-p (cdr resolved))
         (binding (keypad--lookup-key key-str)))
    (when (and binding (commandp binding t)
               (keypad--command-wins-p priority fallback-p))
      (setcar prefix-keys key-str)
      (setcdr prefix-keys (keypad-context-modifier ctx))
      (if (and (not (string-empty-p key-str))
               (keypad--binding-is-prefix-keymap-p binding))
          :continue :done))))

(defun keypad--try-dispatch-command-override
    (char acc modifier fallback ctx prefix-keys)
  "Check if a bound command overrides dispatch for CHAR.
ACC, MODIFIER, FALLBACK, CTX, PREFIX-KEYS passed through.
Returns :done, :continue, or nil."
  (when (not (eq keypad-dispatch-priority nil))
    (keypad--try-command-override char acc modifier fallback
                                  keypad-dispatch-priority ctx prefix-keys)))

(defun keypad--try-toggle-command-override
    (char acc modifier fallback ctx prefix-keys)
  "Check if a bound command overrides toggle for CHAR.
ACC, MODIFIER, FALLBACK, CTX, PREFIX-KEYS passed through.
Returns :done, :continue, or nil."
  (when (not (eq keypad-toggle-priority nil))
    (keypad--try-command-override char acc modifier fallback
                                  keypad-toggle-priority ctx prefix-keys)))

(defun keypad--apply-modifier-dispatch (ctx dispatch-ctx prefix-keys
                                        acc continuation-p char)
  "Handle a modifier-prefix dispatch for CHAR.
DISPATCH-CTX provides the modifier/fallback/toggle target.
Mutates CTX and PREFIX-KEYS (ACC as prefix).
CONTINUATION-P is non-nil inside a prefix keymap continuation.
Returns :done."
  (let* ((new-modifier (keypad-context-modifier dispatch-ctx))
         (target (or new-modifier ""))
         (fallback-check
          (and continuation-p
               (not (keypad--modifier-has-completions-p acc target)))))
    (if fallback-check
        ;; No completions under prefix — resolve as plain key
        (let ((resolved (keypad--resolve-key
                         acc (cdr prefix-keys)
                         (keypad-context-fallback ctx) char)))
          (setcar prefix-keys (car resolved))
          (setcdr prefix-keys (keypad-context-modifier ctx))
          :done)
      ;; Read second key and build the new key string
      (let ((char2 (keypad--read-modifier-event
                    target (if continuation-p acc ""))))
        (setcar
         prefix-keys
         (if continuation-p
             (concat acc " " target (single-key-description char2))
           (concat target (single-key-description char2))))
        (setcdr prefix-keys (keypad-context-modifier ctx))
        (setf (keypad-context-fallback ctx)
              (keypad-context-fallback dispatch-ctx)
              (keypad-context-modifier ctx)
              (keypad-context-modifier dispatch-ctx)
              (keypad-context-toggle-target ctx)
              (keypad-context-toggle-target dispatch-ctx))
        :done))))

(defun keypad--apply-direct-dispatch (ctx dispatch-ctx prefix-keys)
  "Apply a direct (prefix-switch) dispatch.
DISPATCH-CTX provides the new prefix/modifier/fallback/toggle.
Mutates CTX and PREFIX-KEYS."
  (let ((new-prefix (keypad-context-prefix dispatch-ctx))
        (new-modifier (keypad-context-modifier dispatch-ctx)))
    (setcar prefix-keys new-prefix)
    (setcdr prefix-keys new-modifier)
    (setf (keypad-context-fallback ctx)
          (keypad-context-fallback dispatch-ctx)
          (keypad-context-modifier ctx)
          (keypad-context-modifier dispatch-ctx)
          (keypad-context-prefix ctx)
          (keypad-context-prefix dispatch-ctx)
          (keypad-context-toggle-target ctx)
          (keypad-context-toggle-target dispatch-ctx)
          (keypad-context-local-dispatch-alist ctx)
          (keypad-context-local-dispatch-alist dispatch-ctx))))

(defun keypad--process-char (ctx char prefix-keys continuation-p)
  "Process CHAR in CTX, mutating CTX and PREFIX-KEYS in place.
CTX is a `keypad-context', PREFIX-KEYS is (ACCUMULATED . MODIFIER).
CONTINUATION-P is non-nil inside a prefix keymap continuation.
Returns :done, :continue, or nil (toggle, re-read)."
  (cl-block keypad--process-char
    (let* ((acc (car prefix-keys))
           (current-modifier (cdr prefix-keys))
           (alist (if continuation-p
                      (or (keypad-context-local-dispatch-alist ctx)
                          (keypad-context-dispatch-alist ctx))
                    (keypad-context-dispatch-alist ctx)))
           (dispatch (assq char alist))
           (dispatch-ctx (cdr dispatch))
           (dispatch-type (keypad--classify-dispatch dispatch-ctx))
           (suppressed (and continuation-p (eq dispatch-type :direct))))

      (when suppressed
        (setq dispatch nil dispatch-ctx nil dispatch-type nil))

      ;; Prefer-command: check if bound command should win over dispatch
      (when (and dispatch (not (eq dispatch-type :toggle)))
        (let ((result (keypad--try-dispatch-command-override
                       char acc current-modifier
                       (keypad-context-fallback ctx) ctx prefix-keys)))
          (when result
            (cl-return-from keypad--process-char result))))

      (cond
       ;; Toggle
       ((or (eq dispatch-type :toggle)
            (and (null dispatch)
                 (eq char (keypad-context-keypad-char ctx))))
        (let ((result (keypad--try-toggle-command-override
                       char acc current-modifier
                       (keypad-context-fallback ctx) ctx prefix-keys)))
          (when result
            (cl-return-from keypad--process-char result)))
        (setcdr prefix-keys
                (if current-modifier nil
                  (if (and dispatch-ctx)
                      (keypad-context-toggle-target dispatch-ctx)
                    (keypad-context-toggle-target ctx))))
        nil)

       ;; Modifier-prefix dispatch: read second key
       ((eq dispatch-type :modifier)
        (cl-return-from keypad--process-char
          (keypad--apply-modifier-dispatch
           ctx dispatch-ctx prefix-keys acc continuation-p char)))

       ;; Direct dispatch (prefix switch) or no dispatch
       (t
        (if dispatch-ctx
            (keypad--apply-direct-dispatch ctx dispatch-ctx prefix-keys)
          (let ((resolved (keypad--resolve-key
                           acc current-modifier
                           (keypad-context-fallback ctx) char)))
            (setcar prefix-keys (car resolved))
            (setcdr prefix-keys (keypad-context-modifier ctx))))
        (let* ((resolved-key (car prefix-keys))
               (binding (keypad--lookup-key resolved-key)))
          (if (and (not (string-empty-p resolved-key))
                   (keypad--binding-is-prefix-keymap-p binding))
              :continue :done)))))))

(defun keypad--run-handler (vkeys ctx)
  "Process leader key event VKEYS using CTX, return translated key vector."
  (let* ((len (length vkeys))
         (leader (aref vkeys (1- len))))
    (setf (keypad-context-keypad-char ctx) leader)
    (cond
     ((keypad--pass-through-p (keypad-context-pass-through-predicates ctx))
      (vector leader))
     ((= len 1)
      (let ((which-key-inhibit t))
        (condition-case nil
            (let* ((prefix-keys (cons (keypad-context-prefix ctx)
                                      (keypad-context-modifier ctx)))
                   (continuation-p nil)
                   (state :read)
                   (first-char-p (keypad-context-self ctx))
                   (which-key-this-command-keys-function
                    (lambda () (kbd (car prefix-keys)))))
              (when first-char-p
                (setf (keypad-context-keypad-char ctx) nil))
              (while (not (eq state :done))
                (let ((char (if first-char-p
                                (progn (setq first-char-p nil) leader)
                              (keypad--read-event-with-which-key
                               (keypad--prompt (car prefix-keys)
                                               (cdr prefix-keys))
                               (cdr prefix-keys) (car prefix-keys)))))
                  (setq state (keypad--process-char
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

(defun keypad--make-handler (ctx)
  "Return a `key-translation-map' handler closure for CTX."
  (lambda (_)
    (keypad--run-handler (this-command-keys-vector) (copy-keypad-context ctx))))


;;; Install / uninstall

(defun keypad--uninstall ()
  "Remove all leader key handlers from `key-translation-map'."
  (when keypad--installed
    (dolist (ctx keypad--normalized-config)
      (let ((char (keypad-context-keypad-char ctx)))
        (define-key key-translation-map
                    (kbd (key-description (vector char)))
                    nil))))
  (setq keypad--installed nil))

(defun keypad--install ()
  "Install all leader key handlers into `key-translation-map'."
  (keypad--uninstall)
  (keypad--normalize-config)
  (dolist (ctx keypad--normalized-config)
    (let ((char (keypad-context-keypad-char ctx)))
      (define-key key-translation-map
                  (kbd (key-description (vector char)))
                  (keypad--make-handler ctx))))
  (setq keypad--installed t))

;;;###autoload
(define-minor-mode keypad-mode
  "Global minor mode for leader key support.
When enabled, leader keys defined in `keypad-keys' are activated
in `key-translation-map'."
  :global t
  :group 'keypad
  (if keypad-mode (keypad--install) (keypad--uninstall)))

(provide 'keypad)

;; Local Variables:
;; coding: utf-8
;; End:
;;; keypad.el ends here
