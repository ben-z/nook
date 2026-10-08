import AppKit
import ApplicationServices

public enum Accessibility {
    public static func check(_ error: AXError, _ operation: String) throws {
        guard error == .success else { throw ManagerError("\(operation): Accessibility error \(error.rawValue)") }
    }

    public static func configure(_ configuration: Configuration) throws {
        try require(AXIsProcessTrusted(), "Enable Accessibility for Nook in System Settings")
        try check(AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), configuration.accessibilityTimeout), "Set Accessibility timeout")
    }

    public static func optional(_ element: AXUIElement, _ name: String) throws -> CFTypeRef? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        if error == .noValue || error == .attributeUnsupported { return nil }
        try check(error, "Read \(name)")
        guard let value else { throw ManagerError("Accessibility returned success without a value for \(name)") }
        return value
    }

    public static func required(_ element: AXUIElement, _ name: String) throws -> CFTypeRef {
        guard let value = try optional(element, name) else { throw ManagerError("Accessibility does not expose \(name)") }
        return value
    }

    public static func element(_ value: CFTypeRef) throws -> AXUIElement {
        try require(CFGetTypeID(value) == AXUIElementGetTypeID(), "Expected an Accessibility element")
        return value as! AXUIElement
    }

    public static func children(_ element: AXUIElement) throws -> [AXUIElement] {
        guard let value = try optional(element,kAXChildrenAttribute) else { return [] }
        guard let result = value as? [AXUIElement] else { throw ManagerError("Accessibility children have an invalid type") }
        return result
    }

    public static func string(_ element: AXUIElement, _ name: String) throws -> String? {
        guard let value = try optional(element,name) else { return nil }
        guard let result = value as? String else { throw ManagerError("\(name) is not a string") }
        return result
    }

    public static func bounds(_ element: AXUIElement) throws -> CGRect {
        let position = try required(element,kAXPositionAttribute)
        let size = try required(element,kAXSizeAttribute)
        try require(CFGetTypeID(position) == AXValueGetTypeID() && CFGetTypeID(size) == AXValueGetTypeID(), "Invalid Accessibility geometry")
        var point = CGPoint.zero; var dimensions = CGSize.zero
        try require(AXValueGetValue(position as! AXValue,.cgPoint,&point), "Cannot read Accessibility position")
        try require(AXValueGetValue(size as! AXValue,.cgSize,&dimensions), "Cannot read Accessibility size")
        return CGRect(origin:point,size:dimensions)
    }
}

public struct MenuBarItem: Sendable {
    public let key: String
    public let name: String
    public let bundleIdentifier: String
    public let sourcePID: pid_t
    public let window: WindowMetadata
}

public struct Catalog: Sendable {
    public let items: [MenuBarItem]
    public let inspectionErrors: [String]

    private struct Application: Sendable {
        let pid: pid_t
        let identifier: String
        let name: String
    }

    @MainActor public static func read(_ configuration: Configuration) async throws -> Catalog {
        let applications = NSWorkspace.shared.runningApplications.compactMap { application -> Application? in
            guard application.activationPolicy != .prohibited,
                  let url = application.bundleURL, url.pathExtension == "app", !url.path.contains("/Frameworks/"),
                  let identifier = application.bundleIdentifier, let name = application.localizedName else { return nil }
            return Application(pid:application.processIdentifier,identifier:identifier,name:name)
        }
        return try await reader.inspect(applications,configuration:configuration)
    }

    private static let reader = Reader()
    public static func bindWindow(_ key:String,pid:pid_t,window:CGWindowID) async {
        await reader.bindWindow(key,pid:pid,window:window)
    }
    private actor Reader {
        struct Identity { let pid:pid_t; let element:AXUIElement; let window:CGWindowID }
        struct Owned { let pid:pid_t; let window:CGWindowID }
        var identities = [String:Identity]()
        var owned = [String:Owned]()
        var previousApplications = Set<pid_t>()
        func bindWindow(_ key:String,pid:pid_t,window:CGWindowID) { owned[key] = Owned(pid:pid,window:window) }
    func inspect(_ applications:[Application],configuration:Configuration) throws -> Catalog {
        var items = [MenuBarItem](); var errors = Set<String>(); var rootErrors = Set<String>(); var observed = [String:Identity]()
        let currentApplications = Set(applications.map(\.pid))
        let nativeBefore = Set(try WindowMetadata.statusWindows(configuration).map(\.id))
        let identifiedBefore = Set(identities.values.map(\.window))
        let providers = Set(identities.values.map(\.pid))
        let unchanged = currentApplications == previousApplications && nativeBefore == identifiedBefore
        let candidates = unchanged ? applications.filter { providers.contains($0.pid) }:applications
        for application in candidates {
            let identifier = application.identifier; let name = application.name
            var foundBar = false
            do {
                let root = AXUIElementCreateApplication(application.pid)
                guard let value = try Accessibility.optional(root,kAXExtrasMenuBarAttribute) else { continue }
                foundBar = true
                let bar = try Accessibility.element(value)
                let elements = try Accessibility.children(bar).map { ($0,try Accessibility.bounds($0)) }.filter { $0.1.width > 0 && $0.1.height > 0 }
                for (element,_) in elements {
                    let key:String
                    if elements.count == 1 { key = identifier }
                    else {
                        guard let identity = try Accessibility.string(element,kAXIdentifierAttribute), !identity.isEmpty else { throw ManagerError("\(name) must expose stable identities for its multiple icons") }
                        key = identifier + ":" + identity
                    }
                    let window:WindowMetadata
                    if let owned = owned[key], owned.pid == application.pid {
                        window = try WindowMetadata.current(owned.window)
                    } else if let identity = identities[key], identity.pid == application.pid, CFEqual(identity.element,element) {
                        window = try WindowMetadata.current(identity.window)
                    } else {
                        window = try Catalog.locate(element,name:name,configuration:configuration,excluding:[])
                    }
                    observed[key] = Identity(pid:application.pid,element:element,window:window.id)
                    let itemName: String
                    if identifier == "com.apple.controlcenter", let description = try Accessibility.string(element,kAXDescriptionAttribute) { itemName = description }
                    else { itemName = name }
                    items.append(MenuBarItem(key:key,name:itemName,bundleIdentifier:identifier,sourcePID:application.pid,window:window))
                }
            } catch {
                let message = "\(name): \(error.localizedDescription)"
                if foundBar { errors.insert(message) }
                else { rootErrors.insert(message) }
            }
        }
        identities = observed; previousApplications = currentApplications
        owned = owned.filter { entry in applications.contains { $0.pid == entry.value.pid } }
        let grouped = Dictionary(grouping:items,by:\.key)
        try require(grouped.values.allSatisfy {$0.count == 1}, "Menu-bar identities are ambiguous; management is unsafe")
        try require(Set(items.map { $0.window.id }).count == items.count,"Multiple applications claim the same menu-bar surface")
        let native = Set(try WindowMetadata.statusWindows(configuration).map(\.id))
        let issues = Catalog.issues(native:native,identified:Set(items.map { $0.window.id }),itemErrors:errors,rootErrors:rootErrors)
        return Catalog(items:items.sorted {$0.name.localizedStandardCompare($1.name) == .orderedAscending},inspectionErrors:issues)
    }

    }

    static func issues(native:Set<CGWindowID>,identified:Set<CGWindowID>,itemErrors:Set<String>,rootErrors:Set<String>) -> [String] {
        let missing = native.subtracting(identified)
        var issues = itemErrors
        if !missing.isEmpty {
            let noun = missing.count == 1 ? "icon" : "icons"
            issues.insert("\(missing.count) menu-bar \(noun) could not be identified")
            issues.formUnion(rootErrors)
        }
        return issues.sorted()
    }

    static func locate(_ element:AXUIElement,name:String,configuration:Configuration,excluding:Set<CGWindowID>) throws -> WindowMetadata {
        let deadline = Date().addingTimeInterval(configuration.movementTimeout)
        repeat {
            let frame = try Accessibility.bounds(element)
            let matches = try WindowMetadata.statusWindows(configuration).filter {
                !excluding.contains($0.id) && abs($0.bounds.midX-frame.midX) <= configuration.accessibilityCenterTolerance && $0.bounds.contains(CGPoint(x:frame.midX,y:frame.midY))
            }
            try require(matches.count <= 1,"\(name)'s native status-item geometry is ambiguous")
            if let window = matches.first { return window }
            Thread.sleep(forTimeInterval:configuration.movementCheckInterval)
        } while Date() < deadline
        throw ManagerError("\(name)'s menu-bar geometry did not settle")
    }
}
