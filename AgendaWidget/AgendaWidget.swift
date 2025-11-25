//
//  AgendaWidget.swift
//  AgendaWidget
//
//  Created by Antonio Muñoz on 25/11/25.
//

import WidgetKit
import SwiftUI

private let appGroupIdentifier = "group.com.antoniomunoz.Agenda"

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> SimpleEntry {
        let sample = WidgetDataSource().snapshot(at: Date())
        return SimpleEntry(date: Date(),
                           taskTitle: sample.current?.title,
                           remainingMinutes: sample.current?.remainingMinutes,
                           endDate: sample.current?.endDate,
                           nextTaskTitle: sample.next?.title,
                           nextTaskTime: sample.next?.startDate,
                           refreshDate: sample.refreshDate)
    }

    func snapshot(for configuration: ConfigurationAppIntent, in context: Context) async -> SimpleEntry {
        entry(for: Date())
    }
    
    func timeline(for configuration: ConfigurationAppIntent, in context: Context) async -> Timeline<SimpleEntry> {
        let now = Date()
        let first = entry(for: now)
        let secondDate = max(first.refreshDate, now.addingTimeInterval(60))
        let second = entry(for: secondDate)
        return Timeline(entries: [first, second], policy: .after(second.refreshDate))
    }

    private func entry(for date: Date) -> SimpleEntry {
        let snapshot = WidgetDataSource().snapshot(at: date)
        return SimpleEntry(date: date,
                           taskTitle: snapshot.current?.title,
                           remainingMinutes: snapshot.current?.remainingMinutes,
                           endDate: snapshot.current?.endDate,
                           nextTaskTitle: snapshot.next?.title,
                           nextTaskTime: snapshot.next?.startDate,
                           refreshDate: snapshot.refreshDate)
    }
}

struct SimpleEntry: TimelineEntry {
    let date: Date
    let taskTitle: String?
    let remainingMinutes: Int?
    let endDate: Date?
    let nextTaskTitle: String?
    let nextTaskTime: Date?
    let refreshDate: Date
}

struct AgendaWidgetEntryView: View {
    var entry: SimpleEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let title = entry.taskTitle, let remaining = entry.remainingMinutes {
                Text("En curso")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.headline)
                    .lineLimit(2)
                Text("Restan \(remaining) min")
                    .font(.title3)
                    .bold()
                if let endDate = entry.endDate {
                    Text("Hasta \(endDate, style: .time)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("Sin tarea activa")
                    .font(.headline)
                if let nextTitle = entry.nextTaskTitle,
                   let nextTime = entry.nextTaskTime {
                    Text("Próxima: \(nextTitle)")
                        .font(.subheadline)
                    Text(nextTime, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Agenda libre")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(.systemBackground))
    }
}

struct AgendaWidget: Widget {
    let kind: String = "AgendaWidget"

    var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: kind, intent: ConfigurationAppIntent.self, provider: Provider()) { entry in
            AgendaWidgetEntryView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Agenda actual")
        .description("Muestra la tarea en curso y el tiempo restante.")
    }
}

struct WidgetTaskInfo {
    let title: String
    let remainingMinutes: Int
    let endDate: Date
}

struct WidgetUpcomingInfo {
    let title: String
    let startDate: Date
}

struct WidgetSnapshot {
    let current: WidgetTaskInfo?
    let next: WidgetUpcomingInfo?
    let refreshDate: Date
}

struct WidgetDataSource {
    private let defaults = UserDefaults(suiteName: appGroupIdentifier) ?? .standard
    private let tasksKey = "agenda.tasks.storage"
    private let categoriesKey = "agenda.categories.storage"
    private let wakeKey = "agenda.wakeUpAnchor"
    private let blockMinutes: Int = 5

    func snapshot(at date: Date) -> WidgetSnapshot {
        let categories = loadCategories()
        let tasks = loadTasks().sorted { $0.startIndex < $1.startIndex }
        let dayStart = (defaults.object(forKey: wakeKey) as? Date) ?? defaultDayStart(for: date)

        var current: WidgetTaskInfo?
        var next: WidgetUpcomingInfo?

        for task in tasks {
            let start = dayStart.addingTimeInterval(Double(task.startIndex * blockMinutes) * 60)
            let end = start.addingTimeInterval(Double(task.duration * blockMinutes) * 60)

            if date >= start && date < end {
                let remaining = max(0, Int(ceil(end.timeIntervalSince(date) / 60)))
                let title = categories[task.categoryID] ?? "Tarea"
                current = WidgetTaskInfo(title: title, remainingMinutes: remaining, endDate: end)
            } else if date < start {
                let title = categories[task.categoryID] ?? "Tarea"
                let upcoming = WidgetUpcomingInfo(title: title, startDate: start)
                if next == nil || start < next!.startDate {
                    next = upcoming
                }
            }
        }

        let refresh: Date
        if let current {
            refresh = current.endDate
        } else if let next {
            refresh = next.startDate
        } else {
            refresh = date.addingTimeInterval(Double(blockMinutes) * 60)
        }

        return WidgetSnapshot(current: current, next: next, refreshDate: refresh)
    }

    private func loadTasks() -> [StoredTask] {
        guard let data = defaults.data(forKey: tasksKey),
              let decoded = try? JSONDecoder().decode([StoredTask].self, from: data) else {
            return []
        }
        return decoded
    }

    private func loadCategories() -> [UUID: String] {
        guard let data = defaults.data(forKey: categoriesKey),
              let decoded = try? JSONDecoder().decode([StoredCategory].self, from: data) else {
            return [:]
        }
        return Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0.name) })
    }

    private func defaultDayStart(for date: Date) -> Date {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone.current
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 4
        components.minute = 45
        components.second = 0
        components.nanosecond = 0
        guard let anchor = calendar.date(from: components) else { return date }
        if date >= anchor {
            return anchor
        } else {
            return calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
        }
    }
}

private struct StoredTask: Decodable {
    let id: UUID
    let categoryID: UUID
    let startIndex: Int
    let duration: Int
}

private struct StoredCategory: Decodable {
    let id: UUID
    let name: String
}

#Preview(as: .systemSmall) {
    AgendaWidget()
} timeline: {
    SimpleEntry(date: .now,
                taskTitle: "Focus IA",
                remainingMinutes: 25,
                endDate: Date().addingTimeInterval(1500),
                nextTaskTitle: nil,
                nextTaskTime: nil,
                refreshDate: Date().addingTimeInterval(1500))
}
