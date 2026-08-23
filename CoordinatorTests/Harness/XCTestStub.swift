// Stub of the XCTest module, compiled with the SAME default isolation
// (MainActor) as the coordinator test sources, so the isolation checks that
// the real XCTest's nonisolated ObjC declarations would reject compile by
// construction (the documented RenderingTests approach).
//
// The runner (main.swift) drives every test method explicitly, so this only
// needs `XCTestCase` and the assertion functions the tests call. Failures are
// counted in `__testFailures` (global, so the runner can attribute them per
// test) and printed with their file/line.
import Foundation

public nonisolated(unsafe) var __testFailures: Int = 0

open class XCTestCase {
    public init() {}
}

public func XCTFail(_ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
    __testFailures += 1
    print("FAIL: \(message.isEmpty ? "XCTFail" : message) (\(file):\(line))")
}

@discardableResult
public func XCTAssertTrue(_ expression: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression() else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertTrue failed" : message) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertFalse(_ expression: @autoclosure () -> Bool, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard !expression() else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertFalse failed" : message) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertEqual<T: Equatable>(_ expression1: T, _ expression2: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression1 == expression2 else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertEqual failed" : message) — got \(expression1), want \(expression2) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertEqual<T: FloatingPoint>(_ expression1: T, _ expression2: T, accuracy: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard abs(expression1 - expression2) <= accuracy else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertEqual(accuracy:) failed" : message) — got \(expression1), want \(expression2) ±\(accuracy) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertNil<T>(_ expression: @autoclosure () -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression() == nil else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertNil failed" : message) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertNotNil<T>(_ expression: @autoclosure () -> T?, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression() != nil else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertNotNil failed" : message) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertGreaterThan<T: Comparable>(_ expression1: T, _ expression2: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression1 > expression2 else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertGreaterThan failed" : message) — \(expression1) is not > \(expression2) (\(file):\(line))")
        return false
    }
    return true
}

@discardableResult
public func XCTAssertLessThanOrEqual<T: Comparable>(_ expression1: T, _ expression2: T, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) -> Bool {
    guard expression1 <= expression2 else {
        __testFailures += 1
        print("FAIL: \(message.isEmpty ? "XCTAssertLessThanOrEqual failed" : message) — \(expression1) is not <= \(expression2) (\(file):\(line))")
        return false
    }
    return true
}
