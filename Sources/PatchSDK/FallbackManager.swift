import Foundation

/// The graceful-degradation chain: **current → previous → bundled → disabled**.
///
/// This is the SDK's core safety mechanism. If an activated OTA module traps,
/// fails verification, or fails to instantiate, the manager walks down the chain
/// trying the next slot until one activates — or, if none do, lands in
/// **disabled** (run no OTA module; the native shell keeps working). It never
/// crashes the host app.
///
/// Each rung is validated by *actually activating* it (instantiating the WASM
/// instance) — instantiation failures and `_initialize` traps surface there, so
/// a module that can't even load is rejected before it becomes "current".
/// Optional `probe` lets the caller additionally smoke-test an exported function
/// (e.g. call a known entry once) to catch run-time traps a bad patch introduces.
public final class FallbackManager: @unchecked Sendable {

    /// Which slot is currently active after the chain settles.
    public enum State: Equatable, Sendable {
        case current(version: String)
        case previous(version: String)
        case bundled(version: String)
        /// No OTA module active; native shell only.
        case disabled
    }

    /// One step the manager took, for diagnostics + telemetry.
    public struct Step: Equatable, Sendable {
        public enum Slot: String, Sendable { case current, previous, bundled, disabled }
        public let slot: Slot
        public let version: String?
        public let succeeded: Bool
        public let error: String?
    }

    private let storage: ModuleStorage
    /// Activation closure (inject `Patch.activate` in production; a stub in
    /// tests). Throwing means "this slot is unusable" → try the next rung.
    private let activate: ([UInt8]) throws -> Void
    /// Deactivation closure (drop any active module; used to reach "disabled").
    private let deactivate: () -> Void
    /// Optional post-activation smoke test; throwing rejects the slot.
    private let probe: (() throws -> Void)?

    private let lock = NSLock()
    private var _state: State = .disabled
    private var _trail: [Step] = []

    public init(
        storage: ModuleStorage,
        activate: @escaping ([UInt8]) throws -> Void,
        deactivate: @escaping () -> Void,
        probe: (() throws -> Void)? = nil
    ) {
        self.storage = storage
        self.activate = activate
        self.deactivate = deactivate
        self.probe = probe
    }

    public var state: State { lock.lock(); defer { lock.unlock() }; return _state }
    /// The ordered list of attempts from the last `recover`/`activateBest` call.
    public var trail: [Step] { lock.lock(); defer { lock.unlock() }; return _trail }

    // MARK: - Driving the chain

    /// Activate the best available slot, starting at `from`. Walks
    /// current → previous → bundled → disabled, attempting each until one
    /// activates (and passes `probe`, if set). Returns the settled state.
    @discardableResult
    public func activateBest(from start: Step.Slot = .current) -> State {
        lock.lock(); defer { lock.unlock() }
        _trail = []
        let order: [Step.Slot] = [.current, .previous, .bundled]
        let startIndex = order.firstIndex(of: start) ?? 0

        for slot in order[startIndex...] {
            if let settled = tryActivateLocked(slot) {
                _state = settled
                return settled
            }
        }
        // Nothing worked → disabled (native only).
        deactivate()
        _trail.append(Step(slot: .disabled, version: nil, succeeded: true, error: nil))
        _state = .disabled
        return .disabled
    }

    /// Recover after the *current* slot was found bad: demote it and try the
    /// next rung down (previous → bundled → disabled). Mutates storage so the
    /// bad current is dropped/replaced.
    @discardableResult
    public func recoverFromBadCurrent() -> State {
        lock.lock(); defer { lock.unlock() }
        _trail = []
        _trail.append(Step(slot: .current, version: storage.currentVersion,
                           succeeded: false, error: "current rejected; recovering"))

        // Promote previous → current (if any) and try it; otherwise bundled.
        if storage.previousVersion != nil {
            if let bytes = try? storage.promotePreviousToCurrent() {
                if activateAndProbe(bytes) {
                    let v = storage.currentVersion ?? "?"
                    _trail.append(Step(slot: .previous, version: v, succeeded: true, error: nil))
                    _state = .previous(version: v)
                    return _state
                } else {
                    _trail.append(Step(slot: .previous, version: storage.currentVersion,
                                       succeeded: false, error: "previous also failed"))
                    storage.clearCurrent()
                }
            }
        }
        // Bundled.
        if let settled = tryActivateLocked(.bundled) {
            _state = settled
            return settled
        }
        deactivate()
        _trail.append(Step(slot: .disabled, version: nil, succeeded: true, error: nil))
        _state = .disabled
        return .disabled
    }

    // MARK: - Internals

    /// Try one slot. Returns the settled `State` on success, or nil to continue.
    private func tryActivateLocked(_ slot: Step.Slot) -> State? {
        switch slot {
        case .current:
            guard let v = storage.currentVersion, let bytes = try? storage.currentBytes() else {
                _trail.append(Step(slot: .current, version: nil, succeeded: false, error: "empty"))
                return nil
            }
            if activateAndProbe(bytes) {
                _trail.append(Step(slot: .current, version: v, succeeded: true, error: nil))
                return .current(version: v)
            }
            _trail.append(Step(slot: .current, version: v, succeeded: false, error: "activation/probe failed"))
            storage.clearCurrent()
            return nil

        case .previous:
            guard storage.previousVersion != nil, let bytes = try? storage.previousBytes() else {
                _trail.append(Step(slot: .previous, version: nil, succeeded: false, error: "empty"))
                return nil
            }
            if activateAndProbe(bytes) {
                // Promote it into the current slot so it persists across launches.
                let v = storage.previousVersion ?? "?"
                _ = try? storage.promotePreviousToCurrent()
                _trail.append(Step(slot: .previous, version: v, succeeded: true, error: nil))
                return .previous(version: v)
            }
            _trail.append(Step(slot: .previous, version: storage.previousVersion,
                               succeeded: false, error: "activation/probe failed"))
            return nil

        case .bundled:
            guard storage.hasBundled, let bytes = try? storage.bundledBytes() else {
                _trail.append(Step(slot: .bundled, version: nil, succeeded: false, error: "empty"))
                return nil
            }
            if activateAndProbe(bytes) {
                let v = storage.bundledVersion() ?? "bundled"
                _trail.append(Step(slot: .bundled, version: v, succeeded: true, error: nil))
                return .bundled(version: v)
            }
            _trail.append(Step(slot: .bundled, version: storage.bundledVersion(),
                               succeeded: false, error: "activation/probe failed"))
            return nil

        case .disabled:
            return .disabled
        }
    }

    private func activateAndProbe(_ bytes: [UInt8]) -> Bool {
        do {
            try activate(bytes)
            if let probe { try probe() }
            return true
        } catch {
            return false
        }
    }
}
