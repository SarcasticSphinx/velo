import Foundation
import os

/// Only lifecycle events, permission states and numeric error codes; never dictated text.
enum Diagnostics {
    private static let logger = Logger(subsystem: "dev.local.BreezeDictate", category: "Lifecycle")
    static func event(_ message: String) {
        logger.notice("\(message, privacy: .public)")
        if ProcessInfo.processInfo.environment["BREEZE_DIAGNOSTICS"] == "1" {
            fputs("Velo: \(message)\n", stderr)
        }
    }
}
