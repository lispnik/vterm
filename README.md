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

- **Lifecycle / input:** `vterm-check-version`, `vterm-new`, `vterm-free`,
  `vterm-set-utf8` / `vterm-get-utf8`, `vterm-set-size` / `vterm-get-size`,
  `vterm-input-write`.
- **Output:** `vterm-output-set-callback`, or without a callback
  `vterm-output-read` / `vterm-output-read-octets` and the
  `vterm-output-get-buffer-*` queries.
- **Keyboard / mouse:** `vterm-keyboard-unichar`, `vterm-keyboard-key`,
  `vterm-keyboard-start-paste` / `-end-paste`, `vterm-mouse-move`,
  `vterm-mouse-button`; `+key-*+` (including keypad and `key-function` /
  `key-kp`) and `+mod-*+`.
- **Screen:** `vterm-obtain-screen`, `vterm-screen-reset`,
  `vterm-screen-set-callbacks`, `vterm-screen-enable-altscreen`,
  `vterm-screen-enable-reflow`, `vterm-screen-set-default-colors`,
  `vterm-screen-convert-color-to-rgb`, `vterm-screen-set-damage-merge`,
  `vterm-screen-flush-damage`, `vterm-screen-get-cell`,
  `vterm-screen-get-text`, `vterm-screen-get-chars`, `vterm-screen-is-eol`,
  `vterm-screen-get-attrs-extent` (these four take the `VTerm`, not the screen
  — see *Safety* below).
- **State:** `vterm-obtain-state`, `vterm-state-reset`,
  `vterm-state-get-cursorpos`, default and palette colours
  (`vterm-state-{get,set}-default-colors`, `vterm-state-{get,set}-palette-color`,
  `vterm-state-set-bold-highbright`, `vterm-state-convert-color-to-rgb`),
  `vterm-state-get-penattr`, `vterm-state-set-termprop`,
  `vterm-state-focus-in` / `-out`, `vterm-get-lineinfo`, and OSC 52
  (`vterm-state-set-selection-callbacks`, `vterm-state-send-selection`).
- **Structs:** `vterm-pos`, `vterm-rect`, `vterm-color`, `vterm-screen-cell`,
  `vterm-screen-callbacks`, `vterm-string-fragment`, `vterm-value` (union),
  `vterm-selection-callbacks` — hand-laid-out to match the C ABI (no
  cffi-grovel), with `:conc-name` accessors exported (`vterm-cell-chars`,
  `vterm-pos-row`, `vterm-rect-end-col`, `vscb-damage`, …).
- **Bitfield decoders:** `attrs-bold-p`, `attrs-underline`, `attrs-font`,
  `attrs-baseline`, … for a cell's `attrs` word; `lineinfo-continuation-p`
  and friends for `VTermLineInfo`; `vsf-len` / `vsf-initial-p` /
  `vsf-final-p` for string fragments.
- **Colours:** the `+color-*+` type flags with `color-rgb-p`,
  `color-indexed-p`, `color-default-fg-p` / `-bg-p`, `vterm-color-index`,
  `set-color-rgb` / `set-color-indexed` (Lisp versions of libvterm's inline
  constructors) and `vterm-color-is-equal`.
- **Constants:** `+prop-*+` (all nine termprops) with `+cursorshape-*+` and
  `+prop-mouse-*+`, `+attr-*+` and `+attr-*-mask+`, `+selection-*+`,
  `+valuetype-*+`, `+damage-*+`, `+underline-*+`.

Not bound: the parser/state-layer callback and fallback APIs, custom
allocators (`vterm_build`), and `vterm_scroll_rect` / `vterm_copy_cells`.

## By-value structs

`vterm_screen_get_cell` takes a `VTermPos` (two `int`s) **by value**. Rather
than route the per-cell hot path through libffi's struct marshalling, the
binding packs it into a single `:uint64` (`pack-pos`: row in the low 32 bits,
col in the high 32) — ABI-identical for an all-integer 8-byte struct on both
x86-64 SysV and arm64 AAPCS. The same trick works for the screen callbacks that
receive `VTermPos` / `VTermRect` by value (`damage`, `moverect`,
`movecursor`): install them as C-callable closures (e.g. with
[`cffi-callback-closures`](https://github.com/lispnik/cffi-callback-closures))
whose parameters are `:uint64`s and unpack them with `unpack-rect` /
`unpack-pos`.

`VTermScreenCell.attrs` and `VTermStringFragment`'s `len`/`initial`/`final`
are C bitfields; both are read as one `:uint32` and unpacked by hand (bold =
bit 0, underline = bits 1–2, italic = 3, blink = 4, reverse = 5, conceal = 6,
strike = 7; `vsf-len` / `vsf-initial-p` / `vsf-final-p`). The right half of a
double-width glyph reads `chars[0] = 0xFFFFFFFF` — don't `code-char` it.

## Safety

libvterm trusts its caller: an out-of-range position or rectangle passed to
`get_text`, `get_chars`, `is_eol`, `get_attrs_extent` or `get_lineinfo`
dereferences a NULL cell and kills the process, and `vterm_new` happily makes a
terminal of negative size that crashes on its first write. The binding checks
these in Lisp and signals a `vterm:vterm-error` instead — which is why those
screen queries take the `VTerm` (a `VTermScreen` has no size accessor). Palette
indices outside 0–255 are rejected too, rather than silently ignored.

Two things it can't check for you:

- **Callback lifetimes.** `vterm-screen-set-callbacks`,
  `vterm-state-set-selection-callbacks` and `vterm-output-set-callback` store
  your *pointers*, not copies. Allocate callback structs and buffers with
  `cffi:foreign-alloc` and keep them (and the C function pointers in them)
  alive until the `VTerm` is freed.
- **Threads.** libvterm has no locking; drive each `VTerm` from one thread.

`ensure-libvterm` refuses a libvterm older than 0.3 (whose struct layouts
differ), and the system refuses to build on platforms where the by-value
struct packing isn't ABI-correct (anything but 64-bit little-endian
x86-64/arm64 outside Windows).

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
