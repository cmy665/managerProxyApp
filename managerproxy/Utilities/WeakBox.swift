//
//  WeakBox.swift
//  ProxyPilot
//
//  A Sendable container for a weak reference. Used where a closure must not
//  retain its owner but still needs to reach it later.
//

import Foundation

final class WeakBox<T: AnyObject>: @unchecked Sendable {
    weak var value: T?

    init(_ value: T?) {
        self.value = value
    }
}
