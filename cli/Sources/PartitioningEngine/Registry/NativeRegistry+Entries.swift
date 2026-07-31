// SPDX-License-Identifier: Apache-2.0

import Foundation

// MARK: - Standard native symbol entries (Agent A2)
//
// Day-2 re-tiering. Every entry carries a `SymbolTier`:
//
//   .mustStayNative     — safety-critical; forces the function `native`.
//                         Over-inclusion here is always safe (only costs OTA%).
//   .bridgeable         — a host bridge exists/planned; the function can run OTA
//                         via Patch.call(...) → classified `bridged`.
//   .wasmSafeFoundation — Foundation value types proven to compile to WASM under
//                         the full SDK (Day-1 finding). NOT native; registered
//                         only so the classifier recognises them as eligible.
//
// COVERAGE > SIZE (Day-2 decision): the full WASM SDK ships Foundation, so the
// big block of Foundation value types that Day-1 implicitly left as
// "unknown-but-capitalised → native-ish" are reclassified .wasmSafeFoundation.
// Networking / logging / prefs / notifications / keychain move to .bridgeable.

extension NativeRegistry {
    public static let standardEntries: [NativeSymbol] = {
        var e: [NativeSymbol] = []

        func add(_ tier: SymbolTier, _ category: NativeCategory, _ reason: String, _ symbols: [String]) {
            for s in symbols {
                e.append(NativeSymbol(symbol: s, category: category, reason: reason, tier: tier))
            }
        }

        // =====================================================================
        // TIER 1 — mustStayNative (force native; zero false negatives)
        // =====================================================================

        // MARK: UIKit / SwiftUI
        add(.mustStayNative, .uiKitSwiftUI, "UI rendering / view hierarchy", [
            "UIView", "UIViewController", "UILabel", "UIButton", "UIImageView", "UITextField",
            "UITextView", "UIScrollView", "UITableView", "UITableViewCell", "UICollectionView",
            "UICollectionViewCell", "UIStackView", "UINavigationController", "UITabBarController",
            "UIWindow", "UIWindowScene", "UIControl", "UIGestureRecognizer", "UITapGestureRecognizer",
            "UIPanGestureRecognizer", "UISwipeGestureRecognizer", "UIColor", "UIFont", "UIImage",
            "UIBezierPath", "UIGraphicsImageRenderer", "UIResponder", "UIStoryboard", "UINib",
            "UIAlertController", "UIActivityViewController", "UIRefreshControl", "UIPageViewController",
            "UISlider", "UISwitch", "UIStepper", "UISegmentedControl", "UIProgressView",
            "UIActivityIndicatorView", "UIDatePicker", "UIPickerView", "UISearchBar", "UIToolbar",
            "UIBarButtonItem", "UIMenu", "UIAction", "UIContextMenuConfiguration", "UIHostingController",
            "UIViewRepresentable", "UIViewControllerRepresentable",
        ])
        add(.mustStayNative, .uiKitSwiftUI, "SwiftUI view / layout", [
            "View", "Text", "Image", "Button", "VStack", "HStack", "ZStack", "List", "ScrollView",
            "NavigationStack", "NavigationView", "NavigationLink", "TabView", "Form", "Section",
            "LazyVStack", "LazyHStack", "LazyVGrid", "LazyHGrid", "Grid", "GridRow", "Spacer",
            "Divider", "Group", "GeometryReader", "Color", "Font", "TextField", "SecureField",
            "Toggle", "Slider", "Stepper", "Picker", "DatePicker", "ColorPicker", "ProgressView",
            "Label", "Link", "Menu", "Gauge", "Canvas", "TimelineView", "AsyncImage", "EmptyView",
            "AnyView", "Shape", "Path", "Rectangle", "RoundedRectangle", "Circle", "Ellipse",
            "Capsule", "Alert", "ActionSheet", "Sheet", "Scene", "WindowGroup", "App", "Commands",
            "ToolbarItem", "ToolbarItemGroup", "ViewModifier", "PreviewProvider", "ViewBuilder",
            "SceneBuilder", "TableColumn", "Table", "DisclosureGroup", "OutlineGroup", "ControlGroup",
        ])
        add(.mustStayNative, .uiKitSwiftUI, "SwiftUI property wrapper / state", [
            "State", "Binding", "StateObject", "ObservedObject", "EnvironmentObject", "Environment",
            "FetchRequest", "SectionedFetchRequest", "AppStorage", "SceneStorage", "FocusState",
            "GestureState", "Namespace", "ScaledMetric", "Bindable", "Observable", "Published",
            "Query", "Model",
        ])
        add(.mustStayNative, .uiKitSwiftUI, "AppKit (macOS UI)", [
            "NSView", "NSViewController", "NSWindow", "NSWindowController", "NSButton", "NSTextField",
            "NSImageView", "NSTableView", "NSCollectionView", "NSStackView", "NSColor", "NSFont",
            "NSImage", "NSBezierPath", "NSMenu", "NSMenuItem", "NSApplication", "NSResponder",
            "NSViewRepresentable",
        ])

        // MARK: System Frameworks (hardware / OS services) — all native
        add(.mustStayNative, .systemFrameworks, "Audio/video hardware (AVFoundation)", [
            "AVAudioPlayer", "AVAudioRecorder", "AVAudioSession", "AVAudioEngine", "AVPlayer",
            "AVPlayerItem", "AVQueuePlayer", "AVCaptureSession", "AVCaptureDevice", "AVCaptureInput",
            "AVCaptureOutput", "AVCaptureVideoPreviewLayer", "AVAsset", "AVAssetExportSession",
            "AVSpeechSynthesizer", "AVSpeechUtterance", "AVMetadataObject", "AVCaptureMetadataOutput",
        ])
        add(.mustStayNative, .systemFrameworks, "Health data (HealthKit)", [
            "HKHealthStore", "HKQuery", "HKSampleQuery", "HKStatisticsQuery", "HKObserverQuery",
            "HKQuantityType", "HKCategoryType", "HKWorkout", "HKQuantitySample", "HKCategorySample",
            "HKUnit", "HKQuantity",
        ])
        add(.mustStayNative, .systemFrameworks, "Bluetooth (CoreBluetooth)", [
            "CBCentralManager", "CBPeripheralManager", "CBPeripheral", "CBCentral", "CBService",
            "CBCharacteristic", "CBDescriptor", "CBUUID", "CBMutableService", "CBMutableCharacteristic",
        ])
        add(.mustStayNative, .systemFrameworks, "Motion sensors (CoreMotion)", [
            "CMMotionManager", "CMAltimeter", "CMPedometer", "CMMotionActivityManager", "CMHeadphoneMotionManager",
            "CMDeviceMotion", "CMAccelerometerData", "CMGyroData", "CMMagnetometerData", "CMAttitude",
        ])
        // In-app purchase (StoreKit). The legacy `SK*` surface (`SKPaymentQueue`,
        // `SKProductsRequest`, …) is a delegate-driven request/transaction-observer
        // pattern with no by-value bridge → stays native. The MODERN StoreKit 2 value
        // surface (`Product` / `Transaction` / `AppStore` / `PurchaseResult`) is the
        // survey's #1 registry-flip win (§5/§6): StoreKit is LINKED IN EVERY app that
        // sells anything, and these are value-ish types the generalized "call what's
        // already linked" host bridge (Lever #2) resolves via the build-time resolver
        // thunk — a `.bridgeable` StoreKit-2 function routes through `patch_host.call`
        // to the real linked symbol. DEMOTE-SAFE: the generic bridge's classifier only
        // routes the by-value/handle-marshallable, closure-free subset; the rest still
        // demotes (the 3-layer fail-closed net + the thunk compiles-or-demote net). The
        // legacy `SK*` group below stays `.mustStayNative` (the delegate-observer wall).
        add(.bridgeable, .systemFrameworks, "StoreKit 2 value surface via host bridge (survey #21 — linked everywhere)", [
            "Product", "Transaction", "AppStore", "PurchaseResult",
        ])
        add(.mustStayNative, .systemFrameworks, "In-app purchase (legacy StoreKit — delegate/observer)", [
            "SKProduct", "SKPayment", "SKPaymentQueue", "SKPaymentTransaction", "SKProductsRequest",
            "SKStoreReviewController", "StoreKit",
        ])
        add(.mustStayNative, .systemFrameworks, "Push tokens (PushKit)", [
            "PKPushRegistry", "PKPushCredentials", "PKPushPayload",
        ])
        add(.mustStayNative, .systemFrameworks, "Cloud sync (CloudKit)", [
            "CKContainer", "CKDatabase", "CKRecord", "CKQuery", "CKRecordZone", "CKSubscription",
            "CKModifyRecordsOperation", "CKFetchRecordsOperation", "CKShare", "CKAsset",
        ])
        add(.mustStayNative, .systemFrameworks, "Contacts / Calendar store / Photos", [
            "CNContactStore", "CNContact", "CNMutableContact", "EKEventStore", "EKEvent", "EKReminder",
            "EKCalendar", "PHPhotoLibrary", "PHAsset", "PHImageManager", "PHFetchResult", "PHPickerViewController",
        ])
        add(.mustStayNative, .systemFrameworks, "Machine learning (CoreML/Vision)", [
            "MLModel", "VNRequest", "VNImageRequestHandler", "VNCoreMLRequest", "VNDetectFaceRectanglesRequest",
            "CMSampleBuffer",
        ])
        add(.mustStayNative, .systemFrameworks, "Watch connectivity", [
            "WCSession", "WCSessionDelegate",
        ])

        // MARK: Sensors & Location — all native
        add(.mustStayNative, .sensorsLocation, "Location hardware (CoreLocation)", [
            "CLLocationManager", "CLLocation", "CLGeocoder", "CLPlacemark", "CLRegion", "CLCircularRegion",
            "CLBeaconRegion", "CLBeacon", "CLLocationCoordinate2D", "CLHeading", "CLVisit",
        ])
        add(.mustStayNative, .sensorsLocation, "Maps (MapKit)", [
            "MKMapView", "MKAnnotation", "MKPointAnnotation", "MKPolyline", "MKPolygon", "MKDirections",
            "MKLocalSearch", "MKMapItem", "Map", "MapAnnotation", "Marker", "MapPolyline",
        ])
        add(.mustStayNative, .sensorsLocation, "AR (ARKit/RealityKit)", [
            "ARSession", "ARWorldTrackingConfiguration", "ARSCNView", "ARView", "RealityView", "Entity",
            "ModelEntity", "AnchorEntity",
        ])

        // MARK: Storage — FILE SYSTEM / DB.
        // FileManager (read-only subset) + Bundle are re-tiered .bridgeable by
        // breakthrough #8 (host-ABI bridge family; see TIER 2 below). FileHandle
        // (streaming), DirectoryEnumerator, FileWrapper have no safe value-bridge →
        // stay native. The FileManager WRITE/mutating member CALLS are registered as
        // mustStayNative member symbols (TIER 1 guard below) so a function that
        // writes/deletes files keeps a forced-native hit and is NOT mis-promoted.
        add(.mustStayNative, .storage, "File streaming / wrappers (no value-bridge)", [
            "FileHandle", "DirectoryEnumerator", "FileWrapper",
        ])
        // FileManager WRITE / mutating member calls — these have no safe read-only
        // value-bridge (a write changes the native-shell fingerprint / risks data
        // loss on a bad OTA, per breakthrough #8 limit #1). Registering the member
        // CALL NAMES as mustStayNative means a function that writes/deletes/moves
        // files matches here on `reference.name` and stays native even though the
        // `FileManager` TYPE is now .bridgeable for the read-only case.
        add(.mustStayNative, .storage, "FileManager write / mutating ops (native only)", [
            "removeItem", "createFile", "createDirectory", "copyItem", "moveItem",
            "replaceItem", "replaceItemAt", "linkItem", "setAttributes",
            "removeItemAt", "copyItemAt", "moveItemAt", "createDirectoryAt",
            "trashItem", "unmountVolume", "writeToFile",
        ])
        add(.mustStayNative, .storage, "Object database (CoreData)", [
            "NSManagedObject", "NSManagedObjectContext", "NSPersistentContainer",
            "NSPersistentStoreCoordinator", "NSManagedObjectModel", "NSFetchRequest", "NSEntityDescription",
            "NSFetchedResultsController", "NSPersistentStore",
            "NSBatchInsertRequest", "NSBatchDeleteRequest",
        ])
        add(.mustStayNative, .storage, "Object database (SwiftData)", [
            "ModelContainer", "ModelContext", "PersistentModel", "Schema", "FetchDescriptor",
            "ModelConfiguration",
        ])
        add(.mustStayNative, .storage, "Key-value databases / raw SQL", [
            "NSUbiquitousKeyValueStore", "SQLite", "OpaquePointer",
        ])

        // MARK: App lifecycle — all native
        add(.mustStayNative, .appLifecycle, "App / scene lifecycle", [
            "UIApplication", "UIApplicationDelegate", "UIScene", "UISceneDelegate", "UIWindowSceneDelegate",
            "AppDelegate", "SceneDelegate", "NSApplicationDelegate", "UIBackgroundTaskIdentifier",
            "BGTaskScheduler", "BGAppRefreshTask", "BGProcessingTask", "UIApplicationShortcutItem",
            // ProcessInfo (env / OS-version reads) is re-tiered .bridgeable by
            // breakthrough #8 (TIER 2 below). `Process` (subprocess spawn) has no
            // safe value-bridge → stays native.
            "Process",
        ])

        // MARK: Concurrency primitives / OS threads & locks — all native
        add(.mustStayNative, .concurrency, "OS threads / locks", [
            "DispatchQueue", "DispatchGroup", "DispatchSemaphore", "DispatchWorkItem", "DispatchSource",
            "DispatchTime", "DispatchQoS", "OperationQueue", "Operation", "BlockOperation",
            "NSLock", "NSRecursiveLock", "NSCondition", "NSConditionLock", "os_unfair_lock",
            "os_unfair_lock_t", "Thread", "pthread_mutex_t", "pthread_t", "RunLoop", "Timer",
            "CADisplayLink", "NSObjectProtocol", "DispatchIO", "OSAllocatedUnfairLock", "Mutex",
        ])
        // OS-lock C FUNCTIONS (not just the lock TYPE). Previously only the
        // `os_unfair_lock`/`os_unfair_lock_t` TYPE names were registered, so a
        // helper that took a pre-allocated `os_unfair_lock_t` and only *called*
        // `os_unfair_lock_lock(lock)` (a free C function, name not in the registry)
        // slipped through as wasmEligible — a latent false negative (e.g.
        // Nuke's `withNonisolatedStateLock`). Registering the call names closes it.
        // These are genuine OS locking primitives with no WASM equivalent.
        add(.mustStayNative, .concurrency, "OS unfair-lock C calls", [
            "os_unfair_lock_lock", "os_unfair_lock_unlock", "os_unfair_lock_trylock",
            "os_unfair_lock_assert_owner", "os_unfair_lock_assert_not_owner",
            "pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_init",
            "pthread_mutex_trylock", "pthread_mutex_destroy",
            "pthread_rwlock_rdlock", "pthread_rwlock_wrlock", "pthread_rwlock_unlock",
            "pthread_cond_wait", "pthread_cond_signal", "pthread_cond_broadcast",
        ])
        // `recv.withLock { … }` / `withLockUnchecked` are the standard Swift lock
        // APIs (`OSAllocatedUnfairLock`, `Mutex`, NSLock-style wrappers). The lock
        // type lives on the owning property, so it is invisible inside a method
        // body that only writes `someLock.withLock { … }` — the registry scan never
        // sees the lock TYPE there. Registering the CALL name catches it directly.
        // Verified across the corpus: every `withLock` is a lock primitive (no pure
        // collision), so this is safe. A registered call-name match is suppressed
        // only for project TYPE shadows, never for a method name, so it always fires.
        add(.mustStayNative, .concurrency, "Swift lock withLock(…) call", [
            "withLock", "withLockUnchecked", "withLockIfAvailable",
        ])

        // MARK: ObjC interop — all native (runtime / dynamic dispatch)
        add(.mustStayNative, .objcInterop, "ObjC runtime / dynamic dispatch", [
            "NSObject", "NSObjectProtocol", "NSProxy", "objc_getClass", "objc_msgSend",
            "class_getInstanceMethod", "method_exchangeImplementations", "Selector", "IMP",
            "NSInvocation", "NSMethodSignature", "NSKeyValueObservation", "NSKeyValueCoding",
            "objc", "dynamic", "IBAction", "IBOutlet", "IBInspectable", "NSManaged",
            // `autoreleasepool { … }` is an ObjC-runtime construct (drains the
            // autorelease pool); no WASM/Embedded equivalent. Previously unregistered,
            // so a function whose only native touch was `autoreleasepool` slipped
            // through (e.g. NetNewsWire's `_runInDatabase`). Registering it closes
            // that gap — a genuine zero-false-negative hardening.
            "autoreleasepool",
        ])

        // MARK: C interop — all native (raw memory / unsafe pointers)
        add(.mustStayNative, .cInterop, "Raw memory / unsafe pointers", [
            "UnsafePointer", "UnsafeMutablePointer", "UnsafeRawPointer", "UnsafeMutableRawPointer",
            "UnsafeBufferPointer", "UnsafeMutableBufferPointer", "UnsafeRawBufferPointer",
            "UnsafeMutableRawBufferPointer", "AutoreleasingUnsafeMutablePointer",
            "ManagedBufferPointer", "withUnsafePointer", "withUnsafeMutablePointer", "withUnsafeBytes",
            "withUnsafeMutableBytes", "withExtendedLifetime", "malloc", "free", "memcpy", "memset",
            "CVarArg", "va_list", "CFunctionPointer",
        ])

        // MARK: Graphics & Media — all native
        add(.mustStayNative, .graphicsMedia, "Low-level graphics (CoreGraphics/Metal/CoreAnimation)", [
            "CGContext", "CGImage", "CGColor", "CGPath", "CGLayer", "CGDataProvider", "CGFont",
            "CALayer", "CAShapeLayer", "CAGradientLayer", "CAAnimation", "CABasicAnimation",
            "CAKeyframeAnimation", "CATransaction", "CAEmitterLayer",
            "MTLDevice", "MTLCommandQueue", "MTLBuffer", "MTLTexture", "MTLRenderPipelineState",
            "MTKView", "CIImage", "CIContext", "CIFilter", "CGImageSource", "CGImageDestination",
            "CMTime", "VTCompressionSession", "PDFDocument", "CTFont", "CTFrame",
        ])

        // MARK: System services — hardware/UX-touching → native
        add(.mustStayNative, .systemServices, "Pasteboard / haptics / device / webviews", [
            "UIPasteboard", "NSPasteboard", "UIImpactFeedbackGenerator", "UINotificationFeedbackGenerator",
            "UISelectionFeedbackGenerator", "UIDevice", "UIScreen", "WKInterfaceDevice",
            "MFMailComposeViewController", "MFMessageComposeViewController", "SFSafariViewController",
            "ASWebAuthenticationSession", "ASAuthorizationController", "LocalAuthentication",
            "CTTelephonyNetworkInfo", "MPMusicPlayerController", "MPMediaQuery", "WKWebView",
            "SLComposeViewController", "UIPrintInteractionController",
        ])

        // =====================================================================
        // TIER 2 — bridgeable (host bridge exists/planned → classify `bridged`)
        // =====================================================================

        // MARK: Networking — OS networking stack, but bridged through the shell.
        // Day-1 hard-marked these native (biggest single OTA loss after UI). The
        // host shell already owns URLSession; OTA code calls a thin bridge that
        // performs the request and returns Data → classified `bridged`.
        //
        // The request/response surface stays `.bridgeable`: in the DEFAULT engine path
        // a `URLSession`/`URLRequest`-touching function ships OTA by being BRIDGED to
        // the native shell's real URLSession (the whole function runs native) — it does
        // NOT require URLRequest to compile in WASM. Breakthrough #6 adds a SECOND path
        // on top: `await URLSession.shared.data(from:)` is rewritten by the
        // FusionRewriter to the async `patch_host.http_get` import so the
        // decode+transform run IN WASM (see BuildPipeline.fusionRewriteableSymbols,
        // which lists ONLY `URLSession` — `URLRequest` is excluded from the FUSION path
        // because it is absent in the WASM-SDK guest Foundation, but it remains BRIDGED).
        add(.bridgeable, .networking, "OS networking req/resp via host bridge (#6 fusion adds GET-in-WASM)", [
            "URLSession", "URLSessionTask", "URLSessionDataTask", "URLSessionConfiguration",
            "URLRequest", "URLResponse", "HTTPURLResponse", "URLCache",
        ])
        // #6 honest limits — these stay `.mustStayNative` (the brief's explicit list):
        // websocket/upload/download/stream tasks + the auth-challenge/credential/delegate
        // surface are bidirectional-stream / multipart / incremental-byte / delegate
        // shapes the GET request/response bridge cannot model (the host owns
        // cookies/TLS/auth — the security win). A function touching any of these is
        // forced native (and is never offered to the fusion path).
        add(.mustStayNative, .networking, "Networking streaming/websocket/upload/delegate (out of #6 v1)", [
            "URLSessionDownloadTask", "URLSessionUploadTask", "URLSessionWebSocketTask",
            "URLSessionStreamTask", "URLAuthenticationChallenge", "URLCredential",
            "URLSessionDelegate", "URLSessionDataDelegate", "URLSessionTaskDelegate",
            "URLSessionDownloadDelegate", "URLSessionWebSocketDelegate",
        ])
        add(.bridgeable, .networking, "Low-level networking via host bridge", [
            "NWConnection", "NWListener", "NWPath", "NWPathMonitor", "NWEndpoint", "NWParameters",
            "NWProtocolTCP", "NWProtocolUDP", "NWBrowser",
        ])
        add(.bridgeable, .networking, "Streams via host bridge", [
            "Stream", "InputStream", "OutputStream", "Host",
        ])
        // URLProtocol / CFSocket are subclassing/raw-socket surfaces → keep native.
        add(.mustStayNative, .networking, "Custom protocol / raw socket subclassing", [
            "URLProtocol", "CFSocket",
        ])

        // MARK: User preferences — bridged.
        add(.bridgeable, .storage, "User preferences via host bridge", [
            "UserDefaults",
        ])

        // MARK: Read-only file system / Bundle — bridged (breakthrough #8).
        // The host-ABI bridge family (docs/ENGINEERING.md §2 breakthrough #8,
        // 16/16 executing-WASM checks) proved the read-only FileManager surface
        // (fileExists / contents / attributesOfItem .size) and Bundle Info/resource
        // lookups are safe synchronous value-bridges. The FusionRewriter rewrites
        // the call sites to patch_host.* imports the SDK serves. WRITE members are
        // kept native by the mustStayNative member-call guard registered above, so a
        // file-writer is never mis-promoted by the TYPE flip here.
        add(.bridgeable, .storage, "Read-only file ops via host bridge (breakthrough #8)", [
            "FileManager",
        ])
        add(.bridgeable, .storage, "Bundle Info/resource lookups via host bridge (breakthrough #8)", [
            "Bundle",
        ])

        // MARK: ProcessInfo (env / OS version) — bridged (breakthrough #8).
        // ProcessInfo.processInfo.environment[...] and .operatingSystemVersion are
        // synchronous read-only host facts (patch_host.process_env / os_version).
        add(.bridgeable, .systemServices, "ProcessInfo env / OS-version via host bridge (breakthrough #8)", [
            "ProcessInfo",
        ])

        // MARK: Keychain / Security — bridged (host owns the keychain).
        add(.bridgeable, .keychain, "Keychain via host bridge (SecItem*)", [
            "SecItemAdd", "SecItemCopyMatching", "SecItemUpdate", "SecItemDelete",
            "kSecClass", "kSecAttrAccount", "kSecValueData", "kSecClassGenericPassword",
        ])
        // Crypto/cert evaluation primitives stay native (no safe value-type bridge).
        add(.mustStayNative, .keychain, "Crypto / trust evaluation (native only)", [
            "SecKeyCreateRandomKey", "SecKeyCreateSignature", "SecKeyVerifySignature",
            "SecTrustEvaluateWithError", "SecTrust", "SecCertificate", "SecIdentity",
            "SecAccessControlCreateWithFlags", "LAContext", "SecKey",
        ])
        // Security-framework crypto/cert C FUNCTIONS (only the Sec* TYPES were
        // registered before, so a function that called e.g.
        // `SecCertificateCreateWithData` / `SecCertificateCopyKey` but never named
        // the `SecCertificate` TYPE slipped through as bridged/eligible — a latent
        // false negative, e.g. wire-ios' `TrustData.init(rawCertificateKey:hosts:)`.
        // These have no WASM equivalent and no safe value-bridge → native.
        add(.mustStayNative, .keychain, "Security-framework crypto C calls", [
            "SecCertificateCreateWithData", "SecCertificateCopyKey", "SecCertificateCopyData",
            "SecCertificateCopySubjectSummary", "SecKeyCopyExternalRepresentation",
            "SecKeyCreateWithData", "SecKeyCopyPublicKey", "SecKeyCreateEncryptedData",
            "SecKeyCreateDecryptedData", "SecTrustCreateWithCertificates",
            "SecTrustCopyKey", "SecTrustGetCertificateCount", "SecRandomCopyBytes",
            "SecPolicyCreateSSL", "SecPolicyCreateBasicX509",
        ])

        // MARK: Notifications — bridged (post/observe routed through host).
        add(.bridgeable, .notifications, "Notification center via host bridge", [
            "NotificationCenter", "Notification", "NSNotification", "NSNotificationCenter",
            "Notification.Name",
        ])
        add(.bridgeable, .notifications, "User notifications via host bridge", [
            "UNUserNotificationCenter", "UNNotificationRequest", "UNMutableNotificationContent",
            "UNNotificationTrigger", "UNTimeIntervalNotificationTrigger", "UNCalendarNotificationTrigger",
            "UNNotificationSettings", "UNNotificationCategory", "UNNotificationAction",
        ])

        // MARK: Logging / analytics — bridged (host owns os.Logger).
        add(.bridgeable, .systemServices, "Logging / analytics via host bridge", [
            "os_log", "OSLog", "Logger", "NSLog", "syslog",
        ])

        // =====================================================================
        // TIER 3 — wasmSafeFoundation (compiles to WASM under full SDK; NOT native)
        // =====================================================================
        // PROVEN Day-2: Decimal / Date / Calendar / DateComponents / DateFormatter /
        // ISO8601DateFormatter / NumberFormatter / Measurement / Locale / TimeZone /
        // JSONEncoder / JSONDecoder / Codable / UUID / Data / base64 /
        // NSRegularExpression / URL+URLComponents all compile and run under
        // `swift build --swift-sdk swift-6.3.2-RELEASE_wasm` (full Foundation).
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Decimal arithmetic (WASM-safe)", [
            "Decimal", "NSDecimalNumber",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Date / Calendar arithmetic (WASM-safe)", [
            "Date", "DateComponents", "Calendar", "TimeZone", "DateInterval", "TimeInterval",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Formatters (WASM-safe)", [
            "DateFormatter", "ISO8601DateFormatter", "NumberFormatter", "DateComponentsFormatter",
            "DateIntervalFormatter", "ByteCountFormatter", "PersonNameComponentsFormatter",
            "MeasurementFormatter", "RelativeDateTimeFormatter", "ListFormatter", "FormatStyle",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Units / locale (WASM-safe)", [
            "Measurement", "Unit", "UnitLength", "UnitMass", "UnitDuration", "UnitTemperature",
            "UnitSpeed", "UnitAngle", "UnitArea", "UnitVolume", "Dimension", "Locale",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Codable / JSON (WASM-safe)", [
            "JSONEncoder", "JSONDecoder", "Codable", "Encodable", "Decodable", "JSONSerialization",
            "PropertyListEncoder", "PropertyListDecoder", "CodingKeys", "KeyedDecodingContainer",
            "KeyedEncodingContainer", "JSONDecoder.DateDecodingStrategy", "JSONEncoder.DateEncodingStrategy",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Identifiers / bytes (WASM-safe)", [
            "UUID", "Data",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "URL parsing (WASM-safe)", [
            "URL", "URLComponents", "URLQueryItem",
        ])
        add(.wasmSafeFoundation, .wasmSafeFoundation, "Regex / string parsing (WASM-safe)", [
            "NSRegularExpression", "NSTextCheckingResult", "Regex", "CharacterSet", "Scanner",
            "NSString", "NSMutableString", "NSAttributedString", "AttributedString", "NSRange",
        ])
        // NSPredicate / NSExpression / NSSortDescriptor evaluate via ObjC KVC at
        // runtime (dynamic dispatch / @objc) → keep native (zero false negatives).
        add(.mustStayNative, .objcInterop, "Dynamic KVC predicate evaluation (native only)", [
            "NSPredicate", "NSExpression", "NSSortDescriptor",
        ])

        return e
    }()
}
