# CBZ2 — vendored libbzip2

The reference bzip2 library (libbzip2), vendored unmodified so PatchSDK can
inflate the bz2 control/diff/extra blocks of BSDIFF40 patches on every platform.
Apple ships this same library as the SDK's `libbz2`; the Android NDK does not
ship it at all, so it is compiled from source here instead.

| Field | Value |
| --- | --- |
| Upstream | https://sourceware.org/bzip2/ (git: https://sourceware.org/git/bzip2.git) |
| Version | 1.0.8 (tag `bzip2-1.0.8`) |
| Commit | 6a8690fc8d26c815e798c588f796eabe9d684cf0 |
| License | bzip2 license, BSD-style (see `LICENSE`) |

## What was copied

| Upstream path | Here |
| --- | --- |
| `blocksort.c`, `huffman.c`, `crctable.c`, `randtable.c`, `compress.c`, `decompress.c`, `bzlib.c` (the Makefile's `libbz2.a` objects) | `src/` |
| `bzlib_private.h` | `src/` |
| `bzlib.h` | `include/` |
| `LICENSE` | `LICENSE` |

Not copied: the `bzip2` / `bzip2recover` command-line tools, tests, and docs.
The compressor sources are needed because `bzlib.c` references them.

## Updating

```sh
git clone --depth 1 --branch <tag> https://sourceware.org/git/bzip2.git /tmp/bzip2
D=Sources/CBZ2
cp /tmp/bzip2/{blocksort,huffman,crctable,randtable,compress,decompress,bzlib}.c /tmp/bzip2/bzlib_private.h $D/src/
cp /tmp/bzip2/bzlib.h $D/include/
cp /tmp/bzip2/LICENSE $D/LICENSE
```

Then update the version and commit in the table above. Do not edit the
vendored sources by hand.
