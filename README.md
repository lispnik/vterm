# vterm

[![CI](https://github.com/lispnik/vterm/actions/workflows/ci.yml/badge.svg)](https://github.com/lispnik/vterm/actions/workflows/ci.yml)

A Common Lisp **CFFI binding to [libvterm](https://www.leonerd.org.uk/code/libvterm/)**,
the terminal-emulation library behind Neovim's built-in terminal and Emacs'
`vterm`. Feed it the byte stream a program writes to its terminal; read back
an emulated grid of cells (characters, widths, colours, attributes); turn
keystrokes and mouse events into the bytes a real terminal would send.

It binds the slice of the C API a terminal *widget* needs — it was extracted
from [`revision-term`](https://github.com/lispnik/revision-term), a terminal
window for the [`revision`](https://github.com/lispnik/revision) TUI framework.

```lisp
(vterm:ensure-libvterm)
(let* ((vt (vterm:vterm-new 24 80))
       (screen (vterm:vterm-obtain-screen vt)))
  (vterm:vterm-set-utf8 vt 1)
  (vterm:vterm-screen-reset screen 1)
  (cffi:with-foreign-string ((buf n) "hello" :null-terminated-p nil)
    (vterm:vterm-input-write vt buf n))
  (cffi:with-foreign-object (cell '(:struct vterm:vterm-screen-cell))
    (vterm:vterm-screen-get-cell screen 0 0 cell)
    (code-char (cffi:mem-aref (vterm:vterm-cell-chars cell) :uint32 0)))  ; => #\h
  (vterm:vterm-free vt))
```

## What's bound

- **Lifecycle / input:** `vterm-new`, `vterm-free`, `vterm-set-utf8`,
  `vterm-set-size`, `vterm-input-write`, `vterm-output-set-callback`.
- **Keyboard / mouse:** `vterm-keyboard-unichar`, `vterm-keyboard-key`,
  `vterm-keyboard-start-paste` / `-end-paste`, `vterm-mouse-move`,
  `vterm-mouse-button`, and the `+key-*+` / `+mod-*+` constants.
- **Screen:** `vterm-obtain-screen`, `vterm-screen-reset`,
  `vterm-screen-set-callbacks`, `vterm-screen-enable-altscreen`,
  `vterm-screen-enable-reflow`, `vterm-screen-set-default-colors`,
  `vterm-screen-convert-color-to-rgb`, `vterm-screen-set-damage-merge`,
  `vterm-screen-flush-damage`, `vterm-screen-get-cell`.
- **State:** `vterm-obtain-state`, `vterm-state-set-default-colors`,
  `vterm-state-get-cursorpos`, `vterm-state-set-selection-callbacks` (OSC 52).
- **Structs:** `vterm-pos`, `vterm-color`, `vterm-screen-cell`,
  `vterm-screen-callbacks`, `vterm-string-fragment`,
  `vterm-selection-callbacks` — hand-laid-out to match the C ABI (no
  cffi-grovel), with `:conc-name` accessors exported (`vterm-cell-chars`,
  `vterm-pos-row`, `vscb-damage`, …).
- **Props:** `+prop-*+` (title, cursor visibility/shape, alt screen, mouse
  mode, reverse) and `+damage-*+` merge sizes.

## By-value structs

`vterm_screen_get_cell` takes a `VTermPos` (two `int`s) **by value**. Rather
than route the per-cell hot path through libffi's struct marshalling, the
binding packs it into a single `:uint64` (`pack-pos`: row in the low 32 bits,
col in the high 32) — ABI-identical for an all-integer 8-byte struct on both
x86-64 SysV and arm64 AAPCS. The same trick works for the screen callbacks that
receive `VTermPos` / `VTermRect` by value (`damage`, `moverect`,
`movecursor`): install them as C-callable closures (e.g. with
[`cffi-callback-closures`](https://github.com/lispnik/cffi-callback-closures))
whose parameters are `:uint64`s and unpack them in Lisp.

`VTermScreenCell.attrs` and `VTermStringFragment`'s `len`/`initial`/`final`
are C bitfields; both are read as one `:uint32` and unpacked by hand (bold =
bit 0, underline = bits 1–2, italic = 3, blink = 4, reverse = 5, conceal = 6,
strike = 7; `vsf-len` / `vsf-initial-p` / `vsf-final-p`). The right half of a
double-width glyph reads `chars[0] = 0xFFFFFFFF` — don't `code-char` it.

## Requirements

- A Common Lisp with CFFI (developed and tested on SBCL).
- **libvterm** 0.3 — `brew install libvterm` or `apt install libvterm-dev`.
  `ensure-libvterm` adds `/opt/homebrew/lib`, `/usr/local/lib` and `/usr/lib`
  to CFFI's search path before loading it.

## Tests

```sh
make deps    # ocicl install: restore the pinned deps from ocicl.csv
make test    # headless; no terminal needed
```

## License

MIT — see [LICENSE](LICENSE).
