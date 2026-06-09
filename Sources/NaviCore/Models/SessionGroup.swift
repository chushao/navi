import Foundation

public struct SessionGroup: Identifiable {
    public let id: String          // sessionID
    public let info: SessionInfo
    public let events: [NaviEvent]

    public init(id: String, info: SessionInfo, events: [NaviEvent]) {
        self.id = id
        self.info = info
        self.events = events
    }

    public var hasPending: Bool { events.contains { $0.isPending } }

    public var status: SessionStatus {
        if hasPending { return .needsAttention }
        guard info.isAlive else { return .idle }

        // Hook-derived view (fast path): UserPromptSubmit -> "working",
        // Stop -> not working. Instant, but goes stale if a hook is missed.
        let hookWorking = info.lastEventType == "working"

        // Canonical backstop: ~/.claude/sessions/<pid>.json carries the real
        // busy/idle/waiting status Claude maintains regardless of hooks. Trust
        // whichever signal is newer — a just-fired hook keeps Navi instant, while
        // a newer canonical status self-heals a stuck state from a missed Stop,
        // UserPromptSubmit, or PermissionRequest hook. "waiting" means Claude is
        // blocked on a prompt (permission or input), so it surfaces as
        // needsAttention even when no live pending permission event exists — this
        // is what keeps Navi flagging input requests when the hook is missed or
        // its 120s poll has already timed out.
        if let canonicalAt = info.statusUpdatedAt,
           info.claudeStatus == "busy" || info.claudeStatus == "idle" || info.claudeStatus == "waiting",
           canonicalAt > info.lastActivity {
            switch info.claudeStatus {
            case "busy": return .working
            case "waiting": return .needsAttention
            default: return .waitingForInput
            }
        }

        return hookWorking ? .working : .waitingForInput
    }
}
