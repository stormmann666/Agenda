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
            TaskCardView(category: category,
                         durationUnits: displayDuration,
                         startDate: startDate,
                         endDate: endDate,
                         height: blockHeight * CGFloat(displayDuration),
                         dragOffset: draggingTaskID == task.id ? dragOffset : 0,
                         isDragging: draggingTaskID == task.id) {
                taskPendingDeletion = task
            }
            .gesture(dragGesture(for: task))
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                editingTask = task
            })
            .overlay(alignment: .bottom) {
                ResizeHandle(color: category.color)
                    .gesture(resizeGesture(for: task))
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

    private func dragGesture(for task: TaskItem) -> some Gesture {
        DragGesture()
            .onChanged { value in
                draggingTaskID = task.id
                dragOffset = value.translation.height
            }
            .onEnded { value in
                draggingTaskID = nil
                let delta = Int(round(value.translation.height / blockHeight))
                viewModel.move(task: task, by: delta)
                dragOffset = 0
            }
    }

    private func resizeGesture(for task: TaskItem) -> some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                resizingTaskID = task.id
                let delta = Int(round(value.translation.height / blockHeight))
                let maxDuration = viewModel.totalBlocks - task.startIndex
                resizingPreviewDuration = min(maxDuration, max(1, task.duration + delta))
            }
            .onEnded { value in
                let delta = Int(round(value.translation.height / blockHeight))
                let maxDuration = viewModel.totalBlocks - task.startIndex
                let newDuration = min(maxDuration, max(1, task.duration + delta))
                viewModel.resize(task: task, newDuration: newDuration)
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
    var onDelete: () -> Void

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

            HStack {
                Image(systemName: "arrow.up.and.down")
                Text("Arrastra para mover")
                    .font(.caption2)
            }
            .foregroundColor(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: height)
        .background(category.color.opacity(0.15))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(category.color, lineWidth: 2)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .offset(y: isDragging ? dragOffset : 0)
        .onLongPressGesture {
            onDelete()
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

struct ResizeHandle: View {
    let color: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(color)
            .frame(height: 8)
            .padding(.horizontal, 24)
            .padding(.bottom, 6)
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
