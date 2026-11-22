import HaloDomain
import HaloFoundation
import MatrixRustSDK

/// `ReadMarkerPort` over `Room.sendSingleReceipt` and `Room.markAsFullyReadUnchecked` (docs/matrix/READ_RECEIPTS.md §1).
/// Receipts are unthreaded, so they cover every thread (D17).
public final class MatrixReadMarkerPort: ReadMarkerPort {
    private let session: MatrixSessionPort

    public init(session: MatrixSessionPort) { self.session = session }

    public func sendReceipt(room: RoomID, event: EventID, isPrivate: Bool) async throws(HaloError) {
        let sdkRoom = try await session.room(room)
        do {
            try await sdkRoom.sendSingleReceipt(
                receiptType: isPrivate ? .readPrivate : .read, thread: .unthreaded, eventId: event.rawValue)
        } catch { throw ErrorMapper.map(error) }
    }

    public func setFullyRead(room: RoomID, event: EventID) async throws(HaloError) {
        let sdkRoom = try await session.room(room)
        do { try await sdkRoom.markAsFullyReadUnchecked(eventId: event.rawValue) } catch { throw ErrorMapper.map(error) }
    }

    public func markRoomRead(room: RoomID, isPrivate: Bool) async throws(HaloError) -> EventID? {
        let sdkRoom = try await session.room(room)
        do {
            let receiptType: ReceiptType = isPrivate ? .readPrivate : .read
            // Delegate latest-event resolution and unthreaded receipt sending to the SDK (R-20).
            try await sdkRoom.markAsRead(receiptType: receiptType)
            try await sdkRoom.markAsRead(receiptType: .fullyRead)
            if let receipt = try? await sdkRoom.loadUserReceipt(
                receiptType: receiptType, thread: .unthreaded, userId: sdkRoom.ownUserId()
            ) {
                return try EventID(receipt.eventId)
            }
            if let latest = try? await sdkRoom.timeline().latestEventId() {
                return try EventID(latest)
            }
            return nil
        } catch let error as HaloError {
            throw error
        } catch { throw ErrorMapper.map(error) }
    }

    public func setMarkedUnread(room: RoomID, _ value: Bool) async throws(HaloError) {
        let sdkRoom = try await session.room(room)
        do {
            // Clearing is requested on every room open; don't write account data when the flag is already clear.
            if !value, try await sdkRoom.roomInfo().isMarkedUnread == false { return }
            try await sdkRoom.setUnreadFlag(newValue: value)
        } catch { throw ErrorMapper.map(error) }
    }
}
