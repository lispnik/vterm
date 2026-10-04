# CLAUDE.md

`vterm` is a CFFI binding to **libvterm** (the C terminal-emulation library). It was extracted from
[`revision-term`](https://github.com/lispnik/revision-term), its main consumer, which loads it as a
sibling checkout (`../vterm`) via its `setup.lisp`.

## Commands

```sh
make deps    # ocicl install -- restores cffi & co. from ocicl.csv into ./ocicl/
make test    # asdf:test-system "vterm" with a source registry of this tree only
make build   # load check
```

## Layout

- `src/package.lisp` — the `vterm` package and its export list. **Every new binding must be
  exported here**; consumers `:use` the package.
- `src/vterm.lisp` — the binding. Only the slice of libvterm consumers need.
- `tests/tests.lisp` — dependency-free headless tests (`vterm-tests:run` returns T iff all pass).

## Invariants

- Struct layouts are **hand-defined** to match the C ABI (no cffi-grovel). `+cell-size+` must stay
  40 bytes (libvterm 0.3); the `struct-sizes` test guards it.
- By-value `VTermPos` is passed as one `:uint64` (`pack-pos`: row low 32, col high 32).
- C bitfields (`VTermScreenCellAttrs`, `VTermStringFragment`'s packed word) are read as a single
  `:uint32` and decoded by hand.
- Don't export symbols that commonly clash in consumers: the `vterm-pos` slot names `row`/`col`
  stay internal (they clash with `revision:row`) — the `vterm-pos-row`/`-col` accessors are exported
  instead. Slot names that are CL symbols (`type`, `set`) need no export.
- `chars[0] == 0xFFFFFFFF` marks the right half of a double-width glyph.
