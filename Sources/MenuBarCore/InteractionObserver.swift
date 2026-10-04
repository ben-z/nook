import AppKit
import ApplicationServices

public struct AXElementIdentity: Hashable {
    public let element: AXUIElement
    public init(_ element: AXUIElement) { self.element = element }
    public static func ==(lhs:Self,rhs:Self) -> Bool { CFEqual(lhs.element,rhs.element) }
    public func hash(into hasher:inout Hasher) { hasher.combine(CFHash(element)) }
}

@MainActor public final class InteractionObserver {
    public static private(set) var liveCount = 0
    private var observer: AXObserver?
    private var source: CFRunLoopSource?
    private let callback: (AXUIElement,String) -> Void

    public init(pid:pid_t, callback:@escaping (AXUIElement,String) -> Void) throws {
        let root = AXUIElementCreateApplication(pid)
        self.callback = callback
        var observer: AXObserver?
        try Accessibility.check(AXObserverCreate(pid,{_,element,name,context in
            guard let context else { preconditionFailure("Missing Accessibility observer context") }
            MainActor.assumeIsolated {
                let owner = Unmanaged<InteractionObserver>.fromOpaque(context).takeUnretainedValue()
                owner.callback(element,name as String)
            }
        },&observer),"Create interaction observer")
        guard let observer else { throw ManagerError("Accessibility returned no observer") }
        self.observer = observer
        let names = [kAXMenuOpenedNotification,kAXMenuClosedNotification,kAXWindowCreatedNotification,
                     kAXUIElementDestroyedNotification,kAXFocusedWindowChangedNotification,kAXFocusedUIElementChangedNotification]
        do {
            for name in names {
                try Accessibility.check(AXObserverAddNotification(observer,root,name as CFString,Unmanaged.passUnretained(self).toOpaque()),"Observe \(name)")
            }
        } catch {
            self.observer = nil
            throw error
        }
        let source = AXObserverGetRunLoopSource(observer)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
        Self.liveCount += 1
    }

    public func close() {
        guard observer != nil else { return }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        self.source = nil; self.observer = nil
        Self.liveCount -= 1
    }

    isolated deinit { close() }
}
