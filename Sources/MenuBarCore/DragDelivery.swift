// Native drag logic adapted from Ice by Jordan Baird and contributors.
// Copyright 2025 Jordan Baird. Nook adaptations: 2026-10-04.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import CoreGraphics

@MainActor public final class DragDelivery {
    public static private(set) var liveCount = 0
    private let pid:pid_t
    private let configuration:Configuration
    private var ports = [CFMachPort]()
    private var sources = [CFRunLoopSource]()
    private var payload:CGEvent?
    private var remaining = 0
    private var complete = false
    private var failure:String?
    private var disabled = Set<Int>()
    private let entryMarker = Movement.eventMarker+1
    private let exitMarker = Movement.eventMarker+2

    public init(pid:pid_t,configuration:Configuration) throws {
        self.pid = pid; self.configuration = configuration
        let mouseMask = (CGEventMask(1)<<CGEventType.leftMouseDown.rawValue) | (CGEventMask(1)<<CGEventType.leftMouseUp.rawValue)
        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            guard let signals = CGEvent.tapCreateForPid(pid:pid,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:1,callback:{_,type,event,context in
                let forward = MainActor.assumeIsolated {
                    guard let context else { preconditionFailure("Missing drag delivery context") }
                    return Unmanaged<DragDelivery>.fromOpaque(context).takeUnretainedValue().signal(type,event)
                }
                return forward ? Unmanaged.passUnretained(event):nil
            },userInfo:context) else { throw ManagerError("Cannot establish the application's drag signal channel") }
            ports.append(signals)
            guard let session = CGEvent.tapCreate(tap:.cgSessionEventTap,place:.tailAppendEventTap,options:.listenOnly,eventsOfInterest:mouseMask,callback:{_,type,event,context in
                MainActor.assumeIsolated {
                    guard let context else { preconditionFailure("Missing drag delivery context") }
                    Unmanaged<DragDelivery>.fromOpaque(context).takeUnretainedValue().session(type,event)
                }
                return Unmanaged.passUnretained(event)
            },userInfo:context) else { throw ManagerError("Cannot establish the session drag channel") }
            ports.append(session)
            guard let receipt = CGEvent.tapCreateForPid(pid:pid,place:.headInsertEventTap,options:.listenOnly,eventsOfInterest:mouseMask,callback:{_,type,event,context in
                MainActor.assumeIsolated {
                    guard let context else { preconditionFailure("Missing drag delivery context") }
                    Unmanaged<DragDelivery>.fromOpaque(context).takeUnretainedValue().receipt(type,event)
                }
                return Unmanaged.passUnretained(event)
            },userInfo:context) else { throw ManagerError("Cannot establish the application's drag receipt channel") }
            ports.append(receipt)
            for port in ports {
                guard let source = CFMachPortCreateRunLoopSource(nil,port,0) else { throw ManagerError("Cannot create the drag delivery run-loop source") }
                sources.append(source); CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
            }
            Self.liveCount += 1
        } catch { releasePorts(); throw error }
    }

    private func check(_ type:CGEventType,channel:Int) {
        if (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput) && !disabled.contains(channel) { failure = "The native drag event channel was disabled (\(channel), \(type.rawValue))" }
    }
    private func matches(_ event:CGEvent) -> Bool {
        guard let payload, payload.type == event.type else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == Movement.eventMarker &&
            event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == payload.getIntegerValueField(.mouseEventWindowUnderMousePointer)
    }
    private func postSignal(_ marker:Int64) {
        guard let event = CGEvent(source:nil) else { failure = "Cannot allocate a drag delivery signal"; return }
        event.setIntegerValueField(.eventSourceUserData,value:marker); event.postToPid(pid)
    }
    private func signal(_ type:CGEventType,_ event:CGEvent) -> Bool {
        check(type,channel:0)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if type == .null, marker == entryMarker, let payload {
            remaining -= 1; payload.post(tap:.cgSessionEventTap); return false
        }
        if type == .null, marker == exitMarker, payload != nil { complete = true; return false }
        return true
    }
    private func session(_ type:CGEventType,_ event:CGEvent) {
        check(type,channel:1)
        if matches(event), let payload {
            if remaining <= 0 { disabled.insert(1); CGEvent.tapEnable(tap:ports[1],enable:false) }
            payload.postToPid(pid)
            event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        }
    }
    private func receipt(_ type:CGEventType,_ event:CGEvent) {
        check(type,channel:2)
        if matches(event) {
            if remaining <= 0 { disabled.insert(2); CGEvent.tapEnable(tap:ports[2],enable:false) }
            postSignal(remaining > 0 ? entryMarker:exitMarker)
            event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        }
    }
    public func send(_ event:CGEvent,repetitions:Int) async throws {
        try require(payload == nil && repetitions > 0,"Invalid drag delivery transaction")
        event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(pid))
        payload = event; remaining = repetitions; complete = false
        disabled.removeAll()
        CGEvent.tapEnable(tap:ports[1],enable:true)
        CGEvent.tapEnable(tap:ports[2],enable:true)
        defer { payload = nil }
        postSignal(entryMarker)
        let deadline = Date().addingTimeInterval(configuration.movementTimeout)
        repeat {
            if let failure { throw ManagerError(failure) }
            if complete { return }
            try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
        } while Date() < deadline
        throw ManagerError("The application did not acknowledge the drag packet")
    }
    private func releasePorts() {
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        for port in ports { CGEvent.tapEnable(tap:port,enable:false); CFMachPortInvalidate(port) }
        sources.removeAll(); ports.removeAll()
    }
    public func close() {
        guard !ports.isEmpty else { return }
        releasePorts(); Self.liveCount -= 1
    }
    isolated deinit { close() }
}
