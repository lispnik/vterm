;;;; vterm.lisp --- CFFI bindings to libvterm (the terminal-emulation library).
;;;;
;;;; We bind only the slice of libvterm a terminal widget needs: build a VTerm, push
;;;; child bytes in (`vterm_input_write'), read the emulated grid back out cell
;;;; by cell (`vterm_screen_get_cell'), turn keystrokes into the bytes a real
;;;; terminal would send (`vterm_keyboard_*'), and register the handful of
;;;; screen callbacks whose signatures are scalar/pointer-only (so they can be
;;;; libffi *closures*, e.g. via cffi-callback-closures).
;;;;
;;;; The by-value struct callbacks (damage / moverect / movecursor, which take
;;;; VTermRect / VTermPos by value) are deliberately left unbound: we render by
;;;; *polling* the grid each frame instead, which needs no by-value callback.
;;;; (They can still be installed as closures whose by-value args are flattened
;;;; into :uint64s -- see PACK-POS below for the layout.)

(in-package #:vterm)

;;; --- the shared library -----------------------------------------------------

(cffi:define-foreign-library libvterm
  (:darwin (:or "libvterm.0.dylib" "libvterm.dylib"))
  (:unix   (:or "libvterm.so.0" "libvterm.so"))
  (t (:default "libvterm")))

(defun ensure-libvterm ()
  "Load libvterm, adding Homebrew's lib dir to the search path first (Apple
Silicon installs it under /opt/homebrew/lib, which is not always on the default
dyld search path)."
  ;; Pushed in reverse so they're searched in the order listed: a native
  ;; Homebrew build wins over a stale Intel one left in /usr/local.
  (dolist (d (reverse '(#p"/opt/homebrew/lib/" #p"/usr/local/lib/" #p"/usr/lib/")))
    (pushnew d cffi:*foreign-library-directories* :test #'equal))
  (unless (cffi:foreign-library-loaded-p 'libvterm)
    (cffi:use-foreign-library libvterm)))

;;; --- foreign types ----------------------------------------------------------

(cffi:defcstruct (vterm-pos :conc-name vterm-pos-)
  (row :int)
  (col :int))

;; VTermRect: half-open on both axes (end_row / end_col are one past the end).
(cffi:defcstruct (vterm-rect :conc-name vterm-rect-)
  (start-row :int)
  (end-row   :int)
  (start-col :int)
  (end-col   :int))

;; VTermColor is a tagged union: { uint8 type; uint8 red, green, blue; } for an
;; RGB colour, { uint8 type; uint8 idx; } for a palette index (so the index
;; shares RED's byte -- see VTERM-COLOR-INDEX).  vterm_screen_convert_color_to_rgb
;; turns either into the RGB form.
(cffi:defcstruct (vterm-color :conc-name vterm-color-)
  (type  :uint8)
  (red   :uint8)
  (green :uint8)
  (blue  :uint8))

;; VTermColorType: the low bit of TYPE says RGB vs indexed; bits 1-2 flag the
;; terminal's default foreground / background (no SGR colour was requested).
(defconstant +color-rgb+          #x00)
(defconstant +color-indexed+      #x01)
(defconstant +color-type-mask+    #x01)
(defconstant +color-default-fg+   #x02)
(defconstant +color-default-bg+   #x04)
(defconstant +color-default-mask+ #x06)

(defun vterm-color-index (col)
  "The palette index of the indexed VTermColor at COL."
  (cffi:mem-ref col :uint8 1))

(defun color-indexed-p    (col) (logtest (vterm-color-type col) +color-indexed+))
(defun color-rgb-p        (col) (not (color-indexed-p col)))
(defun color-default-fg-p (col) (logtest (vterm-color-type col) +color-default-fg+))
(defun color-default-bg-p (col) (logtest (vterm-color-type col) +color-default-bg+))

(defun set-color-rgb (col red green blue)
  "Store an RGB colour into the VTermColor at COL (vterm_color_rgb, which is
static inline in vterm.h and so not callable through FFI).  Returns COL."
  (setf (vterm-color-type col) +color-rgb+
        (vterm-color-red col) red
        (vterm-color-green col) green
        (vterm-color-blue col) blue)
  col)

(defun set-color-indexed (col index)
  "Store palette INDEX into the VTermColor at COL (vterm_color_indexed).
Returns COL."
  (setf (vterm-color-type col) +color-indexed+
        (cffi:mem-ref col :uint8 1) index)
  col)

;; VTermScreenCell.  `attrs' is a C bitfield struct; we read it as one uint32
;; and pull bits out by hand (bold = bit 0, reverse = bit 5).  The :uint32
;; slot's 4-byte alignment reproduces the pad C inserts after `width'.
(cffi:defcstruct (vterm-screen-cell :conc-name vterm-cell-)
  (chars :uint32 :count 6)
  (width :char)
  (attrs :uint32)
  (fg (:struct vterm-color))
  (bg (:struct vterm-color)))

(defparameter +cell-size+ (cffi:foreign-type-size '(:struct vterm-screen-cell))
  "sizeof(VTermScreenCell); the stride for the sb_pushline cell array.")

;; VTermScreenCallbacks: nine function pointers.  We only fill the ones with
;; scalar/pointer signatures; the by-value ones stay NULL (we poll instead).
(cffi:defcstruct (vterm-screen-callbacks :conc-name vscb-)
  (damage      :pointer)
  (moverect    :pointer)
  (movecursor  :pointer)
  (settermprop :pointer)
  (bell        :pointer)
  (resize      :pointer)
  (sb-pushline :pointer)
  (sb-popline  :pointer)
  (sb-clear    :pointer))

;; VTermStringFragment (how a string property -- e.g. the window title -- is
;; delivered to settermprop, possibly in several pieces).  The C struct packs
;;   size_t len:30;  bool initial:1;  bool final:1;
;; into one word after the pointer, so we read it as a single uint32 and unpack
;; the bits by hand (VSF-LEN / VSF-INITIAL-P / VSF-FINAL-P below).
(cffi:defcstruct (vterm-string-fragment :conc-name vsf-)
  (str    :pointer)
  (packed :uint32))

(declaim (inline vsf-len vsf-initial-p vsf-final-p pack-fragment-bits))
(defun vsf-len       (packed) (logand packed #x3fffffff))
(defun vsf-initial-p (packed) (logbitp 30 packed))
(defun vsf-final-p   (packed) (logbitp 31 packed))
(defun pack-fragment-bits (len &key (initial t) (final t))
  "The packed len/initial/final word of a VTermStringFragment (inverse of
VSF-LEN / VSF-INITIAL-P / VSF-FINAL-P)."
  (logior (logand len #x3fffffff) (if initial (ash 1 30) 0) (if final (ash 1 31) 0)))

;; VTermValue: how a termprop or pen attribute's value is passed (settermprop,
;; vterm_state_get_penattr).  Which member is live depends on the prop's or
;; attr's value type -- see VTERM-GET-PROP-TYPE / VTERM-GET-ATTR-TYPE.
(cffi:defcunion vterm-value
  (boolean :int)
  (number  :int)
  (string  (:struct vterm-string-fragment))
  (color   (:struct vterm-color)))

;; VTermValueType
(defconstant +valuetype-bool+   1)
(defconstant +valuetype-int+    2)
(defconstant +valuetype-string+ 3)
(defconstant +valuetype-color+  4)

;;; --- VTermScreenCellAttrs ---------------------------------------------------
;;;
;;; The C bitfield, read as the single uint32 in the cell's ATTRS slot.  Bit
;;; positions (GCC/Clang allocate little-endian bitfields from bit 0):
;;;   bold 0 | underline 1-2 | italic 3 | blink 4 | reverse 5 | conceal 6 |
;;;   strike 7 | font 8-11 | dwl 12 | dhl 13-14 | small 15 | baseline 16-17

(declaim (inline attrs-bold-p attrs-underline attrs-italic-p attrs-blink-p
                 attrs-reverse-p attrs-conceal-p attrs-strike-p attrs-font
                 attrs-dwl-p attrs-dhl attrs-small-p attrs-baseline))
(defun attrs-bold-p    (attrs) (logbitp 0 attrs))
(defun attrs-underline (attrs)
  "0 none, 1 single, 2 double, 3 curly (+UNDERLINE-*+)."
  (ldb (byte 2 1) attrs))
(defun attrs-italic-p  (attrs) (logbitp 3 attrs))
(defun attrs-blink-p   (attrs) (logbitp 4 attrs))
(defun attrs-reverse-p (attrs) (logbitp 5 attrs))
(defun attrs-conceal-p (attrs) (logbitp 6 attrs))
(defun attrs-strike-p  (attrs) (logbitp 7 attrs))
(defun attrs-font      (attrs) "Alternative font 0-9 (SGR 10-19)." (ldb (byte 4 8) attrs))
(defun attrs-dwl-p     (attrs) "On a DECDWL/DECDHL double-width line." (logbitp 12 attrs))
(defun attrs-dhl       (attrs) "DECDHL half: 0 none, 1 top, 2 bottom." (ldb (byte 2 13) attrs))
(defun attrs-small-p   (attrs) (logbitp 15 attrs))
(defun attrs-baseline  (attrs)
  "0 normal, 1 raised (superscript), 2 lowered (subscript)."
  (ldb (byte 2 16) attrs))

(defconstant +underline-off+    0)
(defconstant +underline-single+ 1)
(defconstant +underline-double+ 2)
(defconstant +underline-curly+  3)

;;; VTermLineInfo: a bitfield in one unsigned int, returned by pointer from
;;; vterm_state_get_lineinfo.  Read it with (cffi:mem-ref p :uint32).
(declaim (inline lineinfo-doublewidth-p lineinfo-doubleheight lineinfo-continuation-p))
(defun lineinfo-doublewidth-p  (word) (logbitp 0 word))
(defun lineinfo-doubleheight   (word) "0 none, 1 top, 2 bottom." (ldb (byte 2 1) word))
(defun lineinfo-continuation-p (word)
  "True if the row is a soft-wrapped continuation of the one above (needs reflow)."
  (logbitp 3 word))

;;; --- VTermKey / VTermModifier (from vterm_keycodes.h) -----------------------

(defconstant +mod-none+  #x00)
(defconstant +mod-shift+ #x01)
(defconstant +mod-alt+   #x02)
(defconstant +mod-ctrl+  #x04)

(defconstant +key-none+       0)
(defconstant +key-enter+      1)
(defconstant +key-tab+        2)
(defconstant +key-backspace+  3)
(defconstant +key-escape+     4)
(defconstant +key-up+         5)
(defconstant +key-down+       6)
(defconstant +key-left+       7)
(defconstant +key-right+      8)
(defconstant +key-ins+        9)
(defconstant +key-del+        10)
(defconstant +key-home+       11)
(defconstant +key-end+        12)
(defconstant +key-pageup+     13)
(defconstant +key-pagedown+   14)
(defconstant +key-function-0+ 256)         ; VTERM_KEY_FUNCTION(n) = 256 + n
(defconstant +key-function-max+ 511)
(defconstant +key-kp-0+       512)         ; keypad: KP_0 .. KP_9 are 512 .. 521
(defconstant +key-kp-mult+    522)
(defconstant +key-kp-plus+    523)
(defconstant +key-kp-comma+   524)
(defconstant +key-kp-minus+   525)
(defconstant +key-kp-period+  526)
(defconstant +key-kp-divide+  527)
(defconstant +key-kp-enter+   528)
(defconstant +key-kp-equal+   529)
(defconstant +key-max+        530)

(defconstant +all-mods-mask+ #x07)

(declaim (inline key-function key-kp))
(defun key-function (n) "VTERM_KEY_FUNCTION(N): the key code of function key FN." (+ +key-function-0+ n))
(defun key-kp (n) "The key code of keypad digit N (0-9)." (+ +key-kp-0+ n))

;;; --- VTermProp ---------------------------------------------------------------

(defconstant +prop-cursorvisible+ 1)   ; bool
(defconstant +prop-cursorblink+   2)   ; bool
(defconstant +prop-altscreen+     3)   ; bool
(defconstant +prop-title+         4)   ; string
(defconstant +prop-iconname+      5)   ; string
(defconstant +prop-reverse+       6)   ; bool
(defconstant +prop-cursorshape+   7)   ; number (+CURSORSHAPE-*+)
(defconstant +prop-mouse+         8)   ; number (+PROP-MOUSE-*+)
(defconstant +prop-focusreport+   9)   ; bool

(defconstant +cursorshape-block+     1)
(defconstant +cursorshape-underline+ 2)
(defconstant +cursorshape-bar+       3)   ; VTERM_PROP_CURSORSHAPE_BAR_LEFT
(defconstant +cursorshape-bar-left+  3)

(defconstant +prop-mouse-none+  0)
(defconstant +prop-mouse-click+ 1)
(defconstant +prop-mouse-drag+  2)
(defconstant +prop-mouse-move+  3)

;;; --- VTermAttr (pen attributes, for vterm_state_get_penattr) -----------------

(defconstant +attr-bold+       1)   ; bool
(defconstant +attr-underline+  2)   ; number
(defconstant +attr-italic+     3)   ; bool
(defconstant +attr-blink+      4)   ; bool
(defconstant +attr-reverse+    5)   ; bool
(defconstant +attr-conceal+    6)   ; bool
(defconstant +attr-strike+     7)   ; bool
(defconstant +attr-font+       8)   ; number
(defconstant +attr-foreground+ 9)   ; color
(defconstant +attr-background+ 10)  ; color
(defconstant +attr-small+      11)  ; bool
(defconstant +attr-baseline+   12)  ; number

;; VTermAttrMask (for vterm_screen_get_attrs_extent)
(defconstant +attr-bold-mask+       (ash 1 0))
(defconstant +attr-underline-mask+  (ash 1 1))
(defconstant +attr-italic-mask+     (ash 1 2))
(defconstant +attr-blink-mask+      (ash 1 3))
(defconstant +attr-reverse-mask+    (ash 1 4))
(defconstant +attr-strike-mask+     (ash 1 5))
(defconstant +attr-font-mask+       (ash 1 6))
(defconstant +attr-foreground-mask+ (ash 1 7))
(defconstant +attr-background-mask+ (ash 1 8))
(defconstant +attr-conceal-mask+    (ash 1 9))
(defconstant +attr-small-mask+      (ash 1 10))
(defconstant +attr-baseline-mask+   (ash 1 11))
(defconstant +all-attrs-mask+       (1- (ash 1 12)))

;;; --- VTermSelectionMask (OSC 52) ---------------------------------------------

(defconstant +selection-clipboard+ (ash 1 0))
(defconstant +selection-primary+   (ash 1 1))
(defconstant +selection-secondary+ (ash 1 2))
(defconstant +selection-select+    (ash 1 3))
(defconstant +selection-cut0+      (ash 1 4))   ; CUT1..CUT7 by shifting further

;;; --- functions --------------------------------------------------------------

(cffi:defcfun ("vterm_new" vterm-new) :pointer
  (rows :int) (cols :int))

(cffi:defcfun ("vterm_free" vterm-free) :void
  (vt :pointer))

(cffi:defcfun ("vterm_set_utf8" vterm-set-utf8) :void
  (vt :pointer) (is-utf8 :int))

(cffi:defcfun ("vterm_set_size" vterm-set-size) :void
  (vt :pointer) (rows :int) (cols :int))

(cffi:defcfun ("vterm_input_write" vterm-input-write) :unsigned-long
  (vt :pointer) (bytes :pointer) (len :unsigned-long))

(cffi:defcfun ("vterm_output_set_callback" vterm-output-set-callback) :void
  (vt :pointer) (func :pointer) (user :pointer))

(cffi:defcfun ("vterm_keyboard_unichar" vterm-keyboard-unichar) :void
  (vt :pointer) (c :uint32) (mod :int))

(cffi:defcfun ("vterm_keyboard_key" vterm-keyboard-key) :void
  (vt :pointer) (key :int) (mod :int))

(cffi:defcfun ("vterm_obtain_screen" vterm-obtain-screen) :pointer
  (vt :pointer))

(cffi:defcfun ("vterm_obtain_state" vterm-obtain-state) :pointer
  (vt :pointer))

(cffi:defcfun ("vterm_screen_set_callbacks" vterm-screen-set-callbacks) :void
  (screen :pointer) (callbacks :pointer) (user :pointer))

(cffi:defcfun ("vterm_screen_reset" vterm-screen-reset) :void
  (screen :pointer) (hard :int))

(cffi:defcfun ("vterm_screen_enable_altscreen" vterm-screen-enable-altscreen) :void
  (screen :pointer) (altscreen :int))

(cffi:defcfun ("vterm_screen_set_default_colors" vterm-screen-set-default-colors) :void
  (screen :pointer) (default-fg :pointer) (default-bg :pointer))

(cffi:defcfun ("vterm_screen_convert_color_to_rgb" vterm-screen-convert-color-to-rgb) :void
  (screen :pointer) (col :pointer))

(cffi:defcfun ("vterm_state_set_default_colors" vterm-state-set-default-colors) :void
  (state :pointer) (default-fg :pointer) (default-bg :pointer))

(cffi:defcfun ("vterm_state_get_cursorpos" vterm-state-get-cursorpos) :void
  (state :pointer) (cursorpos :pointer))

(cffi:defcfun ("vterm_screen_enable_reflow" vterm-screen-enable-reflow) :void
  (screen :pointer) (reflow :int))

;; Damage tracking: merge per-row so the `damage' callback fires once per changed
;; row (flushed by flush_damage), letting us re-poll only the rows that changed.
(defconstant +damage-cell+   0)
(defconstant +damage-row+    1)
(defconstant +damage-screen+ 2)
(defconstant +damage-scroll+ 3)

(cffi:defcfun ("vterm_screen_set_damage_merge" vterm-screen-set-damage-merge) :void
  (screen :pointer) (size :int))

(cffi:defcfun ("vterm_screen_flush_damage" vterm-screen-flush-damage) :void
  (screen :pointer))

(cffi:defcfun ("vterm_mouse_move" vterm-mouse-move) :void
  (vt :pointer) (row :int) (col :int) (mod :int))

(cffi:defcfun ("vterm_mouse_button" vterm-mouse-button) :void
  (vt :pointer) (button :int) (pressed :int) (mod :int))

(cffi:defcfun ("vterm_keyboard_start_paste" vterm-keyboard-start-paste) :void
  (vt :pointer))

(cffi:defcfun ("vterm_keyboard_end_paste" vterm-keyboard-end-paste) :void
  (vt :pointer))

;; OSC 52 (a program setting/reading the system clipboard) is delivered through
;; the state's selection callbacks; libvterm base64-decodes into the buffer we
;; provide and hands us plain-text fragments.
(cffi:defcstruct (vterm-selection-callbacks :conc-name vsel-)
  (set   :pointer)
  (query :pointer))

(cffi:defcfun ("vterm_state_set_selection_callbacks" vterm-state-set-selection-callbacks) :void
  (state :pointer) (callbacks :pointer) (user :pointer)
  (buffer :pointer) (buflen :unsigned-long))

;;; vterm_screen_get_cell takes VTermPos *by value*.  A VTermPos is two ints (8
;;; bytes, all-integer); on both arm64 (AAPCS) and x86-64 (SysV) such a struct
;;; is passed in a single general register, identically to a uint64 with row in
;;; the low 32 bits and col in the high 32 bits.  Packing it that way lets us
;;; make the call without libffi by-value marshalling on this per-cell hot path.
(declaim (inline pack-pos))
(defun pack-pos (row col)
  (logior (logand row #xffffffff) (ash (logand col #xffffffff) 32)))

(declaim (inline vterm-screen-get-cell))
(defun vterm-screen-get-cell (screen row col cell)
  "Read the emulated cell at (ROW,COL) into the foreign CELL (a
VTermScreenCell*).  Returns non-zero if the position is valid."
  (cffi:foreign-funcall "vterm_screen_get_cell"
                        :pointer screen
                        :uint64 (pack-pos row col)
                        :pointer cell
                        :int))

;;; --- by-value VTermPos / VTermRect, unpacked --------------------------------
;;;
;;; The same packing serves callbacks: a closure installed for `damage' receives
;;; a VTermRect as two :uint64 args, `moverect' four, `movecursor' two VTermPos
;;; as two.  UNPACK-RECT / UNPACK-POS recover the fields.  VTermRect is four
;;; ints (16 bytes, all-integer), passed in two general registers on both
;;; x86-64 SysV and arm64 AAPCS -- identically to two uint64s.

(declaim (inline unpack-pos pack-rect unpack-rect %s32))
(defun %s32 (u) (if (logbitp 31 u) (- u #x100000000) u))

(defun unpack-pos (packed)
  "(values ROW COL) from a PACK-POS-style uint64."
  (values (%s32 (logand packed #xffffffff)) (%s32 (ldb (byte 32 32) packed))))

(defun pack-rect (start-row end-row start-col end-col)
  "A VTermRect as the two :uint64 words it occupies when passed by value."
  (values (pack-pos start-row end-row) (pack-pos start-col end-col)))

(defun unpack-rect (rows-word cols-word)
  "(values START-ROW END-ROW START-COL END-COL) from a VTermRect passed by value
as two uint64s (e.g. the args of a `damage' callback)."
  (multiple-value-bind (sr er) (unpack-pos rows-word)
    (multiple-value-bind (sc ec) (unpack-pos cols-word)
      (values sr er sc ec))))

;;; --- version ----------------------------------------------------------------

(cffi:defcfun ("vterm_check_version" vterm-check-version) :void
  "Check the loaded libvterm against MAJOR.MINOR.  NB: on a mismatch libvterm
prints a message and calls abort(), killing the whole process."
  (major :int) (minor :int))

;;; --- VTerm ------------------------------------------------------------------

(cffi:defcfun ("vterm_get_utf8" vterm-get-utf8) :int
  (vt :pointer))

(defun vterm-get-size (vt)
  "(values ROWS COLS) of VT."
  (cffi:with-foreign-objects ((rows :int) (cols :int))
    (cffi:foreign-funcall "vterm_get_size" :pointer vt :pointer rows :pointer cols :void)
    (values (cffi:mem-ref rows :int) (cffi:mem-ref cols :int))))

;; Output buffer: only used when no output callback is set.  libvterm marks
;; these deprecated, but they are the simplest way to collect the bytes a
;; keystroke or report produces without minting a C callback.
(cffi:defcfun ("vterm_output_get_buffer_size" vterm-output-get-buffer-size) :unsigned-long
  (vt :pointer))

(cffi:defcfun ("vterm_output_get_buffer_current" vterm-output-get-buffer-current) :unsigned-long
  (vt :pointer))

(cffi:defcfun ("vterm_output_get_buffer_remaining" vterm-output-get-buffer-remaining) :unsigned-long
  (vt :pointer))

(cffi:defcfun ("vterm_output_read" vterm-output-read) :unsigned-long
  (vt :pointer) (buffer :pointer) (len :unsigned-long))

(defun vterm-output-read-octets (vt)
  "Drain VT's output buffer into a fresh (unsigned-byte 8) vector."
  (let ((n (vterm-output-get-buffer-current vt)))
    (if (zerop n)
        (make-array 0 :element-type '(unsigned-byte 8))
        (cffi:with-foreign-object (buf :unsigned-char n)
          (let* ((got (vterm-output-read vt buf n))
                 (out (make-array got :element-type '(unsigned-byte 8))))
            (dotimes (i got out)
              (setf (aref out i) (cffi:mem-aref buf :unsigned-char i))))))))

;;; --- state ------------------------------------------------------------------

(cffi:defcfun ("vterm_state_reset" vterm-state-reset) :void
  (state :pointer) (hard :int))

(cffi:defcfun ("vterm_state_get_default_colors" vterm-state-get-default-colors) :void
  (state :pointer) (default-fg :pointer) (default-bg :pointer))

(cffi:defcfun ("vterm_state_get_palette_color" vterm-state-get-palette-color) :void
  (state :pointer) (index :int) (col :pointer))

(cffi:defcfun ("vterm_state_set_palette_color" vterm-state-set-palette-color) :void
  (state :pointer) (index :int) (col :pointer))

(cffi:defcfun ("vterm_state_set_bold_highbright" vterm-state-set-bold-highbright) :void
  (state :pointer) (bold-is-highbright :int))

(cffi:defcfun ("vterm_state_convert_color_to_rgb" vterm-state-convert-color-to-rgb) :void
  (state :pointer) (col :pointer))

(cffi:defcfun ("vterm_state_get_penattr" vterm-state-get-penattr) :int
  "Read the current pen's ATTR (+ATTR-*+) into the VTermValue at VAL."
  (state :pointer) (attr :int) (val :pointer))

(cffi:defcfun ("vterm_state_set_termprop" vterm-state-set-termprop) :int
  (state :pointer) (prop :int) (val :pointer))

(cffi:defcfun ("vterm_state_focus_in" vterm-state-focus-in) :void
  "Report focus gained (emits CSI I if the program enabled focus reporting)."
  (state :pointer))

(cffi:defcfun ("vterm_state_focus_out" vterm-state-focus-out) :void
  "Report focus lost (emits CSI O if the program enabled focus reporting)."
  (state :pointer))

(cffi:defcfun ("vterm_state_get_lineinfo" vterm-state-get-lineinfo) :pointer
  "Pointer to ROW's VTermLineInfo; decode (cffi:mem-ref p :uint32) with LINEINFO-*."
  (state :pointer) (row :int))

(defun vterm-state-send-selection (state mask string)
  "Answer an OSC 52 query: send STRING (a Lisp string, sent as UTF-8) as the
contents of the selection buffer in MASK (+SELECTION-*+), as one fragment.
libvterm base64-encodes through the buffer given to
VTERM-STATE-SET-SELECTION-CALLBACKS, so nothing is sent until that is set.
NB: libvterm 0.3.3 sign-extends bytes >= #x80 while encoding, so non-ASCII
text arrives corrupted -- a libvterm bug, reproducible from C.
The VTermStringFragment goes by value as its two words (pointer, packed bits)."
  (cffi:with-foreign-string ((buf n) string :encoding :utf-8 :null-terminated-p nil)
    (cffi:foreign-funcall "vterm_state_send_selection"
                          :pointer state :int mask
                          :pointer buf :uint64 (pack-fragment-bits n)
                          :void)))

;;; --- screen -----------------------------------------------------------------

(defun vterm-screen-get-text (screen start-row end-row start-col end-col)
  "The text in the half-open rectangle as a Lisp string, rows joined by
newlines (libvterm trims each row's trailing blanks)."
  (let ((len (* 4 6 (max 1 (- end-row start-row)) (max 1 (- end-col start-col)))))
    (cffi:with-foreign-object (buf :char len)
      (multiple-value-bind (rows cols) (pack-rect start-row end-row start-col end-col)
        (let ((n (cffi:foreign-funcall "vterm_screen_get_text"
                                       :pointer screen :pointer buf :unsigned-long len
                                       :uint64 rows :uint64 cols
                                       :unsigned-long)))
          (cffi:foreign-string-to-lisp buf :count (min n len) :encoding :utf-8))))))

(defun vterm-screen-get-chars (screen start-row end-row start-col end-col)
  "The code points in the half-open rectangle as a vector of integers."
  (let ((len (* 6 (max 1 (- end-row start-row)) (max 1 (- end-col start-col)))))
    (cffi:with-foreign-object (buf :uint32 len)
      (multiple-value-bind (rows cols) (pack-rect start-row end-row start-col end-col)
        (let* ((n (min len (cffi:foreign-funcall "vterm_screen_get_chars"
                                                 :pointer screen :pointer buf :unsigned-long len
                                                 :uint64 rows :uint64 cols
                                                 :unsigned-long)))
               (out (make-array n)))
          (dotimes (i n out) (setf (aref out i) (cffi:mem-aref buf :uint32 i))))))))

(declaim (inline vterm-screen-is-eol))
(defun vterm-screen-is-eol (screen row col)
  "True if (ROW,COL) is at or past the last printed cell of its row."
  (/= 0 (cffi:foreign-funcall "vterm_screen_is_eol"
                              :pointer screen :uint64 (pack-pos row col) :int)))

(defun vterm-screen-get-attrs-extent (screen row col &optional (mask +all-attrs-mask+))
  "The run of cells on ROW around COL sharing its attributes (those in MASK,
+ATTR-*-MASK+).  Returns the half-open (values START-ROW END-ROW START-COL
END-COL), or NIL if none."
  (cffi:with-foreign-object (r '(:struct vterm-rect))
    ;; libvterm searches within the columns it is given; -1 means the whole row
    (setf (vterm-rect-start-row r) row (vterm-rect-end-row r) (1+ row)
          (vterm-rect-start-col r) -1 (vterm-rect-end-col r) -1)
    (when (/= 0 (cffi:foreign-funcall "vterm_screen_get_attrs_extent"
                                      :pointer screen :pointer r
                                      :uint64 (pack-pos row col) :int mask :int))
      ;; libvterm leaves end_col inclusive here, unlike every other VTermRect
      (values (vterm-rect-start-row r) (vterm-rect-end-row r)
              (vterm-rect-start-col r) (1+ (vterm-rect-end-col r))))))

;;; --- misc -------------------------------------------------------------------

(cffi:defcfun ("vterm_color_is_equal" %vterm-color-is-equal) :int
  (a :pointer) (b :pointer))

(defun vterm-color-is-equal (a b)
  "True if the VTermColors at A and B are the same colour."
  (/= 0 (%vterm-color-is-equal a b)))

(cffi:defcfun ("vterm_get_prop_type" vterm-get-prop-type) :int
  "The +VALUETYPE-*+ of termprop PROP."
  (prop :int))

(cffi:defcfun ("vterm_get_attr_type" vterm-get-attr-type) :int
  "The +VALUETYPE-*+ of pen attribute ATTR."
  (attr :int))
