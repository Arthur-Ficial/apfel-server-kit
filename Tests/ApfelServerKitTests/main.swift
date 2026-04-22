// apfel-server-kit-tests - pure Swift test runner, no XCTest/Testing framework needed.
// Run: swift run apfel-server-kit-tests  (or `swift test`, which invokes the same binary)

import Foundation
import ApfelServerKit

// MARK: - Minimal test harness (ported from apfel's Tests/apfelTests/main.swift)

nonisolated(unsafe) var _passed = 0
nonisolated(unsafe) var _failed = 0

func test(_ name: String, _ block: () throws -> Void) {
    do {
        try block()
        print("  OK \(name)")
        _passed += 1
    } catch {
        print("  FAIL \(name): \(error)")
        _failed += 1
    }
}

func testAsync(_ name: String, _ block: @Sendable @escaping () async throws -> Void) {
    let semaphore = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var failure: Error? = nil
    nonisolated(unsafe) var passed = false

    Task {
        do {
            try await block()
            passed = true
        } catch {
            failure = error
        }
        semaphore.signal()
    }
    semaphore.wait()

    if passed {
        print("  OK \(name)")
        _passed += 1
    } else {
        print("  FAIL \(name): \(failure!)")
        _failed += 1
    }
}

struct TestFailure: Error, CustomStringConvertible {
    let description: String
    init(_ msg: String) { description = msg }
}

func assertEqual<T: Equatable>(_ a: T, _ b: T, _ msg: String = "") throws {
    guard a == b else { throw TestFailure("\(a) != \(b)\(msg.isEmpty ? "" : " - \(msg)")") }
}
func assertNil<T>(_ v: T?, _ msg: String = "") throws {
    guard v == nil else { throw TestFailure("Expected nil, got \(v!)\(msg.isEmpty ? "" : " - \(msg)")") }
}
func assertNotNil<T>(_ v: T?, _ msg: String = "") throws {
    guard v != nil else { throw TestFailure("Expected non-nil\(msg.isEmpty ? "" : " - \(msg)")") }
}
func assertTrue(_ v: Bool, _ msg: String = "") throws {
    guard v else { throw TestFailure("Expected true\(msg.isEmpty ? "" : " - \(msg)")") }
}
func assertFalse(_ v: Bool, _ msg: String = "") throws {
    guard !v else { throw TestFailure("Expected false\(msg.isEmpty ? "" : " - \(msg)")") }
}

func suite(_ name: String, _ block: () -> Void) {
    print("\n\(name)")
    block()
}

// MARK: - Run suites

suite("PackageSmokeTests") {
    test("version is set") {
        try assertEqual(ApfelServerKit.version, "1.0.0")
    }
}
suite("SSEEventTests") { runSSEEventTests() }
suite("SSEParserTests") { runSSEParserTests() }
suite("ApfelBinaryFinderTests") { runApfelBinaryFinderTests() }
suite("PortScannerTests") { runPortScannerTests() }

// MARK: - Summary

print("\n---------------------------------")
if _failed == 0 {
    print("All \(_passed) tests passed")
} else {
    print("\(_failed) failed, \(_passed) passed")
    exit(1)
}
