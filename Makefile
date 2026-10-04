# vterm --- a CFFI binding to libvterm.
#
# Needs SBCL, libvterm (brew install libvterm / apt install libvterm-dev) and
# ocicl (https://github.com/ocicl/ocicl) to restore the pinned dependencies in
# ocicl.csv.  The source registry is this tree alone, so the lock file is
# what gets tested.

SBCL ?= sbcl
REGISTRY := '(asdf:initialize-source-registry `(:source-registry (:tree ,(truename "./")) :ignore-inherited-configuration))'

.PHONY: all deps build test clean

all: test

deps:
	ocicl install

build:
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	  --eval '(require :asdf)' --eval $(REGISTRY) \
	  --eval '(asdf:load-system "vterm")' \
	  --eval '(format t "~&BUILD OK~%")'

test:
	$(SBCL) --non-interactive --no-userinit --no-sysinit \
	  --eval '(require :asdf)' --eval $(REGISTRY) \
	  --eval '(asdf:test-system "vterm")'

clean:
	rm -rf ~/.cache/common-lisp/*$(CURDIR)
