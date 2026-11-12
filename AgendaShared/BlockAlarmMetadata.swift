#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
import AlarmKit
import Foundation

@available(iOS 26.0, *)
struct BlockAlarmMetadata: AlarmMetadata {
    let taskName: String
    let interval: DateInterval?
}

@available(iOS 26.0, *)
struct BlockActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        let interval: DateInterval
    }

    let blockID: UUID
    let taskName: String
}
#endif
