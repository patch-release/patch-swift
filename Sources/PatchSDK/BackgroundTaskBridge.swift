import Foundation
import WasmKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: - BackgroundTaskBridge (begin/end a background task)
//
// Lets an OTA patch request a short window of background execution time when the
// app is backgrounded, mirroring `UIApplication.beginBackgroundTask` /
// `endBackgroundTask`. Two host functions:
//
//   * `begin_background_task(ptr,len) -> i32` — begin a task with the given UTF-8
//     name; returns an opaque task token (a positive i32 handle) the guest later
//     passes to `end_background_task`. Returns 0 if the platform refused / no
//     time is available (the iOS `.invalid` identifier).
//   * `end_background_task(i32) -> []` — end the task with the given token;
//     fire-and-forget. A 0 / unknown token is ignored.
//
// The token is a flat scalar (the flat-scalar ABI, like AppBadgeBridge), so the
// only memory marshalling is reading the task name string on `begin`.
//
// ## Cross-platform core + injected dependencies (Rule 2)
// `UIBackgroundTaskIdentifier` and `UIApplication` are UIKit-only, so the native
// capability is injected as two `@Sendable` closures: a `begin` taking the name
// and returning an Int32 token, and an `end` taking the token. The bridge struct
// + its `register(...)` therefore compile on macOS (no direct UIKit at the top
// level); tests inject spies backed by an in-memory token counter and assert the
// begin/end round-trip. The convenience `init()` wires the real UIApplication
// background-task APIs under `#if canImport(UIKit)`, bookkeeping the mapping from
// our Int32 tokens to the opaque `UIBackgroundTaskIdentifier`s.
public struct BackgroundTaskBridge: Bridge {
    /// Begin a background task with the given name; return an opaque positive
    /// token, or 0 if no background time is available.
    public typealias Begin = @Sendable (_ name: String) -> Int32
    /// End the background task identified by the given token. Unknown / 0 ignored.
    public typealias End = @Sendable (_ token: Int32) -> Void

    public let module = "patch"
    private let begin: Begin
    private let end: End

    /// Cross-platform designated init — tests inject spies here.
    public init(begin: @escaping Begin, end: @escaping End) {
        self.begin = begin
        self.end = end
    }

    #if canImport(UIKit)
    /// Convenience default init wiring the real UIApplication background-task APIs.
    /// Because `UIBackgroundTaskIdentifier` is opaque and not representable as our
    /// guest-facing Int32, a small thread-safe registry maps each begun task to a
    /// monotonically-increasing Int32 token. Guarded by `canImport(UIKit)` so the
    /// macOS host build never references UIKit. All UIApplication calls hop to the
    /// main thread (background-task APIs are main-thread bound).
    public init() {
        let store = BackgroundTaskStore()
        self.init(
            begin: { name in store.begin(name: name) },
            end: { token in store.end(token: token) })
    }
    #endif

    public func register(into imports: inout Imports, store: Store) {
        let begin = self.begin
        let end = self.end
        // begin_background_task(ptr,len) -> i32 : decode name, begin, return token.
        imports.host(module, "begin_background_task", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let name = try ctx.readString(ptr: args[0].i32, len: args[1].i32)
            return [.i32(UInt32(bitPattern: begin(name)))]
        }
        // end_background_task(i32) -> [] : end the task with the given token.
        imports.host(module, "end_background_task", [.i32], [], store: store) { _, args in
            end(Int32(bitPattern: args[0].i32))
            return []
        }
    }
}

#if canImport(UIKit)
/// Thread-safe bridge between our guest-facing Int32 tokens and the opaque
/// `UIBackgroundTaskIdentifier`s vended by UIApplication. Begin/end calls hop to
/// the main thread because UIApplication's background-task APIs are main-thread
/// bound. A token of 0 means "no background time available" (the iOS `.invalid`
/// case) and is never handed out for a real task.
private final class BackgroundTaskStore: @unchecked Sendable {
    private let lock = NSLock()
    private var nextToken: Int32 = 1
    private var live: [Int32: UIBackgroundTaskIdentifier] = [:]

    func begin(name: String) -> Int32 {
        lock.lock()
        let token = nextToken
        nextToken &+= 1
        if nextToken <= 0 { nextToken = 1 } // wrap defensively, never to 0
        lock.unlock()

        let beginOnMain: @Sendable () -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: name) {
                // Expiration handler: end the task so the system reclaims it.
                self.end(token: token)
            }
        }
        let id = Thread.isMainThread ? beginOnMain() : DispatchQueue.main.sync { beginOnMain() }
        if id == .invalid { return 0 }
        lock.lock(); live[token] = id; lock.unlock()
        return token
    }

    func end(token: Int32) {
        guard token != 0 else { return }
        lock.lock(); let id = live.removeValue(forKey: token); lock.unlock()
        guard let id else { return }
        let endOnMain: @Sendable () -> Void = { UIApplication.shared.endBackgroundTask(id) }
        if Thread.isMainThread { endOnMain() } else { DispatchQueue.main.async { endOnMain() } }
    }
}
#endif
