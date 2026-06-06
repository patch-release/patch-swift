;; BridgeFixture — a hand-written WASM module that exercises the PatchSDK
;; bridges end-to-end: it IMPORTS host functions under the "patch" namespace and
;; exports guest functions that call them, so a test can drive a real
;; guest -> host bridge round-trip through linear memory.
;;
;; ABI:
;;   - exports `memory`
;;   - exports `patch_malloc(i32)->i32` (a trivial bump allocator) + `patch_free`
;;   - the host writes bytes into guest memory via patch_malloc; the guest reads
;;     packed (ptr<<32|len) i64 results, see Bridges.swift.
;;
;; Build:  wat2wasm fixtures-src/BridgeFixture.wat -o Tests/PatchSDKTests/Fixtures/BridgeFixture.wasm
(module
  ;; ---- Imported host functions (the bridges under test) -------------------
  (import "patch" "log"                (func $log (param i32 i32 i32)))
  (import "patch" "defaults_get"       (func $defaults_get (param i32 i32) (result i64)))
  (import "patch" "defaults_set"       (func $defaults_set (param i32 i32 i32 i32)))
  (import "patch" "now_unix_millis"    (func $now (result i64)))
  (import "patch" "locale_identifier"  (func $locale (result i64)))
  (import "patch" "json_canonicalize"  (func $json (param i32 i32) (result i64)))

  ;; ---- Linear memory + a bump allocator -----------------------------------
  (memory (export "memory") 2)            ;; 2 pages = 128 KiB
  (global $bump (mut i32) (i32.const 1024)) ;; reserve low 1KiB as scratch

  (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $bump))
    ;; 8-byte align the next allocation
    (global.set $bump
      (i32.and
        (i32.add (i32.add (global.get $bump) (local.get $n)) (i32.const 7))
        (i32.const -8)))
    (local.get $p))

  (func $patch_free (export "patch_free") (param i32))  ;; bump allocator: no-op

  ;; Write `len` bytes from a host-provided source isn't needed; instead the
  ;; test writes its input into memory via patch_malloc + Memory write, then
  ;; calls these. The guest just forwards (ptr,len) to the host import.

  ;; ---- Exported test entry points -----------------------------------------

  ;; log(level, ptr, len): forward straight to the host logging bridge.
  (func (export "call_log") (param $lvl i32) (param $ptr i32) (param $len i32)
    (call $log (local.get $lvl) (local.get $ptr) (local.get $len)))

  ;; defaults_set(kptr,klen,vptr,vlen): forward to the host.
  (func (export "call_defaults_set") (param i32 i32 i32 i32)
    (call $defaults_set (local.get 0) (local.get 1) (local.get 2) (local.get 3)))

  ;; defaults_get(kptr,klen) -> packed i64.
  (func (export "call_defaults_get") (param i32 i32) (result i64)
    (call $defaults_get (local.get 0) (local.get 1)))

  ;; now() -> i64 millis.
  (func (export "call_now") (result i64) (call $now))

  ;; locale() -> packed i64.
  (func (export "call_locale") (result i64) (call $locale))

  ;; json_canonicalize(ptr,len) -> packed i64.
  (func (export "call_json") (param i32 i32) (result i64)
    (call $json (local.get 0) (local.get 1)))
)
