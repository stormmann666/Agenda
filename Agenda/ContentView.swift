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
    @State private var liveModeEnabled = false
    @State private var liveTime = Date()
    private let liveTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(viewModel.timelineBlocks()) { block in
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
                }
                .onAppear {
                    proxy.scrollTo(currentAnchorIndex, anchor: .top)
                }
            }
            .onReceive(liveTimer) { date in
                if liveModeEnabled {
                    liveTime = date
                }
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
                CategoryPickerSheet(title: "Editar tarea",
                                    categories: viewModel.categories,
                                    selectedID: task.categoryID) { category in
                    viewModel.setCategory(category, for: task)
                }
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
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        liveModeEnabled.toggle()
                        if liveModeEnabled {
                            liveTime = Date()
                        }
                    } label: {
                        Image(systemName: liveModeEnabled ? "pause.circle" : "play.circle")
                    }

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
        if let task = block.task, let category = viewModel.category(for: task.categoryID) {
            let displayDuration = (resizingTaskID == task.id ? resizingPreviewDuration : task.duration)
            let taskHeight = blockHeight * CGFloat(displayDuration)
            let isDragging = draggingTaskID == task.id
            let isMoveMode = moveModeTaskID == task.id
            let isSelected = selectedTaskID == task.id
            let isCompleted = task.isCompleted
            let liveStatus = liveModeEnabled ? liveStatusInfo(for: task) : nil

            HStack(spacing: 8) {
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
                                 liveStatus: liveStatus)
                        .contentShape(Rectangle())
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
            EmptySlot(height: height)
                .onTapGesture {
                    selectedBlockIndex = block.index
                    showCategoryPicker = true
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
        viewModel.move(task: task, by: delta)
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
                    let maxDuration = viewModel.totalBlocks - task.startIndex
                    let newDuration = min(maxDuration, max(1, task.duration + delta))
                    viewModel.resize(task: task, newDuration: newDuration)
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

            Text("Duración: \(durationMinutes) min")
                .font(.caption)
                .foregroundColor(.secondary)
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
        .overlay {
            if let liveStatus {
                LiveStatusBar(status: liveStatus)
            }
        }
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
        GeometryReader { geometry in
            VStack {
                Spacer()
                VStack(spacing: 6) {
                    Text("\(status.remainingMinutes) min restantes")
                        .font(.caption)
                        .bold()
                        .foregroundColor(.primary)

                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.primary.opacity(0.15))
                        Capsule()
                            .fill(Color.blue)
                            .frame(width: max(0, geometry.size.width * 0.8 * statusFraction))
                    }
                    .frame(height: 6)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .frame(maxWidth: min(geometry.size.width * 0.8, 240))
                .background(.ultraThinMaterial)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(radius: 4)
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
        .allowsHitTesting(false)
    }

    private var statusFraction: CGFloat {
        CGFloat(max(0, min(1, status.fraction)))
    }
}

struct EmptySlot: View {
    let height: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 12)
            .stroke(style: StrokeStyle(lineWidth: 1, dash: [6]))
            .frame(height: height)
            .foregroundColor(.secondary.opacity(0.3))
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
