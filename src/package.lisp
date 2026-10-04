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
   #:vterm-color #:red #:green #:blue
   #:vterm-color-type #:vterm-color-red #:vterm-color-green #:vterm-color-blue
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
   #:vterm-selection-callbacks #:query    ; the other slot is CL:SET
   #:vsel-set #:vsel-query
   ;; VTermModifier
   #:+mod-none+ #:+mod-shift+ #:+mod-alt+ #:+mod-ctrl+
   ;; VTermKey
   #:+key-none+ #:+key-enter+ #:+key-tab+ #:+key-backspace+ #:+key-escape+
   #:+key-up+ #:+key-down+ #:+key-left+ #:+key-right+
   #:+key-ins+ #:+key-del+ #:+key-home+ #:+key-end+
   #:+key-pageup+ #:+key-pagedown+ #:+key-function-0+
   ;; VTermProp
   #:+prop-cursorvisible+ #:+prop-altscreen+ #:+prop-title+
   #:+prop-reverse+ #:+prop-cursorshape+ #:+prop-mouse+
   #:+cursorshape-block+ #:+cursorshape-underline+ #:+cursorshape-bar+
   ;; VTermDamageSize
   #:+damage-cell+ #:+damage-row+ #:+damage-screen+ #:+damage-scroll+
   ;; functions
   #:vterm-new #:vterm-free #:vterm-set-utf8 #:vterm-set-size
   #:vterm-input-write #:vterm-output-set-callback
   #:vterm-keyboard-unichar #:vterm-keyboard-key
   #:vterm-keyboard-start-paste #:vterm-keyboard-end-paste
   #:vterm-mouse-move #:vterm-mouse-button
   #:vterm-obtain-screen #:vterm-obtain-state
   #:vterm-screen-set-callbacks #:vterm-screen-reset
   #:vterm-screen-enable-altscreen #:vterm-screen-enable-reflow
   #:vterm-screen-set-default-colors #:vterm-screen-convert-color-to-rgb
   #:vterm-screen-set-damage-merge #:vterm-screen-flush-damage
   #:vterm-screen-get-cell
   #:vterm-state-set-default-colors #:vterm-state-get-cursorpos
   #:vterm-state-set-selection-callbacks
   ;; by-value VTermPos packing
   #:pack-pos))
