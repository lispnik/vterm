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
