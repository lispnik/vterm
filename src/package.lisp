;;;; package.lisp --- the VTERM package.
;;;;
;;;; A thin CFFI binding to libvterm, the terminal-emulation library behind
;;;; Neovim's and Emacs' (vterm) terminals.  It binds the slice of the C API a
;;;; terminal widget needs; see vterm.lisp.

(defpackage #:vterm
  (:use #:cl)
  (:documentation "CFFI binding to libvterm (terminal emulation).")
  (:export
   ;; the shared library
   #:libvterm
   #:ensure-libvterm
   ;; foreign types and their slot names
   #:vterm-pos #:vterm-pos-row #:vterm-pos-col  ; slots ROW/COL stay internal
   #:vterm-rect #:vterm-rect-start-row #:vterm-rect-end-row
   #:vterm-rect-start-col #:vterm-rect-end-col
   #:vterm-color #:red #:green #:blue
   #:vterm-color-type #:vterm-color-red #:vterm-color-green #:vterm-color-blue
   #:vterm-color-index
   #:+color-rgb+ #:+color-indexed+ #:+color-type-mask+
   #:+color-default-fg+ #:+color-default-bg+ #:+color-default-mask+
   #:color-rgb-p #:color-indexed-p #:color-default-fg-p #:color-default-bg-p
   #:set-color-rgb #:set-color-indexed
   #:vterm-screen-cell #:chars #:width #:attrs #:fg #:bg
   #:vterm-cell-chars #:vterm-cell-width #:vterm-cell-attrs
   #:vterm-cell-fg #:vterm-cell-bg
   #:+cell-size+
   #:vterm-screen-callbacks
   #:damage #:moverect #:movecursor #:settermprop #:bell #:resize
   #:sb-pushline #:sb-popline #:sb-clear
   #:vscb-damage #:vscb-moverect #:vscb-movecursor #:vscb-settermprop
   #:vscb-bell #:vscb-resize #:vscb-sb-pushline #:vscb-sb-popline
   #:vscb-sb-clear
   #:vterm-string-fragment #:str #:packed
   #:vsf-str #:vsf-packed #:vsf-len #:vsf-initial-p #:vsf-final-p
   #:pack-fragment-bits
   #:vterm-value          ; union; members are CL:BOOLEAN NUMBER STRING + COLOR
   #:color
   #:+valuetype-bool+ #:+valuetype-int+ #:+valuetype-string+ #:+valuetype-color+
   ;; VTermScreenCellAttrs / VTermLineInfo bitfield decoders
   #:attrs-bold-p #:attrs-underline #:attrs-italic-p #:attrs-blink-p
   #:attrs-reverse-p #:attrs-conceal-p #:attrs-strike-p #:attrs-font
   #:attrs-dwl-p #:attrs-dhl #:attrs-small-p #:attrs-baseline
   #:+underline-off+ #:+underline-single+ #:+underline-double+ #:+underline-curly+
   #:lineinfo-doublewidth-p #:lineinfo-doubleheight #:lineinfo-continuation-p
   #:vterm-selection-callbacks #:query    ; the other slot is CL:SET
   #:vsel-set #:vsel-query
   ;; VTermModifier
   #:+mod-none+ #:+mod-shift+ #:+mod-alt+ #:+mod-ctrl+
   ;; VTermKey
   #:+key-none+ #:+key-enter+ #:+key-tab+ #:+key-backspace+ #:+key-escape+
   #:+key-up+ #:+key-down+ #:+key-left+ #:+key-right+
   #:+key-ins+ #:+key-del+ #:+key-home+ #:+key-end+
   #:+key-pageup+ #:+key-pagedown+ #:+key-function-0+ #:+key-function-max+
   #:+key-kp-0+ #:+key-kp-mult+ #:+key-kp-plus+ #:+key-kp-comma+
   #:+key-kp-minus+ #:+key-kp-period+ #:+key-kp-divide+ #:+key-kp-enter+
   #:+key-kp-equal+ #:+key-max+ #:+all-mods-mask+
   #:key-function #:key-kp
   ;; VTermProp
   #:+prop-cursorvisible+ #:+prop-cursorblink+ #:+prop-altscreen+
   #:+prop-title+ #:+prop-iconname+ #:+prop-reverse+ #:+prop-cursorshape+
   #:+prop-mouse+ #:+prop-focusreport+
   #:+cursorshape-block+ #:+cursorshape-underline+ #:+cursorshape-bar+
   #:+cursorshape-bar-left+
   #:+prop-mouse-none+ #:+prop-mouse-click+ #:+prop-mouse-drag+ #:+prop-mouse-move+
   ;; VTermAttr / VTermAttrMask
   #:+attr-bold+ #:+attr-underline+ #:+attr-italic+ #:+attr-blink+
   #:+attr-reverse+ #:+attr-conceal+ #:+attr-strike+ #:+attr-font+
   #:+attr-foreground+ #:+attr-background+ #:+attr-small+ #:+attr-baseline+
   #:+attr-bold-mask+ #:+attr-underline-mask+ #:+attr-italic-mask+
   #:+attr-blink-mask+ #:+attr-reverse-mask+ #:+attr-strike-mask+
   #:+attr-font-mask+ #:+attr-foreground-mask+ #:+attr-background-mask+
   #:+attr-conceal-mask+ #:+attr-small-mask+ #:+attr-baseline-mask+
   #:+all-attrs-mask+
   ;; VTermSelectionMask
   #:+selection-clipboard+ #:+selection-primary+ #:+selection-secondary+
   #:+selection-select+ #:+selection-cut0+
   ;; VTermDamageSize
   #:+damage-cell+ #:+damage-row+ #:+damage-screen+ #:+damage-scroll+
   ;; functions
   #:vterm-check-version
   #:vterm-new #:vterm-free #:vterm-set-utf8 #:vterm-get-utf8
   #:vterm-set-size #:vterm-get-size
   #:vterm-input-write #:vterm-output-set-callback
   #:vterm-output-read #:vterm-output-read-octets
   #:vterm-output-get-buffer-size #:vterm-output-get-buffer-current
   #:vterm-output-get-buffer-remaining
   #:vterm-keyboard-unichar #:vterm-keyboard-key
   #:vterm-keyboard-start-paste #:vterm-keyboard-end-paste
   #:vterm-mouse-move #:vterm-mouse-button
   #:vterm-obtain-screen #:vterm-obtain-state
   #:vterm-screen-set-callbacks #:vterm-screen-reset
   #:vterm-screen-enable-altscreen #:vterm-screen-enable-reflow
   #:vterm-screen-set-default-colors #:vterm-screen-convert-color-to-rgb
   #:vterm-screen-set-damage-merge #:vterm-screen-flush-damage
   #:vterm-screen-get-cell #:vterm-screen-get-text #:vterm-screen-get-chars
   #:vterm-screen-is-eol #:vterm-screen-get-attrs-extent
   #:vterm-state-reset #:vterm-state-get-cursorpos
   #:vterm-state-set-default-colors #:vterm-state-get-default-colors
   #:vterm-state-get-palette-color #:vterm-state-set-palette-color
   #:vterm-state-set-bold-highbright #:vterm-state-convert-color-to-rgb
   #:vterm-state-get-penattr #:vterm-state-set-termprop
   #:vterm-state-focus-in #:vterm-state-focus-out
   #:vterm-state-get-lineinfo
   #:vterm-state-set-selection-callbacks #:vterm-state-send-selection
   #:vterm-color-is-equal #:vterm-get-prop-type #:vterm-get-attr-type
   ;; by-value VTermPos / VTermRect packing
   #:pack-pos #:unpack-pos #:pack-rect #:unpack-rect))
