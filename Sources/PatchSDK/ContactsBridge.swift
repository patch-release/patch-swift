import Foundation
import WasmKit
#if canImport(Contacts)
import Contacts
#endif

// MARK: - ContactsBridge (Contacts framework)
//
// Lets an OTA patch add a contact to, and read the size of, the device address
// book through the native Contacts framework (`CNContactStore`). There are two
// host functions, both under module "patch":
//
//   * contact_add(ptr,len) -> i32
//       arg = JSON `{"given":"Ada","family":"Lovelace",
//                    "phone":"+15551234567","email":"ada@example.com"}`
//       (every field optional, but at least a given OR family name is required).
//       Parsed into a `ContactSpec`; the spec is handed to an injected `add`
//       closure that performs the real `CNContactStore` save. Returns 1 on
//       success, 0 on failure (bad JSON, no name, permission denied, save error).
//   * contacts_count() -> i32
//       Returns the number of contacts in the address book (0 if access is
//       denied or the count cannot be determined).
//
// Cross-platform core + injected dependency (guide Rule 2): the bridge stores
// two `@Sendable` closures so the whole struct + its `register(...)` marshalling
// compiles + unit-tests on macOS (Contacts entitlements/permission flows are
// device territory). Tests inject spies and assert the registered host functions
// decode args and invoke the injected dependencies with the right values. The
// convenience `init()` (guarded by `#if canImport(Contacts)`) wires the real
// `CNContactStore` / `CNMutableContact` implementation.
//
// Mirrors `AnalyticsBridge` (a `static func parse(_:)` for the pure JSON decode,
// unit-tested directly) and `BiometricsBridge` (i32-returning dispatch driven by
// an inline wasm fixture, with the native capability injected as closures).

/// The structured contact the guest asks to add. Every field is optional, but a
/// spec with no name at all is rejected by `parse` (returns nil), so a valid
/// `ContactSpec` always carries at least a `given` or `family` name.
public struct ContactSpec: Sendable, Equatable {
    public let given: String?
    public let family: String?
    public let phone: String?
    public let email: String?

    public init(given: String? = nil, family: String? = nil,
                phone: String? = nil, email: String? = nil) {
        self.given = given
        self.family = family
        self.phone = phone
        self.email = email
    }
}

public struct ContactsBridge: Bridge {
    /// Inject the real "save this contact" capability. Returns true on a
    /// successful save, false otherwise. Tests inject a spy.
    public typealias Add = @Sendable (_ spec: ContactSpec) -> Bool
    /// Inject the real "how many contacts are there" capability. Returns 0 when
    /// access is denied / unavailable.
    public typealias Count = @Sendable () -> Int32

    public let module = "patch"
    private let add: Add
    private let count: Count

    /// Cross-platform designated init — tests inject spies for both capabilities;
    /// apps can inject any custom backing store.
    public init(add: @escaping Add, count: @escaping Count) {
        self.add = add
        self.count = count
    }

    #if canImport(Contacts)
    /// Convenience default init that wires the real Contacts framework:
    /// `CNContactStore` for counting + saving, `CNMutableContact` to build the
    /// new contact. Available wherever the Contacts framework imports.
    public init() {
        self.init(
            add: { spec in ContactsBridge.addNative(spec) },
            count: { ContactsBridge.countNative() })
    }
    #endif

    /// Parse the `contact_add` JSON payload into a `ContactSpec`.
    ///
    /// Exposed as a `static func` (mirroring `AnalyticsBridge.parseTrack`) so the
    /// pure decode is unit-tested directly without a wasm instance. The registered
    /// host function calls exactly this.
    ///
    /// - Each field is read as a String; missing or non-String values become nil.
    /// - Empty strings are treated as absent (so `{"given":""}` has no name).
    /// - Returns nil when the bytes aren't a JSON object OR when NO name (neither
    ///   `given` nor `family`) is present — a contact must have a name to add.
    public static func parse(_ bytes: [UInt8]) -> ContactSpec? {
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else {
            return nil
        }
        // Non-empty String value, else nil.
        func field(_ key: String) -> String? {
            guard let s = obj[key] as? String, !s.isEmpty else { return nil }
            return s
        }
        let given = field("given")
        let family = field("family")
        // Require at least a name component.
        guard given != nil || family != nil else { return nil }
        return ContactSpec(given: given, family: family,
                           phone: field("phone"), email: field("email"))
    }

    public func register(into imports: inout Imports, store: Store) {
        let add = self.add
        let count = self.count
        // contact_add(ptr,len) -> i32 : 1 on success, 0 on failure.
        imports.host(module, "contact_add", [.i32, .i32], [.i32], store: store) { caller, args in
            let ctx = BridgeContext(caller: caller)
            let bytes = try ctx.readBytes(ptr: args[0].i32, len: args[1].i32)
            guard let spec = Self.parse(bytes) else { return [.i32(0)] }
            return [.i32(add(spec) ? 1 : 0)]
        }
        // contacts_count() -> i32 : number of contacts (0 if denied/unavailable).
        imports.host(module, "contacts_count", [], [.i32], store: store) { _, _ in
            [.i32(UInt32(bitPattern: count()))]
        }
    }

    #if canImport(Contacts)
    /// Real `CNContactStore` save. Builds a `CNMutableContact` from the spec and
    /// saves it via a `CNSaveRequest`. Returns false on any failure (permission
    /// denied, save error). Synchronous to match the guest's blocking call shape.
    static func addNative(_ spec: ContactSpec) -> Bool {
        let store = CNContactStore()
        let contact = CNMutableContact()
        if let given = spec.given { contact.givenName = given }
        if let family = spec.family { contact.familyName = family }
        if let phone = spec.phone {
            contact.phoneNumbers = [
                CNLabeledValue(label: CNLabelPhoneNumberMobile,
                               value: CNPhoneNumber(stringValue: phone))
            ]
        }
        if let email = spec.email {
            contact.emailAddresses = [
                CNLabeledValue(label: CNLabelHome, value: email as NSString)
            ]
        }
        let request = CNSaveRequest()
        request.add(contact, toContainerWithIdentifier: nil)
        do {
            try store.execute(request)
            return true
        } catch {
            return false
        }
    }

    /// Real address-book size. Enumerates contacts (requesting only the identifier
    /// key, the cheapest fetch) and counts them. Returns 0 if access is denied or
    /// enumeration fails.
    static func countNative() -> Int32 {
        let store = CNContactStore()
        let request = CNContactFetchRequest(keysToFetch: [CNContactIdentifierKey as CNKeyDescriptor])
        var total = 0
        do {
            try store.enumerateContacts(with: request) { _, _ in total += 1 }
        } catch {
            return 0
        }
        return Int32(clamping: total)
    }
    #endif
}
