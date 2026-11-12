import CryptoKit
import OSLog
import SwiftUI
import UserNotifications
#if os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
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

struct BlockNotification {
    enum Event {
        case start, end
    }

    static let identifierPrefix = "agenda.block."
    let alert: BlockAlert
    let event: Event

    var date: Date { event == .start ? alert.start : alert.end }
    var title: String { event == .start ? "Empieza: \(alert.taskName)" : alert.title }
    var identifier: String {
        let eventPrefix = event == .start ? "start." : ""
        return Self.identifierPrefix + eventPrefix + alert.id.uuidString
    }

    static func upcoming(for alerts: [BlockAlert], after now: Date,
                         nativeAlarmIDs: Set<UUID>?, existingIDs: Set<String>,
                         liveActivityIDs: Set<UUID> = []) -> [Self] {
        alerts.flatMap { alert -> [Self] in
            let start = Self(alert: alert, event: .start)
            let end = Self(alert: alert, event: .end)
            // If AlarmKit cannot report its alarms, retain any existing fallback.
            let needsEnd = nativeAlarmIDs.map { !$0.contains(alert.id) }
                ?? existingIDs.contains(end.identifier)
            // A scheduled Live Activity presents its own alert when it starts.
            let starts = liveActivityIDs.contains(alert.id) ? [] : [start]
            return needsEnd ? starts + [end] : starts
        }
        .filter { $0.date > now }
        .sorted { $0.date < $1.date }
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
        notification.request.identifier.hasPrefix(BlockNotification.identifierPrefix) ? [.banner, .sound, .list] : []
    }

    private func synchronize(_ alerts: [BlockAlert], enabled: Bool) async {
        let desired = enabled ? alerts : []
        let now = Date()
        let upcoming = desired.filter { $0.end > now }.sorted { $0.end < $1.end }
        var nativeIDs: Set<UUID>? = []
        var liveActivityIDs: Set<UUID> = []

        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            liveActivityIDs = await synchronizeLiveActivities(upcoming)
            guard pending == nil else { return }
            nativeIDs = await synchronizeAlarms(upcoming, retaining: Set(desired.map(\.id)),
                                                liveActivityIDs: liveActivityIDs, enabled: enabled)
        }
        #endif

        guard pending == nil else { return }
        await synchronizeNotifications(upcoming, nativeAlarmIDs: nativeIDs, liveActivityIDs: liveActivityIDs)
    }

    private func synchronizeNotifications(_ alerts: [BlockAlert], nativeAlarmIDs: Set<UUID>?,
                                          liveActivityIDs: Set<UUID>) async {
        let existing = await center.pendingNotificationRequests()
        guard pending == nil else { return }
        let existingIDs = Set(existing.map(\.identifier))
        let blockIDs = Set(existingIDs.filter { $0.hasPrefix(BlockNotification.identifierPrefix) })
        let upcoming = BlockNotification.upcoming(for: alerts, after: Date(),
                                                  nativeAlarmIDs: nativeAlarmIDs, existingIDs: blockIDs,
                                                  liveActivityIDs: liveActivityIDs)
        let settings = await center.notificationSettings()
        var authorized = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
        if settings.authorizationStatus == .notDetermined && !upcoming.isEmpty && pending == nil {
            do {
                authorized = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                log.error("Could not request notification authorization: \(error.localizedDescription)")
            }
        }
        guard pending == nil else { return }

        let availableSlots = max(0, 64 - (existingIDs.count - blockIDs.count))
        let now = Date()
        let desired = authorized ? Array(upcoming.lazy.filter { $0.date > now }.prefix(availableSlots)) : []
        let desiredIDs = Set(desired.map(\.identifier))
        center.removePendingNotificationRequests(withIdentifiers: Array(blockIDs.subtracting(desiredIDs)))

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        for notification in desired {
            guard pending == nil else { return }
            guard !blockIDs.contains(notification.identifier), notification.date > Date() else { continue }
            let content = UNMutableNotificationContent()
            content.title = notification.title
            content.sound = .default
            let date = calendar.dateComponents([.timeZone, .year, .month, .day, .hour, .minute, .second],
                                               from: notification.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: date, repeats: false)
            do {
                try await center.add(UNNotificationRequest(identifier: notification.identifier,
                                                           content: content, trigger: trigger))
            } catch {
                log.error("Could not schedule block notification: \(error.localizedDescription)")
            }
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    @available(iOS 26.0, *)
    private func synchronizeLiveActivities(_ upcoming: [BlockAlert]) async -> Set<UUID> {
        typealias BlockActivity = Activity<BlockActivityAttributes>
        let upcomingIDs = Set(upcoming.map(\.id))
        let activitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
        var liveIDs: Set<UUID> = []
        for activity in BlockActivity.activities {
            let id = activity.attributes.blockID
            let state = activity.activityState
            if activitiesEnabled, upcomingIDs.contains(id), !liveIDs.contains(id),
               state == .pending || state == .active {
                liveIDs.insert(id)
            } else {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
        guard activitiesEnabled, UIApplication.shared.applicationState == .active else { return liveIDs }

        for alert in upcoming where !liveIDs.contains(alert.id) {
            guard pending == nil else { break }
            let now = Date()
            guard alert.end > now else { continue }
            let attributes = BlockActivityAttributes(blockID: alert.id, taskName: alert.taskName)
            let content = ActivityContent(
                state: BlockActivityAttributes.ContentState(interval: DateInterval(start: alert.start, end: alert.end)),
                staleDate: alert.end,
                relevanceScore: alert.start.timeIntervalSinceReferenceDate
            )
            do {
                if alert.start > now {
                    let notification = BlockNotification(alert: alert, event: .start)
                    let announcement = AlertConfiguration(
                        title: LocalizedStringResource(stringLiteral: notification.title),
                        body: "Consulta el tiempo restante en la pantalla bloqueada.",
                        sound: .default
                    )
                    _ = try BlockActivity.request(attributes: attributes, content: content, style: .standard,
                                                  alertConfiguration: announcement, start: alert.start)
                } else {
                    _ = try BlockActivity.request(attributes: attributes, content: content)
                }
                liveIDs.insert(alert.id)
            } catch {
                log.error("Could not start or schedule block Live Activity: \(error.localizedDescription)")
            }
        }
        return liveIDs
    }

    @available(iOS 26.0, *)
    private func synchronizeAlarms(_ upcoming: [BlockAlert], retaining desiredIDs: Set<UUID>,
                                   liveActivityIDs: Set<UUID>, enabled: Bool) async -> Set<UUID>? {
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
        let upcomingIDs = Set(upcoming.map(\.id))
        var scheduled: Set<UUID> = []
        for alarm in existing {
            let keep = desiredIDs.contains(alarm.id)
            let hasCountdown = alarm.countdownDuration != nil
            let needsCountdown = !liveActivityIDs.contains(alarm.id)
            if keep && (alarm.state == .alerting || !upcomingIDs.contains(alarm.id) || hasCountdown == needsCountdown) {
                scheduled.insert(alarm.id)
                continue
            }
            do {
                try manager.cancel(id: alarm.id)
            } catch {
                if keep { scheduled.insert(alarm.id) }
                log.error("Could not cancel block alarm: \(error.localizedDescription)")
            }
        }

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
            let usesLiveActivity = liveActivityIDs.contains(alert.id)
            let attributes = AlarmAttributes(
                presentation: AlarmPresentation(
                    alert: presentation,
                    countdown: usesLiveActivity ? nil : .init(title: LocalizedStringResource(stringLiteral: alert.taskName))
                ),
                metadata: BlockAlarmMetadata(taskName: alert.taskName,
                                             interval: DateInterval(start: alert.start, end: alert.end)),
                tintColor: .accentColor
            )
            guard let timing = alert.alarmTiming(at: Date()) else { continue }
            let configuration: AlarmManager.AlarmConfiguration<BlockAlarmMetadata>
            if usesLiveActivity {
                configuration = .alarm(schedule: .fixed(alert.end), attributes: attributes)
            } else {
                switch timing {
                case let .scheduled(end, duration):
                    configuration = .init(countdownDuration: .init(preAlert: duration, postAlert: nil),
                                          schedule: .fixed(end),
                                          attributes: attributes)
                case let .immediate(duration):
                    configuration = .timer(duration: duration, attributes: attributes)
                }
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
