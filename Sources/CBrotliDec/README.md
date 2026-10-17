# CBrotliDec — vendored Brotli decoder

Google's reference Brotli implementation (RFC 7932), **decoder only**, vendored
unmodified so PatchSDK can inflate `.wasm.br` modules on every platform
(Apple and Android) without Apple's `Compression` framework.

| Field | Value |
| --- | --- |
| Upstream | https://github.com/google/brotli |
| Version | v1.2.0 |
| Commit | 028fb5a23661f123017c060daa546b55cf4bde29 |
| License | MIT (see `LICENSE`) |

## What was copied

| Upstream path | Here |
| --- | --- |
| `c/common/*.c`, `c/common/*.h` | `common/` |
| `c/dec/*.c`, `c/dec/*.h` | `dec/` |
| `c/include/brotli/{decode,port,shared_dictionary,types}.h` | `include/brotli/` |
| `LICENSE` | `LICENSE` |

Not copied: the encoder (`c/enc`, `encode.h`), tools, fuzzers, and the
`dictionary.bin*` blobs (the dictionary is compiled in from `dictionary_inc.h`).

## Updating

```sh
git clone --depth 1 --branch <tag> https://github.com/google/brotli.git /tmp/brotli
D=Sources/CBrotliDec
rm -rf $D/common $D/dec $D/include
mkdir -p $D/common $D/dec $D/include/brotli
cp /tmp/brotli/c/common/*.c /tmp/brotli/c/common/*.h $D/common/
cp /tmp/brotli/c/dec/*.c /tmp/brotli/c/dec/*.h $D/dec/
cp /tmp/brotli/c/include/brotli/{decode,port,shared_dictionary,types}.h $D/include/brotli/
cp /tmp/brotli/LICENSE $D/LICENSE
```

Then update the version and commit in the table above. Do not edit the
vendored sources by hand.
