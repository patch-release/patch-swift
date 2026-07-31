// SPDX-License-Identifier: Apache-2.0

import Foundation

/// A lightweight terminal spinner for long, otherwise-silent steps (the WASM
/// compile, toolchain install, browser-link wait). It animates on **stderr** so
/// piped stdout stays clean, and ONLY when stderr is an interactive TTY — under
/// CI / pipes it prints a single static line instead of escape sequences.
///
/// Usage:
///     let spin = Spinner("Compiling Swift → WebAssembly")
///     spin.start()
///     defer { spin.clear() }            // always clears, even on throw
///     let result = try doSlowWork()
///     spin.succeed("Compiled")          // clears + prints a ✓ line
/// `@unchecked Sendable`: every piece of mutable state below is guarded by `lock`,
/// which is what makes the animation `Thread`'s capture of `self` safe. Swift 6
/// can't prove that on its own, so the conformance is asserted explicitly — the
/// same pattern the SDK's lock-guarded bridges use.
final class Spinner: @unchecked Sendable {
    private static let frames = ["⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏"]
    private let label: String
    private let interactive: Bool
    private let lock = NSLock()
    private var spinning = false
    private var thread: Thread?

    init(_ label: String) {
        self.label = label
        self.interactive = isatty(fileno(stderr)) != 0
    }

    /// Convenience: show the spinner while `body` runs, ALWAYS clearing the line
    /// afterward (even on throw), then return `body`'s result. Use this for a long,
    /// otherwise-silent step that prints its OWN output next — the spinner is purely
    /// a "working…" indicator. It animates on **stderr** only (a single static line
    /// under CI / pipes), so stdout (incl. `--json`) is never touched and the caller's
    /// output follows on a clean line.
    ///
    ///     let snapshot = Spinner.run("Computing native-shell fingerprint") {
    ///         FingerprintCommand.computeSnapshot(config: config, root: root)
    ///     }
    @discardableResult
    static func run<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        let spin = Spinner(label)
        spin.start()
        defer { spin.clear() }
        return try body()
    }

    func start() {
        guard interactive else {
            err("• \(label)…\n")
            return
        }
        lock.lock(); spinning = true; lock.unlock()
        let t = Thread { [label] in
            var i = 0
            while true {
                self.lock.lock(); let go = self.spinning; self.lock.unlock()
                if !go { break }
                let frame = Spinner.frames[i % Spinner.frames.count]
                self.err("\r\u{1B}[36m\(frame)\u{1B}[0m \(label)…")
                i += 1
                Thread.sleep(forTimeInterval: 0.08)
            }
        }
        t.start()
        lock.lock(); thread = t; lock.unlock()
    }

    /// Stop + clear the spinner line (caller prints its own output next).
    func clear() { stop(clearLine: true) }

    /// Stop, clear, and print a green ✓ confirmation line to stdout.
    func succeed(_ done: String) {
        stop(clearLine: true)
        print("\u{1B}[32m✓\u{1B}[0m \(done)")
    }

    /// Stop, clear, and print a red ✗ line to stderr.
    func fail(_ message: String) {
        stop(clearLine: true)
        err("\u{1B}[31m✗\u{1B}[0m \(message)\n")
    }

    private func stop(clearLine: Bool) {
        lock.lock()
        let wasSpinning = spinning
        spinning = false
        thread = nil
        lock.unlock()
        // Give the animation thread a tick to exit before we overwrite the line.
        if interactive && wasSpinning {
            Thread.sleep(forTimeInterval: 0.09)
            if clearLine { err("\r\u{1B}[2K") }  // carriage return + clear whole line
        }
    }

    private func err(_ s: String) {
        FileHandle.standardError.write(Data(s.utf8))
    }
}
