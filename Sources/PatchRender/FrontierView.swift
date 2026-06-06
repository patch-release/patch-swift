// FrontierView.swift — the SwiftUI wrapper that hosts a WASM-driven body.
//
// A `FrontierView` holds a `provider` that, given the current inputs (JSON),
// returns the latest `ViewNode` tree (in production this calls into the WASM
// module via `Patch.callJSON("view_body", …)`). On state change the host bumps
// `inputsVersion`; SwiftUI re-asks the provider and re-renders. This is the
// "re-render when the WASM re-emits a new tree on state change" loop.

#if canImport(SwiftUI)
import SwiftUI
import PatchViewIR

public struct FrontierView: View {
    /// Produces the current tree. In tests this is a closure; in production it
    /// wraps a `Patch` module call.
    public let provider: () -> ViewNode
    public let context: RenderContext

    public init(context: RenderContext = RenderContext(),
                provider: @escaping () -> ViewNode) {
        self.provider = provider
        self.context = context
    }

    public var body: some View {
        render(provider(), context: context)
    }
}
#endif
