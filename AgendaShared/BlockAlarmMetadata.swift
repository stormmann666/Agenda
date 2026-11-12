#if os(iOS) && !targetEnvironment(macCatalyst)
import AlarmKit
import Foundation

@available(iOS 26.0, *)
struct BlockAlarmMetadata: AlarmMetadata {
    let taskName: String
    let interval: DateInterval?
}
#endif
