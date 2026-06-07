;;; leadkey-test.el --- Tests for leadkey.el -*- lexical-binding: t; -*-
(require 'ert)
(require 'leadkey)

(defvar leadkey-tt-cx-map (make-sparse-keymap))
(define-key leadkey-tt-cx-map (kbd "C-f") 'ignore)

(defvar leadkey-tt-sub-map (make-sparse-keymap))
(define-key leadkey-tt-sub-map (kbd "C-b") 'ignore)
(define-key leadkey-tt-sub-map (kbd "b") 'ignore)


;;; Helpers

(defun leadkey-test--event-source (events)
  (let ((idx 0))
    (lambda (_)
      (prog1 (nth idx events)
        (setq idx (1+ idx))))))

(defun leadkey-test--key-lookup (bindings)
  (lambda (keystr)
    (cdr (assoc keystr bindings))))

(defun leadkey-test--do-run (config bindings events)
  (setq leadkey-keys config)
  (leadkey--normalize-config)
  (let* ((leadkey--key-lookup-fn (leadkey-test--key-lookup bindings))
         (leadkey--event-reader (leadkey-test--event-source events))
         (ctx (car leadkey--normalized-config)))
    (let ((result (leadkey--run-handler (kbd "<SPC>") ctx)))
      (and result (key-description result)))))

(defun leadkey-test--context (config)
  (setq leadkey-keys config)
  (leadkey--normalize-config)
  (car leadkey--normalized-config))


;;; pass-through-p

(ert-deftest leadkey-tt-pass-through--nil-default ()
  "Default predicates evaluate to nil in normal buffers."
  (let ((leadkey-pass-through-predicates '(minibufferp isearch-mode)))
    (should-not (leadkey--pass-through-p))))

(ert-deftest leadkey-tt-pass-through--lambda-t ()
  "Lambda returning t causes pass-through."
  (let ((leadkey-pass-through-predicates (list (lambda () t))))
    (should (leadkey--pass-through-p))))

(ert-deftest leadkey-tt-pass-through--lambda-nil ()
  "Lambda returning nil does not cause pass-through."
  (let ((leadkey-pass-through-predicates (list (lambda () nil))))
    (should-not (leadkey--pass-through-p))))

(ert-deftest leadkey-tt-pass-through--sym-var ()
  "Symbol-as-variable predicate."
  (defvar leadkey-tt-pt-var t)
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-var)))
    (should (leadkey--pass-through-p)))
  (setq leadkey-tt-pt-var nil))

(ert-deftest leadkey-tt-pass-through--sym-fn ()
  "Symbol predicate called as function (not command) -> non-nil."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-fn)))
    (fset 'leadkey-tt-pt-fn (lambda () t))
    (unwind-protect
        (should (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-fn))))

(ert-deftest leadkey-tt-pass-through--sym-command-major-mode ()
  "Command symbol matching major-mode is t (mode variable void)."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-cmd))
        (major-mode 'leadkey-tt-pt-cmd))
    (defun leadkey-tt-pt-cmd () (interactive) t)
    (unwind-protect
        (should (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-cmd))))

(ert-deftest leadkey-tt-pass-through--sym-command-no-match ()
  "Command symbol not matching major-mode is nil."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-cmd))
        (major-mode 'fundamental-mode))
    (defun leadkey-tt-pt-cmd () (interactive) t)
    (unwind-protect
        (should-not (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-cmd))))

(ert-deftest leadkey-tt-pass-through--multiple-any-true ()
  "Multiple predicates — any true means pass through."
  (let ((leadkey-pass-through-predicates
         (list (lambda () nil) (lambda () t) (lambda () nil))))
    (should (leadkey--pass-through-p))))

;;; -mode suffix predicates

(ert-deftest leadkey-tt-pass-through--mode-suffix-major ()
  "Symbol ending with -mode matching major-mode returns t."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-major-mode))
        (major-mode 'leadkey-tt-pt-major-mode))
    (defun leadkey-tt-pt-major-mode () (interactive) t)
    (unwind-protect
        (should (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-major-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-major-wins-over-nil-var ()
  "Major-mode match takes priority over bound-and-true-p, even when var is nil."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-majvar-mode))
        (major-mode 'leadkey-tt-pt-majvar-mode))
    (defvar leadkey-tt-pt-majvar-mode nil)
    (defun leadkey-tt-pt-majvar-mode () (interactive) t)
    (unwind-protect
        (should (leadkey--pass-through-p))
      (makunbound 'leadkey-tt-pt-majvar-mode)
      (fmakunbound 'leadkey-tt-pt-majvar-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-minor-active ()
  "Symbol ending with -mode: minor-mode enabled via bound-and-true-p."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-minor-mode))
        (major-mode 'fundamental-mode))
    (defvar leadkey-tt-pt-minor-mode t)
    (unwind-protect
        (should (leadkey--pass-through-p))
      (makunbound 'leadkey-tt-pt-minor-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-minor-inactive ()
  "Symbol ending with -mode: minor-mode disabled (bound nil)."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-minor-mode))
        (major-mode 'fundamental-mode))
    (defvar leadkey-tt-pt-minor-mode nil)
    (unwind-protect
        (should-not (leadkey--pass-through-p))
      (makunbound 'leadkey-tt-pt-minor-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-unbound-no-major ()
  "Symbol ending with -mode, unbound, not matching major-mode -> nil."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-nobound-mode))
        (major-mode 'fundamental-mode))
    (should-not (leadkey--pass-through-p))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-command-not-called ()
  "Symbol ending with -mode that is a command: not funcall'd even if fbound."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-cmd-mode))
        (major-mode 'fundamental-mode))
    (defun leadkey-tt-pt-cmd-mode () (interactive) t)
    (unwind-protect
        (should-not (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-cmd-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-noncommand-not-called ()
  "Symbol ending with -mode, non-command, fbound: NOT funcall'd."
  (let ((leadkey-pass-through-predicates '(leadkey-tt-pt-fnmode-mode))
        (major-mode 'fundamental-mode))
    (defun leadkey-tt-pt-fnmode-mode () t)
    (unwind-protect
        (should-not (leadkey--pass-through-p))
      (fmakunbound 'leadkey-tt-pt-fnmode-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-combined-active ()
  "Combined predicates: -mode active plus nil lambda -> pass-through."
  (let ((leadkey-pass-through-predicates
         (list 'leadkey-tt-pt-combo-mode (lambda () nil)))
        (major-mode 'fundamental-mode))
    (defvar leadkey-tt-pt-combo-mode t)
    (unwind-protect
        (should (leadkey--pass-through-p))
      (makunbound 'leadkey-tt-pt-combo-mode))))

(ert-deftest leadkey-tt-pass-through--mode-suffix-combined-all-nil ()
  "Combined predicates: all nil -> no pass-through."
  (let ((leadkey-pass-through-predicates
         (list 'leadkey-tt-pt-nil-mode (lambda () nil)))
        (major-mode 'fundamental-mode))
    (defvar leadkey-tt-pt-nil-mode nil)
    (unwind-protect
        (should-not (leadkey--pass-through-p))
      (makunbound 'leadkey-tt-pt-nil-mode))))

(ert-deftest leadkey-tt-pass-through--predicates-override ()
  "Explicit PREDICATES arg overrides `leadkey-pass-through-predicates'."
  (let ((leadkey-pass-through-predicates '(minibufferp))
        (major-mode 'fundamental-mode))
    (should (leadkey--pass-through-p (list (lambda () t)))))
  (let ((leadkey-pass-through-predicates (list (lambda () t)))
        (major-mode 'fundamental-mode))
    (should-not (leadkey--pass-through-p (list (lambda () nil))))))


;;; Normalization

(ert-deftest leadkey-tt-normalize--basic ()
  "Basic keyword format normalization."
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-")))))
    (should (equal (leadkey-context-prefix ctx) "C-c"))
    (should (equal (leadkey-context-modifier ctx) "C-"))
    (should (equal (leadkey-context-fallback ctx) "C-"))
    (should (eq (leadkey-context-toggle-target ctx) nil))))

(ert-deftest leadkey-tt-normalize--modifier-only ()
  "Modifier-only prefix normalization."
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "" :modifier "M-" :fallback nil)))))
    (should (eq (leadkey-context-prefix ctx) nil))
    (should (equal (leadkey-context-modifier ctx) "M-"))
    (should (eq (leadkey-context-fallback ctx) nil))))

(ert-deftest leadkey-tt-normalize--dispatch ()
  "Dispatch entries normalization."
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                  :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                             (?e . (:prefix "" :modifier "M-" :fallback nil))))))))
    (should (= (length (leadkey-context-dispatch-alist ctx)) 2))
    (let ((d (cdr (assq ?x (leadkey-context-dispatch-alist ctx)))))
      (should (equal (leadkey-context-prefix d) "C-x"))
      (should (equal (leadkey-context-modifier d) "C-")))
    (let ((d (cdr (assq ?e (leadkey-context-dispatch-alist ctx)))))
      (should (eq (leadkey-context-prefix d) nil))
      (should (equal (leadkey-context-modifier d) "M-")))))

(ert-deftest leadkey-tt-normalize--toggle-dispatch ()
  ":toggle dispatch entry."
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                  :dispatch ((?d . :toggle)))))))
    (let ((d (cdr (assq ?d (leadkey-context-dispatch-alist ctx)))))
      (should (eq (leadkey-context-prefix d) nil))
      (should (eq (leadkey-context-modifier d) nil))
      (should (equal (leadkey-context-toggle-target d) "C-")))))

(ert-deftest leadkey-tt-normalize--toggle-inference ()
  "Toggle target inferred from modifier."
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-")))))
    (should (eq (leadkey-context-toggle-target ctx) nil)))
  (let* ((ctx (leadkey-test--context
               '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-")))))
    (should (equal (leadkey-context-toggle-target ctx) "C-"))))


;;; resolve-key

(ert-deftest leadkey-tt-resolve--modifier-bound ()
  (let ((leadkey--key-lookup-fn
         (lambda (k) (when (string= k "C-c C-f") 'ignore))))
    (let ((r (leadkey--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c C-f"))
      (should-not (cdr r)))))

(ert-deftest leadkey-tt-resolve--modifier-unbound-fallback-plain ()
  (let ((leadkey--key-lookup-fn
         (lambda (k) (when (string= k "C-c f") 'ignore))))
    (let ((r (leadkey--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should (cdr r)))))

(ert-deftest leadkey-tt-resolve--plain-bound ()
  (let ((leadkey--key-lookup-fn
         (lambda (k) (when (string= k "C-c f") 'ignore))))
    (let ((r (leadkey--resolve-key "C-c" nil "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should-not (cdr r)))))

(ert-deftest leadkey-tt-resolve--plain-unbound-fallback ()
  (let ((leadkey--key-lookup-fn
         (lambda (k) (when (string= k "C-c C-f") 'ignore))))
    (let ((r (leadkey--resolve-key "C-c" nil "C-" ?f)))
      (should (equal (car r) "C-c C-f"))
      (should (cdr r)))))

(ert-deftest leadkey-tt-resolve--nothing-bound ()
  (let ((leadkey--key-lookup-fn (lambda (_k) nil)))
    (let ((r (leadkey--resolve-key "C-c" "C-" "C-" ?f)))
      (should (equal (car r) "C-c f"))
      (should (cdr r)))))


;;; binding-is-prefix-keymap-p

(ert-deftest leadkey-tt-prefix--keymap-object ()
  (should (leadkey--binding-is-prefix-keymap-p (make-sparse-keymap))))

(ert-deftest leadkey-tt-prefix--keymap-symbol ()
  (defvar leadkey-tt-map (make-sparse-keymap))
  (should (leadkey--binding-is-prefix-keymap-p 'leadkey-tt-map)))

(ert-deftest leadkey-tt-prefix--command-nil ()
  (should-not (leadkey--binding-is-prefix-keymap-p 'ignore)))


;;; Handler: basic resolution

(ert-deftest leadkey-tt-run--basic ()
  "SPC f -> C-c C-f"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(?f))
                 "C-c C-f")))

(ert-deftest leadkey-tt-run--modifier-fallback ()
  "SPC f (C-c C-f not bound) -> C-c f"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(?f))
                 "C-c f")))

(ert-deftest leadkey-tt-run--no-binding-returns-plain ()
  "SPC f (nothing bound) -> C-c f (returned as-is)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '()
                  '(?f))
                 "C-c f")))

(ert-deftest leadkey-tt-run--plain-first ()
  "SPC f (modifier=nil, plain bound)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(?f))
                 "C-c f")))

(ert-deftest leadkey-tt-run--plain-fallback ()
  "SPC f (modifier=nil, plain unbound, fallback to C-)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(?f))
                 "C-c C-f")))


;;; Handler: dispatch

(ert-deftest leadkey-tt-run--dispatch ()
  "SPC x f -> C-x C-f"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x C-f" . ignore) ("C-x" . leadkey-tt-cx-map))
                  '(?x ?f))
                 "C-x C-f")))

(ert-deftest leadkey-tt-run--dispatch-fallback-plain ()
  "SPC x f (C-x C-f not bound) -> C-x f"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x f" . ignore) ("C-x" . leadkey-tt-cx-map))
                  '(?x ?f))
                 "C-x f")))

(ert-deftest leadkey-tt-run--dispatch-plain-modifier ()
  "SPC x f (dispatch with modifier=nil) -> C-x f"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier nil :fallback "C-")))))
                  '(("C-x f" . ignore) ("C-x" . leadkey-tt-cx-map))
                  '(?x ?f))
                 "C-x f")))


;;; Handler: modifier-prefix dispatch

(ert-deftest leadkey-tt-run--modifier-prefix ()
  "SPC e x -> M-x"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("M-x" . ignore))
                  '(?e ?x))
                 "M-x")))

(ert-deftest leadkey-tt-run--modifier-prefix-continuation ()
  "SPC x e a -> C-x M-a"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch
                     ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                      (?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("C-x" . leadkey-tt-cx-map) ("C-x M-a" . ignore))
                  '(?x ?e ?a))
                 "C-x M-a")))

(ert-deftest leadkey-tt-run--modifier-prefix-fallback-no-completions ()
  "SPC x e (no M- completions in C-x map) -> C-x C-e (fallback e883dd3)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch
                     ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
                      (?e . (:prefix "" :modifier "M-" :fallback nil)))))
                  ;; C-x map has NO M-* keys — so 'e' should fall back.
                  ;; 'e' with modifier=C- resolves to "C-x C-e"
                  '(("C-x" . leadkey-tt-cx-map)
                    ("C-x C-e" . ignore))
                  '(?x ?e))
                 "C-x C-e")))


;;; Handler: toggle

(ert-deftest leadkey-tt-run--toggle-off ()
  "SPC SPC f -> C-c f (toggle C- off)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c f" . ignore))
                  '(32 102))
                 "C-c f")))

(ert-deftest leadkey-tt-run--toggle-on ()
  "SPC SPC f -> C-c C-f (toggle nil to C-)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                  '(("C-c C-f" . ignore))
                  '(32 102))
                 "C-c C-f")))

(ert-deftest leadkey-tt-run--toggle-dispatch ()
  "SPC d f -> C-c f (:toggle dispatch entry)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?d . :toggle))))
                  '(("C-c f" . ignore))
                  '(?d ?f))
                 "C-c f")))

(ert-deftest leadkey-tt-run--toggle-in-continuation ()
  "SPC x SPC f -> C-x f (toggle inside continuation)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x" . leadkey-tt-cx-map) ("C-x f" . ignore))
                  '(?x 32 ?f))
                 "C-x f")))


;;; Handler: suppress direct dispatch in continuation

(ert-deftest leadkey-tt-run--suppress-direct-dispatch ()
  "SPC x x -> C-x C-x (dispatch suppressed, modifier applied)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                  '(("C-x" . leadkey-tt-cx-map) ("C-x C-x" . ignore))
                  '(?x ?x))
                 "C-x C-x")))


;;; Handler: continuation (prefix keymap traversal)

(ert-deftest leadkey-tt-run--continuation ()
  "SPC a b -> C-c a C-b"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c a" . leadkey-tt-sub-map) ("C-c a C-b" . ignore))
                  '(?a ?b))
                 "C-c a C-b")))

(ert-deftest leadkey-tt-run--continuation-fallback-plain ()
  "SPC a b (C-c a C-b not bound) -> C-c a b"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                  '(("C-c a" . leadkey-tt-sub-map) ("C-c a b" . ignore))
                  '(?a ?b))
                 "C-c a b")))


;;; dispatch-priority

(ert-deftest leadkey-tt-priority--nil ()
  "leadkey-dispatch-priority nil → dispatch wins"
  (let ((leadkey-dispatch-priority nil))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . leadkey-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f ?f))
                   "C-x C-f"))))

(ert-deftest leadkey-tt-priority--t ()
  "leadkey-dispatch-priority t → command wins"
  (let ((leadkey-dispatch-priority t))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . leadkey-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f))
                   "C-c C-f"))))

(ert-deftest leadkey-tt-priority--primary ()
  "leadkey-dispatch-priority :primary → primary command wins"
  (let ((leadkey-dispatch-priority :primary))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . leadkey-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f))
                   "C-c C-f"))))

(ert-deftest leadkey-tt-priority--primary-fallback-dispatch-wins ()
  ":primary: fallback command does NOT win over dispatch"
  (let ((leadkey-dispatch-priority :primary))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"
                       :dispatch ((?f . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-f" . ignore) ("C-x" . leadkey-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?f ?f))
                   "C-x C-f"))))

(ert-deftest leadkey-tt-priority--toggle-command-wins ()
  "leadkey-toggle-priority=t, SPC SPC -> execute C-c C-SPC command"
  (let ((leadkey-toggle-priority t))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))

(ert-deftest leadkey-tt-priority--toggle-fallback-command-wins ()
  "leadkey-toggle-priority=t, modifier=nil, SPC SPC -> fallback command"
  (let ((leadkey-toggle-priority t))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier nil :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))

(ert-deftest leadkey-tt-priority--toggle-nil-no-command ()
  "leadkey-toggle-priority=nil, SPC SPC -> toggle (no command)"
  (let ((leadkey-toggle-priority nil))
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c f" . ignore))
                    '(32 102))
                   "C-c f"))))

(ert-deftest leadkey-tt-priority--dispatch-nil-toggle-t ()
  "dispatch=nil toggle=t: SPC x dispatch works, SPC SPC command wins"
  (let ((leadkey-dispatch-priority nil)
        (leadkey-toggle-priority t))
    ;; dispatch wins (nil)
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                       :dispatch ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-")))))
                    '(("C-c C-x" . ignore) ("C-x" . leadkey-tt-cx-map)
                      ("C-x C-f" . ignore))
                    '(?x ?f))
                   "C-x C-f"))
    ;; toggle command wins (t)
    (should (equal (leadkey-test--do-run
                    '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"))
                    '(("C-c C-SPC" . ignore))
                    '(32))
                   "C-c C-SPC"))))


;;; empty-p helper

(ert-deftest leadkey-tt-empty-p ()
  (should (leadkey--empty-p nil))
  (should (leadkey--empty-p ""))
  (should-not (leadkey--empty-p "C-x"))
  (should-not (leadkey--empty-p " ")))

(ert-deftest leadkey-tt-run--toggle-in-dispatch-continuation ()
  "SPC h SPC a -> C-h C-a (toggle inside dispatched continuation)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?h . (:prefix "C-h" :modifier nil :fallback "C-")))))
                  '(("C-h" . leadkey-tt-cx-map) ("C-h C-a" . ignore))
                  '(?h 32 ?a))
                 "C-h C-a")))

(ert-deftest leadkey-tt-run--modifier-prefix-no-echo-prefix ()
  "SPC m x -> M-x (modifier-prefix at top level: no C-c prefix)"
  (should (equal (leadkey-test--do-run
                  '((:key "<SPC>" :prefix "C-c" :modifier "C-" :fallback "C-"
                     :dispatch ((?m . (:prefix "" :modifier "M-" :fallback nil)))))
                  '(("M-x" . ignore))
                  '(?m ?x))
                 "M-x")))


;;; self mode

(defun leadkey-test--do-run-self (config bindings events key-str)
  "Run handler with CONFIG, mock BINDINGS/EVENTS, KEY-STR as pressed key."
  (setq leadkey-keys config)
  (leadkey--normalize-config)
  (let* ((leadkey--key-lookup-fn (leadkey-test--key-lookup bindings))
         (leadkey--event-reader (leadkey-test--event-source events))
         (ctx (car leadkey--normalized-config)))
    (let ((result (leadkey--run-handler (kbd key-str) ctx)))
      (and result (key-description result)))))

(ert-deftest leadkey-tt-self--basic ()
  ":self t: leader key itself translated via modifier (single char)."
  (should (equal (leadkey-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil :self t))
                  '(("C-a" . ignore))
                  '()
                  "a")
                 "C-a")))

(ert-deftest leadkey-tt-self--continuation ()
  ":self t: key resolves to prefix, enters continuation, reads next key."
  (should (equal (leadkey-test--do-run-self
                  '((:key "x" :prefix nil :modifier "C-" :fallback nil :self t))
                  `(("C-x" . ,leadkey-tt-cx-map) ("C-x C-f" . ignore))
                  '(?f)
                  "x")
                 "C-x C-f")))

(ert-deftest leadkey-tt-self--no-binding ()
  ":self t: modifier+char not bound, falls back to plain char."
  (should (equal (leadkey-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil :self t))
                  '()
                  '()
                  "a")
                 "a")))

(ert-deftest leadkey-tt-self--off-default ()
  ":self nil: leader key acts as trigger, reads next key via modifier."
  (should (equal (leadkey-test--do-run-self
                  '((:key "a" :prefix nil :modifier "C-" :fallback nil))
                  '(("C-f" . ignore))
                  '(?f)
                  "a")
                 "C-f")))

(defun leadkey-test-run ()
  "Run all leader tests."
  (ert-run-tests-batch-and-exit))

;;; leadkey-test.el ends here
