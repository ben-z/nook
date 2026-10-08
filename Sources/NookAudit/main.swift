import AppKit
import ApplicationServices
import Carbon
import ServiceManagement
import Darwin
import MenuBarCore

struct AuditConfiguration {
    var timeout:TimeInterval = 5
    var checkInterval:TimeInterval = 0.05
    var interactionHold:TimeInterval = 1.2
    var cycles:Int = 2000
    var sampleEvery:Int = 200
    var interactionSampleEvery:Int = 10
    var warmupCycles:Int = 5
    var timerInterval:TimeInterval = 0.001
}

func argument(_ name:String) throws -> String {
    guard let index = CommandLine.arguments.firstIndex(of:name),index+1 < CommandLine.arguments.count else { throw ManagerError("Missing argument \(name)") }
    return CommandLine.arguments[index+1]
}

func footprint(_ pid:pid_t) throws -> UInt64 {
    var info = rusage_info_v4()
    let result = withUnsafeMutablePointer(to:&info) { pointer in
        pointer.withMemoryRebound(to:rusage_info_t?.self,capacity:1) { proc_pid_rusage(pid,RUSAGE_INFO_V4,$0) }
    }
    try require(result == 0,"Cannot read physical footprint for \(pid): \(String(cString:strerror(errno)))")
    return info.ri_phys_footprint
}

struct AuditInterference:LocalizedError {
    let message:String
    var errorDescription:String? { message }
}

@MainActor final class Audit:NSObject,NSApplicationDelegate {
    let configuration = Configuration()
    var audit = AuditConfiguration()
    var samples = [[String:Any]]()
    var completed = [String]()
    var diagnostics:URL?
    var managerPID:pid_t?
    var fixturePID:pid_t?
    var revealWindow:CGWindowID?
    var expectedOrder:[CGWindowID]?
    var inputMonitor:AuditInputMonitor?
    var expectedFailure:String?

    func applicationDidFinishLaunching(_ notification:Notification) {
        Task { @MainActor in
            do {
                try Accessibility.configure(configuration)
                if CommandLine.arguments.contains("--cycles") {
                    guard let cycles = Int(try argument("--cycles")),cycles > 0 else { throw ManagerError("Invalid cycle count") }
                    audit.cycles = cycles
                }
                if CommandLine.arguments.contains("--sample-every") {
                    guard let every = Int(try argument("--sample-every")),every > 0 else { throw ManagerError("Invalid sampling interval") }
                    audit.sampleEvery = every
                }
                if ["--e2e","--sound-e2e","--stress","--space-e2e","--order-e2e","--lifecycle-e2e","--input-e2e","--restore-order","--restore","--select"].contains(where:CommandLine.arguments.contains) {
                    inputMonitor = try AuditInputMonitor()
                }
                defer { inputMonitor?.close() }
                if CommandLine.arguments.contains("--api") { try await api(try argument("--api")) }
                else if CommandLine.arguments.contains("--e2e") { try await endToEnd() }
                else if CommandLine.arguments.contains("--sound-e2e") {
                    try await connectManager()
                    for _ in 0..<audit.cycles { try await soundEndToEnd() }
                }
                else if CommandLine.arguments.contains("--stress") { try await stress() }
                else if CommandLine.arguments.contains("--space-e2e") { try await spaceEndToEnd() }
                else if CommandLine.arguments.contains("--order-e2e") { try await orderEndToEnd() }
                else if CommandLine.arguments.contains("--lifecycle-e2e") { try await lifecycleEndToEnd() }
                else if CommandLine.arguments.contains("--input-e2e") { try await inputEndToEnd() }
                else if CommandLine.arguments.contains("--press") { try await pressStatusItem() }
                else if CommandLine.arguments.contains("--press-title") {
                    guard let pid = pid_t(try argument("--pid")) else { throw ManagerError("Invalid process ID") }
                    let element = try await row(pid:pid,title:argument("--press-title"))
                    try Accessibility.check(AXUIElementPerformAction(element,kAXPressAction as CFString),"Press the test application's control")
                    completed.append("Pressed the requested test control")
                }
                else if CommandLine.arguments.contains("--select") {
                    try await connectManager()
                    try await select(try argument("--select"))
                    completed.append("Completed the selected menu action")
                }
                else if CommandLine.arguments.contains("--dismiss") {
                    let identifier = try argument("--target")
                    guard let application = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first else { throw ManagerError("The dismissal target is not running") }
                    try await dismiss(application.processIdentifier)
                    completed.append("Dismissed the test interaction")
                }
                else if CommandLine.arguments.contains("--restore-order") { try await restoreOrder() }
                else if CommandLine.arguments.contains("--restore") {
                    let source = try await item(try argument("--target"))
                    let before = CommandLine.arguments.contains("--before")
                    try require(before != CommandLine.arguments.contains("--after"),"Specify exactly one --before or --after destination")
                    let anchor = try await item(try argument(before ? "--before":"--after"))
                    try await Movement(configuration:configuration).move(source.window.id,sourcePID:source.sourcePID,relativeTo:anchor.window.id,placement:before ? .left:.right)
                    completed.append("Restored the tested icon's original neighbour")
                }
                else if CommandLine.arguments.contains("--inspect") { try await inspect() }
                else { throw ManagerError("Specify --api, --e2e, or --inspect") }
                try inputMonitor?.check()
                let result:[String:Any] = ["passed":true,"completed":completed,"samples":samples]
                let data = try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys])
                if CommandLine.arguments.contains("--output") { try data.write(to:URL(fileURLWithPath:try argument("--output")),options:.atomic) }
                print(String(data:data,encoding:.utf8)!); NSApp.terminate(nil)
            } catch {
                var message = error.localizedDescription
                if let interference = inputMonitor?.interference { message = interference }
                fputs("AUDIT FAILED: \(message)\n",stderr)
                if CommandLine.arguments.contains("--output") {
                    do {
                        let failure:[String:Any] = ["passed":false,"inconclusive":error is AuditInterference || inputMonitor?.hadInterference == true,"error":message,"completed":completed,"samples":samples]
                        try JSONSerialization.data(withJSONObject:failure,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:try argument("--output")),options:.atomic)
                    } catch { fputs("Cannot save the failed audit: \(error.localizedDescription)\n",stderr); exit(2) }
                }
                exit(1)
            }
        }
    }

    func sample(_ stage:String,_ cycle:Int,_ pid:pid_t) throws {
        samples.append(["stage":stage,"cycle":cycle,"pid":pid,"physicalFootprintBytes":try footprint(pid),"observers":InteractionObserver.liveCount,"dragChannels":DragDelivery.liveCount,"nativeStatusWindows":try WindowMetadata.statusWindows(configuration).count,"allWindowDescriptions":try WindowMetadata.list(.optionAll,relativeTo:0).count])
    }

    func api(_ name:String) async throws {
        let targetName = try argument("--target")
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier:targetName).first else { throw ManagerError("Target is not running: \(targetName)") }
        try sample("baseline",0,getpid())
        let previousWindows = Set(try WindowMetadata.statusWindows(configuration).map(\.id))
        let reusedItem:NSStatusItem?
        if ["status-resize","status-resize-settled"].contains(name) {
            reusedItem = NSStatusBar.system.statusItem(withLength:configuration.controlWidth)
            reusedItem!.button!.title = "T"
            reusedItem!.button!.setAccessibilityIdentifier("audit.memory.status")
        } else { reusedItem = nil }
        defer { if let reusedItem { NSStatusBar.system.removeStatusItem(reusedItem) } }
        let reusedGroup:HiddenGroup?
        if name == "status-resize-settled" {
            let window = try await WindowMetadata.owned(identifier:"audit.memory.status",configuration:configuration,excluding:previousWindows)
            reusedGroup = HiddenGroup(item:reusedItem!,window:window.id,configuration:configuration,movement:Movement(configuration:configuration))
        } else { reusedGroup = nil }
        for cycle in 1...audit.cycles {
            weak var removedGlobal:TimerFlag?
            weak var removedLocal:TimerFlag?
            try autoreleasepool {
                switch name {
                case "pressed-mouse-buttons":
                    _ = NSEvent.pressedMouseButtons; _ = NSEvent.modifierFlags
                    for type in [CGEventType.mouseMoved,.scrollWheel,.keyDown,.keyUp,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp] {
                        _ = CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:type)
                    }
                case "window-metadata":
                    let list = try WindowMetadata.statusWindows(configuration)
                    try require(!list.isEmpty,"No status windows")
                    _ = try WindowMetadata.current(list[0].id)
                case "accessibility-read":
                    let root = AXUIElementCreateApplication(target.processIdentifier)
                    let bar = try Accessibility.element(Accessibility.required(root,kAXExtrasMenuBarAttribute))
                    for child in try Accessibility.children(bar) {
                        _ = try Accessibility.bounds(child)
                        _ = try Accessibility.string(child,kAXDescriptionAttribute)
                    }
                case "observers":
                    var observer:InteractionObserver? = try InteractionObserver(pid:target.processIdentifier) {_,_ in }
                    weak let weakObserver = observer
                    if cycle.isMultiple(of:2) { observer!.close() }
                    observer = nil
                    try require(weakObserver == nil && InteractionObserver.liveCount == 0,"Interaction observer was retained after teardown")
                case "drag-channels":
                    var delivery:DragDelivery? = try DragDelivery(pid:target.processIdentifier,configuration:configuration)
                    weak let weakDelivery = delivery
                    if cycle.isMultiple(of:2) { delivery!.close() }
                    delivery = nil
                    try require(weakDelivery == nil && DragDelivery.liveCount == 0,"The drag event channels were retained after teardown")
                case "mouse-monitors":
                    let globalFlag = TimerFlag(); let localFlag = TimerFlag()
                    removedGlobal = globalFlag; removedLocal = localFlag
                    guard let global = NSEvent.addGlobalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp],handler:{[globalFlag] _ in globalFlag.fired = true }),
                          let local = NSEvent.addLocalMonitorForEvents(matching:[.leftMouseDown,.leftMouseUp],handler:{[localFlag] event in localFlag.fired = true; return event}) else { throw ManagerError("Cannot create event monitor") }
                    NSEvent.removeMonitor(global); NSEvent.removeMonitor(local)
                case "audit-input":
                    var monitor:AuditInputMonitor? = try AuditInputMonitor()
                    weak let weakMonitor = monitor
                    if cycle.isMultiple(of:2) { monitor!.close() }
                    monitor = nil
                    try require(weakMonitor == nil,"The GUI audit's input monitor remained alive after teardown")
                case "running-app-observation":
                    var observation:NSKeyValueObservation? = NSWorkspace.shared.observe(\.runningApplications,options:[]) { workspace,_ in
                        _ = workspace.runningApplications
                    }
                    weak let weakObservation = observation
                    observation!.invalidate(); observation = nil
                    try require(weakObservation == nil,"The running-app observation was retained after invalidation")
                case "workspace":
                    let monitor = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.didActivateApplicationNotification,object:nil,queue:.main) {_ in }
                    NSWorkspace.shared.notificationCenter.removeObserver(monitor)
                    _ = NSWorkspace.shared.runningApplications
                    guard let current = NSRunningApplication(processIdentifier:target.processIdentifier) else { throw ManagerError("The API audit source process exited") }
                    try require(!current.isTerminated && current.bundleIdentifier == targetName,"The API audit source identity changed")
                case "status-items":
                    let item = NSStatusBar.system.statusItem(withLength:configuration.controlWidth)
                    item.button!.title = "T"
                    item.length = configuration.expandedDividerWidth
                    item.length = configuration.controlWidth
                    NSStatusBar.system.removeStatusItem(item)
                case "status-resize":
                    guard let reusedItem else { throw ManagerError("Missing reusable status item") }
                    reusedItem.length = configuration.expandedDividerWidth
                    reusedItem.length = configuration.controlWidth
                case "screen-geometry":
                    for screen in NSScreen.screens {
                        _ = screen.frame; _ = screen.visibleFrame; _ = screen.auxiliaryTopRightArea
                    }
                    _ = CGDisplayBounds(CGMainDisplayID())
                case "cursor":
                    guard let location = CGEvent(source:nil)?.location else { throw ManagerError("Cannot read pointer location") }
                    try require(CGDisplayHideCursor(CGMainDisplayID()) == .success,"Cannot hide cursor")
                    let warped = CGWarpMouseCursorPosition(location)
                    let shown = CGDisplayShowCursor(CGMainDisplayID())
                    try require(warped == .success && shown == .success,"Cannot restore cursor")
                case "menus":
                    let menu = NSMenu(title:"Memory test")
                    let item = NSMenuItem(title:"A",action:nil,keyEquivalent:"")
                    item.representedObject = "test"; menu.addItem(item); menu.removeAllItems()
                case "events":
                    guard let source = CGEventSource(stateID:.hidSystemState),
                          let event = CGEvent(mouseEventSource:source,mouseType:.leftMouseDown,mouseCursorPosition:.zero,mouseButton:.left),
                          let field = CGEventField(rawValue:0x33) else { throw ManagerError("Cannot create drag-event API objects") }
                    source.localEventsSuppressionInterval = 0
                    event.setIntegerValueField(field,value:1)
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:1)
                    event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:1)
                    event.setIntegerValueField(.eventSourceUserData,value:Movement.eventMarker)
                    _ = event.location; _ = CGEventSource.buttonState(.combinedSessionState,button:.left)
                    guard let session = CGEventSource(stateID:.combinedSessionState) else { throw ManagerError("Cannot create a session event source") }
                    let states = [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,.eventSuppressionStateSuppressionInterval]
                    for state in states {
                        let filter = session.getLocalEventsFilterDuringSuppressionState(state)
                        session.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents,.permitLocalKeyboardEvents,.permitSystemDefinedEvents],state:state)
                        session.setLocalEventsFilterDuringSuppressionState(filter,state:state)
                    }
                case "hotkey":
                    var handler:EventHandlerRef?; var hotKey:EventHotKeyRef?
                    let install = InstallEventHandler(GetApplicationEventTarget(),{_,_,_ in noErr},1,[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))],nil,&handler)
                    try require(install == noErr,"Cannot install test hotkey handler")
                    let registered = RegisterEventHotKey(configuration.hotKeyCode,UInt32(controlKey|optionKey|shiftKey),EventHotKeyID(signature:0x41554454,id:1),GetApplicationEventTarget(),0,&hotKey)
                    try require(registered == noErr,"Cannot register test hotkey")
                    try require(UnregisterEventHotKey(hotKey!) == noErr,"Cannot unregister test hotkey")
                    try require(RemoveEventHandler(handler!) == noErr,"Cannot remove test hotkey handler")
                case "login-status": _ = SMAppService.mainApp.status
                case "preferences":
                    guard let defaults = UserDefaults(suiteName:"com.benzhang.nook.memoryaudit") else { throw ManagerError("Cannot create isolated defaults") }
                    defaults.set(["test"],forKey:"hiddenKeys")
                    try require(defaults.array(forKey:"hiddenKeys") as? [String] == ["test"],"Preference round trip failed")
                    defaults.removePersistentDomain(forName:"com.benzhang.nook.memoryaudit")
                case "timers","catalog","status-resize-settled","drag-timeout","drag-cancellation","drag-close": break
                default: throw ManagerError("Unknown API group \(name)")
                }
            }
            if name == "mouse-monitors" {
                try require(removedGlobal == nil && removedLocal == nil,"A removed mouse monitor retained its handler")
            }
            if name == "status-resize-settled" {
                guard let reusedGroup else { throw ManagerError("Missing reusable status group") }
                try await reusedGroup.expanded(true); try await reusedGroup.expanded(false)
            }
            if name == "catalog" { _ = try await Catalog.read(configuration) }
            if ["drag-timeout","drag-cancellation","drag-close"].contains(name) {
                var delivery:DragDelivery? = try DragDelivery(pid:target.processIdentifier,configuration:configuration)
                weak let weakDelivery = delivery
                guard let event = CGEvent(source:nil) else { throw ManagerError("Cannot allocate the test packet") }
                // A null payload cannot reach the mouse receipt channel and changes no input state.
                let sender = Task { @MainActor [delivery = delivery!] in try await delivery.send(event) }
                if name == "drag-cancellation" || name == "drag-close" {
                    try await Task.sleep(for:.seconds(audit.checkInterval))
                    if name == "drag-cancellation" { sender.cancel() }
                    else { delivery!.close() }
                }
                do {
                    try await sender.value
                    throw ManagerError("The deliberately unacknowledged packet unexpectedly succeeded")
                } catch is CancellationError {
                    try require(name == "drag-cancellation","A timeout packet was canceled unexpectedly")
                } catch let error as ManagerError {
                    let expected = name == "drag-close" ? "The native drag channel closed during delivery":"macOS did not receive the request to move the icon"
                    try require(name != "drag-cancellation" && error.message == expected,"Unexpected drag failure: \(error.localizedDescription)")
                }
                delivery!.close(); delivery = nil
                try require(weakDelivery == nil && DragDelivery.liveCount == 0,"Drag delivery remained alive after the pending packet ended")
            }
            if name == "timers" {
                let flag = TimerFlag()
                let timer = Timer(timeInterval:audit.timerInterval,repeats:false) { [weak flag] _ in MainActor.assumeIsolated { flag?.fired = true } }
                RunLoop.main.add(timer,forMode:.common)
                try await Task.sleep(for:.seconds(audit.checkInterval))
                try require(flag.fired && !timer.isValid,"One-shot timer did not fire and invalidate")
            }
            if cycle.isMultiple(of:audit.sampleEvery) {
                try await Task.sleep(for:.seconds(audit.checkInterval))
                try sample("load",cycle,getpid())
            }
        }
        try await Task.sleep(for:.seconds(configuration.gracePeriod))
        if CommandLine.arguments.contains("--hold-for-leaks") {
            guard let seconds = TimeInterval(try argument("--hold-for-leaks")),seconds > 0 else { throw ManagerError("Invalid heap-scan hold interval") }
            try await Task.sleep(for:.seconds(seconds))
        }
        try sample("settled",audit.cycles,getpid())
        completed.append("\(name): \(audit.cycles) cycles")
    }

    func pressStatusItem() async throws {
        let identifier = try argument("--target")
        guard let target = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first else { throw ManagerError("The native activation target is not running") }
        let pid = target.processIdentifier
        let bar = try Accessibility.element(Accessibility.required(AXUIElementCreateApplication(pid),kAXExtrasMenuBarAttribute))
        let children = try Accessibility.children(bar)
        try require(children.count == 1,"Native activation requires exactly one test status item")
        var actions:CFArray?
        try Accessibility.check(AXUIElementCopyActionNames(children[0],&actions),"Read native status-item actions")
        try require((actions as? [String])?.contains(kAXPressAction) == true,"The native status item does not support AXPress")
        func interfaces() throws -> Set<CGWindowID> {
            Set(try WindowMetadata.list(.optionOnScreenOnly,relativeTo:0).filter {$0.pid == pid && $0.bounds.height > configuration.maximumStatusWindowHeight}.map(\.id))
        }
        let before = try interfaces()
        try Accessibility.check(AXUIElementPerformAction(children[0],kAXPressAction as CFString),"Press native status item")
        try await wait("native status-item interface appeared") { try !interfaces().subtracting(before).isEmpty }
        try await Task.sleep(for:.seconds(audit.interactionHold))
        try require(try !interfaces().subtracting(before).isEmpty,"Native activation did not keep its interface open")
        try await dismiss(target.processIdentifier)
        try await wait("native interface dismissed") { try interfaces().subtracting(before).isEmpty }
        completed.append("AXPress opened and dismissed the native status-item interface")
    }

    func inspect() async throws {
        let catalog = try await Catalog.read(configuration)
        for item in catalog.items { print("ITEM \(item.key) name=\(item.name) pid=\(item.sourcePID) window=\(item.window.id) bounds=\(item.window.bounds)") }
        for error in catalog.inspectionErrors { print("INSPECTION ERROR \(error)") }
        if CommandLine.arguments.contains("--target") {
            let identifier = try argument("--target")
            guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first else { throw ManagerError("No target application") }
            try printTree(AXUIElementCreateApplication(app.processIdentifier),depth:0)
        }
    }

    func printTree(_ element:AXUIElement,depth:Int) throws {
        try require(depth <= configuration.maximumAccessibilityDepth,"Accessibility tree exceeded the depth limit")
        print(String(repeating:" ",count:depth),try Accessibility.string(element,kAXRoleAttribute) as Any,try Accessibility.string(element,kAXTitleAttribute) as Any)
        for child in try Accessibility.children(element) { try printTree(child,depth:depth+1) }
    }

    func state() throws -> [String:Any] {
        try inputMonitor?.check()
        guard let diagnostics else { throw ManagerError("Missing diagnostics path") }
        guard let value = try JSONSerialization.jsonObject(with:Data(contentsOf:diagnostics)) as? [String:Any] else { throw ManagerError("Invalid diagnostics") }
        if let error = value["error"] as? String, error != expectedFailure { throw ManagerError(error) }
        if let error = value["failure"] as? String, error != expectedFailure { throw ManagerError(error) }
        try require(value["pid"] as? pid_t == managerPID,"Diagnostics belong to another process")
        return value
    }

    func wait(_ description:String,_ predicate:() throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(audit.timeout)
        while Date() < deadline {
            try inputMonitor?.check()
            if try predicate() { return }
            try await Task.sleep(for:.seconds(audit.checkInterval))
        }
        throw ManagerError("Timed out: \(description)")
    }

    func click(_ id:CGWindowID) async throws {
        let frame = try WindowMetadata.current(id).bounds
        try await click(frame)
    }

    func click(_ frame:CGRect) async throws {
        try require(frame.width > 0 && frame.height > 0,"The test click target has no visible bounds")
        let point = CGPoint(x:frame.midX,y:frame.midY)
        guard let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else { throw ManagerError("Cannot create test click") }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState,value:1); up.setIntegerValueField(.mouseEventClickState,value:0)
        down.post(tap:.cghidEventTap)
        try await Task.sleep(for:.seconds(audit.checkInterval))
        up.post(tap:.cghidEventTap)
        try await Task.sleep(for:.seconds(audit.checkInterval))
    }

    func escape() async throws {
        try await key(53,flags:[])
    }

    func dismiss(_ pid:pid_t) async throws {
        guard let application = NSRunningApplication(processIdentifier:pid) else { throw ManagerError("The dismissal target exited") }
        try require(application.activate(options:[]),"Cannot activate the dismissal target")
        try await wait("dismissal target activation") { NSWorkspace.shared.frontmostApplication?.processIdentifier == pid }
        try await escape(); try await escape()
    }

    func key(_ code:CGKeyCode,flags:CGEventFlags) async throws {
        guard let down = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:true),let up = CGEvent(keyboardEventSource:nil,virtualKey:code,keyDown:false) else { throw ManagerError("Cannot create test key event") }
        down.flags = flags; up.flags = []
        down.post(tap:.cghidEventTap); up.post(tap:.cghidEventTap)
        try await Task.sleep(for:.seconds(audit.checkInterval))
    }

    func find(_ element:AXUIElement,title:String,depth:Int) throws -> AXUIElement? {
        try require(depth <= configuration.maximumAccessibilityDepth,"Accessibility tree exceeded the depth limit")
        if try Accessibility.string(element,kAXTitleAttribute) == title { return element }
        for child in try Accessibility.children(element) {
            if let match = try find(child,title:title,depth:depth+1) { return match }
        }
        return nil
    }

    func row(pid:pid_t,title:String) async throws -> AXUIElement {
        let root = AXUIElementCreateApplication(pid)
        var found:AXUIElement?
        try await wait("menu row \(title)") { found = try find(root,title:title,depth:0); return found != nil }
        return found!
    }

    func select(_ title:String) async throws {
        print("SELECT \(title)"); fflush(stdout)
        guard let managerPID else { throw ManagerError("No manager process") }
        guard let completed = try state()["completedActions"] as? UInt64 else { throw ManagerError("No completed action counter") }
        guard let control = try state()["controlWindow"] as? UInt32 else { throw ManagerError("No control window") }
        try await click(control)
        try await wait("manager menu presentation") { try state()["menuPresented"] as? Bool == true }
        if title.hasPrefix("Hide ") && !title.hasSuffix(" now") || title.hasPrefix("Keep ") {
            let manage = try await row(pid:managerPID,title:"Manage icons")
            try Accessibility.check(AXUIElementPerformAction(manage,kAXPressAction as CFString),"Open Manage icons")
        }
        let element = try await row(pid:managerPID,title:title)
        try Accessibility.check(AXUIElementPerformAction(element,kAXPressAction as CFString),"Select \(title)")
        if title == "Quit Nook" {
            try await wait("manager quit") { NSRunningApplication(processIdentifier:managerPID)?.isTerminated != false }
            return
        }
        try await wait("menu selection completed") { try state()["completedActions"] as! UInt64 > completed && state()["busy"] as? Bool == false && state()["managerMenuOpen"] as? Bool == false }
    }

    func item(_ identifier:String) async throws -> MenuBarItem {
        let catalog = try await Catalog.read(configuration)
        let matches = catalog.items.filter {$0.bundleIdentifier == identifier}
        try require(matches.count == 1,"Expected exactly one item for \(identifier): \(catalog.inspectionErrors.joined(separator:"; "))")
        return matches[0]
    }

    func assertHidden() async throws {
        try await wait("automatic restoration") { try state()["phase"] as? String == "hidden" }
        try require(try state()["resources"] as? Int == 0,"Reveal resources remained allocated after hiding")
        try require(try state()["observers"] as? Int == 0,"Interaction observer remained alive")
        try require(try state()["dragChannels"] as? Int == 0,"Drag channels remained alive")
        guard let revealWindow, let divider = try state()["dividerWindow"] as? CGWindowID else { throw ManagerError("Missing tested window identity") }
        let frame = try WindowMetadata.current(revealWindow).bounds
        try require(frame.maxX <= WindowMetadata.current(divider).bounds.minX+configuration.geometryTolerance,"The restored icon is outside the hidden group")
        try require(!WindowMetadata.statusIsVisible(frame),"The hidden icon is still on a usable menu bar")
        if let expectedOrder {
            let current = try await nativeOrder()
            let surviving = Set(current).intersection(expectedOrder)
            try require(current.filter { surviving.contains($0) } == expectedOrder.filter { surviving.contains($0) },"The surviving icon order changed across the reveal/hide cycle: \(expectedOrder) → \(current)")
        }
    }

    func nativeOrder() async throws -> [CGWindowID] {
        try await WindowMetadata.settledStatusWindows(configuration).sorted {$0.bounds.minX < $1.bounds.minX}.map(\.id)
    }

    func assertHeld() async throws {
        try await Task.sleep(for:.seconds(audit.interactionHold))
        try require(try state()["phase"] as? String == "visible","Icon hid during an active interface")
        let count = (try state()["interfaces"] as! Int)+(try state()["menus"] as! Int)
        try require(count > 0,"No active interface was detected")
    }

    func connectManager() async throws {
        guard let managerPID = pid_t(try argument("--manager")), let fixturePID = pid_t(try argument("--fixture")) else { throw ManagerError("Invalid process IDs") }
        self.managerPID = managerPID; self.fixturePID = fixturePID
        diagnostics = URL(fileURLWithPath:try argument("--diagnostics"))
        try await wait("manager startup") {
            guard FileManager.default.fileExists(atPath:diagnostics!.path) else { return false }
            return try state()["phase"] as? String == "hidden" && state()["busy"] as? Bool == false
        }
        guard let identities = try state()["identities"] as? [[String:Any]] else { throw ManagerError("Missing native item identities") }
        for entry in identities {
            guard let key = entry["key"] as? String, let pid = entry["pid"] as? pid_t, let window = entry["window"] as? CGWindowID else { throw ManagerError("Invalid native item identity") }
            await Catalog.bindWindow(key,pid:pid,window:window)
        }
        let value = try state()
        guard let hidden = value["hidden"] as? [String],let divider = value["dividerWindow"] as? CGWindowID else { throw ManagerError("Missing hidden-group configuration") }
        let boundary = try WindowMetadata.current(divider).bounds.minX
        for entry in identities {
            let pid = entry["pid"] as! pid_t
            if pid == managerPID { continue }
            let key = entry["key"] as! String
            let bounds = try WindowMetadata.current(entry["window"] as! CGWindowID).bounds
            try require((bounds.maxX <= boundary+configuration.geometryTolerance) == hidden.contains(key),"The hidden group does not match the selected icons: \(key)")
        }
    }

    func endToEnd() async throws {
        try await connectManager()
        guard let managerPID,let fixturePID else { throw ManagerError("Test processes were not connected") }
        let fixture = try await item("com.benzhang.nook.fixture")
        revealWindow = fixture.window.id
        let name = fixture.name
        if !(try state()["hidden"] as! [String]).contains(fixture.key) { try await select("Hide \(name)") }
        try await select("Keep \(name) visible")
        try await select("Hide \(name)")
        expectedOrder = try await nativeOrder()
        try await select("Show \(name)")
        try await wait("reveal") { try state()["phase"] as? String == "visible" }
        try await click(fixture.window.id)
        _ = try await row(pid:fixturePID,title:"Nested menu")
        try await assertHeld()
        try await escape(); try await assertHidden()
        completed.append("Native menu remains visible while open and restores after Escape")
        try await select("Show \(name)")
        try await click(fixture.window.id)
        let nested = try await row(pid:fixturePID,title:"Nested menu")
        try Accessibility.check(AXUIElementPerformAction(nested,kAXPressAction as CFString),"Open submenu")
        _ = try await row(pid:fixturePID,title:"Harmless action")
        try await assertHeld(); try await key(123,flags:[]); try await assertHeld(); try await escape(); try await assertHidden()
        completed.append("Closing a submenu preserves the root interaction")
        for (title,button) in [("Open popover","Close popover"),("Open panel","Close panel"),("Open window","Close window")] {
            try await select("Show \(name)")
            try await click(fixture.window.id)
            let menuItem = try await row(pid:fixturePID,title:title)
            try await click(Accessibility.bounds(menuItem))
            let close = try await row(pid:fixturePID,title:button)
            try await assertHeld()
            try Accessibility.check(AXUIElementPerformAction(close,kAXPressAction as CFString),button)
            try await assertHidden(); completed.append("\(title) transition and closure")
        }
        try await select("Show \(name)")
        try await click(fixture.window.id)
        try await wait("menu opened") { try state()["interfaces"] as! Int > 0 }
        try await escape()
        try await wait("native menu closed before reopening") {
            try state()["menus"] as? Int == 0 && WindowMetadata.list(.optionOnScreenOnly,relativeTo:0).allSatisfy {
                $0.pid != fixturePID || $0.bounds.height <= configuration.maximumStatusWindowHeight
            }
        }
        try await click(fixture.window.id)
        try await wait("native menu reopened before restoration") { try state()["interfaces"] as! Int > 0 }
        try await assertHeld(); try await escape(); try await assertHidden()
        completed.append("Reopening cancels an older pending hide")

        let clickWindow = NSWindow(contentRect:NSRect(x:500,y:300,width:180,height:120),styleMask:[.titled],backing:.buffered,defer:false)
        clickWindow.title = "Interaction test"; clickWindow.isReleasedWhenClosed = false
        clickWindow.orderFrontRegardless()
        try await select("Show \(name)")
        let frame = try WindowMetadata.current(CGWindowID(clickWindow.windowNumber)).bounds
        let point = CGPoint(x:frame.midX,y:frame.midY)
        guard let down = CGEvent(mouseEventSource:nil,mouseType:.leftMouseDown,mouseCursorPosition:point,mouseButton:.left),
              let up = CGEvent(mouseEventSource:nil,mouseType:.leftMouseUp,mouseCursorPosition:point,mouseButton:.left) else { throw ManagerError("Cannot create held-click test events") }
        down.flags = []; up.flags = []
        down.setIntegerValueField(.mouseEventClickState,value:1); up.setIntegerValueField(.mouseEventClickState,value:0)
        down.post(tap:.cghidEventTap)
        do {
            try await Task.sleep(for:.seconds(audit.interactionHold))
            try require(try state()["phase"] as? String == "visible","Icon hid while the mouse button was held")
        } catch { up.post(tap:.cghidEventTap); throw error }
        up.post(tap:.cghidEventTap)
        try await assertHidden(); clickWindow.close()
        completed.append("Click away and mouse-down safety")

        clickWindow.orderFrontRegardless()
        try await select("Show \(name)")
        guard let rightDown = CGEvent(mouseEventSource:nil,mouseType:.rightMouseDown,mouseCursorPosition:point,mouseButton:.right),let rightUp = CGEvent(mouseEventSource:nil,mouseType:.rightMouseUp,mouseCursorPosition:point,mouseButton:.right) else { throw ManagerError("Cannot create simultaneous-button test events") }
        rightDown.flags = []; rightUp.flags = []
        down.post(tap:.cghidEventTap); rightDown.post(tap:.cghidEventTap)
        do {
            try await Task.sleep(for:.seconds(audit.interactionHold))
            try require(try state()["phase"] as? String == "visible","Icon hid while both mouse buttons were held")
            up.post(tap:.cghidEventTap)
            try await Task.sleep(for:.seconds(audit.interactionHold))
            try require(try state()["phase"] as? String == "visible","Icon hid after releasing only one of two held buttons")
        } catch { up.post(tap:.cghidEventTap); rightUp.post(tap:.cghidEventTap); throw error }
        rightUp.post(tap:.cghidEventTap)
        try await assertHidden(); clickWindow.close()
        completed.append("Automatic hiding waits until every pressed mouse button is released")

        try await select("Show \(name)")
        try await select("Hide \(name) now")
        guard let pointer = CGEvent(source:nil)?.location else { throw ManagerError("Cannot read the test pointer") }
        let motionDeadline = Date().addingTimeInterval(audit.interactionHold)
        while Date() < motionDeadline {
            guard let motion = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:pointer,mouseButton:.left) else { throw ManagerError("Cannot allocate the motion test") }
            motion.setIntegerValueField(.eventSourceUserData,value:Movement.eventMarker)
            motion.post(tap:.cghidEventTap)
            try await Task.sleep(for:.seconds(audit.checkInterval))
            try require(try state()["phase"] as? String == "visible","Icon hid during continuous pointer motion")
        }
        try await assertHidden()
        completed.append("Pending automatic hiding waits for pointer motion to stop")

        try await select("Show \(name)")
        try await key(CGKeyCode(configuration.hotKeyCode),flags:[.maskControl,.maskAlternate])
        try await wait("keyboard shortcut opened the manager") { try state()["menuPresented"] as? Bool == true }
        try await Task.sleep(for:.seconds(audit.interactionHold))
        try require(try state()["phase"] as? String == "visible","Icon hid while the manager menu was open")
        let hideNow = try await row(pid:managerPID,title:"Hide \(name) now")
        try Accessibility.check(AXUIElementPerformAction(hideNow,kAXPressAction as CFString),"Hide from keyboard-opened menu")
        try await assertHidden()
        completed.append("Global keyboard shortcut and manager-menu safety")

        try await select("Keep \(name) visible")
        let maccy = try await item("org.p0deje.Maccy")
        if (try state()["hidden"] as! [String]).contains(maccy.key) {
            try await select("Keep \(maccy.name) visible")
        }
        revealWindow = maccy.window.id
        try await select("Hide \(maccy.name)"); expectedOrder = try await nativeOrder(); try await select("Show \(maccy.name)")
        try await click(maccy.window.id); try await assertHeld()
        try await dismiss(maccy.sourcePID); try await assertHidden()
        try await select("Keep \(maccy.name) visible")
        try require(try WindowMetadata.statusIsVisible(WindowMetadata.current(maccy.window.id).bounds),"Maccy's icon did not remain visible")
        completed.append("Actual Maccy popup and restoration")
        if CommandLine.arguments.contains("--system") {
            try await soundEndToEnd()
        }
        try sample("settled",0,managerPID)
    }

    func soundEndToEnd() async throws {
        let catalog = try await Catalog.read(configuration)
        guard let sound = catalog.items.first(where: { $0.key == "com.apple.controlcenter:com.apple.menuextra.sound" }) else { throw ManagerError("The system Sound item is missing") }
        if !(try state()["hidden"] as! [String]).contains(sound.key) { try await select("Hide \(sound.name)") }
        revealWindow = sound.window.id; expectedOrder = try await nativeOrder()
        try await select("Show \(sound.name)")
        try await click(sound.window.id); try await assertHeld()
        try await escape(); try await assertHidden()
        try await select("Keep \(sound.name) visible")
        completed.append("Actual system Sound popup and restoration")
    }
    func restoreOrder() async throws {
        let data = try Data(contentsOf:URL(fileURLWithPath:argument("--restore-order")))
        guard let keys = try JSONSerialization.jsonObject(with:data) as? [String],!keys.isEmpty else { throw ManagerError("Invalid original icon order") }
        let catalog = try await Catalog.read(configuration)
        var items = [MenuBarItem]()
        for key in keys {
            guard let item = catalog.items.first(where: { $0.key == key }) else { throw ManagerError("The original icon \(key) is missing") }
            items.append(item)
        }
        let ids = items.map { $0.window.id }
        try require(Set(ids) == Set(try await nativeOrder()),"The original order does not account for every live status item")
        guard let prefixCount = Int(try argument("--prefix-count")),prefixCount > 0,prefixCount < items.count else { throw ManagerError("Invalid original prefix length") }
        let movement = Movement(configuration:configuration)
        for index in (0..<prefixCount).reversed() {
            let item = items[index]
            try await movement.move(item.window.id,sourcePID:item.sourcePID,relativeTo:items[index+1].window.id,placement:.left)
        }
        try require(try await nativeOrder() == ids,"The original native icon order was not restored")
        completed.append("Every native icon matches the complete original order")
    }

    func spaceEndToEnd() async throws {
        try await connectManager()
        guard let managerPID,let fixturePID else { throw ManagerError("Missing test processes") }
        let counter = SpaceCounter()
        let monitor = NSWorkspace.shared.notificationCenter.addObserver(forName:NSWorkspace.activeSpaceDidChangeNotification,object:nil,queue:.main) { _ in
            MainActor.assumeIsolated { counter.changes += 1 }
        }
        defer { NSWorkspace.shared.notificationCenter.removeObserver(monitor) }
        let fixture = try await item("com.benzhang.nook.fixture")
        if !(try state()["hidden"] as! [String]).contains(fixture.key) { try await select("Hide \(fixture.name)") }
        revealWindow = fixture.window.id; expectedOrder = try await nativeOrder()
        try await select("Show \(fixture.name)")
        try await click(fixture.window.id)
        let fullscreen = try await row(pid:fixturePID,title:"Open fullscreen window")
        try Accessibility.check(AXUIElementPerformAction(fullscreen,kAXPressAction as CFString),"Open the full-screen fixture window")
        try await wait("a real fullscreen Space appeared") { counter.changes >= 1 }
        let close = try await row(pid:fixturePID,title:"Close window")
        try await assertHeld()
        try Accessibility.check(AXUIElementPerformAction(close,kAXPressAction as CFString),"Close the full-screen fixture window")
        try await wait("the original Space returned") { counter.changes >= 2 }
        try await assertHidden()
        completed.append("Entering and leaving a real fullscreen Space preserves the active interface and restores icon order")
        try sample("settled",0,managerPID)
    }

    func orderEndToEnd() async throws {
        try await connectManager()
        let identifiers = ["org.p0deje.Maccy","io.tailscale.ipn.macsys","com.benzhang.nook.fixture"]
        var items = [MenuBarItem]()
        for identifier in identifiers { items.append(try await item(identifier)) }
        for item in items where !(try state()["hidden"] as! [String]).contains(item.key) {
            try await select("Hide \(item.name)")
        }
        expectedOrder = try await nativeOrder()
        for item in items {
            revealWindow = item.window.id
            try await select("Show \(item.name)")
            try require(try WindowMetadata.statusIsVisible(WindowMetadata.current(item.window.id).bounds),"The requested icon is not visible")
            try await select("Hide \(item.name) now")
            try await assertHidden()
            completed.append("Three-item group restores its complete order after revealing \(item.name)")
        }
        guard let managerPID else { throw ManagerError("No manager process") }
        try sample("settled",0,managerPID)
    }

    func lifecycleEndToEnd() async throws {
        try await connectManager()
        guard let fixturePID,let managerPID,let fixtureApp = NSRunningApplication(processIdentifier:fixturePID),let bundleURL = fixtureApp.bundleURL else { throw ManagerError("The fixture process is missing") }
        let fixture = try await item("com.benzhang.nook.fixture")
        if !(try state()["hidden"] as! [String]).contains(fixture.key) { try await select("Hide \(fixture.name)") }
        try await select("Show \(fixture.name)")
        try await click(fixture.window.id)
        try await wait("fixture menu opened before termination") { try state()["menus"] as! Int > 0 }
        let quit = try await row(pid:fixturePID,title:"Quit fixture")
        try Accessibility.check(AXUIElementPerformAction(quit,kAXPressAction as CFString),"Quit the fixture from its native menu")
        try await wait("terminated source released its session") {
            try state()["phase"] as? String == "hidden" && state()["resources"] as? Int == 0 && state()["observers"] as? Int == 0 && state()["dragChannels"] as? Int == 0
        }
        completed.append("Quitting a source with its menu open releases every reveal resource")
        let launch = NSWorkspace.OpenConfiguration()
        launch.activates = false
        let relaunched = try await NSWorkspace.shared.openApplication(at:bundleURL,configuration:launch)
        self.fixturePID = relaunched.processIdentifier
        try await wait("relaunch reconciliation") {
            let value = try state()
            guard value["busy"] as? Bool == false, let entries = value["identities"] as? [[String:Any]],let identity = entries.first(where: { $0["key"] as? String == fixture.key && $0["pid"] as? pid_t == relaunched.processIdentifier }),let window = identity["window"] as? CGWindowID,let divider = value["dividerWindow"] as? CGWindowID else { return false }
            return try WindowMetadata.current(window).bounds.maxX <= WindowMetadata.current(divider).bounds.minX
        }
        guard let entries = try state()["identities"] as? [[String:Any]],let entry = entries.first(where: { $0["key"] as? String == fixture.key }),let window = entry["window"] as? CGWindowID else { throw ManagerError("The relaunched fixture identity is missing") }
        await Catalog.bindWindow(fixture.key,pid:relaunched.processIdentifier,window:window)
        let replacement = try await item("com.benzhang.nook.fixture")
        revealWindow = replacement.window.id; expectedOrder = try await nativeOrder()
        try await select("Show \(replacement.name)")
        try await click(replacement.window.id)
        try await wait("relaunched fixture menu opened") { try state()["menus"] as! Int > 0 }
        try await escape(); try await assertHidden()
        completed.append("A relaunched source is hidden again and completes a fresh native interaction")
        try await select("Show \(replacement.name)")
        try await select("Hide \(replacement.name) now")
        try await wait("restoration began before termination") { try state()["phase"] as? String == "hiding" }
        try require(relaunched.terminate(),"Cannot terminate the fixture during restoration")
        try await wait("canceled restoration finished its native cleanup") {
            try state()["phase"] as? String == "hidden" && state()["resources"] as? Int == 0 && state()["observers"] as? Int == 0 && state()["dragChannels"] as? Int == 0
        }
        let remaining = try await nativeOrder()
        try require(remaining == expectedOrder!.filter { $0 != replacement.window.id },"Quitting during restoration changed the surviving icon order")
        completed.append("Quitting during restoration completes native cleanup and preserves surviving icon order")
        try sample("settled",0,managerPID)
        print("FIXTURE TERMINATED \(relaunched.processIdentifier)")
    }

    func inputEndToEnd() async throws {
        try await connectManager()
        let fixture = try await item("com.benzhang.nook.fixture")
        if !(try state()["hidden"] as! [String]).contains(fixture.key) { try await select("Hide \(fixture.name)") }
        revealWindow = fixture.window.id; expectedOrder = try await nativeOrder()
        audit.timeout = configuration.inputWaitTimeout + audit.timeout
        expectedFailure = "Pause mouse and keyboard input briefly so Nook can move the icon"
        let motion = Task { @MainActor in
            while !Task.isCancelled {
                guard let pointer = CGEvent(source:nil)?.location,
                      let event = CGEvent(mouseEventSource:nil,mouseType:.mouseMoved,mouseCursorPosition:pointer,mouseButton:.left) else { throw ManagerError("Cannot allocate active-input test event") }
                event.setIntegerValueField(.eventSourceUserData,value:Movement.eventMarker)
                event.post(tap:.cghidEventTap)
                do { try await Task.sleep(for:.seconds(configuration.movementCheckInterval)) }
                catch is CancellationError { return }
            }
        }
        defer { motion.cancel(); expectedFailure = nil }
        try await select("Show \(fixture.name)")
        let failed = try state()
        try require(failed["phase"] as? String == "failed" && failed["error"] as? String == expectedFailure,"Continuous input did not produce the expected movement timeout")
        try require(failed["resources"] as? Int == 0 && failed["dragChannels"] as? Int == 0 && failed["observers"] as? Int == 0,"The failed reveal retained its interaction resources")
        try require(try await nativeOrder() == expectedOrder,"An input timeout changed native icon order")
        motion.cancel(); try await motion.value
        try await select("Retry hiding the icon")
        try await assertHidden()
        try require(try state()["error"] == nil && state()["failure"] == nil,"Recovery retained a stale error")
        completed.append("Continuous input leaves icon order untouched, releases reveal resources, and offers a working restoration retry")
    }

    func stress() async throws {
        try await connectManager()
        guard let managerPID else { throw ManagerError("Test processes were not connected") }
        let fixture = try await item("com.benzhang.nook.fixture")
        revealWindow = fixture.window.id
        if !(try state()["hidden"] as! [String]).contains(fixture.key) { try await select("Hide \(fixture.name)") }
        expectedOrder = try await nativeOrder()
        var targets = [fixture]
        if CommandLine.arguments.contains("--multiple") {
            let maccy = try await item("org.p0deje.Maccy")
            if !(try state()["hidden"] as! [String]).contains(maccy.key) { try await select("Hide \(maccy.name)") }
            targets.append(maccy)
            expectedOrder = try await nativeOrder()
        }
        for cycle in 1...(audit.cycles+audit.warmupCycles) {
            let target = targets[(cycle-1) % targets.count]
            revealWindow = target.window.id
            try await select("Show \(target.name)")
            try await click(target.window.id)
            try await wait("native interface opened") { try state()["menus"] as! Int > 0 || state()["interfaces"] as! Int > 0 }
            if target.bundleIdentifier == "org.p0deje.Maccy" { try await dismiss(target.sourcePID) }
            else { try await escape() }
            try await assertHidden()
            if cycle == audit.warmupCycles { try sample("warm",0,managerPID) }
            if cycle > audit.warmupCycles && (cycle-audit.warmupCycles).isMultiple(of:audit.interactionSampleEvery) {
                try sample("load",cycle-audit.warmupCycles,managerPID)
                print("STRESS \(cycle-audit.warmupCycles)/\(audit.cycles)"); fflush(stdout)
            }
        }
        if !CommandLine.arguments.contains("--multiple") { try await select("Keep \(fixture.name) visible") }
        try await Task.sleep(for:.seconds(configuration.gracePeriod))
        try sample("settled",audit.cycles,managerPID)
        completed.append("\(audit.cycles) native reveal-menu-dismiss-restore cycles after \(audit.warmupCycles) warmup cycles")
    }

}

@MainActor final class AuditInputMonitor {
    private var global:Any?
    private var local:Any?
    private(set) var interference:String?
    var hadInterference:Bool { interference != nil }

    init() throws {
        try check()
        let mask:NSEvent.EventTypeMask = [.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp,.keyDown,.keyUp,.scrollWheel]
        global = NSEvent.addGlobalMonitorForEvents(matching:mask) { [weak self] in self?.observe($0) }
        guard global != nil else { throw ManagerError("Cannot monitor external input during the GUI audit") }
        local = NSEvent.addLocalMonitorForEvents(matching:mask) { [weak self] event in self?.observe(event); return event }
        guard local != nil else { close(); throw ManagerError("Cannot monitor local input during the GUI audit") }
    }

    private func observe(_ event:NSEvent) {
        guard interference == nil else { return }
        guard let event = event.cgEvent else {
            interference = "An input event did not expose its source; this run is inconclusive"
            return
        }
        let pid = event.getIntegerValueField(.eventSourceUnixProcessID)
        if pid == getpid() || event.getIntegerValueField(.eventSourceUserData) == Movement.eventMarker { return }
        interference = "External input (event \(event.type.rawValue), source process \(pid)) interfered with the GUI audit; this run is inconclusive"
    }

    func check() throws {
        guard let session = CGSessionCopyCurrentDictionary() as? [String:Any] else {
            throw ManagerError("Cannot read the graphical login session")
        }
        try require(session["kCGSSessionOnConsoleKey"] as? Bool == true && session["kCGSessionLoginDoneKey"] as? Bool == true,
                    "GUI audits require a logged-in console session")
        if let value = session["CGSSessionScreenIsLocked"] {
            guard let locked = value as? Bool else { throw ManagerError("The graphical session's lock state has an invalid type") }
            if locked { interference = "The Mac is locked. Unlock it before running GUI audits; this run is inconclusive" }
        }
        if let interference { throw AuditInterference(message:interference) }
    }

    func close() {
        if let global { NSEvent.removeMonitor(global); self.global = nil }
        if let local { NSEvent.removeMonitor(local); self.local = nil }
    }

    isolated deinit { close() }
}

@MainActor final class SpaceCounter { var changes = 0 }
@MainActor final class TimerFlag { var fired = false }
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let runner = Audit(); application.delegate = runner
application.run()
