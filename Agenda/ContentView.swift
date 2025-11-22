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
    @State private var resizingTaskID: UUID?
    @State private var resizingPreviewDuration: Int = 1
    @State private var scheduleError: String?
    @State private var taskBeingMoved: TaskItem?
    @State private var isClearingAllTasks = false

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
                    }
                }
                Button("Cancelar", role: .cancel) {
                    taskPendingDeletion = nil
                }
            } message: {
                Text("¿Quieres borrar esta tarea?")
            }
            .sheet(item: $taskBeingMoved) { task in
                MoveTaskSheet(task: task,
                              options: viewModel.availableStartIndices(for: task),
                              labelProvider: viewModel.label(for:),
                              onConfirm: { index in
                                  viewModel.move(task: task, to: index)
                                  taskBeingMoved = nil
                              })
            }
            .alert("¿Borrar todas las tareas?", isPresented: $isClearingAllTasks) {
                Button("Eliminar todas", role: .destructive) {
                    viewModel.clearAllTasks()
                }
                Button("Cancelar", role: .cancel) { }
            }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
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
            HStack(spacing: 10) {
                Button {
                    taskBeingMoved = task
                } label: {
                    VStack(spacing: 6) {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.title3)
                        Text("Mover")
                            .font(.caption2)
                    }
                    .frame(width: 68, height: taskHeight)
                    .background(Color.blue.opacity(0.15))
                    .foregroundColor(.blue)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)

                TaskCardView(category: category,
                             durationUnits: displayDuration,
                             startDate: startDate,
                             endDate: endDate,
                             height: taskHeight,
                             isResizing: resizingTaskID == task.id)
                .overlay(alignment: .topTrailing) {
                    Button {
                        taskPendingDeletion = task
                    } label: {
                        Image(systemName: "trash")
                            .padding(8)
                            .background(Color.red.opacity(0.15))
                            .clipShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .padding(8)
                }
                .highPriorityGesture(resizeGesture(for: task))
                .highPriorityGesture(TapGesture(count: 3).onEnded {
                    editingTask = task
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

    private func resizeGesture(for task: TaskItem) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture())
            .onChanged { value in
                switch value {
                case let .first(success):
                    guard success else { return }
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
    let isResizing: Bool

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
                Text("Pulsa tres veces para cambiar el tipo.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("Usa el botón azul de la izquierda para moverlo. Mantén pulsado un poco más para ajustar duración. Usa el icono de papelera para borrar.")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(category.color.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(category.color, lineWidth: 2)
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(style: StrokeStyle(lineWidth: isResizing ? 2 : 0, dash: [6]))
                        .foregroundColor(category.color.opacity(isResizing ? 0.8 : 0))
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

struct MoveTaskSheet: View {
    let task: TaskItem
    let options: [Int]
    let labelProvider: (Int) -> String
    var onConfirm: (Int) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Int

    private var sortedOptions: [Int] {
        options.sorted()
    }

    init(task: TaskItem,
         options: [Int],
         labelProvider: @escaping (Int) -> String,
         onConfirm: @escaping (Int) -> Void) {
        self.task = task
        self.options = options
        self.labelProvider = labelProvider
        self.onConfirm = onConfirm
        _selection = State(initialValue: task.startIndex)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Nueva hora") {
                    Picker("Inicio", selection: $selection) {
                        ForEach(sortedOptions, id: \.self) { index in
                            Text(labelProvider(index))
                                .tag(index)
                        }
                    }
                }
            }
            .navigationTitle("Mover tarea")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Guardar") {
                        onConfirm(selection)
                        dismiss()
                    }
                    .disabled(!sortedOptions.contains(selection))
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
