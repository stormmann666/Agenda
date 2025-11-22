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
    private let swipeActivationDistance: CGFloat = 14
    private let swipeDeleteDistance: CGFloat = 90
    private let swipeMaxOffset: CGFloat = 150
    @State private var selectedBlockIndex: Int?
    @State private var showCategoryPicker = false
    @State private var editingTask: TaskItem?
    @State private var taskPendingDeletion: TaskItem?
    @State private var draggingTaskID: UUID?
    @State private var dragOffset: CGFloat = 0
    @State private var resizingTaskID: UUID?
    @State private var resizingPreviewDuration: Int = 1
    @State private var scheduleError: String?
    @State private var swipeTaskID: UUID?
    @State private var swipeOffset: CGFloat = 0

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
            let isDragging = draggingTaskID == task.id
            let isSwiping = swipeTaskID == task.id
            let taskHeight = blockHeight * CGFloat(displayDuration)
            ZStack(alignment: .leading) {
                if isSwiping && swipeOffset > 0 {
                    RoundedRectangle(cornerRadius: 12)
                        .fill(Color.red.opacity(0.15))
                        .frame(height: taskHeight)
                        .overlay(alignment: .leading) {
                            Label("Eliminar", systemImage: "trash")
                                .font(.caption)
                                .foregroundColor(.red)
                                .padding(.horizontal)
                        }
                }

                TaskCardView(category: category,
                             durationUnits: displayDuration,
                             startDate: startDate,
                             endDate: endDate,
                             height: taskHeight,
                             dragOffset: isDragging ? dragOffset : 0,
                             horizontalOffset: isSwiping ? swipeOffset : 0,
                             isDragging: isDragging,
                             isResizing: resizingTaskID == task.id)
            }
            .highPriorityGesture(resizeGesture(for: task))
            .simultaneousGesture(swipeToDeleteGesture(for: task))
            .highPriorityGesture(TapGesture(count: 3).onEnded {
                editingTask = task
            })
            .overlay(
                DoubleTapDragCapture(isEnabled: resizingTaskID == nil && swipeTaskID == nil) { state, offset in
                    handleDoubleTapDrag(state: state, offset: offset, for: task)
                }
            )
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

    private func handleDoubleTapDrag(state: DoubleTapDragCapture.State, offset: CGFloat, for task: TaskItem) {
        guard resizingTaskID == nil,
              swipeTaskID == nil else {
            resetDragState()
            return
        }
        switch state {
        case .began, .changed:
            draggingTaskID = task.id
            dragOffset = offset
        case .ended:
            guard draggingTaskID == task.id else {
                resetDragState()
                return
            }
            let delta = Int(round(offset / blockHeight))
            viewModel.move(task: task, by: delta)
            resetDragState()
        case .cancelled:
            resetDragState()
        }
    }

    private func resetDragState() {
        draggingTaskID = nil
        dragOffset = 0
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

    private func swipeToDeleteGesture(for task: TaskItem) -> some Gesture {
        DragGesture()
            .onChanged { value in
                guard resizingTaskID == nil else { return }
                guard draggingTaskID == nil else { return }
                let horizontal = value.translation.width
                let vertical = value.translation.height
                if swipeTaskID != task.id {
                    guard horizontal > 0,
                          abs(horizontal) > abs(vertical),
                          horizontal > swipeActivationDistance else { return }
                    swipeTaskID = task.id
                }
                guard swipeTaskID == task.id else { return }
                if horizontal <= 0 {
                    withAnimation(.spring()) {
                        swipeTaskID = nil
                        swipeOffset = 0
                    }
                    return
                }
                swipeOffset = min(swipeMaxOffset, max(0, horizontal))
            }
            .onEnded { value in
                guard swipeTaskID == task.id else { return }
                let horizontal = max(value.translation.width, swipeOffset)
                if horizontal > swipeDeleteDistance {
                    taskPendingDeletion = task
                }
                withAnimation(.spring()) {
                    swipeTaskID = nil
                    swipeOffset = 0
                }
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
    let horizontalOffset: CGFloat
    let isDragging: Bool
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
                Text("Haz doble toque y arrastra para moverlo. Mantén pulsado un poco más para ajustar duración. Desliza a la derecha para borrar.")
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
        .offset(x: horizontalOffset, y: isDragging ? dragOffset : 0)
    }
}

struct DoubleTapDragCapture: UIViewRepresentable {
    enum State {
        case began
        case changed
        case ended
        case cancelled
    }

    var isEnabled: Bool
    var handler: (State, CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(handler: handler)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView(frame: .zero)
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = true
        context.coordinator.attach(to: view)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isEnabled = isEnabled
        context.coordinator.handler = handler
    }

    final class Coordinator: NSObject {
        var handler: (State, CGFloat) -> Void
        var isEnabled: Bool = true
        private weak var view: UIView?
        private var startLocation: CGPoint?

        init(handler: @escaping (State, CGFloat) -> Void) {
            self.handler = handler
        }

        func attach(to view: UIView) {
            self.view = view
            let gesture = UILongPressGestureRecognizer(target: self, action: #selector(handleGesture(_:)))
            gesture.minimumPressDuration = 0.05
            gesture.numberOfTapsRequired = 2
            gesture.allowableMovement = .greatestFiniteMagnitude
            gesture.cancelsTouchesInView = false
            view.addGestureRecognizer(gesture)
        }

        @objc private func handleGesture(_ gesture: UILongPressGestureRecognizer) {
            guard isEnabled, let view else {
                handler(.cancelled, 0)
                startLocation = nil
                return
            }

            let current = gesture.location(in: view)

            switch gesture.state {
            case .began:
                startLocation = current
                handler(.began, 0)
            case .changed:
                guard let start = startLocation else { return }
                handler(.changed, current.y - start.y)
            case .ended:
                if let start = startLocation {
                    handler(.ended, current.y - start.y)
                }
                startLocation = nil
            case .cancelled, .failed:
                startLocation = nil
                handler(.cancelled, 0)
            default:
                break
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
