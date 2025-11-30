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

    private let blockHeight: CGFloat = 56
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
    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        let blocks = viewModel.timelineBlocks()
                        ForEach(blocks) { block in
                            let isHourStart = viewModel.isHourBoundaryBlock(index: block.index)
                            if isHourStart {
                                HourMarkerView(label: hourRangeLabel(for: block.index))
                                    .padding(.bottom, 2)
                            }
                            HStack(alignment: .top, spacing: 12) {
                                Text(viewModel.label(for: block.index))
                                    .font(.caption)
                                    .frame(width: 60, alignment: .trailing)
                                    .padding(.top, 8)

                                blockContent(for: block)
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
                    scrollToCurrentHour(animated: false)
                }
                .onChange(of: timelineRefreshID) { _ in
                    scrollToCurrentHour(animated: false)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                scrollToCurrentHour(animated: false)
            }
            .onReceive(liveTimer) { date in
                liveTime = date
                handlePauseProgress(at: date)
            }
            .navigationTitle("Agenda diaria")
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
                    timelineRefreshID = UUID()
                    scrollToCurrentHour(animated: false)
                }
                Button("Cancelar", role: .cancel) { }
            } message: {
                Text("Se guardará el día actual y se iniciará uno nuevo.")
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button {
                        scrollToCurrentHour(animated: true)
                    } label: {
                        Image(systemName: "play.fill")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        showingEndDayConfirmation = true
                    } label: {
                        Image(systemName: "flag.checkered")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        isClearingAllTasks = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .disabled(viewModel.tasks.isEmpty)
                }
            }
        }
    }

    private var currentAnchorIndex: Int {
        let diff = Date().timeIntervalSince(viewModel.dayStart)
        let blockSeconds = Double(ScheduleViewModel.blockMinutes) * 60
        if diff <= 0 {
            return 0
        }
        return min(viewModel.totalBlocks - 1, Int(diff / blockSeconds))
    }

    @ViewBuilder
    private func blockContent(for block: TimelineBlock) -> some View {
        let height = blockHeight * CGFloat(block.span)
        let liveLineOffset = liveIndicatorOffset(for: block)

        ZStack(alignment: .topLeading) {
            if let task = block.task, let category = viewModel.category(for: task.categoryID) {
                let displayDuration = (resizingTaskID == task.id ? resizingPreviewDuration : task.duration)
                let taskHeight = blockHeight * CGFloat(displayDuration)
                let isDragging = draggingTaskID == task.id
                let isMoveMode = moveModeTaskID == task.id
                let isSelected = selectedTaskID == task.id
            let isCompleted = task.isCompleted
            let liveStatus = liveStatusInfo(for: task)
            let focusLabel = focusDisplayLabel(for: task)
            let isFocusIndeterminate = task.isFocusIndeterminate

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
                            .contextMenu {
                                Button {
                                    finishTaskNow(task)
                                } label: {
                                    Label("Terminar Box", systemImage: "flag.checkered")
                                }
                            }
                            .simultaneousGesture(resizeGesture(for: task))
                            .onTapGesture {
                                selectedTaskID = task.id
                            }
                            .onTapGesture(count: 2) {
                                editingTask = task
                                selectedTaskID = task.id
                            }

                        HStack(spacing: 6) {
                            Button {
                                viewModel.toggleCompletion(for: task)
                            } label: {
                                Image(systemName: task.isCompleted ? "checkmark.circle.fill" : "circle")
                                    .font(.headline)
                                    .foregroundColor(task.isCompleted ? .green : .gray)
                                    .padding(6)
                            }
                            .buttonStyle(.plain)

                            Button {
                                toggleFocusState(for: task)
                            } label: {
                                let color = focusIndicatorColor(for: task)
                                Image(systemName: "target")
                                    .font(.headline)
                                    .foregroundColor(color)
                                    .padding(6)
                                    .overlay(
                                        Circle()
                                            .stroke(color.opacity(0.6), lineWidth: 1)
                                    )
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
            let hourNumber = viewModel.hourNumber(for: block.index)
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
                        .foregroundColor(liveLineColor)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color(.systemBackground).opacity(0.85))
                        .clipShape(Capsule())
                    Rectangle()
                        .fill(liveLineColor)
                        .frame(height: 2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .offset(x: -48)
                .offset(y: liveLineOffset - 1)
            }
        }
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

    private func liveStatusInfo(for task: TaskItem) -> LiveStatusInfo? {
        let startDate = viewModel.date(for: task.startIndex)
        let endDate = viewModel.date(for: task.startIndex + task.duration)
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

    private func liveIndicatorOffset(for block: TimelineBlock) -> CGFloat? {
        let blockStart = block.startDate
        let blockEnd = viewModel.date(for: block.index + block.span)
        guard liveTime >= blockStart, liveTime < blockEnd else { return nil }
        let total = blockEnd.timeIntervalSince(blockStart)
        guard total > 0 else { return nil }
        let elapsed = liveTime.timeIntervalSince(blockStart)
        let fraction = max(0, min(1, elapsed / total))
        return CGFloat(fraction) * blockHeight * CGFloat(block.span)
    }

    private var liveLineColor: Color {
        Color(red: 0.15, green: 0.7, blue: 0.45)
    }

    private var liveIndicatorLabel: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: liveTime)
    }

    private func hourRangeLabel(for index: Int) -> String {
        let startDate = viewModel.date(for: index)
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

    private func scrollToCurrentHour(animated: Bool) {
        guard let proxy = scrollProxy else { return }
        let target = currentAnchorIndex
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
        let blocks = viewModel.timelineBlocks()
        return blocks.first { block in
            guard let task = block.task else { return false }
            let startDate = viewModel.date(for: block.index)
            let endDate = viewModel.date(for: block.index + task.duration)
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
                ForEach($viewModel.categories) { $category in
                    HStack(spacing: 12) {
                        TextField("Nombre", text: $category.name)
                            .font(.headline)
                        Spacer()
                        ColorPicker("",
                                    selection: Binding<Color>(
                                        get: { Color(hex: category.colorHex) },
                                        set: { newColor in
                                            category.colorHex = newColor.hexString
                                        })
                        )
                        .labelsHidden()
                        .frame(width: 34, height: 34)
                        .clipShape(Circle())
                    }

                    .padding(.vertical, 6)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        let category = viewModel.categories[index]
                        viewModel.deleteCategory(category)
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
                    Button {
                        showingPriorityAdjuster = true
                    } label: {
                        Label("Prioridades", systemImage: "slider.horizontal.3")
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
                                TextField("Horas", text: $newFocusHours)
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
                                TextField("Horas", text: $focusEditHours)
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
                                updated.expectedMinutes = editEstimationIndeterminate ? nil : (Int(focusEditHours) ?? 0) * 60
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
                    focusEditHours = focus.expectedMinutes.map { String($0 / 60) } ?? ""
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
                await viewModel.refreshFocusesFromRemote()
            }
        }
    }

    private var canSaveFocus: Bool {
        let trimmed = newFocusName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if estimationIndeterminate { return true }
        guard let hours = Int(newFocusHours), hours > 0 else { return false }
        return true
    }

    private func saveFocus() {
        let trimmed = newFocusName.trimmingCharacters(in: .whitespacesAndNewlines)
        let minutes = estimationIndeterminate ? nil : (Int(newFocusHours) ?? 0) * 60
        viewModel.addFocus(name: trimmed,
                           expectedMinutes: minutes,
                           proposedCategoryID: newFocusProposedCategoryID,
                           priority: newFocusPriority)
        resetFocusForm()
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
        guard let hours = Int(focusEditHours), hours > 0 else { return false }
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
    @State private var isImporting = false
    @State private var importError: String?
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
                    }
                }
            }
            .navigationTitle("Ayuda / CSV")
            .onAppear {
                configureRemoteResolvers()
                if exportedCSV.isEmpty {
                    exportedCSV = generateCSV(from: csvRows(for: .local))
                }
            }
            .onChange(of: viewModel.categories) { _ in
                configureRemoteResolvers()
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

    private func configureRemoteResolvers() {
        remoteService.setCategoryResolver { name in
            viewModel.categoryID(named: name)
        }
        remoteService.setCategoryNameResolver { categoryID in
            viewModel.category(for: categoryID)?.name
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
        print("[SupabaseImport] Iniciando importación...")
        Task {
            do {
                let rows = try await remoteService.fetchRemoteRows()
                print("[SupabaseImport] Recibidas \(rows.count) filas.")
                await MainActor.run {
                    importedFocuses = rows
                    isImporting = false
                }
            } catch {
                print("[SupabaseImport] Error: \(error)")
                await MainActor.run {
                    importError = error.localizedDescription
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
