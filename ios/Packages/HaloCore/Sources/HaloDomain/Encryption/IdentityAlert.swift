import HaloFoundation

/// A contact in a room whose end-to-end identity changed and has not been accepted yet (ENCRYPTION_AND_DEVICES FR-7, AC-SEC-1).
public struct IdentityAlert: Sendable, Equatable, Hashable {
    public enum Kind: Sendable, Equatable, Hashable {
        /// The contact's identity differs from the one Halo remembered.
        case changed
        /// The contact had been verified, and now presents a different identity: the serious case.
        case verifiedBefore
    }

    public let user: UserID
    public let kind: Kind

    public init(user: UserID, kind: Kind) {
        self.user = user
        self.kind = kind
    }
}
