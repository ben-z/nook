import AppKit
import ApplicationServices

@MainActor public final class RevealController {
    public private(set) var state = RevealState()
    public private(set) var item: MenuBarItem?
    public private(set) var error: String?
    public var changed: (() -> Void)?
    private let configuration: Configuration
    private let movement: Movement
    private let control: CGWindowID
    private let group:HiddenGroup
    private var observer: InteractionObserver?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var workspaceMonitor: NSObjectProtocol?
    private var timer: Timer?
    private var baselineWindows = Set<CGWindowID>()
    private var hiddenOrder = [MenuBarItem]()
    public private(set) var receivedNotifications: [String:Int] = [:]
    public var resourceCount:Int { (observer == nil ? 0:1) + (globalMonitor == nil ? 0:1) + (localMonitor == nil ? 0:1) + (workspaceMonitor == nil ? 0:1) + (timer == nil ? 0:1) }

    public init(configuration:Configuration,movement:Movement,control:CGWindowID,group:HiddenGroup) {
        self.configuration = configuration; self.movement = movement; self.control = control
        self.group = group
    }

    private func transientWindows() throws -> Set<CGWindowID> {
        guard let item else { throw ManagerError("No revealed item") }
        return Set(try WindowMetadata.list(.optionOnScreenOnly,relativeTo:0).filter { window in
            window.pid == item.sourcePID && window.bounds.height > 0 &&
            ((window.layer > Int(CGWindowLevelForKey(.normalWindow)) && window.layer != Int(CGWindowLevelForKey(.statusWindow))) ||
             (window.bounds.height > configuration.maximumStatusWindowHeight && !baselineWindows.contains(window.id)))
        }.map(\.id))
    }

    public func reveal(_ item:MenuBarItem) async throws {
        let token = try state.begin()
        self.item = item; error = nil; receivedNotifications.removeAll()
        do {
            let current = try WindowMetadata.current(item.window.id)
            let dividerWindow = try WindowMetadata.current(group.window)
            try require(current.bounds.maxX <= dividerWindow.bounds.minX + configuration.geometryTolerance,"This icon is not in the hidden group")
            let hidden = try await group.windows()
            guard hidden.contains(where: { $0.id == current.id }) else { throw ManagerError("The hidden item's original position is missing") }
            let catalog = try await Catalog.read(configuration)
            hiddenOrder = try hidden.map { window in
                guard let item = catalog.items.first(where: { $0.window.id == window.id }) else { throw ManagerError("Cannot identify the hidden neighbour to preserve its order") }
                return item
            }
            baselineWindows = Set(try WindowMetadata.list(.optionOnScreenOnly,relativeTo:0).filter {
                $0.pid == item.sourcePID && $0.layer == Int(CGWindowLevelForKey(.normalWindow))
            }.map(\.id))
            try require(try transientWindows().isEmpty,"Close this application's open menus and popovers before revealing it")
            observer = try InteractionObserver(pid:item.sourcePID) { [weak self] element,name in self?.notification(element,name,token:token) }
            try installMonitors(token)
            let controlWindow = try WindowMetadata.current(control)
            try await movement.move(item.window.id,sourcePID:item.sourcePID,relativeTo:controlWindow.id,placement:.right)
            try require(state.generation == token,"The reveal session changed during movement")
            try require(try WindowMetadata.statusIsVisible(WindowMetadata.current(item.window.id).bounds),"There is not enough room to show this icon")
            state.revealed(); try refreshInterfaces(); changed?()
        } catch {
            guard state.generation == token else { finishCancellation(); return }
            fail(error)
            throw error
        }
    }

    private func installMonitors(_ token:UInt64) throws {
        let mask:NSEvent.EventTypeMask = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp]
        guard let global = NSEvent.addGlobalMonitorForEvents(matching:mask,handler:{[weak self] event in self?.mouse(event,token:token)}) else { throw ManagerError("Cannot observe clicks outside the manager") }
        globalMonitor = global
        guard let local = NSEvent.addLocalMonitorForEvents(matching:mask,handler:{[weak self] event in self?.mouse(event,token:token); return event}) else { throw ManagerError("Cannot observe the manager's clicks") }
        localMonitor = local
        workspaceMonitor = NSWorkspace.shared.notificationCenter.addObserver(forName:nil,object:nil,queue:.main) { [weak self] notification in
            if notification.name == NSWorkspace.activeSpaceDidChangeNotification {
                Task { @MainActor [weak self] in
                    guard let self, self.state.generation == token else { return }
                    self.requestHide()
                }
                return
            }
            guard notification.name == NSWorkspace.didActivateApplicationNotification else { return }
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let pid = application.processIdentifier
            Task { @MainActor [weak self] in
                guard let self, self.state.generation == token, pid != getpid(), pid != self.item?.sourcePID else { return }
                self.requestHide()
            }
        }
    }

    private func mouse(_ event:NSEvent,token:UInt64) {
        guard state.generation == token, state.phase == .visible, !movement.isMoving,
              event.cgEvent?.getIntegerValueField(.eventSourceUserData) != Movement.eventMarker else { return }
        do {
            let down = [.leftMouseDown,.rightMouseDown,.otherMouseDown].contains(event.type)
            state.mouse(down:down || NSEvent.pressedMouseButtons != 0)
            cancelTimer()
            if !down {
                try refreshInterfaces()
                guard let item, let point = event.cgEvent?.location else { throw ManagerError("Missing click location") }
                let insideIcon = try WindowMetadata.current(item.window.id).bounds.contains(point)
                if !insideIcon { state.requestHide() }
            }
            armTimer(); changed?()
        } catch { fail(error) }
    }

    private func notification(_ element:AXUIElement,_ name:String,token:UInt64) {
        guard state.generation == token, [.revealing,.visible].contains(state.phase) else { return }
        receivedNotifications[name,default:0] += 1
        cancelTimer()
        if name == kAXMenuOpenedNotification { state.menuOpened(AXElementIdentity(element)) }
        if name == kAXMenuClosedNotification || name == kAXUIElementDestroyedNotification { state.menuClosed(AXElementIdentity(element)) }
        do { try refreshInterfaces(); armTimer(); changed?() } catch { fail(error) }
    }

    private func refreshInterfaces() throws {
        let current = try transientWindows()
        state.interfaces(current.count)
    }

    public func requestHide() {
        guard state.phase == .visible else { return }
        do { state.requestHide(); try refreshInterfaces(); armTimer(); changed?() } catch { fail(error) }
    }

    public func managerMenu(_ open:Bool) {
        cancelTimer()
        state.managerMenu(open)
        if !open { state.mouse(down:NSEvent.pressedMouseButtons != 0) }
        armTimer(); changed?()
    }

    private func cancelTimer() {
        timer?.invalidate(); timer = nil
    }

    private func armTimer() {
        cancelTimer()
        guard state.phase == .visible, !state.pointerDown, !state.managerMenuOpen else { return }
        let token = state.generation
        let timer = Timer(timeInterval:configuration.gracePeriod,repeats:false) { [weak self] firedTimer in
            let identifier = ObjectIdentifier(firedTimer)
            MainActor.assumeIsolated {
                guard let self, self.state.generation == token, let current = self.timer, ObjectIdentifier(current) == identifier else { return }
                self.timer = nil
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    do { try await self.hide(token:token) } catch {
                        if self.state.generation == token { self.fail(error) }
                        else { self.finishCancellation() }
                    }
                }
            }
        }
        self.timer = timer; RunLoop.main.add(timer,forMode:.common)
    }

    private func hide(token:UInt64) async throws {
        guard token == state.generation, state.phase == .visible else { return }
        try refreshInterfaces()
        changed?()
        if !state.canHide { armTimer(); return }
        if !UserInput.isIdle(for:configuration.restorationQuietPeriod) { armTimer(); return }
        try state.hiding(token); changed?()
        guard let item else { throw ManagerError("Missing restoration information") }
        try await group.restore(item,order:hiddenOrder)
        guard state.generation == token else { finishCancellation(); return }
        stop(); changed?()
    }

    private func closeResources() {
        cancelTimer()
        if let globalMonitor { NSEvent.removeMonitor(globalMonitor); self.globalMonitor = nil }
        if let localMonitor { NSEvent.removeMonitor(localMonitor); self.localMonitor = nil }
        if let workspaceMonitor { NSWorkspace.shared.notificationCenter.removeObserver(workspaceMonitor); self.workspaceMonitor = nil }
        let observer = self.observer; self.observer = nil
        observer?.close()
    }

    private func fail(_ failure:Error) {
        state.fail(); error = failure.localizedDescription
        closeResources()
        changed?()
    }

    public func sourceTerminated(_ pid:pid_t) {
        guard item?.sourcePID == pid else { return }
        if state.phase == .revealing || state.phase == .hiding {
            closeResources(); state.cancelTransition()
        } else { stop() }
        changed?()
    }

    private func finishCancellation() {
        guard state.phase == .stopping else { return }
        stop(); changed?()
    }

    public func stop() {
        closeResources(); item = nil; hiddenOrder.removeAll(); baselineWindows.removeAll(); error = nil
        state.finish()
    }

    public var canRetryHiding:Bool {
        guard state.phase == .failed, let item else { return false }
        return hiddenOrder.contains(where: { $0.key == item.key })
    }

    public func retryHiding() async throws {
        try require(state.phase == .failed,"No failed reveal needs restoration")
        guard let item, hiddenOrder.contains(where: { $0.key == item.key }) else {
            throw ManagerError("The icon's original position is unavailable. Quit Nook to show the hidden group.")
        }
        try require(try transientWindows().isEmpty,"Close the application's menus, popovers and windows before retrying")
        let token = try state.retryHiding(); changed?()
        do {
            try await group.restore(item,order:hiddenOrder)
            guard state.generation == token else { finishCancellation(); return }
            stop(); changed?()
        } catch {
            guard state.generation == token else { finishCancellation(); return }
            fail(error); throw error
        }
    }

    isolated deinit { closeResources() }
}
