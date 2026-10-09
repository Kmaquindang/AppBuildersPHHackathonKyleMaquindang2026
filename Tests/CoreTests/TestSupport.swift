// TestSupport.swift: tiny dependency-free assertion helpers (no XCTest, so it runs with plain swiftc).

import Foundation

enum TestCounter {
    static var passes = 0
    static var failures = 0
}

func check(_ condition: Bool, _ label: String, line: Int = #line, file: String = #fileID) {
    if condition {
        TestCounter.passes += 1
    } else {
        TestCounter.failures += 1
        print("FAIL [\(file):\(line)]: \(label)")
    }
}
