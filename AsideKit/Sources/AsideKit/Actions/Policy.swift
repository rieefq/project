import Foundation

public enum PolicyDecision: Sendable, Hashable {
    case allow
    case confirm(ConfirmationStrength)
    case deny(String)
}

/// The single place that decides whether an action may run, needs approval, or is refused.
///
/// Every call — whether it came from the local grammar, the on-device model or a cloud
/// model — passes through here, so no model output can skip confirmation.
public struct PolicyEngine: Sendable {
    public init() {}

    public func decide(_ prepared: PreparedCall, spec: ToolSpec, context: ExecutionContext) -> PolicyDecision {
        let risk = max(prepared.risk, spec.risk)

        switch risk {
        case .restricted:
            return .deny("I can't do that. Purchases, payments, posting and account changes aren't something I handle.")

        case .consequential:
            if prepared.platformConfirms {
                // The platform's own sheet shows exactly what happens and needs the user's tap.
                return .allow
            }
            let strength = max(.tap, prepared.confirmation?.minimumStrength ?? .tap)
            return .confirm(strength)

        case .reversible:
            if context.origin == .undo || context.origin == .correction && context.lastReferent != nil {
                return .allow
            }
            // Content from the web can carry instructions. Writes that follow it get a quick check.
            if context.origin == .cloudModel && context.turnHasExternalContent {
                return .confirm(.voice)
            }
            if let minimum = prepared.confirmation?.minimumStrength {
                return .confirm(minimum)
            }
            return .allow

        case .read:
            if let minimum = prepared.confirmation?.minimumStrength {
                return .confirm(minimum)
            }
            return .allow
        }
    }
}
