// SPDX-License-Identifier: Apache-2.0

import Foundation
import PartitioningEngine

/// A plan describing how a `mixed` function is split into WASM-eligible pure
/// fragments and a native shell. Produced by `FunctionSplitter`, consumed by
/// `CodeEmitter`. Day-2: carries enough data-flow information to emit a
/// genuinely rewired bridge body (not a documented stub).
public struct SplitPlan: Sendable {
    /// A pure fragment lifted out of the original function and destined for WASM.
    public struct PureFragment: Sendable {
        /// Generated function name, e.g. `_sp_submitOrder_prepare`.
        public let name: String
        /// Inputs the fragment needs (live-in vars), as (name, type) pairs. Type
        /// is best-effort (`_` when unknown → emitted as a generic parameter).
        public let inputs: [(name: String, type: String)]
        /// Outputs the fragment produces and the shell consumes later (live-out
        /// bindings), as (name, type) pairs.
        public let outputs: [(name: String, type: String)]
        /// Source statements (textual) that make up the fragment body.
        public let bodyStatements: [String]

        public init(
            name: String,
            inputs: [(name: String, type: String)],
            outputs: [(name: String, type: String)],
            bodyStatements: [String]
        ) {
            self.name = name
            self.inputs = inputs
            self.outputs = outputs
            self.bodyStatements = bodyStatements
        }

        // Back-compat shims for existing call sites/tests.
        public var parameters: [(label: String, type: String)] {
            inputs.map { (label: $0.name, type: $0.type) }
        }
        public var returnType: String {
            switch outputs.count {
            case 0: return "Void"
            case 1: return outputs[0].type
            default: return "(" + outputs.map { "\($0.name): \($0.type)" }.joined(separator: ", ") + ")"
            }
        }

        public init(name: String, parameters: [(label: String, type: String)], returnType: String, bodyStatements: [String]) {
            self.name = name
            self.inputs = parameters.map { (name: $0.label, type: $0.type) }
            self.outputs = []
            self.bodyStatements = bodyStatements
        }
    }

    /// One step in the rewired shell body, in original order.
    public enum ShellStep: Sendable {
        /// A call into a WASM fragment: bind its outputs from `Patch.call(...)`.
        case fragmentCall(fragment: PureFragment)
        /// A native statement kept verbatim in the shell.
        case nativeStatement(String)
        /// Strategy B: bind a Bool from a WASM fragment, then emit a rewritten
        /// guard/if that tests the bound name (branch bodies stay native).
        case guardConditionCall(fragment: PureFragment, rewrittenStatement: String)
        /// Strategy A2: bind a pure sub-expression value from a WASM fragment, then
        /// emit the native statement with that sub-expression replaced by the bound
        /// temp.
        case subExprCall(fragment: PureFragment, rewrittenStatement: String)
    }

    /// The original function's identity.
    public let originalID: String
    public let originalSimpleName: String
    /// The pure fragments lifted to WASM.
    public let pureFragments: [PureFragment]
    /// The full original signature text (for the bridge function).
    public let nativeSignature: String
    /// The original function's parameters (name, type) — live-ins at entry.
    public let originalParameters: [(name: String, type: String)]
    /// The original return type ("" / "Void" if none).
    public let returnType: String
    /// Whether the original function was `async` and/or `throws`.
    public let isAsync: Bool
    public let isThrows: Bool
    /// The rewired body, in order: fragment calls + retained native statements.
    public let shellSteps: [ShellStep]

    /// Day-1 compatibility field: textual native statements retained in the shell
    /// (verbatim native statements plus rewritten guard/sub-expr host statements,
    /// all of which remain in the App Store binary).
    public var nativeStatementsSummary: [String] {
        shellSteps.compactMap { step in
            switch step {
            case let .nativeStatement(s): return s
            case let .guardConditionCall(_, rewritten): return rewritten
            case let .subExprCall(_, rewritten): return rewritten
            case .fragmentCall: return nil
            }
        }
    }

    public init(
        originalID: String,
        originalSimpleName: String,
        pureFragments: [PureFragment],
        nativeSignature: String,
        originalParameters: [(name: String, type: String)] = [],
        returnType: String = "Void",
        isAsync: Bool = false,
        isThrows: Bool = false,
        shellSteps: [ShellStep] = []
    ) {
        self.originalID = originalID
        self.originalSimpleName = originalSimpleName
        self.pureFragments = pureFragments
        self.nativeSignature = nativeSignature
        self.originalParameters = originalParameters
        self.returnType = returnType
        self.isAsync = isAsync
        self.isThrows = isThrows
        self.shellSteps = shellSteps
    }

    /// Day-1 compatibility initializer.
    public init(
        originalID: String,
        originalSimpleName: String,
        pureFragments: [PureFragment],
        nativeSignature: String,
        nativeStatementsSummary: [String]
    ) {
        self.init(
            originalID: originalID,
            originalSimpleName: originalSimpleName,
            pureFragments: pureFragments,
            nativeSignature: nativeSignature,
            shellSteps: nativeStatementsSummary.map { .nativeStatement($0) }
        )
    }
}
