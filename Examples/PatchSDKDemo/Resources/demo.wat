;; demo.wat — a tiny, self-contained WebAssembly module for the PatchSDKDemo app.
;;
;; It needs no WASI imports and no host (`patch.*`) bridges, so it instantiates
;; cleanly on a stock `WASMRuntime` and runs identically on the iOS Simulator and
;; macOS. It exercises three things the demo UI shows:
;;
;;   1. a plain scalar export:  add(i32,i32) -> i32
;;   2. a recursive/heavier compute export: fib(i32) -> i64
;;   3. the Patch v0 (ptr,len) string ABI: reverse(ptr,len) -> packed i64
;;      (writes the reversed bytes back into guest memory via a bump allocator
;;       and returns (outPtr << 32) | outLen, exactly the packed-i64 convention
;;       Bridges.swift / the marshalling layer use).
;;
;; Build:
;;   wat2wasm Examples/PatchSDKDemo/Resources/demo.wat \
;;     -o Examples/PatchSDKDemo/Resources/demo.wasm
(module
  ;; 4 pages = 256 KiB of linear memory, exported as `memory`.
  (memory (export "memory") 4)

  ;; Bump allocator. Low 64 KiB is reserved as scratch the host can write into;
  ;; allocations start at 65536 and grow upward, 8-byte aligned.
  (global $bump (mut i32) (i32.const 65536))

  (func $patch_malloc (export "patch_malloc") (param $n i32) (result i32)
    (local $p i32)
    (local.set $p (global.get $bump))
    (global.set $bump
      (i32.and
        (i32.add (i32.add (global.get $bump) (local.get $n)) (i32.const 7))
        (i32.const -8)))
    (local.get $p))

  ;; Bump allocator never frees individually; no-op.
  (func $patch_free (export "patch_free") (param i32))

  ;; add(a,b) -> a+b
  (func (export "add") (param $a i32) (param $b i32) (result i32)
    (i32.add (local.get $a) (local.get $b)))

  ;; fib(n) -> nth Fibonacci number (iterative, i64 to avoid overflow up to ~90).
  (func (export "fib") (param $n i32) (result i64)
    (local $a i64) (local $b i64) (local $t i64) (local $i i32)
    (local.set $a (i64.const 0))
    (local.set $b (i64.const 1))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $n)))
        (local.set $t (i64.add (local.get $a) (local.get $b)))
        (local.set $a (local.get $b))
        (local.set $b (local.get $t))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    (local.get $a))

  ;; reverse(ptr,len) -> packed (outPtr<<32)|outLen.
  ;; Reverses the `len` bytes at `ptr`, writing them to a freshly allocated
  ;; buffer, and returns the packed pointer/length of that buffer.
  (func (export "reverse") (param $ptr i32) (param $len i32) (result i64)
    (local $out i32) (local $i i32) (local $b i32)
    (local.set $out (call $patch_malloc (local.get $len)))
    (local.set $i (i32.const 0))
    (block $done
      (loop $loop
        (br_if $done (i32.ge_s (local.get $i) (local.get $len)))
        ;; b = mem[ptr + (len-1-i)]
        (local.set $b
          (i32.load8_u
            (i32.add (local.get $ptr)
                     (i32.sub (i32.sub (local.get $len) (i32.const 1))
                              (local.get $i)))))
        ;; mem[out + i] = b
        (i32.store8 (i32.add (local.get $out) (local.get $i)) (local.get $b))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $loop)))
    ;; pack (out << 32) | len
    (i64.or
      (i64.shl (i64.extend_i32_u (local.get $out)) (i64.const 32))
      (i64.extend_i32_u (local.get $len)))))
