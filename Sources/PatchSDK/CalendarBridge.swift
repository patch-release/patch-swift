import Foundation
import WasmKit
#if canImport(EventKit)
import EventKit
#endif

// MARK: - Calendar (EventKit) bridge
//
// Lets an OTA patch create a calendar event in the user's default calendar
// through the host app's EventKit access. EventKit (`EKEventStore` / `EKEvent` /
// `EKCalendar`) is an iOS/macOS framework guarded behind a privacy permission;
// per Rule 2 the bridge stores the capability as ONE injected closure so the
// wasm<->native marshalling + JSON parsing compile and unit-test on macOS
// without the framework, while the convenience `init()` wires the real
// EventKit write path under `#if canImport(EventKit)`.
//
// Host function (module "patch"):
//   * calendar_add_event(ptr,len) -> i32 (1 ok / 0 fail)
//       arg = JSON `{"title":"Dentist","startUnix":1700000000,
//                    "endUnix":1700003600,"notes":"bring forms"}`
//       (`notes` optional). Parsed into a `CalendarEvent` and handed to the
//       injected `addEvent` closure; its Bool result is encoded 1/0. A parse
//       failure (bad JSON / missing title / missing times) returns 0 WITHOUT
//       invoking the closure.

/// The value a parsed `calendar_add_event` payload decodes to. `startUnix` /
/// `endUnix` are Unix epoch SECONDS. `notes` is optional. `Sendable` so it can
/// cross the injected `@Sendable` closure boundary.
public struct CalendarEvent: Sendable, Equatable {
    public let title: String
    public let startUnix: Int64
    public let endUnix: Int64
    public let notes: String?

    public init(title: String, startUnix: Int64, endUnix: Int64, notes: String? = nil) {
        self.title = title
        self.startUnix = startUnix
        self.endUnix = endUnix
        self.notes = notes
    }
}

public struct CalendarBridge: Bridge {
    public let module = "patch"

    /// Persist a parsed event natively; returns true on success. Tests inject a
    /// spy; the convenience init wires the real `EKEventStore` write.
    private let addEvent: @Sendable (_ event: CalendarEvent) -> Bool

    /// Cross-platform designated init — tests inject a spy here.
    public init(addEvent: @escaping @Sendable (_ event: CalendarEvent) -> Bool) {
        self.addEvent = addEvent
    }

    #if canImport(EventKit)
    /// Convenience default init wiring the real EventKit write path: saving via
    /// `EKEventStore`/`EKEvent` to the store's default calendar.
    public init() {
        self.init(addEvent: { event in Self.writeToEventKit(event) })
    }

    /// Create + save an `EKEvent` for `event` in the store's default calendar.
    /// Returns false if there is no default calendar or the save throws (e.g.
    /// access not granted). Synchronous, mirroring the guest's synchronous call.
    static func writeToEventKit(_ event: CalendarEvent) -> Bool {
        let store = EKEventStore()
        guard let calendar = store.defaultCalendarForNewEvents else { return false }
        let ekEvent = EKEvent(eventStore: store)
        ekEvent.title = event.title
        ekEvent.startDate = Date(timeIntervalSince1970: TimeInterval(event.startUnix))
        ekEvent.endDate = Date(timeIntervalSince1970: TimeInterval(event.endUnix))
        ekEvent.notes = event.notes
        ekEvent.calendar = calendar
        do {
            try store.save(ekEvent, span: .thisEvent, commit: true)
            return true
        } catch {
            return false
        }
    }
    #endif

    /// Parse the `calendar_add_event` JSON payload into a `CalendarEvent`.
    ///
    /// Exposed as a `static func` (mirroring `AnalyticsBridge.parseTrack` /
    /// `FoundationBridge.jsonGetI64`) so the pure parsing logic is unit-tested
    /// directly without a wasm instance. The registered host function calls
    /// exactly this.
    ///
    /// Requirements (nil otherwise — caller encodes 0):
    ///   - top-level JSON object,
    ///   - non-empty String `"title"`,
    ///   - numeric `"startUnix"` AND `"endUnix"` (Unix epoch seconds).
    /// `"notes"` is optional (a String passes through; absent/non-String → nil).
    public static func parse(_ bytes: [UInt8]) -> CalendarEvent? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
              let title = obj["title"] as? String, !title.isEmpty,
              let start = obj["startUnix"] as? NSNumber,
              let end = obj["endUnix"] as? NSNumber else {
            return nil
        }
        let notes = obj["notes"] as? String
        return CalendarEvent(title: title,
                             startUnix: start.int64Value,
                             endUnix: end.int64Value,
                             notes: notes)
    }

    /// Forward a parsed event to the injected closure. Factored out of the
    /// registered host closure so the dispatch path is unit-testable with a spy
    /// (the closure and the tests run identical code).
    func dispatch(_ event: CalendarEvent) -> Bool {
        addEvent(event)
    }

    public func register(into imports: inout Imports, store: Store) {
        let bridge = self
        // calendar_add_event(ptr,len) -> i32 (1 ok / 0 fail).
        imports.host(module, "calendar_add_event", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let event = Self.parse(bytes) else { return [.i32(0)] }
            return [.i32(bridge.dispatch(event) ? 1 : 0)]
        }
    }
}
