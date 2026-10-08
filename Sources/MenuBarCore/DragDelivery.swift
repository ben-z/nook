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
    private var continuation:CheckedContinuation<Void,Error>?
    private var timeout:Timer?
    private var entry:CGEvent?
    private var exit:CGEvent?
    private var failure:String?
    private var disabled = Set<Int>()
    private static var signalSequence:UInt32 = 0

    public init(pid:pid_t,configuration:Configuration) throws {
        self.pid = pid; self.configuration = configuration
        let mouseMask = [CGEventType.leftMouseDown,.leftMouseUp].reduce(CGEventMask(0)) { $0 | (CGEventMask(1)<<$1.rawValue) }
        let context = Unmanaged.passUnretained(self).toOpaque()
        do {
            guard let signals = CGEvent.tapCreateForPid(pid:pid,place:.headInsertEventTap,options:.defaultTap,eventsOfInterest:mouseMask | 1,callback:{_,type,event,context in
                let forward = MainActor.assumeIsolated {
                    guard let context else { preconditionFailure("Missing drag delivery context") }
                    return Unmanaged<DragDelivery>.fromOpaque(context).takeUnretainedValue().application(type,event)
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
            for port in ports {
                guard let source = CFMachPortCreateRunLoopSource(nil,port,0) else { throw ManagerError("Cannot create the drag delivery run-loop source") }
                sources.append(source); CFRunLoopAddSource(CFRunLoopGetMain(),source,.commonModes)
            }
            Self.liveCount += 1
        } catch { releasePorts(); throw error }
    }

    private func check(_ type:CGEventType,channel:Int) {
        if (type == .tapDisabledByTimeout || type == .tapDisabledByUserInput) && !disabled.contains(channel) {
            let message = "The native drag event channel was disabled (\(channel), \(type.rawValue))"
            failure = message; finish(.failure(ManagerError(message)))
        }
    }
    private func finish(_ result:Result<Void,Error>) {
        timeout?.invalidate(); timeout = nil
        let continuation = self.continuation; self.continuation = nil
        continuation?.resume(with:result)
    }
    private func matches(_ event:CGEvent) -> Bool {
        guard let payload, payload.type == event.type else { return false }
        return event.getIntegerValueField(.eventSourceUserData) == Movement.eventMarker &&
            event.getIntegerValueField(.mouseEventWindowUnderMousePointer) == payload.getIntegerValueField(.mouseEventWindowUnderMousePointer)
    }
    private static func signalEvent() throws -> CGEvent {
        precondition(signalSequence < .max,"The drag signal sequence is exhausted")
        signalSequence += 1
        guard let event = CGEvent(source:nil) else { throw ManagerError("Cannot allocate a drag delivery signal") }
        let marker = Int64(getpid()) << 32 | Int64(signalSequence)
        event.setIntegerValueField(.eventSourceUserData,value:marker)
        return event
    }
    private func application(_ type:CGEventType,_ event:CGEvent) -> Bool {
        check(type,channel:0)
        let marker = event.getIntegerValueField(.eventSourceUserData)
        if type == .null, marker == entry?.getIntegerValueField(.eventSourceUserData), let payload {
            remaining -= 1; payload.post(tap:.cgSessionEventTap); return false
        }
        if type == .null, marker == exit?.getIntegerValueField(.eventSourceUserData), payload != nil { finish(.success(())); return false }
        if matches(event) {
            guard let signal = remaining > 0 ? entry:exit else { preconditionFailure("Missing drag packet signal") }
            signal.postToPid(pid)
        }
        return true
    }
    private func session(_ type:CGEventType,_ event:CGEvent) {
        check(type,channel:1)
        if matches(event), let payload {
            if remaining <= 0 { disabled.insert(1); CGEvent.tapEnable(tap:ports[1],enable:false) }
            payload.postToPid(pid)
        }
    }
    public func send(_ event:CGEvent,repetitions:Int) async throws {
        try require(payload == nil && repetitions > 0 && ports.count == 2,"Invalid drag delivery transaction")
        try Task.checkCancellation()
        if let failure { throw ManagerError(failure) }
        let entry = try Self.signalEvent(); let exit = try Self.signalEvent()
        self.entry = entry; self.exit = exit
        let token = entry.getIntegerValueField(.eventSourceUserData)
        payload = event; remaining = repetitions
        disabled.removeAll()
        CGEvent.tapEnable(tap:ports[1],enable:true)
        defer { timeout?.invalidate(); timeout = nil; payload = nil; self.entry = nil; self.exit = nil }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let timer = Timer(timeInterval:configuration.dragTimeout,repeats:false) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, self.entry?.getIntegerValueField(.eventSourceUserData) == token else { return }
                        self.finish(.failure(ManagerError("The application did not acknowledge the drag packet")))
                    }
                }
                timeout = timer; RunLoop.main.add(timer,forMode:.common)
                entry.postToPid(pid)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, self.entry?.getIntegerValueField(.eventSourceUserData) == token else { return }
                self.finish(.failure(CancellationError()))
            }
        }
    }
    private func releasePorts() {
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(),source,.commonModes) }
        for port in ports { CGEvent.tapEnable(tap:port,enable:false); CFMachPortInvalidate(port) }
        sources.removeAll(); ports.removeAll()
    }
    public func close() {
        guard !ports.isEmpty else { return }
        finish(.failure(ManagerError("The native drag channel closed during delivery")))
        payload = nil; entry = nil; exit = nil
        releasePorts(); Self.liveCount -= 1
    }
    isolated deinit { close() }
}
