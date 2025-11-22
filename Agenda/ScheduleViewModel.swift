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

    init(id: UUID = UUID(), categoryID: UUID, startIndex: Int, duration: Int) {
        self.id = id
        self.categoryID = categoryID
        self.startIndex = startIndex
        self.duration = duration
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

    let dayStart: Date
    let dayEnd: Date

    private let wakeUpKey = "agenda.wakeUpAnchor"
    private let calendar = Calendar.current
    private let defaults = UserDefaults.standard

    init() {
        let now = Date()
        let stored = defaults.object(forKey: wakeUpKey) as? Date
        if let stored, calendar.isDate(stored, inSameDayAs: now) {
            dayStart = stored
        } else {
            let newStart = now.roundedDownToBlock(minutes: Self.blockMinutes, calendar: calendar)
            dayStart = newStart
            defaults.set(newStart, forKey: wakeUpKey)
        }

        let midnight = calendar.startOfDay(for: now)
        dayEnd = calendar.date(byAdding: .day, value: 1, to: midnight) ?? midnight.addingTimeInterval(24 * 60 * 60)

        categories = Self.defaultCategories
        tasks = []
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
        update(taskID: task.id) { mutable in
            if canPlace(start: newStart, duration: mutable.duration, ignoring: mutable.id) {
                mutable.startIndex = newStart
            }
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

    func deleteCategory(_ category: TaskCategory) {
        mutateCategories { categories in
            categories.removeAll { $0.id == category.id }
        }
        mutateTasks { tasks in
            tasks.removeAll { $0.categoryID == category.id }
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
    }

    private func mutateCategories(_ transform: (inout [TaskCategory]) -> Void) {
        var updated = categories
        transform(&updated)
        categories = updated
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
