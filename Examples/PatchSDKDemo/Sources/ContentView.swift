import SwiftUI

struct ContentView: View {
    @State private var result: DemoRuntime.Result?
    @State private var error: String?

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 44))
                .foregroundStyle(.tint)
            Text("PatchSDK Demo")
                .font(.title.bold())
            Text("WasmKit + PatchSDK running a real .wasm module")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            if let r = result {
                VStack(alignment: .leading, spacing: 8) {
                    row("module size", "\(r.moduleBytes) bytes")
                    row("add(40, 2)", "\(r.add)")
                    row("fib(20)", "\(r.fib)")
                    row("reverse(\"PatchSDK\")", r.reversed)
                    Divider()
                    HStack {
                        Image(systemName: r.ok ? "checkmark.seal.fill" : "xmark.seal.fill")
                            .foregroundStyle(r.ok ? .green : .red)
                        // The UI test asserts on this exact accessibility id + text.
                        Text(r.ok ? "WASM executed OK" : "WASM result mismatch")
                            .bold()
                            .accessibilityIdentifier("demoStatus")
                    }
                }
                .padding()
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
            } else if let e = error {
                Text("Error: \(e)")
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("demoStatus")
                    .padding()
            } else {
                ProgressView("Loading WASM…")
            }
        }
        .padding()
        .task {
            do { result = try DemoRuntime.run() }
            catch { self.error = "\(error)" }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).foregroundStyle(.secondary)
            Spacer()
            Text(v).monospaced().bold()
        }
    }
}
