import AppKit
import MenuBarCore

@MainActor final class Fixture:NSObject,NSApplicationDelegate {
    let configuration = Configuration()
    var item:NSStatusItem!
    var menu:NSMenu!
    var popover:NSPopover!
    var panel:NSPanel!
    var dialog:NSWindow!
    func applicationDidFinishLaunching(_ notification:Notification) {
        item = NSStatusBar.system.statusItem(withLength:configuration.controlWidth)
        item.autosaveName = "Nook.Fixture"
        item.button!.title = "T"
        item.button!.setAccessibilityIdentifier("fixture-status-item")
        menu = NSMenu(title:"Fixture")
        let first = NSMenuItem(title:"Nested menu",action:nil,keyEquivalent:"")
        let nested = NSMenu(title:"Nested")
        let action = NSMenuItem(title:"Harmless action",action:#selector(noop),keyEquivalent:""); action.target = self
        nested.addItem(action); first.submenu = nested; menu.addItem(first)
        let popup = NSMenuItem(title:"Open popover",action:#selector(openPopover),keyEquivalent:""); popup.target = self; menu.addItem(popup)
        let custom = NSMenuItem(title:"Open panel",action:#selector(openPanel),keyEquivalent:""); custom.target = self; menu.addItem(custom)
        let window = NSMenuItem(title:"Open window",action:#selector(openWindow),keyEquivalent:""); window.target = self; menu.addItem(window)
        let fullscreen = NSMenuItem(title:"Open fullscreen window",action:#selector(openFullscreen),keyEquivalent:""); fullscreen.target = self; menu.addItem(fullscreen)
        let quit = NSMenuItem(title:"Quit fixture",action:#selector(quitFixture),keyEquivalent:""); quit.target = self; menu.addItem(quit)
        item.menu = menu
        popover = NSPopover(); popover.behavior = .transient
        let controller = NSViewController(); controller.view = NSView(frame:NSRect(x:0,y:0,width:220,height:120))
        let button = NSButton(title:"Close popover",target:self,action:#selector(closePopover)); button.frame = NSRect(x:30,y:40,width:160,height:30)
        controller.view.addSubview(button); popover.contentViewController = controller
        panel = NSPanel(contentRect:NSRect(x:0,y:0,width:220,height:120),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        panel.title = "Fixture panel"; panel.level = .statusBar; panel.isReleasedWhenClosed = false; panel.hidesOnDeactivate = false
        let close = NSButton(title:"Close panel",target:self,action:#selector(closePanel)); close.frame = NSRect(x:30,y:40,width:160,height:30); panel.contentView!.addSubview(close)
        dialog = NSWindow(contentRect:NSRect(x:0,y:0,width:220,height:120),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        dialog.title = "Fixture window"; dialog.isReleasedWhenClosed = false
        let closeWindow = NSButton(title:"Close window",target:self,action:#selector(closeWindow)); closeWindow.frame = NSRect(x:30,y:40,width:160,height:30); dialog.contentView!.addSubview(closeWindow)
    }
    @objc func openFullscreen() {
        dialog.collectionBehavior.insert(.fullScreenPrimary)
        openWindow(); dialog.toggleFullScreen(nil)
    }
    @objc func openWindow() { dialog.center(); dialog.makeKeyAndOrderFront(nil); NSApp.activate() }
    @objc func closeWindow() { dialog.close() }
    @objc func noop() {}
    @objc func openPopover() { popover.show(relativeTo:item.button!.bounds,of:item.button!,preferredEdge:.minY) }
    @objc func closePopover() { popover.close() }
    @objc func openPanel() { panel.center(); panel.makeKeyAndOrderFront(nil); NSApp.activate() }
    @objc func closePanel() { panel.close() }
    @objc func quitFixture() { NSApp.terminate(nil) }
    func applicationWillTerminate(_ notification:Notification) { NSStatusBar.system.removeStatusItem(item) }
}
let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let fixture = Fixture(); application.delegate = fixture
application.run()
