# leadkey.el

A modal leader-key package for Emacs.  It intercepts one or more "leader keys"
via `key-translation-map` and translates subsequent keystrokes into standard
Emacs key sequences, so you can type `SPC f` instead of `C-c C-f`.

Unlike most leader-key packages that bind commands under custom keymaps,
leadkey translates keystrokes *before* they reach any keymap.  This means all
your existing Emacs bindings work automatically — no manual rebinding needed.
## Quick Start

```elisp
(require 'leadkey)
(require 'leadkey-which-key)  ; optional which-key integration
(leadkey-mode 1)
```

## Configuration

`leadkey-keys` is a list of plists.  Each entry describes one leader key:

| Keyword | Required | Default | Description |
|---------|----------|---------|-------------|
| `:key` | yes | — | Leader key string (`"<SPC>"`, `","`) |
| `:prefix` | yes | — | Target prefix string (`"C-c"`, `"M-s"`, nil for modifier-only) |
| `:modifier` | no | inferred | Default modifier (`"C-"`, `"M-"`, nil). Empty string = nil |
| `:fallback` | no | inferred | Fallback modifier. nil = plain only |
| `:toggle` | no | inferred | Toggle target modifier (see toggle section) |
| `:dispatch` | no | nil | Alist `(CHAR . PLIST)` or `(CHAR . :toggle)` |
| `:self` | no | nil | t = leader key itself is first char of sequence (see god-mode section) |
| `:pass-through-predicates` | no | nil | Per-key pass-through predicates; nil = use global |

### Default Inference

- **`:fallback`** defaults to `:modifier` (regular prefix) or nil (modifier-only prefix)
- **`:toggle`** defaults to fallback if fallback differs from modifier, else nil (flip on/off) or `"C-"` (modifier=nil)

### Per-Key Pass-Through

Each leader key can override the global `leadkey-pass-through-predicates`:

```elisp
;; , passes through in vc-dir-mode, otherwise acts as C-M- leader
(:key "," :prefix nil :modifier "C-M-" :fallback nil
 :pass-through-predicates (vc-dir-mode))
```

## Dispatch Entries

Dispatch entries carry the same keys as a top-level leader entry (except `:key`).

| Type | Config | Behavior |
|------|--------|----------|
| Prefix switch | `(?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))` | SPC x → enter C-x prefix |
| Plain modifier | `(?h . (:prefix "C-h" :modifier nil :fallback "C-"))` | SPC h k → C-h k (plain first) |
| Modifier-prefix | `(?m . (:prefix nil :modifier "M-" :fallback nil))` | SPC m x → M-x |
| Toggle | `(?d . :toggle)` | SPC d → toggle modifier |

Modifier-prefix dispatches read a second key and translate it with the modifier
prepended.  In continuation, if no completions exist under the current prefix
keymap, they fall back to plain key resolution.

## Key Resolution Logic

For each subsequent keystroke after the leader key:

- **Modifier non-nil**: try `MODIFIER+char` → fall back to plain `char`
- **Modifier nil**: try plain `char` → fall back to `FALLBACK+char`

When nothing is bound, the plain key is returned as-is.

## Modifier Toggle

Pressing the leader key itself (SPC SPC) or a `:toggle` dispatch entry toggles
the current modifier between its value and the `:toggle` target.

Each context has an independent toggle target, inferred: if fallback differs
from modifier, toggle to fallback; if equal, flip on/off.

## Continuation

When a key sequence resolves to a prefix keymap, the handler enters
**continuation** and keeps reading keys until a command is found.

In continuation:
- **Toggle** and **modifier-prefix** dispatches still apply
- **Direct prefix-switch** dispatches are suppressed
- Per-context `:dispatch` defines local dispatches (modifier-prefix/toggle only)

```elisp
;; Define M- and C- modifier-prefix dispatches for C-x continuation
(?x . (:prefix "C-x" :modifier "C-" :fallback "C-"
       :dispatch ((?m . (:prefix nil :modifier "M-" :fallback nil))
                  (?c . (:prefix nil :modifier "C-" :fallback "C-")))))
;; SPC x m a → C-x M-a  (local M- dispatch)
;; SPC x c f → C-x C-f  (local C- dispatch)
```

## Priority System

| Variable | Default | Controls |
|----------|---------|----------|
| `leadkey-dispatch-priority` | nil | Dispatch vs. bound-command |
| `leadkey-toggle-priority` | nil | Toggle vs. bound-command |

Values for both:

| Value | Behavior |
|-------|----------|
| `nil` | Feature (dispatch/toggle) always wins |
| `t` | Bound command always wins (primary + fallback) |
| `:primary` | Primary command wins; fallback loses to feature |

```elisp
(setq leadkey-dispatch-priority nil)  ; dispatch always wins
(setq leadkey-toggle-priority t)      ; toggle checks bound commands
;; → SPC x → dispatch to C-x (dispatch wins)
;; → SPC SPC → C-c C-SPC if bound, else toggle
```

## Pass-Through Predicates

`leadkey-pass-through-predicates` controls when leader keys act as literal
characters.  Each element is:

- A **function**: called with no args, pass-through if non-nil
- A **symbol**: checked in order: variable value → matches `major-mode`
  → non-command function.  Mode symbols work even if their variable is void.

```elisp
(setq leadkey-pass-through-predicates '(minibufferp isearch-mode))
```

## Which-Key Integration

```elisp
(require 'leadkey-which-key)
```

Automatically enables which-key popup during leader sequences, including
modifier-prefix contexts.  Respects `which-key-idle-delay`, supports C-h n/p.

| Custom variable | Default | Description |
|-----------------|---------|-------------|
| `leadkey-which-key-modifier-max-bindings` | 150 | Max bindings in modifier-prefix popup (nil = unlimited) |

## Commands / Variables

| Command | Description |
|---------|-------------|
| `leadkey-mode` | Global minor mode |

| Variable | Default | Description |
|----------|---------|-------------|
| `leadkey-keys` | nil | Leader key configurations |
| `leadkey-pass-through-predicates` | `(minibufferp isearch-mode)` | Global pass-through predicates |
| `leadkey-dispatch-priority` | nil | Dispatch vs. command priority |
| `leadkey-toggle-priority` | nil | Toggle vs. command priority |

## Full Configuration Demo

```elisp
(require 'leadkey)
(require 'leadkey-which-key)

(add-to-list 'leadkey-pass-through-predicates
             (lambda () (eq helixel--current-state 'insert)))

(setq leadkey-keys
  '((:key "<SPC>" :prefix "C-c" :modifier "" :fallback "C-"
     :dispatch
     ((?x . (:prefix "C-x" :modifier "C-" :fallback "C-"))
      (?h . (:prefix "C-h" :modifier nil  :fallback "C-"))
      (?s . (:prefix "M-s" :modifier nil  :fallback "M-"))
      (?g . (:prefix "M-g" :modifier nil  :fallback "M-"))
      (?m . (:prefix nil  :modifier "M-" :fallback nil))))
    (:key "," :prefix nil :modifier "M-" :fallback nil)
    (:key "." :prefix nil :modifier "C-M-" :fallback nil
     :pass-through-predicates (vc-dir-mode))))

(leadkey-mode 1)
```

**Explanations:**

| Key | Behavior |
|-----|----------|
| `SPC f` | `C-c f` — modifier="" (empty string normalized to nil, tried plain `C-c f` first, fallback to `C-c C-f` since bound) |
| `SPC SPC f` | `C-c C-f` — toggle modifier on (from nil → `C-`), then `C-c f` (plain) |
| `SPC x f` | `C-x C-f` — dispatch `?x` to prefix `C-x`, modifier=C- |
| `SPC h k` | `C-h k` — dispatch `?h` to prefix `C-h`, modifier=nil (plain first) |
| `SPC s f` | `M-s f` — dispatch `?s` to prefix `M-s`, modifier=nil, fallback=M-. Auto-added M- since plain `f` has no binding |
| `SPC s SPC f` | `M-s M-f` — toggle inside M-s continuation (nil → M-), then `M-s M-f` |
| `SPC s m a` | `M-s M-a` — modifier-prefix `?m` in M-s continuation, read second key |
| `SPC g g` | `M-g M-g` — dispatch `?g` to prefix `M-g`, modifier=nil, fallback=M- |
| `SPC m x` | `M-x` — modifier-prefix `?m` (global M-), read second key |
| `, f` | `M-f` — `,` is leader with modifier=M- |
| `. a` | `C-M-a` — `.` is leader with modifier=C-M- |
| `.` in vc-dir | `.` — per-key pass-through to literal `.` in vc-dir buffers |

## Experimental: god-mode Alternative

> **Experimental** — the `:self` keyword is new and subject to change.

By setting `:self t` on a-z leader keys, leadkey can emulate
[god-mode](https://github.com/emacsorphanage/god-mode) — no leader key,
every letter is directly translated to its Ctrl equivalent.
Toggle on/off via `leadkey-mode`.

```elisp
(require 'leadkey)

(setq leadkey-keys
      ;; a-z (except x/c/h/g/G) :self t — key itself is first char
      (cl-loop for c from ?a to ?z
               unless (memq c '(?x ?c ?h ?g ?G))
               collect `(:key ,(char-to-string c)
                         :prefix nil :modifier "C-" :fallback nil
                         :self t)))

(nconc leadkey-keys
       `((:key "x" :prefix "C-x" :modifier "C-"   :fallback "C-")
         (:key "c" :prefix "C-c" :modifier nil    :fallback "C-")
         (:key "h" :prefix "C-h" :modifier nil    :fallback "C-")
         (:key "g" :prefix nil   :modifier "M-"   :fallback nil)
         (:key "G" :prefix nil   :modifier "C-M-" :fallback nil)))

(global-set-key (kbd "C-z") #'leadkey-mode)

(leadkey-mode 1)
```

| Keys | Result | Mechanism |
|------|--------|-----------|
| `x f` | `C-x C-f` | prefix leader |
| `c f` | `C-c f` | prefix leader |
| `h k` | `C-h k` | prefix leader, plain-first |
| `a`–`z` (*except above*) | `C-<letter>` | `:self t`, key itself translated |
| `g f` | `M-f` | modifier-prefix leader |
| `G f` | `C-M-f` | modifier-prefix leader |

Use `C-z` to toggle `leadkey-mode` on/off.

## Comparison with similar packages

| | **leadkey** | **evil-leadkey** | **god-mode** |
|---|---|---|---|
| **Mechanism** | `key-translation-map` translation | custom keymap + overlay parsing | minor-mode, overrides `self-insert` |
| **Activation** | press leader key (SPC) | press trigger (SPC) in evil normal/visual/emacs states | ESC toggles, buffer-level switch |
| **Modifier model** | per-leader config: prefix + modifier + fallback | fixed rules: first key `x`→C-x, `c`→C-c, `h`→C-h | all keys default to Ctrl; SPC→literal; `g`→M; `G`→C-M |
| **Prefix switching** | dispatch alist maps any char to any prefix | `x`/`c`/`h` fixed to C-x/C-c/C-h | none — global Ctrl-only |
| **Smart fallback** | Mod+char → unbound? fall back to plain char | Ctrl unbound → try literal | no fallback |
| **Continuation** | follow prefix keymap, keep reading keys | Ctrl-persistent concept | always Ctrl |
| **Multi-leader** | yes — multiple leader keys, each with own prefix | single trigger | single global mode |
| **Toggle** | press leader key itself to toggle modifier | none | ESC exits god-mode |
| **Pass-through** | predicate-based per-key pass-through | exit leadkey to restore | exit god-mode to restore |
| **Dependencies** | none | evil (can be used standalone) | none |
| **which-key** | optional module `leadkey-which-key` | deep integration | not applicable |
| **Prefix args** | not supported | `u`→C-u, `-`→M--, digits | `u`→C-u, digits |
| **Learning curve** | moderate (prefix/modifier/fallback/toggle) | low (fixed rules, intuitive) | low (all letters gain Ctrl) |
| **Maturity** | 0.2.0 | 36 commits | 955 stars, established |

