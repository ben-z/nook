// Native drag logic adapted from Ice by Jordan Baird and contributors.
// Copyright 2025 Jordan Baird. Nook adaptations: 2026-10-04.
// SPDX-License-Identifier: GPL-3.0-only

import AppKit
import ApplicationServices

public enum Placement { case left, right }

@MainActor public final class Movement {
    public static let eventMarker: Int64 = 0x4D424D414E414745
    private let configuration: Configuration
    public private(set) var isMoving = false
    public init(configuration: Configuration) { self.configuration = configuration }

    public func move(_ item: CGWindowID, sourcePID:pid_t, relativeTo anchor: CGWindowID, placement: Placement) async throws {
        try require(!isMoving,"Another menu-bar movement is in progress")
        try require(AXIsProcessTrusted() && CGPreflightPostEventAccess(),"Accessibility permission is required to move icons")
        try require(NSEvent.pressedMouseButtons == 0,"Release the mouse button before moving an icon")
        _ = try await WindowMetadata.settledStatusWindows(configuration)
        let window = try WindowMetadata.current(item)
        let hostPID = sourcePID
        let original = window.bounds
        let target = try WindowMetadata.current(anchor).bounds
        let liveIDs = Set(try WindowMetadata.statusWindows(configuration).map(\.id))
        try require(liveIDs.contains(item) && liveIDs.contains(anchor),"A movement endpoint is absent from the native menu bar")
        func row() throws -> [WindowMetadata] {
            try WindowMetadata.statusWindows(configuration).filter {
                liveIDs.contains($0.id) && abs($0.bounds.midY-target.midY) <= configuration.geometryTolerance
            }.sorted {$0.bounds.minX < $1.bounds.minX}
        }
        enum Position { case settling, adjacent, different }
        func position() throws -> Position {
            let row = try row()
            guard let sourceIndex = row.firstIndex(where: {$0.id == item}),let targetIndex = row.firstIndex(where: {$0.id == anchor}) else { return .settling }
            let adjacent = placement == .left ? sourceIndex+1 == targetIndex:sourceIndex == targetIndex+1
            let sourceBounds = row[sourceIndex].bounds; let targetBounds = row[targetIndex].bounds
            let gap = placement == .left ? sourceBounds.maxX-targetBounds.minX:sourceBounds.minX-targetBounds.maxX
            return adjacent && abs(gap) <= configuration.geometryTolerance ? .adjacent:.different
        }
        let initialPosition = try position()
        try require(initialPosition != .settling,"An icon disappeared before movement")
        if initialPosition == .adjacent { return }
        guard let source = CGEventSource(stateID:.hidSystemState), let pointer = CGEvent(source:nil)?.location,
              let windowField = CGEventField(rawValue:0x33) else { throw ManagerError("Cannot create the menu-bar drag event") }
        source.localEventsSuppressionInterval = 0
        guard let sessionSource = CGEventSource(stateID:.combinedSessionState) else { throw ManagerError("Cannot configure native event delivery") }
        let suppressionStates = [CGEventSuppressionState.eventSuppressionStateRemoteMouseDrag,.eventSuppressionStateSuppressionInterval]
        let filters = suppressionStates.map { sessionSource.getLocalEventsFilterDuringSuppressionState($0) }
        let interval = sessionSource.localEventsSuppressionInterval
        defer {
            for (state,filter) in zip(suppressionStates,filters) { sessionSource.setLocalEventsFilterDuringSuppressionState(filter,state:state) }
            sessionSource.localEventsSuppressionInterval = interval
        }
        for state in suppressionStates {
            sessionSource.setLocalEventsFilterDuringSuppressionState([.permitLocalMouseEvents,.permitLocalKeyboardEvents,.permitSystemDefinedEvents],state:state)
        }
        sessionSource.localEventsSuppressionInterval = 0
        var start = CGPoint(x:placement == .left ? target.minX:target.maxX,y:target.minY)
        var end = start
        if placement == .left {
            if original.maxX <= target.minX { end.x -= original.width } else { start.x -= 1 }
        } else {
            if original.minX <= target.maxX { end.x -= original.width } else { start.x += 1 }
        }
        func event(_ type:CGEventType,_ point:CGPoint,_ window:CGWindowID) throws -> CGEvent {
            guard let event = CGEvent(mouseEventSource:source,mouseType:type,mouseCursorPosition:point,mouseButton:.left) else { throw ManagerError("Cannot allocate mouse event") }
            event.flags = type == .leftMouseUp ? []:.maskCommand
            event.setIntegerValueField(.eventTargetUnixProcessID,value:Int64(hostPID))
            event.setIntegerValueField(.eventSourceUserData,value:Self.eventMarker)
            event.setIntegerValueField(.mouseEventWindowUnderMousePointer,value:Int64(window))
            event.setIntegerValueField(.mouseEventWindowUnderMousePointerThatCanHandleThisEvent,value:Int64(window))
            // macOS routes offscreen status-item drags using this undocumented window field.
            event.setIntegerValueField(windowField,value:Int64(window))
            return event
        }
        let down = try event(.leftMouseDown,start,item)
        let release = try event(.leftMouseUp,CGPoint(x:original.midX,y:original.minY),item)
        let delivery = try DragDelivery(pid:hostPID,configuration:configuration)
        defer { delivery.close() }
        try require(CGDisplayHideCursor(CGMainDisplayID()) == .success,"Cannot hide the pointer during movement")
        isMoving = true
        defer {
            let restored = CGWarpMouseCursorPosition(pointer)
            let shown = CGDisplayShowCursor(CGMainDisplayID())
            isMoving = false
            precondition(restored == .success && shown == .success,"Cannot restore the pointer after movement")
        }
        do {
            try await delivery.send(down,repetitions:1)
            let responseDeadline = Date().addingTimeInterval(configuration.movementTimeout)
            while try WindowMetadata.current(item).bounds.origin == original.origin {
                try require(Date() < responseDeadline,"The status item did not acknowledge the drag start")
                try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
            }
            _ = try await WindowMetadata.settledStatusWindows(configuration)
            let destination = try WindowMetadata.current(anchor).bounds
            // Lifting an icon clamps it to the display edge and shifts offscreen anchors.
            if placement == .left && target.maxX < CGDisplayBounds(CGMainDisplayID()).minX {
                end = CGPoint(x:destination.minX,y:destination.minY)
            }
            if CommandLine.arguments.contains("--trace-movement") {
                fputs("Drag \(item): initial \(original), target \(target), down \(start), lifted \(try WindowMetadata.current(item).bounds), updated target \(destination), up \(end)\n",stderr)
            }
            let up = try event(.leftMouseUp,end,anchor)
            try await delivery.send(up,repetitions:2)
        } catch {
            for _ in 0..<2 { release.post(tap:.cgSessionEventTap); release.postToPid(hostPID) }
            throw error
        }
        let deadline = Date().addingTimeInterval(configuration.movementTimeout)
        while Date() < deadline {
            if try position() == .adjacent { return }
            try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
        }
        throw ManagerError("macOS did not move the icon to the requested position: source \(try WindowMetadata.current(item).bounds), target \(try WindowMetadata.current(anchor).bounds)")
    }
}
