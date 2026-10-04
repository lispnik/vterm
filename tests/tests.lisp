;;;; tests.lisp --- headless tests for the libvterm binding.
;;;;
;;;; No test framework, so the system needs nothing beyond cffi: each test is a
;;;; function of no arguments that signals on failure, and RUN reports a tally
;;;; and returns true iff everything passed.

(defpackage #:vterm-tests
  (:use #:cl #:vterm)
  (:export #:run))

(in-package #:vterm-tests)

(defvar *tests* '())

(defmacro deftest (name &body body)
  `(progn (defun ,name () ,@body)
          (pushnew ',name *tests*)))

(defun check (form-value description)
  (unless form-value (error "check failed: ~A" description)))

(defmacro with-vterm ((vt screen &key (rows 24) (cols 80)) &body body)
  `(progn
     (ensure-libvterm)
     (let ((,vt (vterm-new ,rows ,cols)))
       (unwind-protect
            (let ((,screen (vterm-obtain-screen ,vt)))
              (vterm-set-utf8 ,vt 1)
              (vterm-screen-reset ,screen 1)
              ,@body)
         (vterm-free ,vt)))))

(defun feed (vt string)
  "Push STRING's UTF-8 bytes into VT as if the child wrote them."
  (cffi:with-foreign-string ((buf n) string :encoding :utf-8 :null-terminated-p nil)
    (vterm-input-write vt buf n)))

(defun cell-code (screen cell row col)
  (vterm-screen-get-cell screen row col cell)
  (cffi:mem-aref (cffi:foreign-slot-pointer cell '(:struct vterm-screen-cell) 'chars)
                 :uint32 0))

(defun row-text (screen row ncols)
  (cffi:with-foreign-object (cell '(:struct vterm-screen-cell))
    (coerce (loop for c below ncols
                  for code = (cell-code screen cell row c)
                  collect (if (or (zerop code) (>= code #x110000)) #\Space (code-char code)))
            'string)))

;;; --- tests ------------------------------------------------------------------

(deftest struct-sizes
  ;; sizeof(VTermScreenCell) on every libvterm 0.3 ABI we support.
  (check (= +cell-size+ 40) (format nil "VTermScreenCell is 40 bytes, got ~D" +cell-size+))
  (check (= (cffi:foreign-type-size '(:struct vterm-pos)) 8) "VTermPos is 8 bytes"))

(deftest pack-pos-layout
  (check (= (pack-pos 3 5) (logior 3 (ash 5 32))) "row low, col high")
  (check (= (pack-pos 0 0) 0) "origin packs to zero"))

(deftest write-and-read-grid
  (with-vterm (vt screen)
    (feed vt "hello")
    (check (string= (row-text screen 0 5) "hello") "text lands on row 0")))

(deftest cursor-position
  (with-vterm (vt screen)
    (feed vt (format nil "ab~C[3;7H" #\Esc))  ; CUP row 3 col 7 (1-based)
    (cffi:with-foreign-object (pos '(:struct vterm-pos))
      (vterm-state-get-cursorpos (vterm-obtain-state vt) pos)
      (check (and (= (vterm-pos-row pos) 2) (= (vterm-pos-col pos) 6))
             "cursor at (2,6)"))))

(deftest wide-glyph
  ;; A double-width glyph occupies two cells; the right half reads 0xFFFFFFFF.
  (with-vterm (vt screen)
    (feed vt (string (code-char #x4E2D)))  ; 中
    (cffi:with-foreign-object (cell '(:struct vterm-screen-cell))
      (check (= (cell-code screen cell 0 0) #x4E2D) "left half holds the code point")
      (check (= (cffi:foreign-slot-value cell '(:struct vterm-screen-cell) 'width) 2)
             "width 2")
      (check (= (cell-code screen cell 0 1) #xFFFFFFFF) "right half is the continuation marker"))))

(deftest attrs-and-rgb
  (with-vterm (vt screen)
    (feed vt (format nil "~C[1;38;2;10;20;30mX" #\Esc))  ; bold, truecolour fg
    (cffi:with-foreign-object (cell '(:struct vterm-screen-cell))
      (vterm-screen-get-cell screen 0 0 cell)
      (check (logbitp 0 (cffi:foreign-slot-value cell '(:struct vterm-screen-cell) 'attrs))
             "bold bit")
      (let ((fg (cffi:foreign-slot-pointer cell '(:struct vterm-screen-cell) 'fg)))
        (vterm-screen-convert-color-to-rgb screen fg)
        (check (equal (list (vterm-color-red fg) (vterm-color-green fg) (vterm-color-blue fg))
                      '(10 20 30))
               "rgb fg")))))

(deftest keyboard-output
  ;; Keystrokes come back out through the output callback; with no callback
  ;; set they go to libvterm's output buffer instead, which we can't read here,
  ;; so just confirm the calls are safe.
  (with-vterm (vt screen)
    (vterm-keyboard-unichar vt (char-code #\a) +mod-none+)
    (vterm-keyboard-key vt +key-enter+ +mod-ctrl+)
    (vterm-keyboard-start-paste vt)
    (vterm-keyboard-end-paste vt)
    (check t "no crash")))

(deftest resize-preserves-contents
  (with-vterm (vt screen :rows 10 :cols 20)
    (feed vt "resize")
    (vterm-set-size vt 30 100)
    (check (string= (row-text screen 0 6) "resize") "contents survive a resize")
    (cffi:with-foreign-object (cell '(:struct vterm-screen-cell))
      (check (/= 0 (vterm-screen-get-cell screen 29 99 cell)) "new extent is addressable"))))

(deftest string-fragment-bits
  (let ((packed (logior 42 (ash 1 30) (ash 1 31))))
    (check (= (vsf-len packed) 42) "len")
    (check (vsf-initial-p packed) "initial")
    (check (vsf-final-p packed) "final")))

;;; --- text, output, state, colours (the wider API) ----------------------------

(defun drain (vt) (map 'string #'code-char (vterm-output-read-octets vt)))

(deftest text-extraction
  (with-vterm (vt screen :rows 5 :cols 20)
    (feed vt (format nil "ab~C[1mCD~C[0mef~C~Cxy" #\Esc #\Esc #\Return #\Newline))
    (check (string= (vterm-screen-get-text screen 0 2 0 20) (format nil "abCDef~%xy"))
           "get-text joins rows with newlines")
    (check (equalp (vterm-screen-get-chars screen 0 1 0 4) #(97 98 67 68)) "get-chars")
    (check (equal (multiple-value-list (vterm-screen-get-attrs-extent screen 0 2))
                  '(0 1 2 4))
           "bold run CD is cols [2,4)")
    (check (and (not (vterm-screen-is-eol screen 0 5)) (vterm-screen-is-eol screen 0 6))
           "eol after the last printed cell")))

(deftest size-and-utf8-queries
  (with-vterm (vt screen :rows 7 :cols 33)
    (check (equal (multiple-value-list (vterm-get-size vt)) '(7 33)) "get-size")
    (check (= (vterm-get-utf8 vt) 1) "get-utf8")))

(deftest output-buffer
  (with-vterm (vt screen)
    (drain vt)
    (vterm-keyboard-key vt +key-up+ +mod-none+)
    (check (string= (drain vt) (format nil "~C[A" #\Esc)) "cursor-up bytes")
    (vterm-keyboard-key vt +key-kp-enter+ +mod-none+)
    (check (plusp (length (drain vt))) "keypad enter produces output")
    (check (zerop (vterm-output-get-buffer-current vt)) "drained")))

(deftest focus-reporting
  (with-vterm (vt screen)
    (let ((state (vterm-obtain-state vt)))
      (drain vt)
      (vterm-state-focus-in state)
      (check (string= (drain vt) "") "silent until the program enables it")
      (feed vt (format nil "~C[?1004h" #\Esc))
      (vterm-state-focus-in state)
      (check (string= (drain vt) (format nil "~C[I" #\Esc)) "focus in")
      (vterm-state-focus-out state)
      (check (string= (drain vt) (format nil "~C[O" #\Esc)) "focus out"))))

(deftest osc52-send-selection
  (with-vterm (vt screen)
    (let ((state (vterm-obtain-state vt)))
      (cffi:with-foreign-object (cbs '(:struct vterm-selection-callbacks))
        (setf (vsel-set cbs) (cffi:null-pointer) (vsel-query cbs) (cffi:null-pointer))
        (vterm-state-set-selection-callbacks state cbs (cffi:null-pointer) (cffi:null-pointer) 1024)
        (drain vt)
        (vterm-state-send-selection state +selection-clipboard+ "hi")
        (check (string= (drain vt) (format nil "~C]52;c;aGk=~C\\" #\Esc #\Esc))
               "OSC 52 reply carries base64(\"hi\")")))))

(deftest pen-attributes
  (with-vterm (vt screen)
    (let ((state (vterm-obtain-state vt)))
      (feed vt (format nil "~C[1;11m" #\Esc))
      (cffi:with-foreign-object (v '(:union vterm-value))
        (vterm-state-get-penattr state +attr-bold+ v)
        (check (= 1 (cffi:foreign-slot-value v '(:union vterm-value) 'boolean)) "pen bold")
        (vterm-state-get-penattr state +attr-font+ v)
        (check (= 1 (cffi:foreign-slot-value v '(:union vterm-value) 'number)) "pen font 1"))
      (check (= (vterm-get-prop-type +prop-title+) +valuetype-string+) "title is a string")
      (check (= (vterm-get-attr-type +attr-foreground+) +valuetype-color+) "fg is a colour")
      (check (= (cffi:foreign-type-size '(:union vterm-value)) 16) "VTermValue is 16 bytes"))))

(deftest cell-attr-decoders
  (with-vterm (vt screen)
    ;; bold, double underline, italic, strike, font 1, superscript
    (feed vt (format nil "~C[1;21;3;9;11;73mS" #\Esc))
    (cffi:with-foreign-object (cell '(:struct vterm-screen-cell))
      (vterm-screen-get-cell screen 0 0 cell)
      (let ((a (vterm-cell-attrs cell)))
        (check (attrs-bold-p a) "bold")
        (check (= (attrs-underline a) +underline-double+) "double underline")
        (check (attrs-italic-p a) "italic")
        (check (attrs-strike-p a) "strike")
        (check (not (or (attrs-blink-p a) (attrs-reverse-p a) (attrs-conceal-p a))) "others off")
        (check (= (attrs-font a) 1) "font 1")
        (check (and (attrs-small-p a) (= (attrs-baseline a) 1)) "superscript")))))

(deftest palette-and-colour-flags
  (with-vterm (vt screen)
    (let ((state (vterm-obtain-state vt)))
      (cffi:with-foreign-objects ((a '(:struct vterm-color)) (b '(:struct vterm-color)))
        (vterm-state-get-default-colors state a b)
        (check (and (color-default-fg-p a) (color-default-bg-p b)) "default fg/bg flags")
        (set-color-rgb b 1 2 3)
        (vterm-state-set-palette-color state 1 b)
        (vterm-state-get-palette-color state 1 a)
        (check (vterm-color-is-equal a b) "palette entry set")
        (set-color-indexed a 1)
        (check (and (color-indexed-p a) (= (vterm-color-index a) 1)) "indexed colour")
        (vterm-state-convert-color-to-rgb state a)
        (check (and (color-rgb-p a) (= (vterm-color-blue a) 3)) "index 1 converts via palette")))))

(deftest lineinfo-continuation
  (with-vterm (vt screen :rows 3 :cols 5)
    (vterm-screen-enable-reflow screen 1)
    (feed vt "abcdefgh")
    (flet ((cont (r) (lineinfo-continuation-p
                      (cffi:mem-ref (vterm-state-get-lineinfo (vterm-obtain-state vt) r) :uint32))))
      (check (and (not (cont 0)) (cont 1)) "row 1 soft-wraps from row 0"))))

(deftest rect-and-pos-packing
  (check (equal (multiple-value-list
                 (multiple-value-call #'unpack-rect (pack-rect 1 2 3 4)))
                '(1 2 3 4))
         "rect round-trip")
  (check (equal (multiple-value-list (unpack-pos (pack-pos -1 7))) '(-1 7)) "signed pos")
  (check (= (key-function 12) 268) "F12")
  (check (= (key-kp 9) 521) "KP_9")
  (check (= (pack-fragment-bits 42) (logior 42 (ash 1 30) (ash 1 31))) "fragment bits"))

(deftest library-version
  (vterm-check-version 0 3)             ; aborts the process on a mismatch
  (check t "libvterm is 0.3-compatible"))

;;; --- runner -----------------------------------------------------------------

(defun run ()
  "Run every test; print a tally; return T iff all passed."
  (let ((failures 0))
    (dolist (name (reverse *tests*))
      (handler-case (progn (funcall name) (format t "~&  ok    ~(~A~)~%" name))
        (error (e)
          (incf failures)
          (format t "~&  FAIL  ~(~A~): ~A~%" name e))))
    (format t "~&~D test~:P, ~D failure~:P~%" (length *tests*) failures)
    (zerop failures)))
