import AppKit
import ApplicationServices
import ServiceManagement
import Carbon
import MenuBarCore

@MainActor final class Manager: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let configuration = Configuration()
    let menu = NSMenu(title:"Nook")
    let manageMenu = NSMenu(title:"Manage icons")
    lazy var movement = Movement(configuration:configuration)
    var control: NSStatusItem!
    var divider: NSStatusItem!
    var controlWindow: CGWindowID!
    var dividerWindow: CGWindowID!
    var reveal: RevealController!
    var group:HiddenGroup!
    var hidden = Set<String>()
    var catalog: Catalog?
    var failure: String?
    var menuLoading = false
    var menuPresented = false
    var busy = false
    var ready = false
    var completedActions:UInt64 = 0
    var hotKey: EventHotKeyRef?
    var hotKeyHandler: EventHandlerRef?
    var diagnosticsURL: URL?
    var applicationsObservation:NSKeyValueObservation?
    var applications = [pid_t:String]()
    var pendingApplications = Set<String>()
    var reconciliation:Task<Void,Never>?

    func applicationDidFinishLaunching(_ notification:Notification) {
        runLoginAudit()
        Task { @MainActor in
        do {
            try Accessibility.configure(configuration)
            UserDefaults.standard.register(defaults:["hiddenKeys":configuration.hiddenKeys])
            guard let keys = UserDefaults.standard.array(forKey:"hiddenKeys") as? [String] else { throw ManagerError("Invalid saved hidden-item configuration") }
            hidden = Set(keys)
            if let index = CommandLine.arguments.firstIndex(of:"--diagnostics") {
                try require(index+1 < CommandLine.arguments.count,"--diagnostics requires a file path")
                diagnosticsURL = URL(fileURLWithPath:CommandLine.arguments[index+1])
            }
            _ = try await Catalog.read(configuration)
            let previousWindows = Set(try WindowMetadata.statusWindows(configuration).map(\.id))
            control = NSStatusBar.system.statusItem(withLength:configuration.controlWidth)
            control.autosaveName = "Nook.Control"
            guard let button = control.button else { throw ManagerError("Cannot create the menu-bar button") }
            button.image = NSImage(systemSymbolName:"line.3.horizontal.decrease",accessibilityDescription:"Nook")
            button.toolTip = "Nook (Control–Option–M)"
            button.setAccessibilityIdentifier("Nook.Control")
            button.target = self; button.action = #selector(showMenu)
            button.isEnabled = false
            divider = NSStatusBar.system.statusItem(withLength:configuration.dividerWidth)
            divider.autosaveName = "Nook.Divider"
            divider.button!.title = "│"
            divider.button!.setAccessibilityIdentifier("Nook.Divider")
            try registerHotKey()
            applications = Dictionary(uniqueKeysWithValues:NSWorkspace.shared.runningApplications.compactMap { app in
                app.bundleIdentifier.map { (app.processIdentifier,$0) }
            })
            applicationsObservation = NSWorkspace.shared.observe(\.runningApplications,options:[]) { [weak self] workspace,_ in
                let current = Dictionary(uniqueKeysWithValues:workspace.runningApplications.compactMap { app in app.bundleIdentifier.map { (app.processIdentifier,$0) } })
                MainActor.assumeIsolated {
                    guard let self else { return }
                    let previous = self.applications; self.applications = current
                    for pid in previous.keys where current[pid] == nil { self.reveal?.sourceTerminated(pid) }
                    for (pid,identifier) in current where previous[pid] == nil && self.hidden.contains(where: { $0 == identifier || $0.hasPrefix(identifier+":") }) {
                        self.pendingApplications.insert(identifier)
                    }
                    self.writeDiagnostics(); self.reconcileApplications()
                }
            }
            busy = true
            defer { busy = false; writeDiagnostics(); reconcileApplications() }
            try await Task.sleep(for:.seconds(configuration.gracePeriod))
            controlWindow = try await WindowMetadata.owned(identifier:"Nook.Control",configuration:configuration,excluding:previousWindows).id
            dividerWindow = try await WindowMetadata.owned(identifier:"Nook.Divider",configuration:configuration,excluding:previousWindows).id
            await Catalog.bindWindow("com.benzhang.nook:Nook.Control",pid:getpid(),window:controlWindow)
            await Catalog.bindWindow("com.benzhang.nook:Nook.Divider",pid:getpid(),window:dividerWindow)
            group = HiddenGroup(item:divider,window:dividerWindow,configuration:configuration,movement:movement)
            reveal = RevealController(configuration:configuration,movement:movement,control:controlWindow,group:group)
            reveal.changed = { [weak self] in self?.updateControl(); self?.writeDiagnostics(); self?.reconcileApplications() }
            let catalog = try await Catalog.read(configuration)
            self.catalog = catalog
            guard let anchor = catalog.items.first(where: {$0.key == "com.apple.controlcenter:com.apple.menuextra.controlcenter"}) else { throw ManagerError("Cannot locate Control Center to position the manager") }
            try await movement.move(controlWindow,sourcePID:getpid(),relativeTo:anchor.window.id,placement:.left)
            let ordered = catalog.items.filter { $0.sourcePID != getpid() }.sorted { $0.window.bounds.minX < $1.window.bounds.minX }
            guard let first = ordered.first else { throw ManagerError("No native icons are available to position the hidden group") }
            try await movement.move(dividerWindow,sourcePID:getpid(),relativeTo:first.window.id,placement:.left)
            for item in ordered.reversed() where hidden.contains(item.key) { try await hidePermanently(item) }
            try await group.expanded(!hidden.isEmpty); ready = true; button.isEnabled = true; writeDiagnostics()
        } catch {
            busy = true; reconciliation?.cancel(); report(error)
            let alert = NSAlert(); alert.messageText = "Nook cannot start"; alert.informativeText = error.localizedDescription
            alert.addButton(withTitle:"Quit")
            if !AXIsProcessTrusted() { alert.addButton(withTitle:"Open Accessibility Settings") }
            if alert.runModal() == .alertSecondButtonReturn { NSWorkspace.shared.open(URL(string:"x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
            NSApp.terminate(nil)
        }
        }
    }

    private func registerHotKey() throws {
        let status = InstallEventHandler(GetApplicationEventTarget(),{_,_,context in
            guard let context else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<Manager>.fromOpaque(context).takeUnretainedValue()
            manager.showMenu()
            return noErr
        },1,[EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))],Unmanaged.passUnretained(self).toOpaque(),&hotKeyHandler)
        try require(status == noErr,"Cannot install the keyboard-shortcut handler: \(status)")
        let registration = RegisterEventHotKey(configuration.hotKeyCode,configuration.hotKeyModifiers,EventHotKeyID(signature:0x4D424D47,id:1),GetApplicationEventTarget(),0,&hotKey)
        try require(registration == noErr,"Control–Option–M is unavailable: \(registration)")
    }

    @objc func showMenu() {
        guard ready, !menuLoading, !busy, let reveal, ![.revealing,.hiding,.stopping].contains(reveal.state.phase) else { return }
        menuLoading = true
        reveal.managerMenu(true)
        Task { @MainActor in
        control.button?.appearsDisabled = true
        defer { control.button?.appearsDisabled = false; menuLoading = false; reveal.managerMenu(false); reconcileApplications() }
        do {
            try Accessibility.configure(configuration)
            let catalog = try await Catalog.read(configuration)
            self.catalog = catalog
            menu.removeAllItems()
            menu.delegate = self
            menu.autoenablesItems = false
            if reveal.error != nil || failure != nil {
                add("The last action could not finish",to:menu,enabled:false)
                let details = add("Show error details…",to:menu,enabled:true)
                details.target = self; details.action = #selector(showFailure)
                if reveal.canRetryHiding {
                    let retry = add("Retry hiding the icon",to:menu,enabled:true)
                    retry.target = self; retry.action = #selector(retryHiding)
                } else if reveal.state.phase == .failed {
                    add("Quit Nook to show all icons",to:menu,enabled:false)
                }
                menu.addItem(.separator())
            }
            if let item = reveal.item {
                let hide = add("Hide \(item.name) now",to:menu,enabled:reveal.state.phase == .visible)
                hide.target = self; hide.action = #selector(hideRevealed)
                menu.addItem(.separator())
            }
            let items = catalog.items.filter {
                $0.sourcePID != getpid() && !["com.apple.controlcenter:com.apple.menuextra.clock","com.apple.controlcenter:com.apple.menuextra.controlcenter"].contains($0.key)
            }
            let hiddenItems = items.filter { hidden.contains($0.key) }
            add(hiddenItems.isEmpty ? "Choose icons in Manage icons" : "Hidden icons",to:menu,enabled:false)
            for item in hiddenItems {
                let row = add("Show \(item.name)",to:menu,enabled:reveal.state.phase == .hidden)
                row.representedObject = item.key; row.target = self; row.action = #selector(selectItem(_:))
            }
            menu.addItem(.separator())
            let manage = add("Manage icons",to:menu,enabled:reveal.state.phase == .hidden)
            let settings = manageMenu; settings.removeAllItems(); settings.autoenablesItems = false
            manage.submenu = settings
            for isHidden in [true,false] {
                let group = items.filter { hidden.contains($0.key) == isHidden }
                if group.isEmpty { continue }
                if settings.numberOfItems > 0 { settings.addItem(.separator()) }
                add(isHidden ? "Hidden icons" : "Visible icons",to:settings,enabled:false)
                for item in group {
                    let row = add(isHidden ? "Keep \(item.name) visible" : "Hide \(item.name)",to:settings,enabled:true)
                    row.representedObject = item.key; row.target = self
                    row.action = isHidden ? #selector(keepVisible(_:)) : #selector(selectItem(_:))
                }
            }
            if !catalog.inspectionErrors.isEmpty {
                menu.addItem(.separator())
                let row = add("Some icons are unavailable…",to:menu,enabled:true)
                row.target = self; row.action = #selector(showInspectionErrors)
            }
            menu.addItem(.separator())
            let login = add("Launch at login",to:menu,enabled:true)
            login.state = SMAppService.mainApp.status == .enabled ? .on:.off
            login.target = self; login.action = #selector(toggleLogin)
            let quit = add("Quit Nook",to:menu,enabled:!busy && ![.revealing,.hiding,.stopping].contains(reveal.state.phase))
            quit.target = self; quit.action = #selector(quitManager)
            guard let button = control.button else { throw ManagerError("The menu-bar control is unavailable") }
            menu.popUp(positioning:nil,at:NSPoint(x:button.bounds.minX,y:button.bounds.minY),in:button)
        } catch {
            report(error)
            menu.removeAllItems(); menu.delegate = self; menu.autoenablesItems = false
            add("Menu-bar icons could not be read",to:menu,enabled:false)
            let details = add("Show error details…",to:menu,enabled:true)
            details.target = self; details.action = #selector(showFailure)
            let quit = add("Quit Nook",to:menu,enabled:true)
            quit.target = self; quit.action = #selector(quitManager)
            guard let button = control.button else { preconditionFailure("The menu-bar control is unavailable") }
            menu.popUp(positioning:nil,at:NSPoint(x:button.bounds.minX,y:button.bounds.minY),in:button)
        }
    }

    }

    @discardableResult private func add(_ title:String,to menu:NSMenu,enabled:Bool) -> NSMenuItem {
        let item = NSMenuItem(title:title,action:nil,keyEquivalent:"")
        item.isEnabled = enabled; menu.addItem(item); return item
    }

    @objc private func selectItem(_ sender:NSMenuItem) {
        guard let key = sender.representedObject as? String, let item = catalog?.items.first(where: {$0.key == key}) else { report(ManagerError("The selected item is no longer available")); return }
        busy = true
        writeDiagnostics()
        Task { @MainActor in
            defer { busy = false; completedActions += 1; updateControl(); writeDiagnostics(); reconcileApplications() }
            do {
                if hidden.contains(key) { try await reveal.reveal(item) }
                else { try await hidePermanently(item) }
                failure = nil
            } catch { report(error) }
        }
    }

    private func hidePermanently(_ item:MenuBarItem) async throws {
        try require(reveal.state.phase == .hidden,"Finish the current reveal before hiding another icon")
        let target = try await group.expanded(true)
        do {
            if try WindowMetadata.current(item.window.id).bounds.maxX > target.bounds.minX+configuration.geometryTolerance {
                try await group.prepend(item.window.id,sourcePID:item.sourcePID)
            }
        } catch {
            try await group.expanded(!hidden.isEmpty)
            throw error
        }
        hidden.insert(item.key)
        UserDefaults.standard.set(hidden.sorted(),forKey:"hiddenKeys")
        failure = nil; try await group.expanded(!hidden.isEmpty)
    }
    @objc private func keepVisible(_ sender:NSMenuItem) {
        guard let key = sender.representedObject as? String, let item = catalog?.items.first(where: {$0.key == key}) else { report(ManagerError("The selected item is no longer available")); return }
        busy = true
        writeDiagnostics()
        Task { @MainActor in
            defer { busy = false; completedActions += 1; updateControl(); writeDiagnostics(); reconcileApplications() }
            do {
                try await movement.move(item.window.id,sourcePID:item.sourcePID,relativeTo:controlWindow,placement:.right)
                hidden.remove(key); UserDefaults.standard.set(hidden.sorted(),forKey:"hiddenKeys")
                try await group.expanded(!hidden.isEmpty); failure = nil
            } catch { report(error) }
        }
    }
    private func reconcileApplications() {
        guard reconciliation == nil, !busy, !menuLoading, let reveal, reveal.state.phase == .hidden,
              !reveal.state.managerMenuOpen, !pendingApplications.isEmpty else { return }
        busy = true
        reconciliation = Task { @MainActor in
            defer { reconciliation = nil; busy = false; writeDiagnostics(); reconcileApplications() }
            do {
                while let identifier = pendingApplications.first {
                    pendingApplications.remove(identifier)
                    let deadline = Date().addingTimeInterval(configuration.applicationLaunchTimeout)
                    var items = [MenuBarItem]()
                    repeat {
                        try await Task.sleep(for:.seconds(configuration.gracePeriod))
                        let catalog = try await Catalog.read(configuration)
                        self.catalog = catalog
                        items = catalog.items.filter {$0.bundleIdentifier == identifier && hidden.contains($0.key)}
                    } while items.isEmpty && Date() < deadline
                    try require(!items.isEmpty,"\(identifier) did not expose its saved menu-bar items after launch")
                    for item in items { try await hidePermanently(item) }
                }
            } catch { report(error) }
        }
    }

    @objc private func hideRevealed() { reveal.requestHide(); completedActions += 1; writeDiagnostics() }
    func menuWillOpen(_ menu:NSMenu) { menuPresented = true; reveal.managerMenu(true) }
    func menuDidClose(_ menu:NSMenu) { menuPresented = false; reveal.managerMenu(false); reconcileApplications() }
    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { report(error) }
    }
    @objc private func showInspectionErrors() {
        guard let catalog else { report(ManagerError("No catalog available")); return }
        let alert = NSAlert(); alert.messageText = "Some menu-bar icons are unavailable"
        alert.informativeText = "Nook could not identify every native icon. Those icons cannot be managed safely.\n\n" + catalog.inspectionErrors.joined(separator:"\n")
        alert.runModal()
    }

    @objc private func showFailure() {
        guard let message = reveal.error ?? failure else { return }
        let alert = NSAlert(); alert.messageText = "Nook could not finish the action"
        alert.informativeText = message; alert.runModal()
    }

    @objc private func retryHiding() {
        busy = true; writeDiagnostics()
        Task { @MainActor in
            defer { busy = false; completedActions += 1; writeDiagnostics(); reconcileApplications() }
            do { try await reveal.retryHiding(); failure = nil; updateControl() }
            catch { report(error) }
        }
    }

    private func updateControl() {
        let failed = failure != nil || reveal?.error != nil
        control?.button?.image = NSImage(systemSymbolName:failed ? "exclamationmark.circle" : "line.3.horizontal.decrease",accessibilityDescription:"Nook")
        control?.button?.toolTip = failed ? "Nook: an action failed. Open the menu for details." : "Nook (Control–Option–M)"
    }

    private func report(_ error:Error) {
        failure = error.localizedDescription; writeDiagnostics()
        fputs("Nook: \(error.localizedDescription)\n",stderr)
        updateControl()
    }

    func writeDiagnostics() {
        guard let diagnosticsURL else { return }
        do {
            var value:[String:Any] = ["pid":getpid(),"phase":"starting","busy":busy,"menuPresented":menuPresented]
            if let reveal {
                value.merge(["phase":reveal.state.phase.rawValue,"generation":reveal.state.generation,
                "resources":reveal.resourceCount,"observers":InteractionObserver.liveCount,"dragChannels":DragDelivery.liveCount,
                "pointerDown":reveal.state.pointerDown,"menus":reveal.state.menus.count,"interfaces":reveal.state.interfaceCount,"hideRequested":reveal.state.hideRequested,
                "managerMenuOpen":reveal.state.managerMenuOpen,"busy":busy,"completedActions":completedActions,"hidden":hidden.sorted(),"notifications":reveal.receivedNotifications,
                "controlWindow":controlWindow!,
                "dividerWindow":dividerWindow!],uniquingKeysWith: {_,new in new})
            if let item = reveal.item { value["item"] = item.key }
            if let error = reveal.error { value["error"] = error }
            }
            if let failure { value["failure"] = failure }
            if let catalog { value["identities"] = catalog.items.map { ["key":$0.key,"pid":$0.sourcePID,"window":$0.window.id] as [String:Any] } }
            try JSONSerialization.data(withJSONObject:value,options:[.sortedKeys]).write(to:diagnosticsURL,options:.atomic)
        } catch { fputs("Diagnostic output failed: \(error.localizedDescription)\n",stderr) }
    }

    @objc private func quitManager() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) {
        do {
            reconciliation?.cancel(); reveal?.stop()
            if let hotKey { try require(UnregisterEventHotKey(hotKey) == noErr,"Cannot unregister hotkey") }
            if let hotKeyHandler { try require(RemoveEventHandler(hotKeyHandler) == noErr,"Cannot remove hotkey handler") }
            applicationsObservation?.invalidate(); applicationsObservation = nil
            if let divider { divider.length = configuration.dividerWidth; NSStatusBar.system.removeStatusItem(divider) }
            if let control { NSStatusBar.system.removeStatusItem(control) }
        } catch { fputs("Shutdown failed: \(error.localizedDescription)\n",stderr) }
    }
}

@MainActor func runLoginAudit() {
if CommandLine.arguments.contains("--login-status") {
    do {
        let status:[String:Any] = ["status":SMAppService.mainApp.status.rawValue,"bundleIdentifier":Bundle.main.bundleIdentifier as Any,"runningBundleIdentifier":NSRunningApplication.current.bundleIdentifier as Any,"bundlePath":Bundle.main.bundleURL.path]
        let data = try JSONSerialization.data(withJSONObject:status,options:[.sortedKeys])
        if let index = CommandLine.arguments.firstIndex(of:"--output") {
            try require(index+1 < CommandLine.arguments.count,"Missing login-status output path")
            try data.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]),options:.atomic)
        }
        print(String(data:data,encoding:.utf8)!); exit(0)
    } catch { fputs("LOGIN STATUS FAILED: \(error.localizedDescription)\n",stderr); exit(1) }
}

if CommandLine.arguments.contains("--test-login") {
    var registrationAttempted = false
    do {
        let status = SMAppService.mainApp.status
        try require(status == .notRegistered || status == .notFound,"Login testing requires an absent or unregistered app; current status \(status.rawValue), bundle \(Bundle.main.bundleIdentifier ?? "none")")
        registrationAttempted = true
        try SMAppService.mainApp.register()
        let registered = SMAppService.mainApp.status
        try SMAppService.mainApp.unregister()
        try require(registered == .enabled,"The login service was not enabled: \(registered.rawValue)")
        try require(SMAppService.mainApp.status == .notRegistered,"The login service remained registered after testing")
        print("LOGIN TEST PASSED: registered, enabled, unregistered")
        exit(0)
    } catch {
        fputs("LOGIN TEST FAILED: \(error.localizedDescription)\n",stderr)
        if registrationAttempted && SMAppService.mainApp.status != .notRegistered {
            do { try SMAppService.mainApp.unregister() }
            catch { fputs("LOGIN CLEANUP FAILED: \(error.localizedDescription)\n",stderr); exit(2) }
        }
        exit(1)
    }
}

}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let manager = Manager()
application.delegate = manager
application.run()
