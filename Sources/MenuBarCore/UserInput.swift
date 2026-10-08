import AppKit

@MainActor enum UserInput {
    static func isIdle(for interval:TimeInterval) -> Bool {
        guard NSEvent.modifierFlags.intersection([.command,.shift,.control,.option]).isEmpty, NSEvent.pressedMouseButtons == 0 else { return false }
        let types:[CGEventType] = [.mouseMoved,.scrollWheel,.keyDown,.keyUp,.leftMouseDown,.leftMouseUp,.rightMouseDown,.rightMouseUp,.otherMouseDown,.otherMouseUp]
        return types.allSatisfy {
            CGEventSource.secondsSinceLastEventType(.combinedSessionState,eventType:$0) >= interval
        }
    }

    static func waitUntilIdle(configuration:Configuration) async throws {
        let deadline = ContinuousClock.now.advanced(by:.seconds(configuration.inputWaitTimeout))
        while !isIdle(for:configuration.inputQuietPeriod) {
            try Task.checkCancellation()
            try require(ContinuousClock.now < deadline,"Pause mouse and keyboard input briefly so Nook can move the icon")
            try await Task.sleep(for:.seconds(configuration.movementCheckInterval))
        }
        try Task.checkCancellation()
    }
}
