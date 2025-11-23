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
        let teardown = {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return (viewModel, teardown)
    }

    private func makeTask(start: Int, duration: Int) -> TaskItem {
        TaskItem(categoryID: UUID(), startIndex: start, duration: duration)
    }

    // MARK: - Tests
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
*/
    func testAdjustTaskPositionMovesOrShiftsGroup() {
        let leading = makeTask(start: 0, duration: 2)
        let trailing = makeTask(start: 2, duration: 2)
        let blocking = makeTask(start: 4, duration: 2)
        let (viewModel, cleanup) = makeViewModel(tasks: [leading, trailing, blocking])
        defer { cleanup() }

        // Move into free space
        viewModel.adjustTaskPosition(for: trailing, by: 2)
        XCTAssertEqual(viewModel.task(with: trailing.id)?.startIndex, 4, "Trailing task should move into empty space")

        // Force shift when space is occupied/*
        viewModel.adjustTaskPosition(for: leading, by: 1)
        let updatedLeading = viewModel.task(with: leading.id)
        let updatedTrailing = viewModel.task(with: trailing.id)
        let updatedBlocking = viewModel.task(with: blocking.id)

        XCTAssertEqual(updatedLeading?.startIndex, 1, "Leading task should shift down when direct move fails")
        XCTAssertEqual(updatedTrailing?.startIndex, 5, "Subsequent task should maintain relative offset after shift")
        XCTAssertEqual(updatedBlocking?.startIndex, 7, "All tasks from the group should shift together")
                                              
 
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
}
