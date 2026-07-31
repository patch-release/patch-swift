// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Compiler
@testable import CodeGenerator
import PartitioningEngine
import SwiftParser

/// BREAKTHROUGH-#7 wiring: the Compiler-side pieces that feed the GenericSpecializer's
/// three new instantiation sources (same-type pins, call-site mining, custom value-type
/// conformers). These exercise the call-site argument-type visitor and the
/// scanner-level integration the BuildPipeline drives.
final class GenericMonomorphizationWiringTests: XCTestCase {

    // MARK: - Call-site argument-type mining (source ii)

    /// `f(Foo(...))` records `Foo` as a call-site value type for `f`.
    func testMinesInitializerCallArgType() {
        let src = """
        struct Foo: Codable { var x: Int }
        func wrap<T>(_ v: T) -> T { v }
        func use() { _ = wrap(Foo(x: 1)) }
        """
        let v = CallSiteArgTypeVisitor(valueTypeNames: ["Foo"])
        v.walk(Parser.parse(source: src))
        XCTAssertEqual(v.callArgTypes["wrap"], ["Foo"])
    }

    /// `let t = Foo(...); f(t)` records `Foo` via the local binding.
    func testMinesLocalBindingCallArgType() {
        let src = """
        struct Token: Codable { var v: Int }
        func wrap<T>(_ x: T) -> T { x }
        func use() { let t = Token(v: 3); _ = wrap(t) }
        """
        let v = CallSiteArgTypeVisitor(valueTypeNames: ["Token"])
        v.walk(Parser.parse(source: src))
        XCTAssertEqual(v.callArgTypes["wrap"], ["Token"])
    }

    /// A param typed as a value type, passed through to a call, is mined.
    func testMinesParamCallArgType() {
        let src = """
        struct Money: Codable { var amount: Int }
        func wrap<T>(_ x: T) -> T { x }
        func forward(_ m: Money) { _ = wrap(m) }
        """
        let v = CallSiteArgTypeVisitor(valueTypeNames: ["Money"])
        v.walk(Parser.parse(source: src))
        XCTAssertEqual(v.callArgTypes["wrap"], ["Money"])
    }

    /// A non-value-type (or unknown) argument is NOT mined (conservative).
    func testIgnoresUnknownCallArgType() {
        let src = """
        func wrap<T>(_ x: T) -> T { x }
        func use(_ s: String) { _ = wrap(s); _ = wrap(SomeClass()) }
        """
        let v = CallSiteArgTypeVisitor(valueTypeNames: ["Money"])  // neither String nor SomeClass
        v.walk(Parser.parse(source: src))
        XCTAssertNil(v.callArgTypes["wrap"], "no known value-type arg → nothing mined")
    }

    /// A multi-argument or labelled call is left to the conformer/pin sources.
    func testIgnoresMultiArgCall() {
        let src = """
        struct Foo: Codable { var x: Int }
        func combine<T>(_ a: T, _ b: T) -> T { a }
        func use() { _ = combine(Foo(x: 1), Foo(x: 2)) }
        """
        let v = CallSiteArgTypeVisitor(valueTypeNames: ["Foo"])
        v.walk(Parser.parse(source: src))
        XCTAssertNil(v.callArgTypes["combine"], "multi-arg call site is not mined")
    }
}
