import XCTest
@testable import Agenda

final class ScheduleViewModelTests: XCTestCase {
    
    // MARK: - Helpers
    
    private func makeViewModel(tasks: [TaskItem]) -> (ScheduleViewModel, () -> Void) {
        let suiteName = "AgendaTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            fatalError("Unable to create suite \(suiteName)")
        }
        defaults.removePersistentDomain(forName: suiteName)
        let viewModel = ScheduleViewModel(defaults: defaults)
        viewModel.categories = []
        viewModel.tasks = tasks
        viewModel.focuses = []
        let teardown = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (viewModel, teardown)
    }
    
    private func makeTask(start: Int, duration: Int) -> TaskItem {
        TaskItem(categoryID: UUID(), startIndex: start, duration: duration)
    }
    
    // MARK: - Tests

    func testProposeFocusScheduleUsesPriorityAndSplitsAroundExistingTasks() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let blocker = TaskItem(categoryID: category.id, startIndex: 6, duration: 3)
        let (viewModel, cleanup) = makeViewModel(tasks: [blocker])
        defer { cleanup() }
        viewModel.categories = [category]
        viewModel.focuses = [
            FocusItem(name: "Secundario", expectedMinutes: 15, proposedCategoryID: category.id, priority: 2),
            FocusItem(name: "Prioritario", expectedMinutes: 45, proposedCategoryID: category.id, priority: 5)
        ]

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0))

        XCTAssertEqual(proposals.map(\.startIndex), [0, 9, 12])
        XCTAssertEqual(proposals.map(\.duration), [6, 3, 3])
        XCTAssertEqual(proposals.first?.focusID, viewModel.focuses[1].id)
        XCTAssertEqual(proposals.last?.focusID, viewModel.focuses[0].id)
    }

    func testApplyFocusScheduleCreatesLinkedBoxesAndRejectsStalePlan() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let focus = FocusItem(name: "Planificable", expectedMinutes: 30, proposedCategoryID: category.id, priority: 5)
        viewModel.focuses = [focus]
        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0))

        XCTAssertTrue(viewModel.applyFocusSchedule(proposals))
        XCTAssertEqual(viewModel.tasks.count, 1)
        XCTAssertEqual(viewModel.tasks.first?.duration, 6)
        XCTAssertEqual(viewModel.tasks.first?.focusID, focus.id)
        XCTAssertEqual(viewModel.focus(with: focus.id)?.taskIDs, [viewModel.tasks[0].id])
        XCTAssertFalse(viewModel.applyFocusSchedule(proposals), "A stale preview must not overlap the boxes it already created")
    }

    func testProposeFocusScheduleDoesNotDuplicateAlreadyScheduledTime() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let focus = FocusItem(name: "En curso", expectedMinutes: 30, proposedCategoryID: category.id, priority: 5)
        let scheduled = TaskItem(categoryID: category.id, startIndex: 0, duration: 6, focusID: focus.id)
        let (viewModel, cleanup) = makeViewModel(tasks: [scheduled])
        defer { cleanup() }
        viewModel.categories = [category]
        viewModel.focuses = [focus]

        XCTAssertTrue(viewModel.proposeFocusSchedule(from: viewModel.date(for: 0)).isEmpty)
    }

    func testPlannerHonorsPriorityAvoidanceAndSessionLength() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let prioritized = FocusItem(name: "Prioritario", expectedMinutes: 60, proposedCategoryID: category.id, priority: 3)
        let unprioritized = FocusItem(name: "Sin prioridad", expectedMinutes: 60, proposedCategoryID: category.id, priority: 0)
        viewModel.focuses = [unprioritized, prioritized]
        let avoidedRange = viewModel.date(for: 6)..<viewModel.date(for: 12)

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0),
                                                       maximumSessionMinutes: 15,
                                                       avoiding: avoidedRange)

        XCTAssertTrue(proposals.allSatisfy { $0.focusID == prioritized.id })
        XCTAssertTrue(proposals.allSatisfy { $0.duration <= 3 })
        XCTAssertFalse(proposals.contains { $0.startIndex < 12 && $0.startIndex + $0.duration > 6 })
    }

    /*
     func testAdjustTaskDurationClampsWithinBounds() {
     let initialTask = makeTask(start: 0, duration: 4)
     let (viewModel, cleanup) = makeViewModel(tasks: [initialTask])
     defer { cleanup() }
     
     viewModel.adjustTaskDuration(for: initialTask, by: 2)
     XCTAssertEqual(viewModel.task(with: initialTask.id)?.duration, 6, "Task should extend when there is space")
     
     viewModel.adjustTaskDuration(for: initialTask, by: -10)
     XCTAssertEqual(viewModel.task(with: initialTask.id)?.duration, 1, "Duration never drops below one block")
     
     let nearEndTask = makeTask(start: viewModel.totalBlocks - 2, duration: 2)
     viewModel.tasks.append(nearEndTask)
     viewModel.adjustTaskDuration(for: nearEndTask, by: 5)
     XCTAssertEqual(viewModel.task(with: nearEndTask.id)?.duration, 2, "Task cannot extend past end of day")
     }
     
     func testAdjustTaskPositionMovesOrShiftsGroup() {
     let leading = makeTask(start: 0, duration: 2)
     let trailing = makeTask(start: 2, duration: 2)
     let blocking = makeTask(start: 4, duration: 2)
     let (viewModel, cleanup) = makeViewModel(tasks: [leading, trailing, blocking])
     defer { cleanup() }
     
     // Move into free space (the helper should shift trailing tasks because the destination is occupied)
     viewModel.adjustTaskPosition(for: trailing, by: 2)
     XCTAssertEqual(viewModel.task(with: trailing.id)?.startIndex, 4, "Trailing task should move into empty space")
     
     // Force shift when space is occupied
     viewModel.adjustTaskPosition(for: leading, by: 3)
     let updatedLeading = viewModel.task(with: leading.id)
     let updatedTrailing = viewModel.task(with: trailing.id)
     let updatedBlocking = viewModel.task(with: blocking.id)
     
     XCTAssertEqual(updatedLeading?.startIndex, 3, "Leading task should shift down when direct move fails")
     XCTAssertEqual(updatedTrailing?.startIndex, 7, "Subsequent task should maintain relative offset after shift")
     XCTAssertEqual(updatedBlocking?.startIndex, 9, "All tasks from the group should shift together")
     }
     
     func testFinishTaskRoundsToCurrentTime() {
     let task = makeTask(start: 8, duration: 6)
     let (viewModel, cleanup) = makeViewModel(tasks: [task])
     defer { cleanup() }
     
     let startDate = viewModel.date(for: task.startIndex)
     let halfway = startDate.addingTimeInterval(Double(ScheduleViewModel.blockMinutes * 2) * 60)
     
     viewModel.finishTask(task, at: halfway)
     XCTAssertEqual(viewModel.task(with: task.id)?.duration, 2, "Task should end on the block covering the provided date")
     }
     
     func testAdjustTaskEndTimeShortensToExplicitHour() {
     let task = makeTask(start: 4, duration: 6)
     let (viewModel, cleanup) = makeViewModel(tasks: [task])
     defer { cleanup() }
     
     let endDate = viewModel.date(for: task.startIndex).addingTimeInterval(Double(ScheduleViewModel.blockMinutes * 3) * 60)
     viewModel.adjustTaskEndTime(for: task, to: endDate)
     
     XCTAssertEqual(viewModel.task(with: task.id)?.duration, 3, "Task should now finish exactly at the requested time boundary")
     
     // Requesting a later time (beyond current duration) keeps duration unchanged
     let laterEnd = viewModel.date(for: task.startIndex + 10)
     viewModel.adjustTaskEndTime(for: task, to: laterEnd)
     XCTAssertEqual(viewModel.task(with: task.id)?.duration, 3, "Task should not extend when forcing an end time past its current duration")
     }
     
     func testFocusLifecycleAssignAndDetach() {
     let task = makeTask(start: 4, duration: 4)
     let (viewModel, cleanup) = makeViewModel(tasks: [task])
     defer { cleanup() }
     
        let focus = viewModel.addFocus(name: "Focus test")
     viewModel.assignFocus(focus, to: task)
     
        XCTAssertEqual(viewModel.task(with: task.id)?.focusID, focus.id)
        XCTAssertTrue(viewModel.focus(with: focus.id)?.taskIDs.contains(task.id) ?? false)
     
        viewModel.clearFocus(for: task)
        XCTAssertNil(viewModel.task(with: task.id)?.focusID)
        XCTAssertFalse(viewModel.focus(with: focus.id)?.taskIDs.contains(task.id) ?? true)
     
     viewModel.assignFocus(focus, to: task)
        viewModel.delete(task: task)
        XCTAssertFalse(viewModel.focus(with: focus.id)?.taskIDs.contains(task.id) ?? true, "Deleting the task should free the focus")
     }
     
    func testFocusIndeterminateState() {
        let task = makeTask(start: 6, duration: 3)
        let (viewModel, cleanup) = makeViewModel(tasks: [task])
        defer { cleanup() }

        viewModel.setTaskFocusIndeterminate(task, isIndeterminate: true)
        XCTAssertTrue(viewModel.task(with: task.id)?.isFocusIndeterminate ?? false)
        XCTAssertNil(viewModel.task(with: task.id)?.focusID)

        let focus = viewModel.addFocus(name: "Attach later")
        viewModel.assignFocus(focus, to: task)
        XCTAssertFalse(viewModel.task(with: task.id)?.isFocusIndeterminate ?? true)
        XCTAssertEqual(viewModel.task(with: task.id)?.focusID, focus.id)

        viewModel.setTaskFocusIndeterminate(task, isIndeterminate: true)
        XCTAssertFalse(viewModel.focus(with: focus.id)?.taskIDs.contains(task.id) ?? true)
        XCTAssertTrue(viewModel.task(with: task.id)?.isFocusIndeterminate ?? false)
    }

    func testFocusUsageAccumulatesAcrossTasks() {
        let taskA = makeTask(start: 2, duration: 2)
        let taskB = makeTask(start: 6, duration: 3)
        let (viewModel, cleanup) = makeViewModel(tasks: [taskA, taskB])
        defer { cleanup() }

        let focus = viewModel.addFocus(name: "Focus multi")
        viewModel.assignFocus(focus, to: taskA)
        viewModel.assignFocus(focus, to: taskB)

        viewModel.toggleCompletion(for: taskA)
        viewModel.toggleCompletion(for: taskB)

        let expectedMinutes = (taskA.duration + taskB.duration) * ScheduleViewModel.blockMinutes
        XCTAssertEqual(viewModel.focus(with: focus.id)?.actualMinutes, expectedMinutes)
    }
     }*/
}
