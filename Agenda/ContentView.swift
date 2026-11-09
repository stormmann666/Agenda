//
//  ContentView.swift
//  Agenda
//
//  Created by Antonio Muñoz on 22/11/25.
//

import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = ScheduleViewModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        TabView {
            DayTimelineView(viewModel: viewModel)
                .tabItem {
                    Label("Hoy", systemImage: "calendar")
                }
            CategoryManagerView(viewModel: viewModel)
                .tabItem {
                    Label("Tipos", systemImage: "slider.horizontal.3")
                }
            FocusManagerView(viewModel: viewModel)
                .tabItem {
                    Label("Focuses", systemImage: "target")
                }
            FocusDiagnosticsView(viewModel: viewModel)
                .tabItem {
                    Label("Ayuda", systemImage: "questionmark.circle")
                }
            OneThingView()
                .tabItem {
                    Label("OneThing", systemImage: "lightbulb.max")
                }
        }
        .task(id: scenePhase) {
            if scenePhase == .active {
                await viewModel.refreshFromRemote()
            }
        }
    }
}

private struct FocusCSVRowData {
    let id: String
    let description: String
    let type: String
    let priority: Int
    let estimated: Int
    let worked: Int
}

private enum FocusDataSource: String, CaseIterable, Identifiable {
    case local
    case supabase

    var id: String { rawValue }

    var label: String {
        switch self {
        case .local: return "Local"
        case .supabase: return "Supabase"
        }
    }
}

struct DayTimelineView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var selectedDate: Date

    private let blockHeight: CGFloat = 56
    private static let navigationDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "EEE dd MMM"
        return formatter
    }()
    @State private var selectedBlockIndex: Int?
    @State private var showCategoryPicker = false
    @State private var editingTask: TaskItem?
    @State private var taskPendingDeletion: TaskItem?
    @State private var draggingTaskID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var resizingTaskID: UUID?
    @State private var resizingPreviewDuration: Int = 1
    @State private var scheduleError: String?
    @State private var isClearingAllTasks = false
    @State private var moveModeTaskID: UUID?
    @State private var selectedTaskID: UUID?
    @State private var liveTime = Date()
    @State private var isPaused = false
    @State private var pauseReferenceDate: Date?
    @State private var pauseTaskID: UUID?
    @State private var pauseAccumulatedBlocks: Int = 0
    @State private var timelineRefreshID = UUID()
    @State private var scrollProxy: ScrollViewProxy?
    @State private var showingEndDayConfirmation = false
    @State private var statsAlertText: String?
    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    init(viewModel: ScheduleViewModel) {
        _viewModel = ObservedObject(initialValue: viewModel)
        _selectedDate = State(initialValue: viewModel.dayStart)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                daySelector
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            let blocks = viewModel.timelineBlocks(for: selectedDate)
                            let isActiveDay = viewModel.isCurrentDay(selectedDate)
                            ForEach(blocks) { block in
                                let isHourStart = viewModel.isHourBoundaryBlock(index: block.index, on: selectedDate)
                                if isHourStart {
                                    HourMarkerView(label: hourRangeLabel(for: block.index, on: selectedDate))
                                        .padding(.bottom, 2)
                                }
                                HStack(alignment: .top, spacing: 12) {
                                    Text(viewModel.label(for: block.index, on: selectedDate))
                                        .font(.caption)
                                        .frame(width: 60, alignment: .trailing)
                                        .padding(.top, 8)

                                    blockContent(for: block, dayDate: selectedDate, isActiveDay: isActiveDay)
                                }
                                .padding(.vertical, 2)
                                .id(block.index)
                            }
                        }
                        .padding(.horizontal)
                        .id(timelineRefreshID)
                    }
                    .onAppear {
                        scrollProxy = proxy
                        scrollToCurrentHour(animated: false, targetDate: selectedDate)
                    }
                    .onChange(of: timelineRefreshID) { _ in
                        scrollToCurrentHour(animated: false, targetDate: selectedDate)
                    }
                }
            }
            .onChange(of: selectedDate) { _ in
                timelineRefreshID = UUID()
                scrollToCurrentHour(animated: false, targetDate: selectedDate)
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                scrollToCurrentHour(animated: false, targetDate: selectedDate)
            }
            .onReceive(liveTimer) { date in
                liveTime = date
                handlePauseProgress(at: date)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Tipo de tarea", isPresented: $showCategoryPicker, presenting: selectedBlockIndex) { index in
                ForEach(viewModel.categories) { category in
                    Button(category.name) {
                        addTask(at: index, with: category)
                    }
                }
                Button("Cancelar", role: .cancel) {
                    selectedBlockIndex = nil
                }
            }
            .sheet(item: $editingTask) { task in
                TaskEditorSheet(viewModel: viewModel, taskID: task.id)
            }
            .alert(scheduleError ?? "", isPresented: Binding(
                get: { scheduleError != nil },
                set: { _ in scheduleError = nil })
            ) {
                Button("Entendido") {
                    scheduleError = nil
                }
            }
            .confirmationDialog("Eliminar tarea", isPresented: Binding(
                get: { taskPendingDeletion != nil },
                set: { if !$0 { taskPendingDeletion = nil } })
            ) {
                if let task = taskPendingDeletion {
                    Button("Eliminar", role: .destructive) {
                        viewModel.delete(task: task)
                        taskPendingDeletion = nil
                        if selectedTaskID == task.id {
                            selectedTaskID = nil
                        }
                    }
                }
                Button("Cancelar", role: .cancel) {
                    taskPendingDeletion = nil
                }
            } message: {
                Text("¿Quieres borrar esta tarea?")
            }
            .alert("¿Borrar todas las tareas?", isPresented: $isClearingAllTasks) {
                Button("Eliminar todas", role: .destructive) {
                    viewModel.clearAllTasks()
                    selectedTaskID = nil
                }
                Button("Cancelar", role: .cancel) { }
            }
            .alert("Terminar día", isPresented: $showingEndDayConfirmation) {
                Button("Terminar", role: .destructive) {
                    viewModel.endCurrentDay()
                    updateSelectedDate(viewModel.dayStart, force: true)
                    timelineRefreshID = UUID()
                    scrollToCurrentHour(animated: false, targetDate: selectedDate)
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se guardará el día actual y se iniciará uno nuevo.")
            }
            .alert("Estadísticas del día", isPresented: Binding(
                get: { statsAlertText != nil },
                set: { if !$0 { statsAlertText = nil } })
            ) {
                Button("Cerrar", role: .cancel) {
                    statsAlertText = nil
                }
            } message: {
                Text(statsAlertText ?? "")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        scrollToCurrentHour(animated: true, targetDate: selectedDate)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                    .disabled(!viewModel.isCurrentDay(selectedDate))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        presentStats()
                    } label: {
                        Image(systemName: "chart.bar.xaxis")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEndDayConfirmation = true
                    } label: {
                        Image(systemName: "flag.checkered")
                    }
                    .disabled(!viewModel.isCurrentDay(selectedDate))
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isClearingAllTasks = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(!viewModel.isCurrentDay(selectedDate) || viewModel.tasks.isEmpty)
                }
            }
        }
    }

    private func currentAnchorIndex(for date: Date) -> Int {
        guard viewModel.isCurrentDay(date) else { return 0 }
        let start = viewModel.timelineDayStart(for: date)
        let diff = Date().timeIntervalSince(start)
        let blockSeconds = Double(ScheduleViewModel.blockMinutes) * 60
        if diff <= 0 {
            return 0
        }
        let total = viewModel.totalBlocks(for: date)
        return min(total - 1, Int(diff / blockSeconds))
    }

    @ViewBuilder
    private func blockContent(for block: TimelineBlock, dayDate: Date, isActiveDay: Bool) -> some View {
        let height = blockHeight * CGFloat(block.span)
        let liveLineOffset = isActiveDay ? liveIndicatorOffset(for: block, on: dayDate) : nil

        ZStack(alignment: .topLeading) {
            if let task = block.task, let category = viewModel.category(for: task.categoryID) {
                let currentTask = isActiveDay ? (viewModel.task(with: task.id) ?? task) : task
                let displayDuration = (resizingTaskID == task.id ? resizingPreviewDuration : task.duration)
                let taskHeight = blockHeight * CGFloat(displayDuration)
                let isDragging = draggingTaskID == task.id
                let isMoveMode = moveModeTaskID == task.id
                let isSelected = selectedTaskID == task.id
                let isCompleted = currentTask.isCompleted
                let liveStatus = isActiveDay ? liveStatusInfo(for: task, on: dayDate) : nil
                let focusLabel = focusDisplayLabel(for: currentTask)
                let isFocusIndeterminate = currentTask.isFocusIndeterminate

                HStack(spacing: 8) {
                    VStack(spacing: 4) {
                        ZStack(alignment: .topTrailing) {
                            TaskCardView(category: category,
                                         height: taskHeight,
                                         durationMinutes: displayDuration * ScheduleViewModel.blockMinutes,
                                         dragOffset: isDragging ? dragOffset : 0,
                                         isDragging: isDragging,
                                         isResizing: resizingTaskID == task.id,
                                         isMoveModeActive: isMoveMode,
                                         isSelected: isSelected,
                                         isCompleted: isCompleted,
                                         liveStatus: liveStatus,
                                         focusLabel: focusLabel,
                                         isFocusIndeterminate: isFocusIndeterminate)
                            .contentShape(Rectangle())
                            .gesture(
                                TapGesture(count: 2)
                                    .onEnded {
                                        editingTask = task
                                        selectedTaskID = task.id
                                    }
                                    .exclusively(before: resizeGesture(for: task))
                            )
                            .simultaneousGesture(
                                TapGesture()
                                    .onEnded {
                                        selectedTaskID = task.id
                                    }
                            )

                            HStack(spacing: 6) {
                                Button {
                                    viewModel.toggleCompletion(for: currentTask)
                                } label: {
                                    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
                                        .font(.headline)
                                        .foregroundColor(isCompleted ? .green : .gray)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Completar box")

                                Button {
                                    toggleFocusState(for: task)
                                } label: {
                                    let color = focusIndicatorColor(for: task)
                                    Image(systemName: "target")
                                        .font(.headline)
                                        .foregroundColor(color)
                                        .frame(width: 34, height: 34)
                                        .background(Circle().fill(Color(.systemBackground).opacity(0.9)))
                                        .overlay(
                                            Circle()
                                                .stroke(color.opacity(0.6), lineWidth: 1)
                                        )
                                        .contentShape(Circle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    taskPendingDeletion = task
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.caption)
                                        .padding(8)
                                        .background(Color.red.opacity(0.18))
                                        .clipShape(Circle())
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(8)
                        }

                        if let liveStatus {
                            LiveStatusBar(status: liveStatus)
                        }
                    }

                    MoveHandleView(height: taskHeight,
                                   isActive: isMoveMode,
                                   onStart: {
                                       beginMove(for: task)
                                   },
                                   onChanged: { offset in
                                       handleMoveDragChanged(for: task, offset: offset)
                                   },
                                   onEnded: { offset in
                                       handleMoveDragEnded(for: task, offset: offset)
                                   })
                }
            } else {
                let hourNumber = viewModel.hourNumber(for: block.index, on: dayDate)
                let strokeColor = hourStrokeColor(forHour: hourNumber)
                EmptySlot(height: height, strokeColor: strokeColor)
                    .onTapGesture {
                        selectedBlockIndex = block.index
                        showCategoryPicker = true
                    }
            }

            if let liveLineOffset {
                HStack(spacing: 8) {
                    Text(liveIndicatorLabel)
                        .font(.caption2)
                        .foregroundColor(liveLineColor(for: block))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemBackground).opacity(0.85))
                        .clipShape(Capsule())
                    Rectangle()
                        .fill(liveLineColor(for: block))
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: -48)
                .offset(y: liveLineOffset - 1)
                .allowsHitTesting(false)
            }
        }
        .allowsHitTesting(isActiveDay)
    }

    private var daySelector: some View {
        HStack(spacing: 24) {
            Button {
                shiftSelectedDate(by: -1)
            } label: {
                Image(systemName: "chevron.left")
                    .font(.headline)
            }
            .buttonStyle(.borderless)

            Text(selectedDateLabel)
                .font(.headline)
                .frame(maxWidth: .infinity)

            Button {
                shiftSelectedDate(by: 1)
            } label: {
                Image(systemName: "chevron.right")
                    .font(.headline)
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
    }

    private var selectedDateLabel: String {
        Self.navigationDateFormatter.string(from: selectedDate)
    }

    private func shiftSelectedDate(by days: Int) {
        guard let newDate = Calendar.current.date(byAdding: .day, value: days, to: selectedDate) else { return }
        updateSelectedDate(newDate, force: true)
    }

    private func updateSelectedDate(_ rawDate: Date, force: Bool = false) {
        let normalized = viewModel.timelineDayStart(for: rawDate)
        if !force && normalized == selectedDate {
            return
        }
        clearTransientSelections()
        selectedDate = normalized
    }

    private func clearTransientSelections() {
        selectedBlockIndex = nil
        showCategoryPicker = false
        editingTask = nil
        taskPendingDeletion = nil
        draggingTaskID = nil
        resizingTaskID = nil
        moveModeTaskID = nil
        selectedTaskID = nil
    }

    private func presentStats() {
        let stats = viewModel.focusStats(for: selectedDate)
        statsAlertText = statsDescription(for: stats)
    }

    private func statsDescription(for stats: ScheduleDayLog.FocusStatistics) -> String {
        func format(_ hours: Double) -> String {
            let totalMinutes = Int(round(hours * 60))
            let h = totalMinutes / 60
            let m = totalMinutes % 60
            switch (h, m) {
            case (0, let minutes):
                return "\(minutes)m"
            case (let hours, 0):
                return "\(hours)h"
            default:
                return "\(h)h \(m)m"
            }
        }

        let total = format(stats.totalHours)
        let focused = format(stats.focusedHours)
        let indeterminate = format(stats.indeterminateFocusHours)
        let unfocused = format(stats.unfocusedHours)

        return """
Total estudiado: \(total)
Con focus: \(focused)
Focus indeterminado: \(indeterminate)
Sin focus: \(unfocused)
"""
    }

    private func addTask(at index: Int, with category: TaskCategory) {
        if viewModel.addTask(at: index, category: category) == nil {
            scheduleError = "Ese espacio ya está ocupado."
        }
        selectedBlockIndex = nil
    }

    private func handleMoveDragChanged(for task: TaskItem, offset: CGFloat) {
        guard moveModeTaskID == task.id else { return }
        draggingTaskID = task.id
        dragOffset = offset
    }

    private func handleMoveDragEnded(for task: TaskItem, offset: CGFloat) {
        guard draggingTaskID == task.id else {
            finishMove()
            return
        }
        let delta = Int(round(offset / blockHeight))
        finishMove()
        guard delta != 0 else { return }
        viewModel.adjustTaskPosition(for: task, by: delta)
    }

    private func resetDragState() {
        draggingTaskID = nil
        dragOffset = 0
    }

    private func beginMove(for task: TaskItem) {
        if moveModeTaskID != task.id {
            moveModeTaskID = task.id
            resetDragState()
        }
        selectedTaskID = task.id
    }

    private func finishMove() {
        moveModeTaskID = nil
        resetDragState()
    }

    private func finishTaskNow(_ task: TaskItem) {
        let now = Date()
        liveTime = now
        withAnimation {
            viewModel.finishTask(task, at: now)
            timelineRefreshID = UUID()
        }
    }

    private func toggleFocusState(for task: TaskItem) {
        if task.isFocusIndeterminate {
            viewModel.setTaskFocusIndeterminate(task, isIndeterminate: false)
        } else {
            viewModel.setTaskFocusIndeterminate(task, isIndeterminate: true)
        }
    }

    private func focusIndicatorColor(for task: TaskItem) -> Color {
        if task.focusID != nil {
            return Color.red
        }
        if task.isFocusIndeterminate {
            return Color.blue.opacity(0.7)
        }
        return Color.gray.opacity(0.7)
    }

    private func liveStatusInfo(for task: TaskItem, on date: Date) -> LiveStatusInfo? {
        guard viewModel.isCurrentDay(date) else { return nil }
        let startDate = viewModel.date(for: task.startIndex, on: date)
        let endDate = viewModel.date(for: task.startIndex + task.duration, on: date)
        guard liveTime >= startDate, liveTime < endDate else { return nil }
        let total = endDate.timeIntervalSince(startDate)
        guard total > 0 else { return nil }
        let remaining = endDate.timeIntervalSince(liveTime)
        let fraction = max(0, min(1, remaining / total))
        let minutes = max(0, Int(ceil(remaining / 60)))
        return LiveStatusInfo(remainingMinutes: minutes, fraction: fraction)
    }

    private func focusDisplayLabel(for task: TaskItem) -> String? {
        guard let focusID = task.focusID,
              let focus = viewModel.focus(with: focusID) else {
            return nil
        }
        if let firstLine = focus.name.split(separator: "\n").first {
            return String(firstLine)
        }
        return focus.name
    }

    private func liveIndicatorOffset(for block: TimelineBlock, on date: Date) -> CGFloat? {
        guard viewModel.isCurrentDay(date) else { return nil }
        let blockStart = block.startDate
        let blockEnd = viewModel.date(for: block.index + block.span, on: date)
        guard liveTime >= blockStart, liveTime < blockEnd else { return nil }
        let total = blockEnd.timeIntervalSince(blockStart)
        guard total > 0 else { return nil }
        let elapsed = liveTime.timeIntervalSince(blockStart)
        let fraction = max(0, min(1, elapsed / total))
        return CGFloat(fraction) * blockHeight * CGFloat(block.span)
    }

    private func liveLineColor(for block: TimelineBlock) -> Color {
        if block.task != nil {
            return .red
        }
        return Color(red: 0.15, green: 0.7, blue: 0.45)
    }

    private var liveIndicatorLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: liveTime)
    }

    private func hourRangeLabel(for index: Int, on date: Date) -> String {
        let startDate = viewModel.date(for: index, on: date)
        let calendar = Calendar.current
        let startHour = calendar.component(.hour, from: startDate)
        let endHour = (startHour + 1) % 24
        return "\(String(format: "%02d", startHour)) - \(String(format: "%02d", endHour)) h"
    }

    private func hourStrokeColor(forHour hour: Int) -> Color {
        if hour % 2 == 0 {
            return Color(red: 0.3, green: 0.5, blue: 0.8).opacity(0.55)
        } else {
            return Color(red: 0.8, green: 0.6, blue: 0.3).opacity(0.55)
        }
    }

    private func scrollToCurrentHour(animated: Bool, targetDate: Date) {
        guard let proxy = scrollProxy else { return }
        let target = currentAnchorIndex(for: targetDate)
        if animated {
            withAnimation {
                proxy.scrollTo(target, anchor: .top)
            }
        } else {
            proxy.scrollTo(target, anchor: .top)
        }
    }

    private func handlePauseProgress(at currentDate: Date) { }

    private func currentTask(at date: Date) -> TaskItem? {
        let blocks = viewModel.timelineBlocks(for: selectedDate)
        return blocks.first { block in
            guard let task = block.task else { return false }
            let startDate = viewModel.date(for: block.index, on: selectedDate)
            let endDate = viewModel.date(for: block.index + task.duration, on: selectedDate)
            return date >= startDate && date < endDate
        }?.task
    }

    private func resizeGesture(for task: TaskItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture())
            .onChanged { value in
                switch value {
                case let .first(success):
                    guard success else { return }
                    finishMove()
                    resizingTaskID = task.id
                    resizingPreviewDuration = task.duration
                case let .second(success, drag):
                    guard success else { return }
                    guard let translation = drag?.translation else { return }
                    resizingTaskID = task.id
                    let delta = Int(round(translation.height / blockHeight))
                    let maxDuration = viewModel.totalBlocks - task.startIndex
                    resizingPreviewDuration = min(maxDuration, max(1, task.duration + delta))
                default:
                    break
                }
            }
            .onEnded { value in
                if case let .second(success, drag) = value,
                   success,
                   let translation = drag?.translation {
                    let delta = Int(round(translation.height / blockHeight))
                    viewModel.adjustTaskDuration(for: task, by: delta)
                }
                resizingTaskID = nil
                resizingPreviewDuration = 1
            }
    }

}

struct TaskCardView: View {
    let category: TaskCategory
    let height: CGFloat
    let durationMinutes: Int
    let dragOffset: CGFloat
    let isDragging: Bool
    let isResizing: Bool
    let isMoveModeActive: Bool
    let isSelected: Bool
    let isCompleted: Bool
    let liveStatus: LiveStatusInfo?
    let focusLabel: String?
    let isFocusIndeterminate: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                Circle()
                    .fill(category.color)
                    .frame(width: 18, height: 18)
                Text(category.name)
                    .font(.headline)
                    .foregroundColor(isCompleted ? .secondary : category.color)
                    .strikethrough(isCompleted, color: category.color)
                Spacer()
            }

            HStack(spacing: 8) {
                Text("Duración: \(durationMinutes) min")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let liveStatus {
                    Text("· Restan \(liveStatus.remainingMinutes) min")
                        .font(.caption)
                        .foregroundColor(.yellow)
                }
            }
            if let focusLabel {
                Text("Focus: \(focusLabel)")
                    .font(.caption2)
                    .foregroundColor(category.color)
            } else if isFocusIndeterminate {
                Text("Focus pendiente")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(category.color.opacity(isSelected || isMoveModeActive ? 0.22 : 0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isMoveModeActive ? Color.blue : (isSelected ? category.color.opacity(0.9) : category.color),
                        lineWidth: isMoveModeActive || isSelected ? 3 : 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(style: StrokeStyle(lineWidth: isResizing ? 2 : 0, dash: [6]))
                        .foregroundColor(category.color.opacity(isResizing ? 0.8 : 0))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .offset(y: isDragging ? dragOffset : 0)
        .shadow(color: isMoveModeActive ? Color.blue.opacity(0.3) : .clear, radius: isMoveModeActive ? 6 : 0)
        .opacity(isCompleted ? 0.7 : 1)
    }
}

struct MoveHandleView: View {
    let height: CGFloat
    let isActive: Bool
    var onStart: () -> Void
    var onChanged: (CGFloat) -> Void
    var onEnded: (CGFloat) -> Void

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .fill(isActive ? Color.blue : Color.blue.opacity(0.6))
            .frame(width: 48, height: height)
            .frame(minHeight: 72)
            .overlay(
                VStack(spacing: 6) {
                    Image(systemName: "arrow.up.arrow.down")
                        .font(.headline)
                        .foregroundColor(.white)
                    Text("Mover")
                        .font(.caption2)
                        .foregroundColor(.white.opacity(0.9))
                }
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        onStart()
                        onChanged(value.translation.height)
                    }
                    .onEnded { value in
                        onEnded(value.translation.height)
                    }
            )
    }
}

struct LiveStatusInfo {
    let remainingMinutes: Int
    let fraction: Double
}

struct LiveStatusBar: View {
    let status: LiveStatusInfo

    var body: some View {
        HStack(spacing: 8) {
            Capsule()
                .fill(Color.blue.opacity(0.25))
                .frame(width: 120, height: 4)
                .overlay(
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: max(0, 120 * statusFraction), height: 4),
                    alignment: .leading
                )
            Text("\(status.remainingMinutes) min")
                .font(.caption2)
                .foregroundColor(.blue)
            Spacer()
        }
        .padding(.leading, 26)
        .allowsHitTesting(false)
    }

    private var statusFraction: CGFloat {
        CGFloat(max(0, min(1, status.fraction)))
    }
}

struct EmptySlot: View {
    let height: CGFloat
    let strokeColor: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [6]))
            .foregroundColor(strokeColor)
            .frame(height: height)
            .overlay(
                Text("Toque para asignar")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .allowsHitTesting(false)
            )
            .contentShape(Rectangle())
    }
}

struct CategoryPickerSheet: View {
    let title: String
    let categories: [TaskCategory]
    @State private var selection: UUID
    var onSelection: (TaskCategory) -> Void
    @Environment(\.dismiss) private var dismiss

    init(title: String, categories: [TaskCategory], selectedID: UUID, onSelection: @escaping (TaskCategory) -> Void) {
        self.title = title
        self.categories = categories
        _selection = State(initialValue: selectedID)
        self.onSelection = onSelection
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Orden", selection: .constant(0)) {
                        Text("Default").tag(0)
                        Text("Tipos").tag(1)
                        Text("Prioridad").tag(2)
                    }
                    .pickerStyle(.segmented)
                }
                ForEach(categories) { category in
                    HStack {
                        Circle()
                            .fill(category.color)
                            .frame(width: 16, height: 16)
                        Text(category.name)
                        Spacer()
                        if selection == category.id {
                            Image(systemName: "checkmark")
                                .foregroundColor(.accentColor)
                        }
                    }
                    .contentShape(Rectangle())
                    .onTapGesture {
                        selection = category.id
                    }
                }
            }
            .navigationTitle(title)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        guard let selected = categories.first(where: { $0.id == selection }) else {
                            dismiss()
                            return
                        }
                        onSelection(selected)
                        dismiss()
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }
            }
        }
    }
}

struct CategoryManagerView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var showingAddCategory = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(viewModel.categories) { category in
                    HStack(spacing: 12) {
                        TextField("Nombre", text: Binding(
                            get: { viewModel.category(for: category.id)?.name ?? category.name },
                            set: { name in
                                guard var updated = viewModel.category(for: category.id) else { return }
                                updated.name = name
                                viewModel.updateCategory(updated)
                            }))
                            .font(.headline)
                        Spacer()
                        ColorPicker("",
                                    selection: Binding<Color>(
                                        get: { viewModel.category(for: category.id)?.color ?? category.color },
                                        set: { newColor in
                                            guard var updated = viewModel.category(for: category.id) else { return }
                                            updated.colorHex = newColor.hexString
                                            viewModel.updateCategory(updated)
                                        })
                        )
                        .labelsHidden()
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                    }

                    .padding(.vertical, 6)
                }
                .onDelete { indexSet in
                    let removed = indexSet.map { viewModel.categories[$0] }
                    for category in removed {
                        viewModel.deleteCategory(category)
                    }
                }
            }
            .refreshable {
                await viewModel.refreshCategoriesFromRemote()
            }
            .safeAreaInset(edge: .bottom) {
                VStack(spacing: 4) {
                    if let date = viewModel.categoriesLastRefreshedAt {
                        Text("Actualizado a las \(date.formatted(date: .omitted, time: .standard)) · \(viewModel.categories.count) tipos")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let error = viewModel.categoryMutationError ?? viewModel.categoryRefreshError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .padding()
                    }
                }
            }
            .navigationTitle("Tipos de tarea")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddCategory = true
                    } label: {
                        Label("Añadir", systemImage: "plus")
                    }
                }
            }
        }
        .task {
            await viewModel.refreshCategoriesFromRemote()
        }
        .sheet(isPresented: $showingAddCategory) {
            AddCategorySheet { name, color in
                viewModel.addCategory(name: name, color: color)
            }
        }
    }
}

#Preview {
    ContentView()
}

struct AddCategorySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var color: Color = Color.randomAccent()
    @FocusState private var nameFieldFocused: Bool
    var onSave: (String, Color) -> Void

    var body: some View {
        NavigationStack {
            Form {
                Section("Nombre") {
                    TextField("Nombre de la tarea", text: $name)
                        .focused($nameFieldFocused)
                }
                Section("Color") {
                    ColorGrid(selectedColor: $color)
                    ColorPicker("Personalizar color", selection: $color, supportsOpacity: false)
                        .font(.footnote)
                }
            }
            .navigationTitle("Nueva tarea")
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    nameFieldFocused = true
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancelar") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onSave(name.isEmpty ? "Nueva tarea" : name, color)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct ColorGrid: View {
    @Binding var selectedColor: Color

    private let colors: [Color] = [
        .red, .orange, .yellow, .green, .mint, .teal, .blue, .indigo, .purple, .pink,
        Color(red: 0.97, green: 0.58, blue: 0.12),
        Color(red: 0.55, green: 0.27, blue: 0.07),
        Color(red: 0.4, green: 0.71, blue: 0.54),
        Color(red: 0.2, green: 0.29, blue: 0.37),
        Color(red: 0.8, green: 0.12, blue: 0.35),
        Color(red: 0.07, green: 0.62, blue: 0.69),
        Color(red: 0.12, green: 0.12, blue: 0.26),
        Color(red: 0.86, green: 0.23, blue: 0.18),
        Color(red: 0.32, green: 0.42, blue: 0.68),
        Color(red: 0.54, green: 0.67, blue: 0.82)
    ]

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 5)

    var body: some View {
        LazyVGrid(columns: columns, spacing: 10) {
            ForEach(colors.indices, id: \.self) { idx in
                let color = colors[idx]
                Circle()
                    .fill(color)
                    .frame(width: 34, height: 34)
                    .overlay(
                        Circle()
                            .stroke(Color.white, lineWidth: selectedColor.isApproximatelyEqual(to: color) ? 3 : 0)
                    )
                    .shadow(radius: selectedColor.isApproximatelyEqual(to: color) ? 3 : 0)
                    .onTapGesture {
                        selectedColor = color
                    }
            }
        }
        .padding(.vertical, 4)
    }
}

private extension Color {
    func isApproximatelyEqual(to other: Color) -> Bool {
        let lhs = UIColor(self)
        let rhs = UIColor(other)
        var lRed: CGFloat = 0, lGreen: CGFloat = 0, lBlue: CGFloat = 0, lAlpha: CGFloat = 0
        var rRed: CGFloat = 0, rGreen: CGFloat = 0, rBlue: CGFloat = 0, rAlpha: CGFloat = 0
        lhs.getRed(&lRed, green: &lGreen, blue: &lBlue, alpha: &lAlpha)
        rhs.getRed(&rRed, green: &rGreen, blue: &rBlue, alpha: &rAlpha)
        return abs(lRed - rRed) < 0.02 &&
               abs(lGreen - rGreen) < 0.02 &&
               abs(lBlue - rBlue) < 0.02 &&
               abs(lAlpha - rAlpha) < 0.02
    }
}

private struct AvoidedScheduleWindow: Identifiable, Equatable {
    let id: UUID
    var start: Date
    var end: Date

    init(id: UUID = UUID(), referenceDate: Date = Date(), startHour: Int = 13, endHour: Int = 14) {
        self.id = id
        start = Calendar.current.date(bySettingHour: startHour, minute: 0, second: 0, of: referenceDate) ?? referenceDate
        end = Calendar.current.date(bySettingHour: endHour, minute: 0, second: 0, of: referenceDate) ?? referenceDate.addingTimeInterval(3600)
    }

    init(id: UUID = UUID(), referenceDate: Date = Date(), startMinutes: Int, endMinutes: Int) {
        self.id = id
        let calendar = Calendar.current
        let day = calendar.startOfDay(for: referenceDate)
        start = calendar.date(byAdding: .minute, value: startMinutes, to: day) ?? day
        end = calendar.date(byAdding: .minute, value: endMinutes, to: day) ?? day
    }

    var startMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: start)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    var endMinutes: Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: end)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

private struct PersistedAvoidedScheduleWindow: Codable {
    let startMinutes: Int
    let endMinutes: Int
}

struct FocusManagerView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var showingAddFocus = false
    @State private var newFocusName: String = ""
    @State private var newFocusHours: String = ""
    @State private var newFocusProposedCategoryID: UUID? = nil
    @State private var newFocusPriority: Int = 0
    @State private var estimationIndeterminate = true
    @State private var editingFocus: FocusItem?
    @State private var focusEditName: String = ""
    @State private var focusEditHours: String = ""
    @State private var focusEditActualMinutes: String = ""
    @State private var editEstimationIndeterminate = false
    @State private var focusEditProposedCategoryID: UUID? = nil
    @State private var focusEditPriority: Int = 0
    @FocusState private var focusFieldFocused: Bool
    @FocusState private var hoursFieldFocused: Bool
    @State private var focusSortMode: FocusSortMode = .defaultOrder
    @State private var focusActionMessage: String?
    @State private var recentlyScheduledFocusID: UUID?
    @State private var showingPriorityAdjuster = false
    @State private var scheduleProposals: [FocusScheduleProposal] = []
    @State private var showingSchedulePreview = false
    @State private var avoidedTimeWindows: [AvoidedScheduleWindow] = []
    @State private var focusSessionMinutes = 30
    @State private var maximumConsecutiveFocusTypes = 2
    @State private var breakMinutes = 0
    @State private var scheduleReorderMessage: String?

    private static let avoidedWindowsStorageKey = "agenda.autoFocus.avoidedWindows"
    private static let appGroupID = "group.com.antoniomunoz.Agenda"

    init(viewModel: ScheduleViewModel) {
        _viewModel = ObservedObject(initialValue: viewModel)
        _avoidedTimeWindows = State(initialValue: Self.loadAvoidedTimeWindows())
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Orden", selection: $focusSortMode) {
                        Text("Default").tag(FocusSortMode.defaultOrder)
                        Text("Tipos").tag(FocusSortMode.byType)
                        Text("Prioridad").tag(FocusSortMode.priority)
                    }
                    .pickerStyle(.segmented)
                }

                if filteredFocuses.isEmpty {
                    ContentUnavailableView("No hay focuses pendientes", systemImage: "target", description: Text("Marca o añade nuevos focuses para verlos aquí."))
                } else {
                    focusListContent
                }
            }
            .navigationTitle("Focuses")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    HStack {
                        Button {
                            prepareAutomaticSchedule()
                        } label: {
                            Label("Planificar", systemImage: "wand.and.stars")
                        }
                        Button {
                            showingPriorityAdjuster = true
                        } label: {
                            Label("Prioridades", systemImage: "slider.horizontal.3")
                        }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingAddFocus = true
                    } label: {
                        Label("Nuevo focus", systemImage: "plus")
                    }
                }
            }
            .sheet(isPresented: $showingAddFocus) {
                NavigationStack {
                    Form {
                        Section("Descripción") {
                            TextField("Descripción del focus", text: $newFocusName)
                                .focused($focusFieldFocused)
                        }
                        Section("Estimación") {
                            Toggle("Indeterminado", isOn: $estimationIndeterminate)
                                .onChange(of: estimationIndeterminate) { value in
                                    if value {
                                        newFocusHours = ""
                                        hoursFieldFocused = false
                                    } else {
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                            hoursFieldFocused = true
                                        }
                                    }
                                }
                            if !estimationIndeterminate {
                                TextField("Minutos", text: $newFocusHours)
                                    .keyboardType(.numberPad)
                                    .focused($hoursFieldFocused)
                            }
                        }
                        Section("Propuesta de tipo") {
                            Picker("Tipo", selection: $newFocusProposedCategoryID) {
                                Text("Indeterminado").tag(UUID?.none)
                                ForEach(viewModel.categories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        }
                        Section("Prioridad (0-5)") {
                            Picker("Prioridad", selection: $newFocusPriority) {
                                ForEach(0...5, id: \.self) { value in
                                    Text(String(repeating: "★", count: value)).tag(value)
                                }
                            }
                        }
                    }
                    .navigationTitle("Nuevo focus")
                    .onAppear {
                        focusFieldFocused = true
                    }
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") {
                                resetFocusForm()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Guardar") {
                                saveFocus()
                            }
                            .disabled(!canSaveFocus)
                        }
                    }
                }
                .presentationDetents([.medium])
                .onDisappear {
                    resetFocusForm()
                }
            }
            .sheet(item: $editingFocus) { focus in
                NavigationStack {
                    Form {
                        Section("Descripción") {
                            TextField("Descripción", text: $focusEditName)
                        }
                        Section("Estimación") {
                            Toggle("Indeterminado", isOn: $editEstimationIndeterminate)
                                .onChange(of: editEstimationIndeterminate) { value in
                                    if value {
                                        focusEditHours = ""
                                    }
                                }
                            if !editEstimationIndeterminate {
                                TextField("Minutos", text: $focusEditHours)
                                    .keyboardType(.numberPad)
                            }
                        }
                        Section("Tiempo trabajado (min)") {
                            TextField("Minutos", text: $focusEditActualMinutes)
                                .keyboardType(.numberPad)
                        }
                        Section("Propuesta de tipo") {
                            Picker("Tipo", selection: $focusEditProposedCategoryID) {
                                Text("Indeterminado").tag(UUID?.none)
                                ForEach(viewModel.categories) { category in
                                    Text(category.name).tag(Optional(category.id))
                                }
                            }
                        }
                        Section("Prioridad (0-5)") {
                            Picker("Prioridad", selection: $focusEditPriority) {
                                ForEach(0...5, id: \.self) { value in
                                    Text(String(repeating: "★", count: value)).tag(value)
                                }
                            }
                        }
                    }
                    .navigationTitle("Editar focus")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") {
                                editingFocus = nil
                                resetEditFocusState()
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Guardar") {
                                guard var updated = editingFocus else { return }
                                updated.name = focusEditName
                                let estimateText = focusEditHours.trimmingCharacters(in: .whitespacesAndNewlines)
                                let estimatedMinutes = editEstimationIndeterminate ? nil : max(0, Int(estimateText) ?? 0)
                                updated.expectedMinutes = estimatedMinutes
                                updated.actualMinutes = max(0, Int(focusEditActualMinutes) ?? 0)
                                updated.proposedCategoryID = focusEditProposedCategoryID
                                updated.priority = focusEditPriority
                                viewModel.updateFocus(updated)
                                editingFocus = nil
                                resetEditFocusState()
                            }
                            .disabled(!canSaveEditedFocus)
                        }
                    }
                }
                .onAppear {
                    focusEditName = focus.name
                    editEstimationIndeterminate = focus.expectedMinutes == nil
                    focusEditHours = focus.expectedMinutes.map { String($0) } ?? ""
                    focusEditActualMinutes = String(focus.actualMinutes ?? 0)
                    focusEditProposedCategoryID = focus.proposedCategoryID
                }
                .onDisappear {
                    resetEditFocusState()
                }
            }
            .sheet(isPresented: $showingPriorityAdjuster) {
                NavigationStack {
                    FocusPriorityAdjustView(viewModel: viewModel)
                }
            }
            .sheet(isPresented: $showingSchedulePreview) {
                NavigationStack {
                    List {
                        Section("Configuración") {
                            Picker("Tiempo por tarea", selection: $focusSessionMinutes) {
                                ForEach([15, 25, 30, 45, 60, 90], id: \.self) { minutes in
                                    Text("\(minutes) min").tag(minutes)
                                }
                            }
                            Picker("Máximo del mismo tipo seguidos", selection: $maximumConsecutiveFocusTypes) {
                                ForEach(1...5, id: \.self) { count in
                                    Text("\(count)").tag(count)
                                }
                            }
                            Picker("Descanso entre actividades", selection: $breakMinutes) {
                                ForEach([0, 5, 10, 15, 20, 30], id: \.self) { minutes in
                                    Text(minutes == 0 ? "Sin descanso" : "\(minutes) min").tag(minutes)
                                }
                            }
                            ForEach($avoidedTimeWindows) { $window in
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Text("Horario a evitar")
                                            .font(.subheadline.weight(.semibold))
                                        Spacer()
                                        Button(role: .destructive) {
                                            avoidedTimeWindows.removeAll { $0.id == window.id }
                                        } label: {
                                            Image(systemName: "trash")
                                        }
                                        .buttonStyle(.borderless)
                                        .accessibilityLabel("Eliminar horario a evitar")
                                    }
                                    DatePicker("Desde", selection: $window.start, displayedComponents: .hourAndMinute)
                                    DatePicker("Hasta", selection: $window.end, displayedComponents: .hourAndMinute)
                                    if window.end <= window.start {
                                        Text("La hora final debe ser posterior a la inicial.")
                                            .font(.caption)
                                            .foregroundStyle(.red)
                                    }
                                }
                            }
                            Button {
                                avoidedTimeWindows.append(AvoidedScheduleWindow())
                            } label: {
                                Label("Añadir horario a evitar", systemImage: "plus.circle")
                            }
                            Text("Solo se incluyen focuses con prioridad entre 1 y 5. Los boxes existentes siempre se respetan.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Button {
                                refreshAutomaticSchedule()
                            } label: {
                                Label("Actualizar propuesta", systemImage: "arrow.clockwise")
                            }
                        }
                        Section("Propuesta") {
                            if let scheduleReorderMessage {
                                Text(scheduleReorderMessage)
                                    .font(.caption)
                                    .foregroundStyle(.red)
                            }
                            if scheduleProposals.isEmpty {
                                Text("No hay focuses prioritarios que puedan colocarse con esta configuración.")
                                    .foregroundStyle(.secondary)
                            } else {
                                ForEach(scheduleProposals) { proposal in
                                    scheduleProposalRow(proposal)
                                }
                                .onMove(perform: moveScheduleProposals)
                                .onDelete(perform: deleteScheduleProposals)
                            }
                        }
                    }
                    .navigationTitle("Plan automático")
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancelar") {
                                showingSchedulePreview = false
                            }
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Añadir a la agenda") {
                                applyAutomaticSchedule()
                            }
                            .disabled(scheduleProposals.isEmpty || hasInvalidAvoidedWindow)
                        }
                        ToolbarItem(placement: .bottomBar) {
                            EditButton()
                        }
                    }
                    .onChange(of: focusSessionMinutes) { _ in refreshAutomaticSchedule() }
                    .onChange(of: maximumConsecutiveFocusTypes) { _ in refreshAutomaticSchedule() }
                    .onChange(of: breakMinutes) { _ in refreshAutomaticSchedule() }
                    .onChange(of: avoidedTimeWindows) { _ in
                        saveAvoidedTimeWindows()
                        refreshAutomaticSchedule()
                    }
                    .onChange(of: viewModel.focuses) { _ in refreshAutomaticSchedule() }
                }
            }
            .alert("Focus", isPresented: Binding(
                get: { focusActionMessage != nil },
                set: { newValue in
                    if !newValue {
                        focusActionMessage = nil
                    }
                })
            ) {
                Button("Aceptar", role: .cancel) {
                    focusActionMessage = nil
                }
            } message: {
                Text(focusActionMessage ?? "")
            }
            .refreshable {
                await viewModel.refreshFromRemote()
                refreshAutomaticSchedule()
            }
        }
    }

    private var canSaveFocus: Bool {
        let trimmed = newFocusName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if estimationIndeterminate { return true }
        let minutesValue = newFocusHours.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(minutesValue), minutes > 0 else { return false }
        return true
    }

    private func saveFocus() {
        guard showingAddFocus, canSaveFocus else { return }
        let trimmed = newFocusName.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutesInput = newFocusHours.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = estimationIndeterminate ? nil : max(0, Int(minutesInput) ?? 0)
        viewModel.addFocus(name: trimmed,
                           expectedMinutes: minutes,
                           proposedCategoryID: newFocusProposedCategoryID,
                           priority: newFocusPriority)
        resetFocusForm()
    }

    private func prepareAutomaticSchedule() {
        refreshAutomaticSchedule()
        showingSchedulePreview = true
    }

    private func refreshAutomaticSchedule() {
        scheduleReorderMessage = nil
        scheduleProposals = viewModel.proposeFocusSchedule(maximumSessionMinutes: focusSessionMinutes,
                                                           maximumConsecutiveSameCategory: maximumConsecutiveFocusTypes,
                                                           breakMinutes: breakMinutes,
                                                           avoiding: avoidedScheduleRanges)
    }

    private func moveScheduleProposals(from offsets: IndexSet, to destination: Int) {
        let previous = scheduleProposals
        var reordered = scheduleProposals
        reordered.move(fromOffsets: offsets, toOffset: destination)
        if let reflowed = viewModel.reflowFocusSchedule(reordered,
                                                        breakMinutes: breakMinutes,
                                                        avoiding: avoidedScheduleRanges) {
            scheduleProposals = reflowed
            scheduleReorderMessage = nil
        } else {
            scheduleProposals = previous
            scheduleReorderMessage = "Ese orden no cabe en los huecos disponibles."
        }
    }

    private func deleteScheduleProposals(at offsets: IndexSet) {
        var remaining = scheduleProposals
        remaining.remove(atOffsets: offsets)
        if remaining.isEmpty {
            scheduleProposals = []
            scheduleReorderMessage = nil
            return
        }
        if let reflowed = viewModel.reflowFocusSchedule(remaining,
                                                        breakMinutes: breakMinutes,
                                                        avoiding: avoidedScheduleRanges) {
            scheduleProposals = reflowed
            scheduleReorderMessage = nil
        } else {
            scheduleReorderMessage = "No se pudieron recolocar las tareas restantes."
        }
    }

    private var avoidedScheduleRanges: [Range<Date>] {
        avoidedTimeWindows.compactMap { window in
            guard window.start < window.end else { return nil }
            return window.start..<window.end
        }
    }

    private var hasInvalidAvoidedWindow: Bool {
        avoidedTimeWindows.contains { $0.end <= $0.start }
    }

    private static var scheduleDefaults: UserDefaults {
        UserDefaults(suiteName: appGroupID) ?? .standard
    }

    private static func loadAvoidedTimeWindows() -> [AvoidedScheduleWindow] {
        guard let data = scheduleDefaults.data(forKey: avoidedWindowsStorageKey),
              let stored = try? JSONDecoder().decode([PersistedAvoidedScheduleWindow].self, from: data) else {
            return []
        }
        return stored.compactMap { item in
            guard item.startMinutes >= 0,
                  item.endMinutes <= 24 * 60,
                  item.startMinutes < item.endMinutes else { return nil }
            return AvoidedScheduleWindow(startMinutes: item.startMinutes, endMinutes: item.endMinutes)
        }
    }

    private func saveAvoidedTimeWindows() {
        let stored = avoidedTimeWindows.compactMap { window -> PersistedAvoidedScheduleWindow? in
            guard window.start < window.end else { return nil }
            return PersistedAvoidedScheduleWindow(startMinutes: window.startMinutes,
                                                  endMinutes: window.endMinutes)
        }
        guard let data = try? JSONEncoder().encode(stored) else { return }
        Self.scheduleDefaults.set(data, forKey: Self.avoidedWindowsStorageKey)
    }

    private func applyAutomaticSchedule() {
        if viewModel.applyFocusSchedule(scheduleProposals) {
            showingSchedulePreview = false
            scheduleProposals = []
        } else {
            showingSchedulePreview = false
            focusActionMessage = "La agenda ha cambiado. Vuelve a generar la propuesta para evitar solapamientos."
        }
    }

    @ViewBuilder
    private func scheduleProposalRow(_ proposal: FocusScheduleProposal) -> some View {
        if let focus = viewModel.focus(with: proposal.focusID),
           let category = viewModel.category(for: proposal.categoryID) {
            HStack(spacing: 12) {
                Circle()
                    .fill(category.color)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 3) {
                    Text(focus.name)
                        .font(.headline)
                    Text("\(viewModel.label(for: proposal.startIndex))–\(viewModel.label(for: proposal.startIndex + proposal.duration)) · \(proposal.duration * ScheduleViewModel.blockMinutes) min")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var focusListContent: some View {
        switch focusSortMode {
        case .defaultOrder:
            focusRows(for: filteredFocuses)
        case .priority:
            focusRows(for: prioritySortedFocuses)
        case .byType:
            focusSectionsList
        }
    }

    @ViewBuilder
    private func focusRows(for focuses: [FocusItem]) -> some View {
        ForEach(focuses) { focus in
            focusRow(for: focus)
        }
        .onDelete { offsets in
            deleteFocuses(from: focuses, at: offsets)
        }
    }

    @ViewBuilder
    private var focusSectionsList: some View {
        ForEach(groupedFocusSections) { section in
            Section(header: sectionHeader(for: section)) {
                ForEach(section.focuses) { focus in
                    focusRow(for: focus)
                }
                .onDelete { offsets in
                    deleteFocuses(from: section.focuses, at: offsets)
                }
            }
        }
    }

    @ViewBuilder
    private func focusRow(for focus: FocusItem) -> some View {
        let indicatorColor = focusColor(for: focus)
        HStack(spacing: 12) {
            Button {
                viewModel.completeFocus(focus)
            } label: {
                Image(systemName: "circle")
                    .foregroundColor(.gray)
            }
            .buttonStyle(.plain)
            Circle()
                .fill(indicatorColor)
                .frame(width: 14, height: 14)
                .overlay(
                    Circle().stroke(indicatorColor.opacity(0.6), lineWidth: 1)
                )
            VStack(alignment: .leading, spacing: 4) {
                Text(focus.name)
                    .font(.headline)
                Text(priorityLabel(for: focus))
                    .font(.caption2)
                    .foregroundColor(.orange)
                Text(estimationLabel(for: focus))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(proposedLabel(for: focus))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                progressBar(for: focus)
                if let id = focus.taskIDs.first,
                   let task = viewModel.task(with: id),
                   let category = viewModel.category(for: task.categoryID) {
                    Text("Asignada a \(category.name)")
                        .font(.caption)
                        .foregroundColor(category.color)
                } else if focus.taskIDs.count > 1 {
                    Text("Asignada a \(focus.taskIDs.count) boxes")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Sin asignar")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .listRowBackground(indicatorColor.opacity(0.12))
        .overlay(alignment: .topTrailing) {
            if recentlyScheduledFocusID == focus.id {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundColor(.green)
                    .padding(6)
                    .transition(.scale)
            }
        }
        .onTapGesture(count: 2) {
            editingFocus = focus
        }
        .onLongPressGesture(minimumDuration: 0.45) {
            handleFocusQuickSchedule(focus)
        }
    }

    private func resetFocusForm() {
        showingAddFocus = false
        newFocusName = ""
        newFocusHours = ""
        newFocusProposedCategoryID = nil
        estimationIndeterminate = true
        focusFieldFocused = false
        hoursFieldFocused = false
    }

    private func deleteFocuses(from focuses: [FocusItem], at offsets: IndexSet) {
        let targets = offsets.compactMap { index in
            focuses.indices.contains(index) ? focuses[index] : nil
        }
        for focus in targets {
            viewModel.deleteFocus(focus)
        }
    }

    private var filteredFocuses: [FocusItem] {
        let active = viewModel.focuses.filter { focus in
            !(focus.isCompleted ?? false)
        }
        return Array(active.reversed())
    }

    private var prioritySortedFocuses: [FocusItem] {
        filteredFocuses.sorted { lhs, rhs in
            if lhs.priority == rhs.priority {
                return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            }
            return lhs.priority > rhs.priority
        }
    }

    private var groupedFocusSections: [FocusSectionData] {
        let grouped = Dictionary(grouping: filteredFocuses, by: { $0.proposedCategoryID })
        return grouped.map { key, focuses in
            let ordered = focuses.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if let id = key,
               let category = viewModel.category(for: id) {
                return FocusSectionData(identifier: id.uuidString,
                                        title: category.name,
                                        color: category.color,
                                        focuses: ordered,
                                        isIndeterminate: false)
            } else {
                return FocusSectionData(identifier: "indeterminado",
                                        title: "Indeterminado",
                                        color: nil,
                                        focuses: ordered,
                                        isIndeterminate: true)
            }
        }
        .sorted { lhs, rhs in
            if lhs.isIndeterminate != rhs.isIndeterminate {
                return !lhs.isIndeterminate && rhs.isIndeterminate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func focusColor(for focus: FocusItem) -> Color {
        if let id = focus.taskIDs.first,
           let task = viewModel.task(with: id),
           let category = viewModel.category(for: task.categoryID) {
            return category.color
        } else if let proposed = focus.proposedCategoryID,
                  let category = viewModel.category(for: proposed) {
            return category.color.opacity(0.7)
        }
        return Color.secondary.opacity(0.4)
    }

    private func estimationLabel(for focus: FocusItem) -> String {
        let expectedHours = focus.expectedMinutes.map { $0 / 60 }
        let actualMinutes = focus.actualMinutes ?? 0
        let actualHours = actualMinutes / 60
        let actualMinutesRemainder = actualMinutes % 60
        let actualText: String
        if actualMinutes > 0 {
            actualText = " · Empleado: \(actualHours)h \(actualMinutesRemainder)m"
        } else {
            actualText = " · Empleado: 0h"
        }
        if let expectedHours = expectedHours {
            return "Estimado: \(expectedHours) h\(actualText)"
        } else {
            return "Sin estimación\(actualText)"
        }
    }

    private func priorityLabel(for focus: FocusItem) -> String {
        let value = (focus.priority)
        if value <= 0 {
            return "Prioridad baja"
        }
        return "Prioridad: " + String(repeating: "★", count: min(value, 5))
    }

    private func proposedLabel(for focus: FocusItem) -> String {
        if let id = focus.proposedCategoryID,
           let category = viewModel.category(for: id) {
            return "Propuesto: \(category.name)"
        }
        return "Propuesto: indeterminado"
    }

    private var canSaveEditedFocus: Bool {
        let trimmed = focusEditName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if editEstimationIndeterminate { return true }
        let estimateText = focusEditHours.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let minutes = Int(estimateText), minutes > 0 else { return false }
        return true
    }

    private func resetEditFocusState() {
        focusEditName = ""
        focusEditHours = ""
        focusEditActualMinutes = ""
        editEstimationIndeterminate = false
        focusEditProposedCategoryID = nil
    }

    @ViewBuilder
    private func progressBar(for focus: FocusItem) -> some View {
        let actual = focus.actualMinutes ?? 0
        if let expected = focus.expectedMinutes, expected > 0 {
            ProgressView(value: min(Double(actual) / Double(expected), 1.0))
                .tint(.blue)
        } else if actual > 0 {
            ProgressView(value: min(Double(actual) / Double(max(actual, 1)), 1.0))
                .tint(.green)
        } else {
            ProgressView(value: 0)
                .tint(.gray)
        }
    }

    private func handleFocusQuickSchedule(_ focus: FocusItem) {
        guard let proposedID = focus.proposedCategoryID,
              viewModel.category(for: proposedID) != nil else {
            focusActionMessage = "Este focus necesita un tipo propuesto antes de poder crear un box."
            return
        }
        if viewModel.scheduleFocusAtCurrentTime(focus) == nil {
            focusActionMessage = "No hay espacio disponible ahora mismo para añadir este focus al horario."
        } else {
            focusActionMessage = nil
            recentlyScheduledFocusID = focus.id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if recentlyScheduledFocusID == focus.id {
                    recentlyScheduledFocusID = nil
                }
            }
        }
    }
}

private extension FocusManagerView {
    enum FocusSortMode: Int, Hashable {
        case defaultOrder = 0
        case byType = 1
        case priority = 2
    }

    struct FocusSectionData: Identifiable {
        let identifier: String
        let title: String
        let color: Color?
        let focuses: [FocusItem]
        let isIndeterminate: Bool

        var id: String { identifier }
    }

    @ViewBuilder
    func sectionHeader(for section: FocusSectionData) -> some View {
        HStack(spacing: 8) {
            if let color = section.color {
                Circle()
                    .fill(color)
                    .frame(width: 10, height: 10)
            } else {
                Circle()
                    .stroke(Color.secondary, lineWidth: 1)
                    .frame(width: 10, height: 10)
            }
            Text(section.title)
                .font(.headline)
        }
    }
}

struct TaskEditorSheet: View {
    @ObservedObject var viewModel: ScheduleViewModel
    let taskID: UUID
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFocusOption: FocusOption = .none
    @State private var suppressSelectionUpdate = false

    var body: some View {
        NavigationStack {
            Form {
                focusSection
            }
            .navigationTitle("Focus del box")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Cerrar") {
                        dismiss()
                    }
                }
            }
            .overlay {
                if viewModel.task(with: taskID) == nil {
                    ContentUnavailableView("Tarea no encontrada",
                                           systemImage: "exclamationmark.triangle",
                                           description: Text("Esta tarea ya no está disponible."))
                }
            }
            .onAppear {
                synchronizeSelection()
            }
            .onChange(of: viewModel.tasks) { _ in
                synchronizeSelection()
            }
            .onChange(of: viewModel.focuses) { _ in
                synchronizeSelection()
            }
            .onChange(of: selectedFocusOption) { newValue in
                guard !suppressSelectionUpdate else { return }
                applySelection(newValue)
            }
        }
    }

    private var focusSection: some View {
        Section("Focus") {
            focusSelectionRow(option: .none) {
                Text("Sin focus")
            }
            focusSelectionRow(option: .indeterminate) {
                Text("Focus indeterminado")
            }

            if sortedAvailableFocuses.isEmpty {
                Text("No hay focuses libres ahora mismo.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(sortedAvailableFocuses) { focus in
                    focusSelectionRow(option: .focus(focus.id),
                                      highlight: matchesTaskCategory(focus)) {
                        FocusSelectionLabel(focus: focus,
                                            color: indicatorColor(for: focus),
                                            proposedName: proposedCategoryName(for: focus))
                    }
                }
            }
        }
    }

    private func synchronizeSelection() {
        guard let task = viewModel.task(with: taskID) else { return }
        let newSelection: FocusOption
        if let focusID = task.focusID,
           viewModel.focus(with: focusID) != nil {
            newSelection = .focus(focusID)
        } else if task.isFocusIndeterminate {
            newSelection = .indeterminate
        } else {
            newSelection = .none
        }
        if newSelection != selectedFocusOption {
            suppressSelectionUpdate = true
            selectedFocusOption = newSelection
            DispatchQueue.main.async {
                suppressSelectionUpdate = false
            }
        }
    }

    private func applySelection(_ option: FocusOption) {
        guard let task = viewModel.task(with: taskID) else { return }
        switch option {
        case .none:
            viewModel.clearFocus(for: task)
        case .indeterminate:
            viewModel.setTaskFocusIndeterminate(task, isIndeterminate: true)
        case .focus(let id):
            if let focus = viewModel.focus(with: id) {
                viewModel.assignFocus(focus, to: task)
            }
        }
    }

    private enum FocusOption: Hashable {
        case none
        case indeterminate
        case focus(UUID)
    }

    private var availableFocuses: [FocusItem] {
        viewModel.focuses.filter { !($0.isCompleted ?? false) }
    }

    private var sortedAvailableFocuses: [FocusItem] {
        let categoryID = taskCategoryID
        return availableFocuses.sorted { lhs, rhs in
            let lhsMatch = lhs.proposedCategoryID == categoryID
            let rhsMatch = rhs.proposedCategoryID == categoryID
            if lhsMatch != rhsMatch {
                return lhsMatch && !rhsMatch
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private var taskCategoryID: UUID? {
        viewModel.task(with: taskID)?.categoryID
    }

    private func matchesTaskCategory(_ focus: FocusItem) -> Bool {
        focus.proposedCategoryID != nil && focus.proposedCategoryID == taskCategoryID
    }

    private func indicatorColor(for focus: FocusItem) -> Color {
        if let proposed = focus.proposedCategoryID,
           let category = viewModel.category(for: proposed) {
            return category.color
        }
        return .secondary.opacity(0.5)
    }

    private func proposedCategoryName(for focus: FocusItem) -> String {
        if let proposed = focus.proposedCategoryID,
           let category = viewModel.category(for: proposed) {
            return category.name
        }
        return "Indeterminado"
    }

    @ViewBuilder
    private func focusSelectionRow(option: FocusOption,
                                   highlight: Bool = false,
                                   @ViewBuilder content: () -> some View) -> some View {
        Button {
            selectedFocusOption = option
        } label: {
            HStack {
                content()
                Spacer()
                if selectedFocusOption == option {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                } else {
                    Image(systemName: "circle")
                        .foregroundColor(.secondary)
                }
            }
        }
        .buttonStyle(.plain)
        .listRowBackground(highlight ? Color.gray.opacity(0.2) : Color.clear)
    }

    struct FocusSelectionLabel: View {
        let focus: FocusItem
        let color: Color
        let proposedName: String

        var body: some View {
            HStack(spacing: 10) {
                Circle()
                    .fill(color)
                    .frame(width: 12, height: 12)
                VStack(alignment: .leading, spacing: 2) {
                    Text(focus.name)
                        .font(.body)
                    Text("Propuesto: \(proposedName)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

struct HourMarkerView: View {
    let label: String

    var body: some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.caption2)
                .foregroundColor(.blue.opacity(0.7))
            Rectangle()
                .fill(Color.secondary.opacity(0.2))
                .frame(height: 1)
        }
        .padding(.horizontal)
    }
}

struct FocusPriorityAdjustView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @Environment(\.dismiss) private var dismiss

    private var editableFocuses: [FocusItem] {
        viewModel.focuses.filter { !($0.isCompleted ?? false) }
    }

    private var groupedFocuses: [FocusPrioritySection] {
        let grouped = Dictionary(grouping: editableFocuses, by: { $0.proposedCategoryID })
        return grouped.map { key, focuses in
            let ordered = focuses.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
            if let categoryID = key,
               let category = viewModel.category(for: categoryID) {
                return FocusPrioritySection(id: categoryID.uuidString,
                                            title: category.name,
                                            color: category.color,
                                            focuses: ordered,
                                            isIndeterminate: false)
            } else {
                return FocusPrioritySection(id: "indeterminado",
                                            title: "Indeterminado",
                                            color: nil,
                                            focuses: ordered,
                                            isIndeterminate: true)
            }
        }
        .sorted { lhs, rhs in
            if lhs.isIndeterminate != rhs.isIndeterminate {
                return !lhs.isIndeterminate && rhs.isIndeterminate
            }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    var body: some View {
        List {
            if editableFocuses.isEmpty {
                ContentUnavailableView("No hay focuses pendientes",
                                       systemImage: "target",
                                       description: Text("Añade o reactiva focuses para ajustar prioridades."))
            } else {
                ForEach(groupedFocuses) { section in
                    Section {
                        ForEach(section.focuses) { focus in
                            FocusPriorityRow(focus: focus) { newPriority in
                                var updated = focus
                                updated.priority = newPriority
                                viewModel.updateFocus(updated)
                            }
                        }
                    } header: {
                        HStack(spacing: 8) {
                            if let color = section.color {
                                Circle()
                                    .fill(color)
                                    .frame(width: 10, height: 10)
                            } else {
                                Circle()
                                    .stroke(Color.secondary, lineWidth: 1)
                                    .frame(width: 10, height: 10)
                            }
                            Text(section.title)
                        }
                    } footer: {
                        if section.isIndeterminate {
                            Text("Focuses sin tipo propuesto.")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle("Prioridades")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Cerrar") {
                    dismiss()
                }
            }
        }
    }
}

private struct FocusPrioritySection: Identifiable {
    let id: String
    let title: String
    let color: Color?
    let focuses: [FocusItem]
    let isIndeterminate: Bool
}

private struct FocusPriorityRow: View {
    let focus: FocusItem
    var onPriorityChange: (Int) -> Void
    @State private var sliderValue: Double

    init(focus: FocusItem, onPriorityChange: @escaping (Int) -> Void) {
        self.focus = focus
        self.onPriorityChange = onPriorityChange
        _sliderValue = State(initialValue: Double(focus.priority))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(focus.name)
                    .font(.headline)
                Spacer()
                Text(priorityDescription)
                    .font(.caption)
                    .foregroundColor(.orange)
            }
            Slider(value: $sliderValue, in: 0...5, step: 1)
                .tint(.orange)
                .accessibilityLabel("Prioridad para \(focus.name)")
        }
        .contentShape(Rectangle())
        .padding(.vertical, 6)
        .onChange(of: sliderValue) { newValue in
            let clamped = Int(newValue.rounded())
            if clamped != focus.priority {
                onPriorityChange(clamped)
            }
        }
        .onChange(of: focus.priority) { newPriority in
            sliderValue = Double(newPriority)
        }
    }

    private var priorityDescription: String {
        if focus.priority <= 0 {
            return "Prioridad baja"
        }
        return String(repeating: "★", count: min(focus.priority, 5))
    }
}

struct FocusDiagnosticsView: View {
    @ObservedObject var viewModel: ScheduleViewModel
    @State private var exportedCSV: String = ""
    @State private var lastExportDate: Date?
    @State private var importedFocuses: [SupabaseFocusRow] = []
    @State private var importedCategoriesText: String = ""
    @State private var isImporting = false
    @State private var importError: String?
    @State private var importInfo: String?
    @State private var dataSource: FocusDataSource = .local
    private let remoteService = SupabaseFocusService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section("Origen de datos") {
                    Picker("Fuente", selection: $dataSource) {
                        ForEach(FocusDataSource.allCases) { source in
                            Text(source.label).tag(source)
                        }
                    }
                    .pickerStyle(.segmented)
                    Text(dataSource == .local ? "Usando focuses locales del dispositivo." : "Usando focuses sincronizados desde Supabase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Section("Herramientas de exportación") {
                    Button {
                        exportCurrentSource()
                    } label: {
                        Label("Export to CSV", systemImage: "arrow.down.doc")
                            .font(.headline)
                    }
                    .disabled(dataSource == .supabase && importedFocuses.isEmpty)
                    if let timestamp = lastExportDate {
                        Text("Generado: \(timestamp.formatted(date: .omitted, time: .standard))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(exportedCSV.isEmpty ? exportHint : exportedCSV)
                            .font(.system(.body, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(8)
                    }
                    .frame(minHeight: 220)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.secondarySystemBackground)))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.4))
                    )
                    .textSelection(.enabled)
                    .accessibilityLabel("Contenido CSV exportado")

                    if dataSource == .local {
                        Button {
                            exportCategories()
                        } label: {
                            Label("Export categories CSV", systemImage: "square.and.arrow.down.on.square")
                                .font(.subheadline)
                        }
                    }
                }
                Section("Formato esperado") {
                    Text("id, Descripcion, Tipo Asociado, Prioridad, Duracion Estimada, Trabajado")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if dataSource == .supabase {
                    Section("Importación Supabase") {
                        Button {
                            fetchFocusesFromSupabase()
                        } label: {
                            Label("Import from Supabase", systemImage: "arrow.up.doc")
                        }
                        .disabled(isImporting)
                        if isImporting {
                            ProgressView("Importando…")
                        }
                        if let error = importError {
                            Text(error)
                                .font(.caption)
                                .foregroundColor(.red)
                        }
                        if let info = importInfo {
                            Text(info)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if importedFocuses.isEmpty {
                            Text("Todavía no se han recibido datos.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            ScrollView(.horizontal) {
                                VStack(alignment: .leading, spacing: 8) {
                                    headerRow
                                    Divider()
                                    ForEach(importedFocuses) { row in
                                        HStack {
                                            Text(row.descripcion ?? "-")
                                            Text(row.tipoAsociado ?? "-")
                                            Text("\(row.prioridad ?? 0)")
                                            Text("\(row.duracionEstimanda ?? 0)")
                                            Text("\(row.trabajado ?? 0)")
                                        }
                                        .font(.caption)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(minHeight: 180)
                        }

                        Button {
                            fetchCategoriesFromSupabase()
                        } label: {
                            Label("Import categories", systemImage: "folder.badge.plus")
                        }
                        if !importedCategoriesText.isEmpty {
                            ScrollView {
                                Text(importedCategoriesText)
                                    .font(.system(.caption, design: .monospaced))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(8)
                            }
                            .frame(minHeight: 120)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color(UIColor.secondarySystemBackground)))
                            .overlay(
                                RoundedRectangle(cornerRadius: 8)
                                    .stroke(Color.secondary.opacity(0.4))
                            )
                            .textSelection(.enabled)
                        }
                        if let error = importError {
                            Text("Supabase: \(error)")
                                .font(.caption2)
                                .foregroundColor(.red)
                        }
                    }
                }
            }
            .navigationTitle("Ayuda / CSV")
            .onAppear {
                if exportedCSV.isEmpty {
                    exportedCSV = generateCSV(from: csvRows(for: .local))
                }
            }
            .onChange(of: dataSource) { _ in
                exportedCSV = ""
                importError = nil
                if dataSource == .local {
                    importedFocuses = []
                }
            }
        }
    }

    private func csvRows(for source: FocusDataSource) -> [FocusCSVRowData] {
        switch source {
        case .local:
            return viewModel.focuses.map { focus in
                let typeName = focus.proposedCategoryID.flatMap { viewModel.category(for: $0)?.name } ?? "Indeterminado"
                return FocusCSVRowData(id: numericID(for: focus),
                                       description: focus.name,
                                       type: typeName,
                                       priority: focus.priority,
                                       estimated: focus.expectedMinutes ?? 0,
                                       worked: focus.actualMinutes ?? 0)
            }
        case .supabase:
            return importedFocuses.map { row in
                FocusCSVRowData(id: String(row.id),
                                description: row.descripcion ?? "Focus remoto",
                                type: row.tipoAsociado ?? "Indeterminado",
                                priority: row.prioridad ?? 0,
                                estimated: row.duracionEstimanda ?? 0,
                                worked: row.trabajado ?? 0)
            }
        }
    }

    private func generateCSV(from rows: [FocusCSVRowData]) -> String {
        var lines: [String] = []
        lines.append("id,Descripcion,Tipo Asociado,Prioridad,Duracion Estimada,Trabajado")
        for row in rows {
            let line = [
                csvField(row.id),
                csvField(row.description),
                csvField(row.type),
                "\(row.priority)",
                "\(row.estimated)",
                "\(row.worked)"
            ].joined(separator: ",")
            lines.append(line)
        }
        return lines.joined(separator: "\n")
    }

    private func csvField(_ value: String) -> String {
        let sanitized = value.replacingOccurrences(of: "\"", with: "\"\"")
        if sanitized.contains(",") || sanitized.contains("\"") || sanitized.contains("\n") {
            return "\"\(sanitized)\""
        } else {
            return sanitized
        }
    }

    private func numericID(for focus: FocusItem) -> String {
        let hex = focus.id.uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = String(hex.prefix(16))
        let value = UInt64(prefix, radix: 16) ?? 0
        let signed = Int64(value % UInt64(Int64.max))
        return String(signed)
    }

    private func exportCurrentSource() {
        let rows = csvRows(for: dataSource)
        guard !rows.isEmpty else {
            exportedCSV = ""
            return
        }
        let csv = generateCSV(from: rows)
        exportedCSV = csv
        lastExportDate = Date()
        UIPasteboard.general.string = csv
    }

    private func exportCategories() {
        let header = "id,name,colorHex"
        let lines = viewModel.categories.map { category in
            "\(category.id.uuidString),\(category.name),\(category.colorHex)"
        }
        let csv = ([header] + lines).joined(separator: "\n")
        exportedCSV = csv
        lastExportDate = Date()
        UIPasteboard.general.string = csv
    }

    private var exportHint: String {
        switch dataSource {
        case .local:
            return "Pulsa \"Export to CSV\" para exportar los focuses locales."
        case .supabase:
            return importedFocuses.isEmpty ? "Importa los focuses de Supabase antes de exportar." : "Pulsa \"Export to CSV\" para exportar los focuses de Supabase."
        }
    }

    private func fetchFocusesFromSupabase() {
        isImporting = true
        importError = nil
        importInfo = nil
        print("[SupabaseImport] Iniciando importación...")
        Task {
            do {
                let rows = try await remoteService.fetchRemoteRows()
                print("[SupabaseImport] Recibidas \(rows.count) filas.")
                await MainActor.run {
                    importedFocuses = rows
                    isImporting = false
                    importInfo = "Importados \(rows.count) focuses."
                }
            } catch {
                print("[SupabaseImport] Error: \(error)")
                await MainActor.run {
                    importError = error.localizedDescription
                    importInfo = nil
                    isImporting = false
                }
            }
        }
    }

    private func fetchCategoriesFromSupabase() {
        isImporting = true
        importError = nil
        importInfo = nil
        Task {
            do {
                print("[SupabaseCategories] Iniciando importación...")
                let rows = try await SupabaseTaskCategoryService.shared.importCategories()
                print("[SupabaseCategories] Recibidas \(rows.count) categorías")
                await MainActor.run {
                    viewModel.categories = rows
                    importedCategoriesText = rows
                        .map { "\($0.id.uuidString)  |  \($0.name)  |  \($0.colorHex)" }
                        .joined(separator: "\n")
                    isImporting = false
                    importInfo = "Importadas \(rows.count) categorías."
                }
            } catch {
                await MainActor.run {
                    importError = error.localizedDescription
                    importInfo = nil
                    isImporting = false
                }
            }
        }
    }

    private var headerRow: some View {
        HStack {
            Text("Descripcion").bold()
            Text("Tipo Asociado").bold()
            Text("Prioridad").bold()
            Text("Duracion Estim.").bold()
            Text("Trabajado").bold()
        }
        .font(.caption)
    }
}
