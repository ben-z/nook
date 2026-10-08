import Foundation

public struct Configuration: Sendable {
    public var gracePeriod: TimeInterval = 0.5
    public var accessibilityTimeout: Float = 0.3
    public var applicationLaunchTimeout: TimeInterval = 10
    public var movementTimeout: TimeInterval = 1
    public var movementCheckInterval: TimeInterval = 0.02
    public var layoutSettlementPeriod:TimeInterval = 0.12
    public var inputQuietPeriod:TimeInterval = 0.1
    public var restorationQuietPeriod:TimeInterval = 0.25
    public var inputWaitTimeout:TimeInterval = 10
    public var dragTimeout:TimeInterval = 0.15
    public var expandedDividerWidth: CGFloat = 10_000
    public var controlWidth: CGFloat = 20
    public var dividerWidth: CGFloat = 8
    public var maximumStatusWindowHeight: CGFloat = 60
    public var geometryTolerance: CGFloat = 1.5
    public var accessibilityCenterTolerance: CGFloat = 0.25
    public var maximumAccessibilityDepth: Int = 12
    public var hiddenKeys: [String] = []
    public var hotKeyCode: UInt32 = 46
    public var hotKeyModifiers: UInt32 = 0x800 | 0x1000
    public init() {}
}

public struct ManagerError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw ManagerError(message) }
}
