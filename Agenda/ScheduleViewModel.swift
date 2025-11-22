//
//  ScheduleViewModel.swift
//  Agenda
//
//  Created by Codex on 27/11/25.
//

import SwiftUI
import UIKit

struct TaskCategory: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var colorHex: String

    init(id: UUID = UUID(), name: String, colorHex: String) {
        self.id = id
        self.name = name
        self.colorHex = colorHex
    }

    var color: Color {
        Color(hex: colorHex)
    }
}

struct TaskItem: Identifiable, Codable, Hashable {
    let id: UUID
    var categoryID: UUID
    var startIndex: Int
    var duration: Int
    var isCompleted: Bool

    init(id: UUID = UUID(), categoryID: UUID, startIndex: Int, duration: Int, isCompleted: Bool = false) {
        self.id = id
        self.categoryID = categoryID
        self.startIndex = startIndex
        self.duration = duration
        self.isCompleted = isCompleted
    }

    enum CodingKeys: String, CodingKey {
        case id, categoryID, startIndex, duration, isCompleted
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        startIndex = try container.decode(Int.self, forKey: .startIndex)
        duration = try container.decode(Int.self, forKey: .duration)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(startIndex, forKey: .startIndex)
        try container.encode(duration, forKey: .duration)
        try container.encode(isCompleted, forKey: .isCompleted)
    }
}

struct TimelineBlock: Identifiable {
    let index: Int
    let span: Int
    let task: TaskItem?
    let startDate: Date

    var id: Int { index }
}

final class ScheduleViewModel: ObservableObject {
    static let blockMinutes = 15
    @Published var categories: [TaskCategory]
    @Published var tasks: [TaskItem]
    @Published var dayLogs: [ScheduleDayLog]

    let dayStart: Date
    let dayEnd: Date

    private let wakeUpKey = "agenda.wakeUpAnchor"
    private let tasksKey = "agenda.tasks.storage"
    private let categoriesKey = "agenda.categories.storage"
    private let dayLogsKey = "agenda.dayLogs.storage"
    private var calendar: Calendar = {
        var cal = Calendar.current
        cal.timeZone = TimeZone.current
        return cal
    }()
    private let defaults = UserDefaults.standard

    init() {
        categories = []
        tasks = []
        dayLogs = []

        let now = Date()
        let candidateStart = Self.dailyStart(for: now, calendar: calendar)
        let stored = defaults.object(forKey: wakeUpKey) as? Date
        var previousDayStart: Date?
        if let stored, calendar.isDate(stored, inSameDayAs: candidateStart), stored == candidateStart {
            dayStart = stored
        } else {
            previousDayStart = stored
            dayStart = candidateStart
            defaults.set(candidateStart, forKey: wakeUpKey)
        }

        let nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        dayEnd = nextMidnight

        categories = loadCategories()
        let loadedTasks = loadTasks()
        dayLogs = loadDayLogs()

        if let previousDayStart {
            archiveDay(date: previousDayStart, tasks: loadedTasks)
            tasks = []
            saveTasks()
        } else {
            tasks = loadedTasks
        }
    }

    var totalBlocks: Int {
        max(1, Int(dayEnd.timeIntervalSince(dayStart) / Double(Self.blockMinutes * 60)))
    }

    func timelineBlocks() -> [TimelineBlock] {
        var blocks: [TimelineBlock] = []
        var pointer = 0
        let sortedTasks = tasks.sorted { $0.startIndex < $1.startIndex }

        while pointer < totalBlocks {
            if let task = sortedTasks.first(where: { $0.startIndex == pointer }) {
                let startDate = date(for: pointer)
                blocks.append(TimelineBlock(index: pointer, span: task.duration, task: task, startDate: startDate))
                pointer += task.duration
            } else {
                let startDate = date(for: pointer)
                blocks.append(TimelineBlock(index: pointer, span: 1, task: nil, startDate: startDate))
                pointer += 1
            }
        }

        return blocks
    }

    func label(for index: Int) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date(for: index))
    }

    func date(for index: Int) -> Date {
        dayStart.addingTimeInterval(Double(index * Self.blockMinutes) * 60)
    }

    func category(for id: UUID) -> TaskCategory? {
        categories.first { $0.id == id }
    }

    @discardableResult
    func addTask(at index: Int, category: TaskCategory) -> TaskItem? {
        let newTask = TaskItem(categoryID: category.id, startIndex: index, duration: 1)
        guard canPlace(start: index, duration: newTask.duration) else { return nil }
        mutateTasks { tasks in
            tasks.append(newTask)
            tasks.sort { $0.startIndex < $1.startIndex }
        }
        return newTask
    }

    func canPlace(start: Int, duration: Int, ignoring taskID: UUID? = nil) -> Bool {
        guard start >= 0 else { return false }
        let end = start + duration
        guard end <= totalBlocks else { return false }
        for task in tasks where task.id != taskID {
            let taskEnd = task.startIndex + task.duration
            if (start < taskEnd) && (end > task.startIndex) {
                return false
            }
        }
        return true
    }

    func move(task: TaskItem, by delta: Int) {
        guard delta != 0 else { return }
        let newStart = max(0, min(totalBlocks - task.duration, task.startIndex + delta))
        move(task: task, to: newStart)
    }

    func move(task: TaskItem, to startIndex: Int) {
        update(taskID: task.id) { mutable in
            let clamped = max(0, min(totalBlocks - mutable.duration, startIndex))
            guard canPlace(start: clamped, duration: mutable.duration, ignoring: mutable.id) else { return }
            mutable.startIndex = clamped
        }
    }

    func resize(task: TaskItem, newDuration: Int) {
        guard newDuration >= 1 else { return }
        update(taskID: task.id) { mutable in
            guard canPlace(start: mutable.startIndex, duration: newDuration, ignoring: mutable.id) else { return }
            mutable.duration = newDuration
        }
    }

    func setCategory(_ category: TaskCategory, for task: TaskItem) {
        update(taskID: task.id) { mutable in
            mutable.categoryID = category.id
        }
    }

    func toggleCompletion(for task: TaskItem) {
        update(taskID: task.id) { mutable in
            mutable.isCompleted.toggle()
        }
    }

    func delete(task: TaskItem) {
        mutateTasks { tasks in
            tasks.removeAll { $0.id == task.id }
        }
    }

    func updateCategory(_ category: TaskCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        mutateCategories { categories in
            categories[index] = category
        }
    }

    func addCategory() {
        let color = Color.randomAccent().hexString
        let newCategory = TaskCategory(name: "Nueva tarea", colorHex: color)
        mutateCategories { categories in
            categories.append(newCategory)
        }
    }

    func addCategory(name: String, color: Color) {
        let newCategory = TaskCategory(name: name.isEmpty ? "Nueva tarea" : name,
                                       colorHex: color.hexString)
        mutateCategories { categories in
            categories.append(newCategory)
        }
    }

    func deleteCategory(_ category: TaskCategory) {
        mutateCategories { categories in
            categories.removeAll { $0.id == category.id }
        }
        mutateTasks { tasks in
            tasks.removeAll { $0.categoryID == category.id }
        }
    }

    func clearAllTasks() {
        mutateTasks { tasks in
            tasks.removeAll()
        }
    }

    private func update(taskID: UUID, updateBlock: (inout TaskItem) -> Void) {
        mutateTasks { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            var mutable = tasks[index]
            updateBlock(&mutable)
            tasks[index] = mutable
        }
    }

    private func mutateTasks(_ transform: (inout [TaskItem]) -> Void) {
        var updated = tasks
        transform(&updated)
        tasks = updated
        saveTasks()
    }

    private func mutateCategories(_ transform: (inout [TaskCategory]) -> Void) {
        var updated = categories
        transform(&updated)
        categories = updated
        saveCategories()
    }

    private func loadCategories() -> [TaskCategory] {
        guard
            let data = defaults.data(forKey: categoriesKey),
            let decoded = try? JSONDecoder().decode([TaskCategory].self, from: data)
        else {
            return Self.defaultCategories
        }
        return decoded.isEmpty ? Self.defaultCategories : decoded
    }

    private func loadTasks() -> [TaskItem] {
        guard
            let data = defaults.data(forKey: tasksKey),
            var decoded = try? JSONDecoder().decode([TaskItem].self, from: data)
        else {
            return []
        }
        decoded = decoded.filter { $0.duration > 0 }
        decoded = decoded.map { task in
            var mutable = task
            if mutable.startIndex + mutable.duration > totalBlocks {
                mutable.startIndex = max(0, totalBlocks - mutable.duration)
            }
            return mutable
        }
        decoded.sort { $0.startIndex < $1.startIndex }
        return decoded
    }

    private func saveTasks() {
        guard let data = try? JSONEncoder().encode(tasks) else { return }
        defaults.set(data, forKey: tasksKey)
    }

    private func saveCategories() {
        guard let data = try? JSONEncoder().encode(categories) else { return }
        defaults.set(data, forKey: categoriesKey)
    }

    private func archiveDay(date: Date, tasks: [TaskItem]) {
        let dayStart = calendar.startOfDay(for: date)
        if dayLogs.contains(where: { calendar.isDate($0.date, inSameDayAs: dayStart) }) {
            return
        }
        let log = ScheduleDayLog(date: dayStart, tasks: tasks)
        dayLogs.append(log)
        dayLogs.sort { $0.date > $1.date }
        saveDayLogs()
    }

    private func loadDayLogs() -> [ScheduleDayLog] {
        guard
            let data = defaults.data(forKey: dayLogsKey),
            let decoded = try? JSONDecoder().decode([ScheduleDayLog].self, from: data)
        else {
            return []
        }
        return decoded
    }

    private func saveDayLogs() {
        guard let data = try? JSONEncoder().encode(dayLogs) else { return }
        defaults.set(data, forKey: dayLogsKey)
    }

    private static let defaultCategories: [TaskCategory] = [
        TaskCategory(name: "IA", colorHex: "#9874ff"),
        TaskCategory(name: "IA app", colorHex: "#2a9d8f"),
        TaskCategory(name: "IA teoría", colorHex: "#e76f51"),
        TaskCategory(name: "Bolsa", colorHex: "#f4a261"),
        TaskCategory(name: "Fondo", colorHex: "#f7b267"),
        TaskCategory(name: "FatherFondo", colorHex: "#118ab2"),
        TaskCategory(name: "Bolsa teoría", colorHex: "#8ecae6")
    ]
}

struct ScheduleDayLog: Identifiable, Codable {
    let id: UUID
    let date: Date
    let tasks: [TaskItem]

    init(id: UUID = UUID(), date: Date, tasks: [TaskItem]) {
        self.id = id
        self.date = date
        self.tasks = tasks
    }
}

private extension Date {
    func roundedDownToBlock(minutes: Int, calendar: Calendar) -> Date {
        let comps = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: self)
        guard let hour = comps.hour, let minute = comps.minute else {
            return self
        }
        let totalMinutes = hour * 60 + minute
        let rounded = (totalMinutes / minutes) * minutes
        let newHour = rounded / 60
        let newMinute = rounded % 60
        var updated = comps
        updated.hour = newHour
        updated.minute = newMinute
        return calendar.date(from: updated) ?? self
    }
}

extension ScheduleViewModel {
    private static func dailyStart(for date: Date, calendar: Calendar) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: date)
        components.hour = 4
        components.minute = 45
        components.second = 0
        components.nanosecond = 0
        guard let anchor = calendar.date(from: components) else {
            return date
        }
        if date >= anchor {
            return anchor
        } else {
            return calendar.date(byAdding: .day, value: -1, to: anchor) ?? anchor
        }
    }
}

extension Color {
    init(hex: String) {
        var hexValue = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        if hexValue.count == 3 {
            let chars = Array(hexValue)
            hexValue = "\(chars[0])\(chars[0])\(chars[1])\(chars[1])\(chars[2])\(chars[2])"
        }

        var int = UInt64()
        Scanner(string: hexValue).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hexValue.count {
        case 8:
            (a, r, g, b) = (int >> 24, (int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        default:
            (a, r, g, b) = (255, (int >> 16) & 0xff, (int >> 8) & 0xff, int & 0xff)
        }
        self.init(.sRGB,
                  red: Double(r) / 255,
                  green: Double(g) / 255,
                  blue: Double(b) / 255,
                  opacity: Double(a) / 255)
    }

    var hexString: String {
        guard let components = UIColor(self).cgColor.components else { return "#000000" }
        let r: CGFloat
        let g: CGFloat
        let b: CGFloat
        if components.count >= 3 {
            r = components[0]
            g = components[1]
            b = components[2]
        } else {
            r = components[0]
            g = components[0]
            b = components[0]
        }
        return String(format: "#%02X%02X%02X",
                      Int(r * 255),
                      Int(g * 255),
                      Int(b * 255))
    }

    static func randomAccent() -> Color {
        Color(hue: Double.random(in: 0...1),
              saturation: 0.4,
              brightness: 0.9)
    }
}
