//
//  ScheduleViewModel.swift
//  Agenda
//
//  Created by Codex on 27/11/25.
//

import SwiftUI
import UIKit

protocol FocusStorageProvider {
    func loadFocuses() -> [FocusItem]
    func saveFocuses(_ focuses: [FocusItem])
}

protocol FocusRemoteService {
    func importFocuses() async throws -> [FocusItem]
    func exportFocuses(_ focuses: [FocusItem]) async throws
    func createFocus(_ focus: FocusItem) async throws
    func updateFocus(_ focus: FocusItem) async throws
    func deleteFocus(_ focusID: UUID) async throws
    func updateCategoryMappings(_ categories: [TaskCategory])
}

extension FocusRemoteService {
    func updateCategoryMappings(_ categories: [TaskCategory]) { }
}

protocol TaskCategoryRemoteService {
    func importCategories() async throws -> [TaskCategory]
    func createCategory(_ category: TaskCategory) async throws
    func updateCategory(_ category: TaskCategory) async throws
    func deleteCategory(_ categoryID: UUID) async throws
}

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
    var focusID: UUID?
    var isFocusIndeterminate: Bool

    init(id: UUID = UUID(),
         categoryID: UUID,
         startIndex: Int,
         duration: Int,
         isCompleted: Bool = false,
         focusID: UUID? = nil,
         isFocusIndeterminate: Bool = false) {
        self.id = id
        self.categoryID = categoryID
        self.startIndex = startIndex
        self.duration = duration
        self.isCompleted = isCompleted
        self.focusID = focusID
        self.isFocusIndeterminate = isFocusIndeterminate
    }

    enum CodingKeys: String, CodingKey {
        case id, categoryID, startIndex, duration, isCompleted, focusID, isFocusIndeterminate
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        categoryID = try container.decode(UUID.self, forKey: .categoryID)
        startIndex = try container.decode(Int.self, forKey: .startIndex)
        duration = try container.decode(Int.self, forKey: .duration)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted) ?? false
        focusID = try container.decodeIfPresent(UUID.self, forKey: .focusID)
        isFocusIndeterminate = try container.decodeIfPresent(Bool.self, forKey: .isFocusIndeterminate) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(categoryID, forKey: .categoryID)
        try container.encode(startIndex, forKey: .startIndex)
        try container.encode(duration, forKey: .duration)
        try container.encode(isCompleted, forKey: .isCompleted)
        try container.encodeIfPresent(focusID, forKey: .focusID)
        try container.encode(isFocusIndeterminate, forKey: .isFocusIndeterminate)
    }
}

struct FocusItem: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var expectedMinutes: Int?
    var actualMinutes: Int?
    var isCompleted: Bool?
    var taskIDs: [UUID]
    var proposedCategoryID: UUID?
    var priority: Int

    init(id: UUID = UUID(),
         name: String,
         expectedMinutes: Int? = nil,
         actualMinutes: Int? = nil,
         isCompleted: Bool? = nil,
         taskIDs: [UUID] = [],
         proposedCategoryID: UUID? = nil,
         priority: Int = 0) {
        self.id = id
        self.name = name
        self.expectedMinutes = expectedMinutes
        self.actualMinutes = actualMinutes
        self.isCompleted = isCompleted
        self.taskIDs = taskIDs
        self.proposedCategoryID = proposedCategoryID
        self.priority = max(0, min(priority, 5))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, expectedMinutes, actualMinutes, isCompleted, taskIDs, assignedTaskID, proposedCategoryID, priority
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        expectedMinutes = try container.decodeIfPresent(Int.self, forKey: .expectedMinutes)
        actualMinutes = try container.decodeIfPresent(Int.self, forKey: .actualMinutes)
        isCompleted = try container.decodeIfPresent(Bool.self, forKey: .isCompleted)
        if let decodedTaskIDs = try container.decodeIfPresent([UUID].self, forKey: .taskIDs) {
            taskIDs = decodedTaskIDs
        } else if let legacyID = try container.decodeIfPresent(UUID.self, forKey: .assignedTaskID) {
            taskIDs = [legacyID]
        } else {
            taskIDs = []
        }
        proposedCategoryID = try container.decodeIfPresent(UUID.self, forKey: .proposedCategoryID)
        priority = (try container.decodeIfPresent(Int.self, forKey: .priority)) ?? 0
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encodeIfPresent(expectedMinutes, forKey: .expectedMinutes)
        try container.encodeIfPresent(actualMinutes, forKey: .actualMinutes)
        try container.encodeIfPresent(isCompleted, forKey: .isCompleted)
        try container.encode(taskIDs, forKey: .taskIDs)
        try container.encodeIfPresent(proposedCategoryID, forKey: .proposedCategoryID)
        try container.encode(priority, forKey: .priority)
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
    private let categoryService: TaskCategoryRemoteService
    static var blocksPerHour: Int { max(1, 60 / blockMinutes) }
    private static let appGroupID = "group.com.antoniomunoz.Agenda"
    @Published var categories: [TaskCategory] {
        didSet {
            updateFocusServiceResolver()
        }
    }
    @Published var tasks: [TaskItem]
    @Published var dayLogs: [ScheduleDayLog]
    @Published var focuses: [FocusItem]

    var dayStart: Date
    var dayEnd: Date

    private let wakeUpKey = "agenda.wakeUpAnchor"
    private let tasksKey = "agenda.tasks.storage"
    private let categoriesKey = "agenda.categories.storage"
    private let dayLogsKey = "agenda.dayLogs.storage"
    private let blockVersionKey = "agenda.blockMinutes.version"
    private let legacyBlockMinutes = 15
    private let focusesKey = "agenda.focuses.storage"
    private var calendar: Calendar
    private let defaults: UserDefaults
    private let fallbackDefaults = UserDefaults.standard
    private let focusService: FocusRemoteService
    private let focusCache: FocusStorageProvider?

    init(defaults: UserDefaults = UserDefaults(suiteName: ScheduleViewModel.appGroupID) ?? .standard,
         calendar: Calendar = Calendar.current,
         focusService: FocusRemoteService? = SupabaseFocusService.shared,
         categoryService: TaskCategoryRemoteService? = SupabaseTaskCategoryService.shared) {
        //en focuservice cabiamos el DB o local
        
        
        var normalizedCalendar = calendar
        normalizedCalendar.timeZone = TimeZone.current
        self.calendar = normalizedCalendar
        self.defaults = defaults
        let resolvedFocusService = focusService ?? UserDefaultsFocusStorage(defaults: defaults, key: focusesKey)
        self.focusService = resolvedFocusService
        self.categoryService = categoryService ?? SupabaseTaskCategoryService.shared
        self.focusCache = resolvedFocusService as? FocusStorageProvider
        categories = []
        tasks = []
        dayLogs = []
        focuses = []

        let now = Date()
        let candidateStart = Self.dailyStart(for: now, calendar: self.calendar)
        let stored = defaults.object(forKey: wakeUpKey) as? Date
        var previousDayStart: Date?
        if let stored, self.calendar.isDate(stored, inSameDayAs: candidateStart), stored == candidateStart {
            dayStart = stored
        } else {
            previousDayStart = stored
            dayStart = candidateStart
            defaults.set(candidateStart, forKey: wakeUpKey)
        }

        let nextMidnight = self.calendar.startOfDay(for: self.calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        dayEnd = nextMidnight

        migrateLegacyDataIfNeeded()

        categories = loadCategories()
        updateFocusServiceResolver()
        Task { [weak self] in
            do {
                guard let self else { return }
                let remoteCategories = try await self.categoryService.importCategories()
                await MainActor.run {
                    self.categories = remoteCategories
                }
            } catch {
                #if DEBUG
                print("[Categories] Remote fetch failed: \(error)")
                #endif
            }
        }
        //focuses = loadCachedFocuses()
        var loadedTasks = loadTasks()
        var loadedLogs = loadDayLogs()

        let storedBlockVersion: Int
        if defaults.object(forKey: blockVersionKey) == nil {
            storedBlockVersion = legacyBlockMinutes
        } else {
            let value = defaults.integer(forKey: blockVersionKey)
            storedBlockVersion = value == 0 ? Self.blockMinutes : value
        }

        if storedBlockVersion != Self.blockMinutes {
            loadedTasks = convert(tasks: loadedTasks, from: storedBlockVersion, to: Self.blockMinutes, clampToDay: true)
            loadedLogs = loadedLogs.map { log in
                let converted = convert(tasks: log.tasks, from: storedBlockVersion, to: Self.blockMinutes, clampToDay: false)
                return ScheduleDayLog(id: log.id, date: log.date, tasks: converted)
            }
            if let data = try? JSONEncoder().encode(loadedTasks) {
                defaults.set(data, forKey: tasksKey)
            }
            if let data = try? JSONEncoder().encode(loadedLogs) {
                defaults.set(data, forKey: dayLogsKey)
            }
        }
        defaults.set(Self.blockMinutes, forKey: blockVersionKey)

        if let previousDayStart {
            archiveDay(date: previousDayStart, tasks: loadedTasks)
            tasks = []
            saveTasks()
        } else {
            tasks = loadedTasks
        }
        dayLogs = loadedLogs
        cleanupFocusAssignments()
        Task { [weak self] in
            await self?.refreshFocusesFromRemote()
        }
    }

    var totalBlocks: Int {
        max(1, Int(dayEnd.timeIntervalSince(dayStart) / Double(Self.blockMinutes * 60)))
    }

    func timelineBlocks() -> [TimelineBlock] {
        timelineBlocks(for: dayStart)
    }

    func timelineBlocks(for date: Date) -> [TimelineBlock] {
        let blocksCount = totalBlocks(for: date)
        guard blocksCount > 0 else { return [] }
        let dayTasks = timelineTasks(for: date)
        let baseStart = timelineDayStart(for: date)
        var blocks: [TimelineBlock] = []
        var pointer = 0
        let sortedTasks = dayTasks.sorted { $0.startIndex < $1.startIndex }

        while pointer < blocksCount {
            if let task = sortedTasks.first(where: { $0.startIndex == pointer }) {
                let startDate = baseStart.addingTimeInterval(Double(pointer * Self.blockMinutes) * 60)
                blocks.append(TimelineBlock(index: pointer, span: task.duration, task: task, startDate: startDate))
                pointer += task.duration
            } else {
                let startDate = baseStart.addingTimeInterval(Double(pointer * Self.blockMinutes) * 60)
                blocks.append(TimelineBlock(index: pointer, span: 1, task: nil, startDate: startDate))
                pointer += 1
            }
        }

        return blocks
    }

    func label(for index: Int) -> String {
        label(for: index, on: dayStart)
    }

    func label(for index: Int, on date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: self.date(for: index, on: date))
    }

    func date(for index: Int) -> Date {
        date(for: index, on: dayStart)
    }

    func date(for index: Int, on date: Date) -> Date {
        let start = timelineDayStart(for: date)
        return start.addingTimeInterval(Double(index * Self.blockMinutes) * 60)
    }

    func category(for id: UUID) -> TaskCategory? {
        categories.first { $0.id == id }
    }

    func categoryID(named name: String) -> UUID? {
        categories.first {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }?.id
    }

    func isHourBoundaryBlock(index: Int) -> Bool {
        isHourBoundaryBlock(index: index, on: dayStart)
    }

    func isHourBoundaryBlock(index: Int, on date: Date) -> Bool {
        let blockMinutes = Self.blockMinutes
        guard blockMinutes > 0 else { return false }
        let minutesFromStart = index * blockMinutes
        let start = timelineDayStart(for: date)
        let targetDate = start.addingTimeInterval(Double(minutesFromStart * 60))
        let minute = calendar.component(.minute, from: targetDate)
        return minute == 0
    }

    func hourNumber(for index: Int) -> Int {
        hourNumber(for: index, on: dayStart)
    }

    func hourNumber(for index: Int, on date: Date) -> Int {
        let minutesFromStart = index * Self.blockMinutes
        let start = timelineDayStart(for: date)
        let targetDate = start.addingTimeInterval(Double(minutesFromStart * 60))
        return calendar.component(.hour, from: targetDate)
    }

    func endCurrentDay() {
        let snapshot = tasks
        archiveDay(date: dayStart, tasks: snapshot)
        mutateTasks { tasks in
            tasks.removeAll()
        }
        cleanupFocusAssignments()

        if let nextStart = calendar.date(byAdding: .day, value: 1, to: dayStart) {
            dayStart = nextStart
        }
        let nextMidnight = calendar.startOfDay(for: calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart)
        dayEnd = nextMidnight
        defaults.set(dayStart, forKey: wakeUpKey)
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
        if let focusID = task.focusID,
           let focus = focus(with: focusID) {
            let minutes = task.duration * Self.blockMinutes
            logFocusUsage(focus, minutes: minutes)
        }
    }

    func delete(task: TaskItem) {
        mutateTasks { tasks in
            tasks.removeAll { $0.id == task.id }
        }
        if let focusID = task.focusID {
            mutateFocuses { focuses in
                if let index = focuses.firstIndex(where: { $0.id == focusID }) {
                    focuses[index].taskIDs.removeAll { $0 == task.id }
                }
            }
        }
    }

    func task(with id: UUID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    func focus(with id: UUID) -> FocusItem? {
        focuses.first { $0.id == id }
    }

    func addFocus(name: String,
                  expectedMinutes: Int? = nil,
                  actualMinutes: Int? = nil,
                  proposedCategoryID: UUID? = nil,
                  priority: Int = 0) -> FocusItem {
        let newFocus = FocusItem(name: name.isEmpty ? "Nuevo focus" : name,
                                 expectedMinutes: expectedMinutes,
                                 actualMinutes: actualMinutes,
                                 proposedCategoryID: proposedCategoryID,
                                 priority: priority)
        mutateFocuses { focuses in
            focuses.append(newFocus)
        }
        return newFocus
    }

    func updateFocus(_ focus: FocusItem) {
        mutateFocuses { focuses in
            guard let index = focuses.firstIndex(where: { $0.id == focus.id }) else { return }
            focuses[index] = focus
        }
    }

    func deleteFocus(_ focus: FocusItem) {
        mutateFocuses { focuses in
            focuses.removeAll { $0.id == focus.id }
        }
        mutateTasks { tasks in
            for index in tasks.indices where tasks[index].focusID == focus.id {
                tasks[index].focusID = nil
                tasks[index].isFocusIndeterminate = false
            }
        }
    }

    func assignFocus(_ focus: FocusItem, to task: TaskItem?) {
        guard let task = task,
              let taskEntity = self.task(with: task.id) else { return }
        let taskID = task.id
        let previousFocusID = taskEntity.focusID

        mutateTasks { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return }
            tasks[index].focusID = focus.id
            tasks[index].isFocusIndeterminate = false
        }

        mutateFocuses { focuses in
            guard let index = focuses.firstIndex(where: { $0.id == focus.id }) else { return }
            if !focuses[index].taskIDs.contains(taskID) {
                focuses[index].taskIDs.append(taskID)
            }
        }

        if let previous = previousFocusID, previous != focus.id {
            mutateFocuses { focuses in
                if let index = focuses.firstIndex(where: { $0.id == previous }) {
                    focuses[index].taskIDs.removeAll { $0 == taskID }
                }
            }
        }
    }

    @discardableResult
    func scheduleFocusAtCurrentTime(_ focus: FocusItem, referenceDate: Date = Date()) -> TaskItem? {
        guard let categoryID = focus.proposedCategoryID,
              let category = category(for: categoryID) else { return nil }
        print("[ScheduleViewModel] Scheduling focus using category id: \(categoryID)")
        guard let startIndex = nextAvailableStart(after: referenceDate) else { return nil }
        guard let newTask = addTask(at: startIndex, category: category) else { return nil }
        assignFocus(focus, to: newTask)
        return task(with: newTask.id)
    }

    func logFocusUsage(_ focus: FocusItem, minutes: Int) {
        guard minutes > 0 else { return }
        mutateFocuses { focuses in
            guard let index = focuses.firstIndex(where: { $0.id == focus.id }) else { return }
            let current = focuses[index].actualMinutes ?? 0
            focuses[index].actualMinutes = current + minutes
        }
    }

    func completeFocus(_ focus: FocusItem) {
        mutateFocuses { focuses in
            guard let index = focuses.firstIndex(where: { $0.id == focus.id }) else { return }
            focuses[index].isCompleted = true
        }
        Task {
            try? await focusService.deleteFocus(focus.id)
        }
    }

    func clearFocus(for task: TaskItem) {
        var removedFocusID: UUID?
        update(taskID: task.id) { mutable in
            removedFocusID = mutable.focusID
            mutable.focusID = nil
            mutable.isFocusIndeterminate = false
        }
        if let focusID = removedFocusID {
            mutateFocuses { focuses in
                if let index = focuses.firstIndex(where: { $0.id == focusID }) {
                    focuses[index].taskIDs.removeAll { $0 == task.id }
                }
            }
        }
    }

    func setTaskFocusIndeterminate(_ task: TaskItem, isIndeterminate: Bool) {
        var removedFocusID: UUID?
        update(taskID: task.id) { mutable in
            if isIndeterminate {
                removedFocusID = mutable.focusID
                mutable.focusID = nil
                mutable.isFocusIndeterminate = true
            } else {
                mutable.isFocusIndeterminate = false
            }
        }
        if let focusID = removedFocusID {
            mutateFocuses { focuses in
                if let index = focuses.firstIndex(where: { $0.id == focusID }) {
                    focuses[index].taskIDs.removeAll { $0 == task.id }
                }
            }
        }
    }

    func updateCategory(_ category: TaskCategory) {
        guard let index = categories.firstIndex(where: { $0.id == category.id }) else { return }
        mutateCategories { categories in
            categories[index] = category
        }
        syncCategoryUpdate(category)
    }

    func addCategory() {
        let color = Color.randomAccent().hexString
        let newCategory = TaskCategory(name: "Nueva tarea", colorHex: color)
        mutateCategories { categories in
            categories.append(newCategory)
        }
        syncCategoryCreation(newCategory)
    }

    func addCategory(name: String, color: Color) {
        let newCategory = TaskCategory(name: name.isEmpty ? "Nueva tarea" : name,
                                       colorHex: color.hexString)
        mutateCategories { categories in
            categories.append(newCategory)
        }
        syncCategoryCreation(newCategory)
    }

    func deleteCategory(_ category: TaskCategory) {
        mutateCategories { categories in
            categories.removeAll { $0.id == category.id }
        }
        mutateTasks { tasks in
            tasks.removeAll { $0.categoryID == category.id }
        }
        syncCategoryDeletion(category)
    }

    func clearAllTasks() {
        mutateTasks { tasks in
            tasks.removeAll()
        }
    }

    func shiftTasks(from startIndex: Int, by delta: Int) {
        guard delta > 0 else { return }
        mutateTasks { tasks in
            for index in tasks.indices {
                if tasks[index].startIndex >= startIndex {
                    let newStart = min(max(0, totalBlocks - tasks[index].duration), tasks[index].startIndex + delta)
                    tasks[index].startIndex = newStart
                }
            }
            tasks.sort { $0.startIndex < $1.startIndex }
        }
    }

    func shiftGroup(startingFrom task: TaskItem, by delta: Int) {
        guard delta != 0 else { return }
        mutateTasks { tasks in
            guard tasks.contains(where: { $0.id == task.id }) else { return }
            let group = tasks.filter { $0.startIndex >= task.startIndex }
            guard !group.isEmpty else { return }
            let sortedGroup = group.sorted { $0.startIndex < $1.startIndex }
            let prevEnd = tasks
                .filter { $0.startIndex < task.startIndex }
                .map { $0.startIndex + $0.duration }
                .max() ?? 0
            let groupMinStart = sortedGroup.first?.startIndex ?? task.startIndex
            let groupMaxEnd = sortedGroup.map { $0.startIndex + $0.duration }.max() ?? (task.startIndex + task.duration)

            if delta > 0 {
                guard groupMaxEnd + delta <= totalBlocks else { return }
            } else {
                guard groupMinStart + delta >= prevEnd else { return }
            }

            for index in tasks.indices where tasks[index].startIndex >= task.startIndex {
                tasks[index].startIndex += delta
            }
            tasks.sort { $0.startIndex < $1.startIndex }
        }
    }

    func adjustTaskPosition(for task: TaskItem, by deltaBlocks: Int) {
        guard deltaBlocks != 0,
              let current = self.task(with: task.id) else { return }

        if deltaBlocks > 0 {
            let previousStart = current.startIndex
            move(task: current, by: deltaBlocks)
            if let updated = self.task(with: current.id),
               updated.startIndex == previousStart {
                shiftGroup(startingFrom: current, by: deltaBlocks)
            }
        } else {
            move(task: current, by: deltaBlocks)
        }
    }

    func adjustTaskDuration(for task: TaskItem, by deltaBlocks: Int) {
        guard let current = self.task(with: task.id) else { return }
        let maxDuration = totalBlocks - current.startIndex
        let proposed = current.duration + deltaBlocks
        let newDuration = min(maxDuration, max(1, proposed))
        guard newDuration != current.duration else { return }
        resize(task: current, newDuration: newDuration)
    }

    func adjustTaskEndTime(for task: TaskItem, to endDate: Date) {
        let blockSeconds = Double(Self.blockMinutes) * 60
        mutateTasks { tasks in
            guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
            let startIndex = tasks[index].startIndex
            let startDate = self.date(for: startIndex)
            guard endDate > startDate else { return }
            let elapsed = endDate.timeIntervalSince(startDate)
            guard elapsed > 0 else { return }
            let rawBlocks = elapsed / blockSeconds
            let desiredBlocks = Int(ceil(rawBlocks))
            let clamped = max(1, min(tasks[index].duration, desiredBlocks))
            guard clamped != tasks[index].duration else { return }
            tasks[index].duration = clamped
            tasks.sort { $0.startIndex < $1.startIndex }
        }
    }

    func finishTask(_ task: TaskItem, at date: Date) {
        adjustTaskEndTime(for: task, to: date)
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
        cleanupFocusAssignments()
    }

    private func mutateCategories(_ transform: (inout [TaskCategory]) -> Void) {
        var updated = categories
        transform(&updated)
        categories = updated
        saveCategories()
    }

    private func mutateFocuses(_ transform: (inout [FocusItem]) -> Void) {
        var updated = focuses
        transform(&updated)
        applyFocusChanges(updated)
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

    private func syncCategoryCreation(_ category: TaskCategory) {
        Task {
            do {
                try await categoryService.createCategory(category)
#if DEBUG
                print("[Categories] Created remote category \(category.id) (\(category.name))")
#endif
            } catch {
                #if DEBUG
                print("[Categories] Failed to create \(category.id): \(error)")
                #endif
            }
        }
    }

    private func syncCategoryDeletion(_ category: TaskCategory) {
        Task {
            do {
                try await categoryService.deleteCategory(category.id)
#if DEBUG
                print("[Categories] Deleted remote category \(category.id) (\(category.name))")
#endif
            } catch {
                #if DEBUG
                print("[Categories] Failed to delete \(category.id): \(error)")
                #endif
            }
        }
    }

    private func syncCategoryUpdate(_ category: TaskCategory) {
        Task {
            do {
                try await categoryService.updateCategory(category)
#if DEBUG
                print("[Categories] Updated remote category \(category.id) (\(category.name))")
#endif
            } catch {
#if DEBUG
                print("[Categories] Failed to update \(category.id): \(error)")
#endif
            }
        }
    }

    private func loadCachedFocuses() -> [FocusItem] {
        focusCache?.loadFocuses() ?? []
    }

    private func applyFocusChanges(_ updated: [FocusItem], shouldSyncRemote: Bool = true) {
        guard updated != focuses else { return }
        let previous = focuses
        focuses = updated
        focusCache?.saveFocuses(updated)
        if shouldSyncRemote {
            syncFocuses(previous: previous, updated: updated)
        }
    }

    private func syncFocuses(previous: [FocusItem], updated: [FocusItem]) {
        let service = focusService
        Task {
            do {
                let previousMap = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
                let updatedIDs = Set(updated.map { $0.id })
                for focus in updated {
                    if let existing = previousMap[focus.id] {
                        if existing != focus {
                            try await service.updateFocus(focus)
                        }
                    } else {
                        try await service.createFocus(focus)
                    }
                }
                for removed in previous where !updatedIDs.contains(removed.id) {
                    try await service.deleteFocus(removed.id)
                }
            } catch {
                #if DEBUG
                print("Focus sync failed: \(error)")
                #endif
            }
        }
    }

    @MainActor
    func refreshFocusesFromRemote() async {
        do {
            let remoteFocuses = try await focusService.importFocuses()
            var merged = focuses
            for focus in remoteFocuses {
                if let index = merged.firstIndex(where: { $0.id == focus.id }) {
                    merged[index] = focus
                } else {
                    merged.append(focus)
                }
            }
            applyFocusChanges(merged, shouldSyncRemote: false)
            cleanupFocusAssignments()
        } catch {
            #if DEBUG
            print("Focus import failed: \(error)")
            #endif
        }
    }

    private func updateFocusServiceResolver() {
        guard let supabaseService = focusService as? SupabaseFocusService else { return }
        supabaseService.setCategoryResolver { [weak self] typeName in
            guard let categories = self?.categories else { return nil }
            return categories.first {
                $0.name.caseInsensitiveCompare(typeName) == .orderedSame
            }?.id
        }
        supabaseService.setCategoryNameResolver { [weak self] identifier in
            self?.category(for: identifier)?.name
        }
    }

    private func nextAvailableStart(after date: Date) -> Int? {
        guard totalBlocks > 0 else { return nil }
        guard var candidate = blockIndex(for: date) else { return nil }
        if let overlapping = taskOccupying(block: candidate) {
            candidate = overlapping.startIndex + overlapping.duration
        }
        while candidate < totalBlocks {
            if canPlace(start: candidate, duration: 1) {
                return candidate
            }
            if let blocking = taskOccupying(block: candidate) {
                candidate = blocking.startIndex + blocking.duration
            } else {
                candidate += 1
            }
        }
        return nil
    }

    private func blockIndex(for date: Date) -> Int? {
        let blockSeconds = Double(Self.blockMinutes) * 60
        let diff = date.timeIntervalSince(dayStart)
        if diff < 0 {
            return 0
        }
        let index = Int(diff / blockSeconds)
        guard index < totalBlocks else { return nil }
        return index
    }

    private func taskOccupying(block index: Int) -> TaskItem? {
        guard index >= 0 else { return nil }
        return tasks.first { task in
            index >= task.startIndex && index < task.startIndex + task.duration
        }
    }

    private func cleanupFocusAssignments() {
        guard !focuses.isEmpty else { return }
        let validIDs = Set(tasks.map { $0.id })
        var updated = focuses
        var changed = false
        for index in updated.indices {
            let filtered = updated[index].taskIDs.filter { validIDs.contains($0) }
            if filtered.count != updated[index].taskIDs.count {
                updated[index].taskIDs = filtered
                changed = true
            }
        }
        if changed {
            applyFocusChanges(updated)
        }
    }

    private func convert(tasks: [TaskItem], from oldMinutes: Int, to newMinutes: Int, clampToDay: Bool) -> [TaskItem] {
        guard oldMinutes > 0, newMinutes > 0, oldMinutes != newMinutes else { return tasks }
        var converted = tasks.map { task -> TaskItem in
            var updated = task
            let startMinutes = task.startIndex * oldMinutes
            let durationMinutes = task.duration * oldMinutes
            updated.startIndex = max(0, Int(floor(Double(startMinutes) / Double(newMinutes))))
            updated.duration = max(1, Int(ceil(Double(durationMinutes) / Double(newMinutes))))
            return updated
        }
        if clampToDay {
            let maxStart = max(0, totalBlocks - 1)
            for index in converted.indices {
                converted[index].startIndex = min(converted[index].startIndex, maxStart)
                if converted[index].startIndex + converted[index].duration > totalBlocks {
                    converted[index].duration = max(1, totalBlocks - converted[index].startIndex)
                }
            }
        }
        converted.sort { $0.startIndex < $1.startIndex }
        return converted
    }

    private func migrateLegacyDataIfNeeded() {
        guard defaults !== fallbackDefaults else { return }

        func copyIfNeeded(key: String) {
            if defaults.object(forKey: key) == nil,
               let value = fallbackDefaults.object(forKey: key) {
                defaults.set(value, forKey: key)
            }
        }

        copyIfNeeded(key: tasksKey)
        copyIfNeeded(key: categoriesKey)
        copyIfNeeded(key: dayLogsKey)
        copyIfNeeded(key: focusesKey)
        copyIfNeeded(key: wakeUpKey)
        copyIfNeeded(key: blockVersionKey)
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

struct UserDefaultsFocusStorage: FocusStorageProvider {
    let defaults: UserDefaults
    let key: String

    func loadFocuses() -> [FocusItem] {
        guard
            let data = defaults.data(forKey: key),
            let decoded = try? JSONDecoder().decode([FocusItem].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func saveFocuses(_ focuses: [FocusItem]) {
        guard let data = try? JSONEncoder().encode(focuses) else { return }
        defaults.set(data, forKey: key)
    }
}

extension UserDefaultsFocusStorage: FocusRemoteService {
    func importFocuses() async throws -> [FocusItem] {
        loadFocuses()
    }

    func exportFocuses(_ focuses: [FocusItem]) async throws {
        saveFocuses(focuses)
    }

    func createFocus(_ focus: FocusItem) async throws {
        var current = loadFocuses()
        current.append(focus)
        saveFocuses(current)
    }

    func updateFocus(_ focus: FocusItem) async throws {
        var current = loadFocuses()
        if let index = current.firstIndex(where: { $0.id == focus.id }) {
            current[index] = focus
            saveFocuses(current)
        }
    }

    func deleteFocus(_ focusID: UUID) async throws {
        var current = loadFocuses()
        current.removeAll { $0.id == focusID }
        saveFocuses(current)
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

    func timelineDayStart(for date: Date) -> Date {
        Self.dailyStart(for: date, calendar: calendar)
    }

    func timelineDayEnd(for date: Date) -> Date {
        let start = timelineDayStart(for: date)
        let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
        return calendar.startOfDay(for: nextDay)
    }

    func totalBlocks(for date: Date) -> Int {
        let start = timelineDayStart(for: date)
        let end = timelineDayEnd(for: date)
        return max(1, Int(end.timeIntervalSince(start) / Double(Self.blockMinutes * 60)))
    }

    func timelineTasks(for date: Date) -> [TaskItem] {
        if calendar.isDate(date, inSameDayAs: dayStart) {
            return tasks
        }
        if let log = dayLogs.first(where: { calendar.isDate($0.date, inSameDayAs: date) }) {
            return log.tasks
        }
        return []
    }

    func isCurrentDay(_ date: Date) -> Bool {
        calendar.isDate(date, inSameDayAs: dayStart)
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
