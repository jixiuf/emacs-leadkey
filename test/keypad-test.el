;;; keypad-test.el --- Tests for keypad.el -*- lexical-binding: t; -*-
(require 'ert)
(require 'keypad)

(defvar keypad-tt-cx-map (make-sparse-keymap))
(define-key keypad-tt-cx-map (kbd "C-f") 'ignore)

(defvar keypad-tt-sub-map (make-sparse-keymap))
(define-key keypad-tt-sub-map (kbd "C-b") 'ignore)
(define-key keypad-tt-sub-map (kbd "b") 'ignore)


;;; Helpers

(defun keypad-test--event-source (events)
  (let ((idx 0))
    (lambda (_)
      (prog1 (nth idx events)
        (setq idx (1+ idx))))))

(defun keypad-test--key-lookup (bindings)
  (lambda (keystr)
    (cdr (assoc keystr bindings))))

(defun keypad-test--do-run (config bindings events)
  (setq keypad-keys config)
  (keypad--normalize-config)
  (let* ((keypad--key-lookup-fn (keypad-test--key-lookup bindings))
         (keypad--event-reader (keypad-test--event-source events))
         (ctx (car keypad--normalized-config)))
    (let ((result (keypad--run-handler (kbd "<SPC>") ctx)))
      (and result (key-description result)))))

(defun keypad-test--context (config)
  (setq keypad-keys config)
  (keypad--normalize-config)
  (car keypad--normalized-config))


;;; pass-through-p

(ert-deftest keypad-tt-pass-through--nil-default ()
  "Default predicates evaluate to nil in normal buffers."
  (let ((keypad-pass-through-predicates '(minibufferp isearch-mode)))
    (should-not (keypad--pass-through-p))))

(ert-deftest keypad-tt-pass-through--lambda-t ()
  "Lambda returning t causes pass-through."
  (let ((keypad-pass-through-predicates (list (lambda () t))))
    (should (keypad--pass-through-p))))

(ert-deftest keypad-tt-pass-through--lambda-nil ()
  "Lambda returning nil does not cause pass-through."
  (let ((keypad-pass-through-predicates (list (lambda () nil))))
    (should-not (keypad--pass-through-p))))

(ert-deftest keypad-tt-pass-through--sym-var ()
  "Symbol-as-variable predicate."
  (defvar keypad-tt-pt-var t)
  (let ((keypad-pass-through-predicates '(keypad-tt-pt-var)))
    (should (keypad--pass-through-p)))
  (setq keypad-tt-pt-var nil))

(ert-deftest keypad-tt-pass-through--sym-fn ()
  "Symbol predicate called as function (not command) -> non-nil."
  (let ((keypad-pass-through-predicates '(keypad-tt-pt-fn)))
    (fset 'keypad-tt-pt-fn (lambda () t))
    (unwind-protect
        (should (keypad--pass-through-p))
      (fmakunbound 'keypad-tt-pt-fn))))

(ert-deftest keypad-tt-pass-through--sym-command-major-mode ()
  "Command symbol matching major-mode is t (mode variable void)."
  (let ((keypad-pass-through-predicates '(keypad-tt-pt-cmd))
        (major-mode 'keypad-tt-pt-cmd))
    (defun keypad-tt-pt-cmd () (interactive) t)
    (unwind-protect
        (should (keypad--pass-through-p))
      (fmakunbound 'keypad-tt-pt-cmd))))

(ert-deftest keypad-tt-pass-through--sym-command-no-match ()
  "Command symbol not matching major-mode is nil."
  (let ((keypad-pass-through-predicates '(keypad-tt-pt-cmd))
        (major-mode 'fundamental-mode))
    (defun keypad-tt-pt-cmd () (interactive) t)
    (unwind-protect
        (should-not (keypad--pass-through-p))
      (fmakunbound 'keypad-tt-pt-cmd))))

(ert-deftest keypad-tt-pass-through--multiple-any-true ()
  "Multiple predicates — any true means pass through."
  (let ((keypad-pass-through-predicates
         (list (lambda () nil) (lambda () t) (lambda () nil))))
    (should (keypad--pass-through-p))))


;;; Normalization

(ert-deftest keypad-tt-normalize--basic ()
  "Basic keyword format normalization."
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-")))))
    (should (equal (keypad-context-prefix ctx) "C-c"))
    (should (equal (keypad-context-modifier ctx) "C-"))
    (should (equal (keypad-context-fallback ctx) "C-"))
    (should (eq (keypad-context-toggle-target ctx) nil))))

(ert-deftest keypad-tt-normalize--modifier-only ()
  "Modifier-only prefix normalization."
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "" :modifier "M-" :fallback nil)))))
    (should (eq (keypad-context-prefix ctx) nil))
    (should (equal (keypad-context-modifier ctx) "M-"))
    (should (eq (keypad-context-fallback ctx) nil))))

(ert-deftest keypad-tt-normalize--dispatch ()
  "Dispatch entries normalization."
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                  :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                             (?e . (:prefix "" :modifier "M-" :fallback nil))))))))
    (should (= (length (keypad-context-dispatch-alist ctx)) 2))
    (let ((d (cdr (assq ?x (keypad-context-dispatch-alist ctx)))))
      (should (equal (keypad-context-prefix d) "C-x"))
      (should (equal (keypad-context-modifier d) "C-")))
    (let ((d (cdr (assq ?e (keypad-context-dispatch-alist ctx)))))
      (should (eq (keypad-context-prefix d) nil))
      (should (equal (keypad-context-modifier d) "M-")))))

(ert-deftest keypad-tt-normalize--toggle-dispatch ()
  ":toggle dispatch entry."
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                  :dispatch ((?d . :toggle)))))))
    (let ((d (cdr (assq ?d (keypad-context-dispatch-alist ctx)))))
      (should (eq (keypad-context-prefix d) nil))
      (should (eq (keypad-context-modifier d) nil))
      (should (equal (keypad-context-toggle-target d) "C-")))))

(ert-deftest keypad-tt-normalize--toggle-inference ()
  "Toggle target inferred from modifier."
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-")))))
    (should (eq (keypad-context-toggle-target ctx) nil)))
  (let* ((ctx (keypad-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-")))))
    (should (equal (keypad-context-toggle-target ctx) "C-"))))


;;; resolve-key

(ert-deftest keypad-tt-resolve--modifier-bound ()
  (let ((keypad--key-lookup-fn
         (lambda (k) (when (string= k "C-c C-f") 'ignore))))
    (let ((r (keypad--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c C-f"))
      (should-not (cdr r)))))

(ert-deftest keypad-tt-resolve--modifier-unbound-fallback-plain ()
  (let ((keypad--key-lookup-fn
         (lambda (k) (when (string= k "C-c f") 'ignore))))
    (let ((r (keypad--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should (cdr r)))))

(ert-deftest keypad-tt-resolve--plain-bound ()
  (let ((keypad--key-lookup-fn
         (lambda (k) (when (string= k "C-c f") 'ignore))))
    (let ((r (keypad--resolve-key "C-c" nil "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should-not (cdr r)))))

(ert-deftest keypad-tt-resolve--plain-unbound-fallback ()
  (let ((keypad--key-lookup-fn
         (lambda (k) (when (string= k "C-c C-f") 'ignore))))
    (let ((r (keypad--resolve-key "C-c" nil "C-" ?f)))
      (should (equal (car r) "C-c C-f"))
      (should (cdr r)))))

(ert-deftest keypad-tt-resolve--nothing-bound ()
  (let ((keypad--key-lookup-fn (lambda (_k) nil)))
    (let ((r (keypad--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should (cdr r)))))


;;; binding-is-prefix-keymap-p

(ert-deftest keypad-tt-prefix--keymap-object ()
  (should (keypad--binding-is-prefix-keymap-p (make-sparse-keymap))))

(ert-deftest keypad-tt-prefix--keymap-symbol ()
  (defvar keypad-tt-map (make-sparse-keymap))
  (should (keypad--binding-is-prefix-keymap-p 'keypad-tt-map)))

(ert-deftest keypad-tt-prefix--command-nil ()
  (should-not (keypad--binding-is-prefix-keymap-p 'ignore)))


;;; Handler: basic resolution

(ert-deftest keypad-tt-run--basic ()
  "SPC f -> C-c C-f"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(?f))
                 "C-c C-f")))

(ert-deftest keypad-tt-run--modifier-fallback ()
  "SPC f (C-c C-f not bound) -> C-c f"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(?f))
                 "C-c f")))

(ert-deftest keypad-tt-run--no-binding-returns-plain ()
  "SPC f (nothing bound) -> C-c f (returned as-is)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '()
                  '(?f))
                 "C-c f")))

(ert-deftest keypad-tt-run--plain-first ()
  "SPC f (modifier=nil, plain bound)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(?f))
                 "C-c f")))

(ert-deftest keypad-tt-run--plain-fallback ()
  "SPC f (modifier=nil, plain unbound, fallback to C-)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(?f))
                 "C-c C-f")))


;;; Handler: dispatch

(ert-deftest keypad-tt-run--dispatch ()
  "SPC x f -> C-x C-f"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x C-f" . ignore) ("C-x" . keypad-tt-cx-map))
                  '(?x ?f))
                 "C-x C-f")))

(ert-deftest keypad-tt-run--dispatch-fallback-plain ()
  "SPC x f (C-x C-f not bound) -> C-x f"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x f" . ignore) ("C-x" . keypad-tt-cx-map))
                  '(?x ?f))
                 "C-x f")))

(ert-deftest keypad-tt-run--dispatch-plain-modifier ()
  "SPC x f (dispatch with modifier=nil) -> C-x f"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier nil :fallback "C-")))))
                  '(("C-x f" . ignore) ("C-x" . keypad-tt-cx-map))
                  '(?x ?f))
                 "C-x f")))


;;; Handler: modifier-prefix dispatch

(ert-deftest keypad-tt-run--modifier-prefix ()
  "SPC e x -> M-x"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("M-x" . ignore))
                  '(?e ?x))
                 "M-x")))

(ert-deftest keypad-tt-run--modifier-prefix-continuation ()
  "SPC x e a -> C-x M-a"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch
                     ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                      (?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("C-x" . keypad-tt-cx-map) ("C-x M-a" . ignore))
                  '(?x ?e ?a))
                 "C-x M-a")))

(ert-deftest keypad-tt-run--modifier-prefix-fallback-no-completions ()
  "SPC x e (no M- completions in C-x map) -> C-x C-e (fallback e883dd3)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch
                     ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                      (?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  ;; C-x map has NO M-* keys — so 'e' should fall back.
                  ;; 'e' with modifier=C- resolves to "C-x C-e"
                  '(("C-x" . keypad-tt-cx-map)
                    ("C-x C-e" . ignore))
                  '(?x ?e))
                 "C-x C-e")))


;;; Handler: toggle

(ert-deftest keypad-tt-run--toggle-off ()
  "SPC SPC f -> C-c f (toggle C- off)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(32 102))
                 "C-c f")))

(ert-deftest keypad-tt-run--toggle-on ()
  "SPC SPC f -> C-c C-f (toggle nil to C-)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(32 102))
                 "C-c C-f")))

(ert-deftest keypad-tt-run--toggle-dispatch ()
  "SPC d f -> C-c f (:toggle dispatch entry)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?d . :toggle))))
                  '(("C-c f" . ignore))
                  '(?d ?f))
                 "C-c f")))

(ert-deftest keypad-tt-run--toggle-in-continuation ()
  "SPC x SPC f -> C-x f (toggle inside continuation)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x" . keypad-tt-cx-map) ("C-x f" . ignore))
                  '(?x 32 ?f))
                 "C-x f")))


;;; Handler: suppress direct dispatch in continuation

(ert-deftest keypad-tt-run--suppress-direct-dispatch ()
  "SPC x x -> C-x C-x (dispatch suppressed, modifier applied)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x" . keypad-tt-cx-map) ("C-x C-x" . ignore))
                  '(?x ?x))
                 "C-x C-x")))


;;; Handler: continuation (prefix keymap traversal)

(ert-deftest keypad-tt-run--continuation ()
  "SPC a b -> C-c a C-b"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c a" . keypad-tt-sub-map) ("C-c a C-b" . ignore))
                  '(?a ?b))
                 "C-c a C-b")))

(ert-deftest keypad-tt-run--continuation-fallback-plain ()
  "SPC a b (C-c a C-b not bound) -> C-c a b"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c a" . keypad-tt-sub-map) ("C-c a b" . ignore))
                  '(?a ?b))
                 "C-c a b")))


;;; dispatch-priority

(ert-deftest keypad-tt-priority--nil ()
  "keypad-dispatch-priority nil → dispatch wins"
  (let ((keypad-dispatch-priority nil))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . keypad-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f ?f))
                   "C-x C-f"))))

(ert-deftest keypad-tt-priority--t ()
  "keypad-dispatch-priority t → command wins"
  (let ((keypad-dispatch-priority t))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . keypad-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f))
                   "C-c C-f"))))

(ert-deftest keypad-tt-priority--primary ()
  "keypad-dispatch-priority :primary → primary command wins"
  (let ((keypad-dispatch-priority :primary))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . keypad-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f))
                   "C-c C-f"))))

(ert-deftest keypad-tt-priority--primary-fallback-dispatch-wins ()
  ":primary: fallback command does NOT win over dispatch"
  (let ((keypad-dispatch-priority :primary))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . keypad-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f ?f))
                   "C-x C-f"))))

(ert-deftest keypad-tt-priority--toggle-command-wins ()
  "keypad-toggle-priority=t, SPC SPC -> execute C-c C-SPC command"
  (let ((keypad-toggle-priority t))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))

(ert-deftest keypad-tt-priority--toggle-fallback-command-wins ()
  "keypad-toggle-priority=t, modifier=nil, SPC SPC -> fallback command"
  (let ((keypad-toggle-priority t))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))

(ert-deftest keypad-tt-priority--toggle-nil-no-command ()
  "keypad-toggle-priority=nil, SPC SPC -> toggle (no command)"
  (let ((keypad-toggle-priority nil))
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c f" . ignore))
                    '(32 102))
                   "C-c f"))))

(ert-deftest keypad-tt-priority--dispatch-nil-toggle-t ()
  "dispatch=nil toggle=t: SPC x dispatch works, SPC SPC command wins"
  (let ((keypad-dispatch-priority nil)
        (keypad-toggle-priority t))
    ;; dispatch wins (nil)
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-x" . ignore) ("C-x" . keypad-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?x ?f))
                   "C-x C-f"))
    ;; toggle command wins (t)
    (should (equal (keypad-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))


;;; empty-p helper

(ert-deftest keypad-tt-empty-p ()
  (should (keypad--empty-p nil))
  (should (keypad--empty-p ""))
  (should-not (keypad--empty-p "C-x"))
  (should-not (keypad--empty-p " ")))

(ert-deftest keypad-tt-run--toggle-in-dispatch-continuation ()
  "SPC h SPC a -> C-h C-a (toggle inside dispatched continuation)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?h . (:prefix "C-h" :modifier nil :fallback "C-")))))
                  '(("C-h" . keypad-tt-cx-map) ("C-h C-a" . ignore))
                  '(?h 32 ?a))
                 "C-h C-a")))

(ert-deftest keypad-tt-run--modifier-prefix-no-echo-prefix ()
  "SPC m x -> M-x (modifier-prefix at top level: no C-c prefix)"
  (should (equal (keypad-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?m . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("M-x" . ignore))
                  '(?m ?x))
                 "M-x")))


;;; self mode

(defun keypad-test--do-run-self (config bindings events key-str)
  "Run handler with CONFIG, mock BINDINGS/EVENTS, KEY-STR as pressed key."
  (setq keypad-keys config)
  (keypad--normalize-config)
  (let* ((keypad--key-lookup-fn (keypad-test--key-lookup bindings))
         (keypad--event-reader (keypad-test--event-source events))
         (ctx (car keypad--normalized-config)))
    (let ((result (keypad--run-handler (kbd key-str) ctx)))
      (and result (key-description result)))))

(ert-deftest keypad-tt-self--basic ()
  ":self t: leader key itself translated via modifier (single char)."
  (should (equal (keypad-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil :self t))
                  '(("C-a" . ignore))
                  '()
                  "a")
                 "C-a")))

(ert-deftest keypad-tt-self--continuation ()
  ":self t: key resolves to prefix, enters continuation, reads next key."
  (should (equal (keypad-test--do-run-self
                  '((:key "x" :prefix nil :modifier "C-" :fallback nil :self t))
                  `(("C-x" . ,keypad-tt-cx-map) ("C-x C-f" . ignore))
                  '(?f)
                  "x")
                 "C-x C-f")))

(ert-deftest keypad-tt-self--no-binding ()
  ":self t: modifier+char not bound, falls back to plain char."
  (should (equal (keypad-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil :self t))
                  '()
                  '()
                  "a")
                 "a")))

(ert-deftest keypad-tt-self--off-default ()
  ":self nil: leader key acts as trigger, reads next key via modifier."
  (should (equal (keypad-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil))
                  '(("C-f" . ignore))
                  '(?f)
                  "a")
                 "C-f")))

(defun keypad-test-run ()
  "Run all leader tests."
  (ert-run-tests-batch-and-exit))

;;; keypad-test.el ends here
