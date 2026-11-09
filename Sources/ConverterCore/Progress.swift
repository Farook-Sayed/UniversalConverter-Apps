import Foundation

/// What a conversion is doing right now. `fraction` is 0...1 when the work can be measured, and nil when it cannot.
public struct ConversionProgress: Sendable, Equatable {
    public let message: String
    public let fraction: Double?

    public init(_ message: String, fraction: Double? = nil) {
        self.message = message
        self.fraction = fraction.map { min(max($0, 0), 1) }
    }
}
