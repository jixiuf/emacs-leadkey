# -*- coding:utf-8 -*-

EMACS ?= emacs
ELC := keypad.elc keypad-which-key.elc
ELS := keypad.el keypad-which-key.el

.PHONY: all build test test-all lint byte-compile clean
all: byte-compile lint test

byte-compile: $(ELC)

%.elc: %.el
	$(EMACS) --batch -Q --eval "(setq byte-compile-error-on-warn t)" \
		--eval "(package-initialize)" \
		-f batch-byte-compile $<
test:
	$(EMACS) --batch -Q --eval "(package-initialize)" -L . -L test \
	  -l ert \
	  -l test/keypad-test.el \
	  -f keypad-test-run


lint: byte-compile package-lint checkdoc
package-lint:
	$(EMACS) --batch -Q \
		--eval "(package-initialize)" \
		--eval "(require 'package-lint)" \
		-f package-lint-batch-and-exit \
		keypad.el keypad-which-key.el

checkdoc:
	@for file in $(ELS); do \
		echo "Checking $$file..."; \
		$(EMACS) -Q --batch \
		--eval "(require 'checkdoc)" \
		--eval "(setq checkdoc-sentence-ends-double-space t \
		            checkdoc-proper-noun-list nil \
		            checkdoc-verb-check-experimental-flag nil)" \
		--eval "(let ((ok t)) \
		          (ignore-errors (kill-buffer \"*Warnings*\")) \
		          (let ((inhibit-message t)) \
		            (checkdoc-file \"$$file\")) \
		          (when (get-buffer \"*Warnings*\") \
		            (setq ok nil) \
		            (with-current-buffer \"*Warnings*\" \
		              (message \"%s\" (buffer-string)))) \
		          (unless ok (kill-emacs 1)))" || exit 1; \
	done


