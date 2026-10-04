;;;; vterm.asd --- a CFFI binding to libvterm, the terminal-emulation library.

(asdf:defsystem "vterm"
  :description "CFFI binding to libvterm (terminal emulation)."
  :author "Matthew Kennedy"
  :license "MIT"
  :version "0.1.0"
  :depends-on ("cffi")
  :components ((:module "src"
                :serial t
                :components ((:file "package")
                             (:file "vterm"))))
  :in-order-to ((test-op (test-op "vterm/test"))))

(asdf:defsystem "vterm/test"
  :description "Headless tests for the libvterm binding (no terminal needed)."
  :depends-on ("vterm")
  :components ((:module "tests"
                :components ((:file "tests"))))
  :perform (test-op (o c)
             (unless (uiop:symbol-call :vterm-tests '#:run)
               (error "vterm tests failed"))))
