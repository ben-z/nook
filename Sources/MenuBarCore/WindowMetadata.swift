import AppKit
import CoreGraphics

public struct WindowMetadata: Sendable {
    public let id: CGWindowID
    public let pid: pid_t
    public let bounds: CGRect
    public let layer: Int
    public let isOnScreen:Bool

    public init(_ dictionary: [String: Any]) throws {
        guard let id = dictionary[kCGWindowNumber as String] as? CGWindowID,
              let pid = dictionary[kCGWindowOwnerPID as String] as? pid_t,
              let rectangle = dictionary[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: rectangle),
              let layer = dictionary[kCGWindowLayer as String] as? Int else {
            throw ManagerError("Window metadata is missing required fields")
        }
        self.id = id; self.pid = pid; self.bounds = bounds
        self.layer = layer
        self.isOnScreen = dictionary[kCGWindowIsOnscreen as String] as? Bool == true
    }

    public static func list(_ option: CGWindowListOption, relativeTo id: CGWindowID) throws -> [WindowMetadata] {
        guard let list = CGWindowListCopyWindowInfo(option, id) as? [[String: Any]] else {
            throw ManagerError("WindowServer did not return window metadata")
        }
        return try list.map(WindowMetadata.init)
    }

    public static func current(_ id: CGWindowID) throws -> WindowMetadata {
        var pointer:UnsafeRawPointer? = UnsafeRawPointer(bitPattern:UInt(id))
        guard let identifiers = CFArrayCreate(nil,&pointer,1,nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(identifiers) as? [[String:Any]] else {
            throw ManagerError("WindowServer did not return metadata for window \(id)")
        }
        let matches = try descriptions.map(WindowMetadata.init)
        guard let window = matches.first(where: {$0.id == id}) else {
            throw ManagerError("Menu-bar window \(id) no longer exists")
        }
        return window
    }

    public static func statusWindows(_ configuration: Configuration) throws -> [WindowMetadata] {
        let identifiers = try NativeStatusWindows.identifiers()
        var pointers = identifiers.map { UnsafeRawPointer(bitPattern:UInt($0)) }
        guard let selected = CFArrayCreate(nil,&pointers,pointers.count,nil),
              let descriptions = CGWindowListCreateDescriptionFromArray(selected) as? [[String:Any]] else { throw ManagerError("WindowServer did not return native status-window metadata") }
        return try descriptions.filter { $0[kCGWindowLayer as String] as? Int == Int(CGWindowLevelForKey(.statusWindow)) }.map(WindowMetadata.init).filter {
            $0.bounds.height > 0 && $0.bounds.height <= configuration.maximumStatusWindowHeight
        }
    }

    public static func settledStatusWindows(_ configuration:Configuration) async throws -> [WindowMetadata] {
        var previous = Dictionary(uniqueKeysWithValues:try statusWindows(configuration).map { ($0.id,$0.bounds) })
        var since = Date()
        let deadline = since.addingTimeInterval(configuration.movementTimeout)
        repeat {
            try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
            let current = try statusWindows(configuration)
            let bounds = Dictionary(uniqueKeysWithValues:current.map { ($0.id,$0.bounds) })
            if bounds != previous { since = Date(); previous = bounds }
            if Date().timeIntervalSince(since) >= configuration.layoutSettlementPeriod { return current }
        } while Date() < deadline
        throw ManagerError("The native menu-bar layout did not settle")
    }

    public static func owned(identifier:String, configuration:Configuration,excluding:Set<CGWindowID>) async throws -> WindowMetadata {
        let pid = getpid()
        return try await Task.detached {
            let root = AXUIElementCreateApplication(pid)
            let deadline = Date().addingTimeInterval(configuration.applicationLaunchTimeout)
            repeat {
                if let value = try Accessibility.optional(root,kAXExtrasMenuBarAttribute) {
                    let bar = try Accessibility.element(value)
                    let matches = try Accessibility.children(bar).filter {
                        try Accessibility.string($0,kAXIdentifierAttribute) == identifier
                    }
                    try require(matches.count <= 1,"The manager's status-item identity is ambiguous")
                    if let element = matches.first { return try Catalog.locate(element,name:identifier,configuration:configuration,excluding:excluding) }
                }
                try Task.checkCancellation()
                try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
            } while Date() < deadline
            throw ManagerError("The manager's status-item identity did not appear: \(identifier)")
        }.value
    }

    @MainActor public static func statusIsVisible(_ bounds:CGRect) throws -> Bool {
        let top = CGDisplayBounds(CGMainDisplayID()).height
        for screen in NSScreen.screens {
            let area:NSRect
            if screen.safeAreaInsets.top > 0 {
                guard let right = screen.auxiliaryTopRightArea else { throw ManagerError("The notched display did not expose its usable menu-bar area") }
                area = right
            } else { area = screen.frame }
            let rectangle = CGRect(x:area.minX,y:top-area.maxY,width:area.width,height:area.height)
            if bounds.minX >= rectangle.minX && bounds.maxX <= rectangle.maxX && rectangle.contains(CGPoint(x:bounds.midX,y:bounds.midY)) { return true }
        }
        return false
    }
}
