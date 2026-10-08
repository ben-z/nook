import AppKit

@MainActor public final class HiddenGroup {
    private let item:NSStatusItem
    public let window:CGWindowID
    private let configuration:Configuration
    private let movement:Movement

    public init(item:NSStatusItem,window:CGWindowID,configuration:Configuration,movement:Movement) {
        self.item = item; self.window = window; self.configuration = configuration; self.movement = movement
    }

    @discardableResult public func expanded(_ expanded:Bool) async throws -> WindowMetadata {
        item.length = expanded ? configuration.expandedDividerWidth:configuration.dividerWidth
        let deadline = Date().addingTimeInterval(configuration.movementTimeout)
        repeat {
            let current = try WindowMetadata.current(window)
            if (current.bounds.width > configuration.maximumStatusWindowHeight) == expanded {
                _ = try await WindowMetadata.settledStatusWindows(configuration)
                return try WindowMetadata.current(window)
            }
            try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
        } while Date() < deadline
        throw ManagerError("macOS did not resize the hidden-group divider")
    }

    func windows() async throws -> [WindowMetadata] {
        let windows = try await WindowMetadata.settledStatusWindows(configuration)
        let divider = try WindowMetadata.current(window)
        return windows.filter {
            $0.bounds.maxX <= divider.bounds.minX+configuration.geometryTolerance && abs($0.bounds.midY-divider.bounds.midY) <= configuration.geometryTolerance
        }.sorted { $0.bounds.minX < $1.bounds.minX }
    }

    public func prepend(_ source:CGWindowID,sourcePID:pid_t) async throws {
        _ = try await expanded(true)
        let candidates = try await windows().filter { $0.id != source }
        let anchor:CGWindowID
        if let first = candidates.first { anchor = first.id } else { anchor = window }
        try await movement.move(source,sourcePID:sourcePID,relativeTo:anchor,placement:.left)
    }

    public func restore(_ source:MenuBarItem,order:[MenuBarItem]) async throws {
        guard let index = order.firstIndex(where: { $0.window.id == source.window.id }) else { throw ManagerError("The original hidden position is missing") }
        func running(_ item:MenuBarItem) -> Bool {
            guard let app = NSRunningApplication(processIdentifier:item.sourcePID) else { return false }
            return !app.isTerminated && app.bundleIdentifier == item.bundleIdentifier
        }
        let successor = order.dropFirst(index+1).first(where:running)
        try await expanded(true)
        try await movement.move(source.window.id,sourcePID:source.sourcePID,relativeTo:successor?.window.id ?? window,placement:.left)
        let restored = try await windows().map(\.id)
        try require(restored == order.filter(running).map { $0.window.id },"The hidden group did not regain its original order")
    }
}
