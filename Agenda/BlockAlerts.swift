import CryptoKit
import OSLog
import SwiftUI
import UserNotifications
#if os(iOS) && !targetEnvironment(macCatalyst)
import AlarmKit
import UIKit
#endif

struct BlockAlert: Equatable {
    enum AlarmTiming: Equatable {
        case scheduled(end: Date, duration: TimeInterval)
        case immediate(duration: TimeInterval)
    }

    let id: UUID
    let taskName: String
    let start: Date
    let end: Date

    init(taskID: UUID, taskName: String, start: Date, end: Date) {
        // The version replaces alarms created with the previous countdown configuration.
        let key = "2|\(taskID)|\(start.timeIntervalSinceReferenceDate)|\(end.timeIntervalSinceReferenceDate)|\(taskName)"
        let digest = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        id = UUID(uuid: (digest[0], digest[1], digest[2], digest[3],
                         digest[4], digest[5], digest[6], digest[7],
                         digest[8], digest[9], digest[10], digest[11],
                         digest[12], digest[13], digest[14], digest[15]))
        self.taskName = taskName
        self.start = start
        self.end = end
    }

    var title: String { "Ha terminado el bloque: \(taskName)" }

    func alarmTiming(at now: Date) -> AlarmTiming? {
        let remaining = end.timeIntervalSince(max(now, start))
        guard remaining > 0 else { return nil }
        if now < start {
            return .scheduled(end: end, duration: remaining)
        }
        return .immediate(duration: remaining)
    }
}

extension ScheduleViewModel {
    var blockAlerts: [BlockAlert] {
        tasks.compactMap { task in
            guard !task.isCompleted, task.duration > 0 else { return nil }
            let focusName = task.focusID.flatMap { focus(with: $0)?.name.split(whereSeparator: \.isNewline).first }
            let name = focusName.map(String.init) ?? category(for: task.categoryID)?.name ?? "Tarea de Agenda"
            return BlockAlert(taskID: task.id,
                              taskName: name,
                              start: date(for: task.startIndex),
                              end: date(for: task.startIndex + task.duration))
        }
    }
}

@MainActor
final class BlockAlertScheduler: NSObject, UNUserNotificationCenterDelegate {
    static let enabledKey = "agenda.blockAlerts.enabled"

    private nonisolated static let notificationPrefix = "agenda.block."
    private let center = UNUserNotificationCenter.current()
    private let log = Logger(subsystem: "com.ams.Agenda2", category: "BlockAlerts")
    private var pending: (alerts: [BlockAlert], enabled: Bool)?
    private var isSynchronizing = false

    override init() {
        super.init()
        center.delegate = self
    }

    func update(_ alerts: [BlockAlert], enabled: Bool) {
        pending = (alerts, enabled)
        guard !isSynchronizing else { return }
        isSynchronizing = true
        Task {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            let application = UIApplication.shared
            var backgroundTask = UIBackgroundTaskIdentifier.invalid
            let endBackgroundTask: @MainActor @Sendable () -> Void = {
                guard backgroundTask != .invalid else { return }
                application.endBackgroundTask(backgroundTask)
                backgroundTask = .invalid
            }
            backgroundTask = application.beginBackgroundTask(withName: "Schedule block alerts",
                                                               expirationHandler: endBackgroundTask)
            defer { endBackgroundTask() }
            #endif
            while let update = pending {
                pending = nil
                await synchronize(update.alerts, enabled: update.enabled)
            }
            isSynchronizing = false
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        notification.request.identifier.hasPrefix(Self.notificationPrefix) ? [.banner, .sound, .list] : []
    }

    private func synchronize(_ alerts: [BlockAlert], enabled: Bool) async {
        let desired = enabled ? alerts : []
        let now = Date()
        let upcoming = desired.filter { $0.end > now }.sorted { $0.end < $1.end }
        var nativeIDs: Set<UUID> = []

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            guard let scheduled = await synchronizeAlarms(upcoming, retaining: Set(desired.map(\.id)), enabled: enabled),
                  pending == nil else { return }
            nativeIDs = scheduled
        }
        #endif

        let fallback = upcoming.filter { !nativeIDs.contains($0.id) }
        await synchronizeNotifications(fallback)
    }

    private func synchronizeNotifications(_ alerts: [BlockAlert]) async {
        let settings = await center.notificationSettings()
        var authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        if settings.authorizationStatus == .notDetermined && !alerts.isEmpty && pending == nil {
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("Could not request notification authorization: \(error.localizedDescription)")
            }
        }
        guard pending == nil else { return }

        // Keep the earliest reminders when the schedule exceeds the system's pending request limit.
        let now = Date()
        let desired = authorized ? Array(alerts.lazy.filter { $0.end > now }.prefix(64)) : []
        let desiredIDs = Set(desired.map { Self.notificationPrefix + $0.id.uuidString })
        let existingIDs = Set(await center.pendingNotificationRequests()
            .map(\.identifier)
            .filter { $0.hasPrefix(Self.notificationPrefix) })
        guard pending == nil else { return }
        center.removePendingNotificationRequests(withIdentifiers: Array(existingIDs.subtracting(desiredIDs)))

        for alert in desired {
            guard pending == nil else { return }
            let id = Self.notificationPrefix + alert.id.uuidString
            guard !existingIDs.contains(id), alert.end > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.sound = .default
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .gmt
            let date = calendar.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second], from: alert.end)
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
            } catch {
                log.error("Could not schedule block notification: \(error.localizedDescription)")
            }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    private func synchronizeAlarms(_ upcoming: [BlockAlert], retaining desiredIDs: Set<UUID>,
                                   enabled: Bool) async -> Set<UUID>? {
        let manager = AlarmManager.shared
        if enabled && manager.authorizationState == .notDetermined {
            do {
                _ = try await manager.requestAuthorization()
            } catch {
                log.error("Could not request alarm authorization: \(error.localizedDescription)")
            }
        }
        guard pending == nil else { return nil }
        guard manager.authorizationState == .authorized else { return [] }

        let existing: [Alarm]
        do {
            existing = try manager.alarms
        } catch {
            log.error("Could not read scheduled block alarms: \(error.localizedDescription)")
            return nil
        }
        for alarm in existing where !desiredIDs.contains(alarm.id) {
            do {
                try manager.cancel(id: alarm.id)
            } catch {
                log.error("Could not cancel block alarm: \(error.localizedDescription)")
            }
        }

        var scheduled = Set(existing.map(\.id)).intersection(desiredIDs)
        for alert in upcoming where !scheduled.contains(alert.id) {
            guard pending == nil else { return nil }

            let title = LocalizedStringResource(stringLiteral: alert.title)
            let presentation: AlarmPresentation.Alert
            if #available(iOS 26.1, *) {
                presentation = .init(title: title)
            } else {
                presentation = .init(title: title, stopButton: AlarmButton(
                    text: "Detener", textColor: .white, systemImageName: "stop.fill"))
            }
            let attributes = AlarmAttributes(
                presentation: AlarmPresentation(
                    alert: presentation,
                    countdown: .init(title: LocalizedStringResource(stringLiteral: alert.taskName))
                ),
                metadata: BlockAlarmMetadata(taskName: alert.taskName,
                                             interval: DateInterval(start: alert.start, end: alert.end)),
                tintColor: .accentColor
            )
            guard let timing = alert.alarmTiming(at: Date()) else { continue }
            let configuration: AlarmManager.AlarmConfiguration<BlockAlarmMetadata>
            switch timing {
            case let .scheduled(end, duration):
                configuration = .init(countdownDuration: .init(preAlert: duration, postAlert: nil),
                                      schedule: .fixed(end),
                                      attributes: attributes)
            case let .immediate(duration):
                configuration = .timer(duration: duration, attributes: attributes)
            }
            do {
                _ = try await manager.schedule(id: alert.id, configuration: configuration)
                scheduled.insert(alert.id)
            } catch AlarmManager.AlarmError.maximumLimitReached {
                break
            } catch {
                log.error("Could not schedule block alarm: \(error.localizedDescription)")
            }
        }
        return scheduled
    }
    #endif
}
