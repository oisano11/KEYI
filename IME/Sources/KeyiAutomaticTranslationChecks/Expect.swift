//
//  Expect.swift
//  断言计数与分组标题。
//

import Foundation

var failures: [String] = []
var passed = 0

func expect(_ condition: Bool, _ label: String) {
    if condition {
        passed += 1
        print("PASS: \(label)")
    } else {
        failures.append(label)
        print("FAIL: \(label)")
    }
}

func expectEqual<T: Equatable>(_ actual: T, _ expected: T, _ label: String) {
    if actual == expected {
        expect(true, label)
    } else {
        expect(false, "\(label) (got \(actual), expected \(expected))")
    }
}

func section(_ title: String) {
    print("-- \(title)")
}
