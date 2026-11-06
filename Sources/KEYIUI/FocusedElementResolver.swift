import Foundation

/// Bounded, side-effect-free orchestration; callers supply all focus operations.
@MainActor
enum FocusedElementResolver {
    static func resolve<Element>(
        isCurrent: @MainActor () -> Bool,
        read: @MainActor () throws -> Element?,
        recover: (@MainActor () -> Bool)? = nil,
        wait: @MainActor () async throws -> Void
    ) async throws -> Element {
        @MainActor
        func checkBoundary() throws {
            try Task.checkCancellation()
            let current = isCurrent()
            try Task.checkCancellation()
            guard current else { throw AccessibilityTextClient.Error.contentChanged }
        }

        @MainActor
        func checkedWait() async throws {
            try checkBoundary()
            do {
                try await wait()
            } catch {
                try checkBoundary()
                throw error
            }
            try checkBoundary()
        }

        @MainActor
        func probe() async throws -> Element? {
            for attempt in 0..<4 {
                try checkBoundary()
                let element: Element?
                do {
                    element = try read()
                } catch {
                    try checkBoundary()
                    throw error
                }
                try checkBoundary()
                if let element {
                    try checkBoundary()
                    return element
                }
                if attempt < 3 { try await checkedWait() }
            }
            try checkBoundary()
            return nil
        }

        if let element = try await probe() {
            try checkBoundary()
            return element
        }
        try checkBoundary()
        guard let recover else { throw AccessibilityTextClient.Error.noFocusedText }
        try checkBoundary()
        let recovered = recover()
        try checkBoundary()
        guard recovered else { throw AccessibilityTextClient.Error.noFocusedText }
        try await checkedWait()
        if let element = try await probe() {
            try checkBoundary()
            return element
        }
        try checkBoundary()
        throw AccessibilityTextClient.Error.noFocusedText
    }
}
