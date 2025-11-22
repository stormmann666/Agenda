//
//  ContentView.swift
//  Agenda
//
//  Created by Antonio Muñoz on 22/11/25.
//

import SwiftUI

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
                .simultaneousGesture(moveScrollGuardGesture)
                .scrollDisabled(moveModeTaskID != nil || resizingTaskID != nil || draggingTaskID != nil)
                .onAppear {
                    proxy.scrollTo(currentAnchorIndex, anchor: .top)
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
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Borrar todo") {
                        isClearingAllTasks = true
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
            let startDate = block.startDate
            let endDate = viewModel.date(for: block.index + displayDuration)
            let taskHeight = blockHeight * CGFloat(displayDuration)
            let isDragging = draggingTaskID == task.id
            let isMoveMode = moveModeTaskID == task.id
            let isSelected = selectedTaskID == task.id

            HStack(spacing: 8) {
                ZStack(alignment: .topTrailing) {
                    TaskCardView(category: category,
                                 durationUnits: displayDuration,
                                 startDate: startDate,
                                 endDate: endDate,
                                 height: taskHeight,
                                 dragOffset: isDragging ? dragOffset : 0,
                                 isDragging: isDragging,
                                 isResizing: resizingTaskID == task.id,
                                 isMoveModeActive: isMoveMode,
                                 isSelected: isSelected)
                        .contentShape(Rectangle())
                        .simultaneousGesture(resizeGesture(for: task))
                        .onTapGesture {
                            selectedTaskID = task.id
                        }
                        .onTapGesture(count: 2) {
                            editingTask = task
                            selectedTaskID = task.id
                        }

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
    let durationUnits: Int
    let startDate: Date
    let endDate: Date
    let height: CGFloat
    let dragOffset: CGFloat
    let isDragging: Bool
    let isResizing: Bool
    let isMoveModeActive: Bool
    let isSelected: Bool

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(category.name)
                .font(.headline)
                .foregroundColor(category.color)

            Text("\(Self.timeFormatter.string(from: startDate)) - \(Self.timeFormatter.string(from: endDate))")
                .font(.subheadline)

            Text("Duración: \(durationUnits * ScheduleViewModel.blockMinutes) min")
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            VStack(alignment: .leading, spacing: 4) {
                Text("Toca una vez para seleccionarlo.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Pulsa dos veces para cambiar el tipo.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Pulsa el botón azul y arrastra para moverlo. Mantén pulsado un poco más para ajustar duración. Usa el icono de papelera para borrar.")
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

    var body: some View {
        NavigationStack {
            List {
                ForEach($viewModel.categories) { $category in
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Nombre", text: $category.name)
                            .font(.headline)

                        ColorPicker("Color", selection: Binding<Color>(
                            get: { Color(hex: category.colorHex) },
                            set: { newColor in
                                category.colorHex = newColor.hexString
                            }
                        ))
                    }
                    .padding(.vertical, 4)
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
                        viewModel.addCategory()
                    } label: {
                        Label("Añadir", systemImage: "plus")
                    }
                }
            }
        }
    }
}

#Preview {
    ContentView()
}
