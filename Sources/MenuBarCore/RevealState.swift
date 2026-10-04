import Foundation

public struct RevealState {
    public enum Phase: String { case hidden, revealing, visible, hiding, stopping, failed }
    public private(set) var phase: Phase = .hidden
    public private(set) var generation: UInt64 = 0
    public private(set) var hideRequested = false
    public private(set) var pointerDown = false
    public private(set) var managerMenuOpen = false
    public private(set) var menus = Set<AXElementIdentity>()
    public private(set) var interfaceCount = 0
    public init() {}

    @discardableResult public mutating func begin() throws -> UInt64 {
        try require(phase == .hidden,"Finish the currently revealed item first")
        generation += 1; phase = .revealing; hideRequested = false
        pointerDown = false; menus.removeAll(); interfaceCount = 0
        return generation
    }
    public mutating func revealed() { precondition(phase == .revealing); phase = .visible }
    public mutating func requestHide() { hideRequested = true }
    public mutating func mouse(down:Bool) { pointerDown = down }
    public mutating func managerMenu(_ open:Bool) { managerMenuOpen = open }
    public mutating func menuOpened(_ element:AXElementIdentity) { menus.insert(element) }
    public mutating func menuClosed(_ element:AXElementIdentity) { menus.remove(element); hideRequested = true }
    public mutating func interfaces(_ count:Int) {
        precondition(count >= 0)
        if interfaceCount > 0 && count == 0 { hideRequested = true }
        interfaceCount = count
    }
    public var shouldCheckClosure:Bool { phase == .visible && hideRequested && !pointerDown && !managerMenuOpen && menus.isEmpty }
    public var canHide:Bool { shouldCheckClosure && interfaceCount == 0 }
    public mutating func hiding(_ token:UInt64) throws {
        try require(token == generation && canHide,"The reveal session is not safe to hide")
        phase = .hiding
    }
    public mutating func cancelTransition() {
        precondition(phase == .revealing || phase == .hiding)
        generation += 1; phase = .stopping
    }
    public mutating func finish() { self = RevealState(generation:generation+1) }
    public mutating func fail() { phase = .failed }
    private init(generation:UInt64) { self.generation = generation }
}
