import XCTest
@testable import Agenda

final class ScheduleViewModelTests: XCTestCase {
    
    @MainActor
    func testCategoryRefreshReplacesSnapshotAndPersistsEmptyTable() async throws {
        let suite = "CategoryRefresh-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CategoryServiceStub()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        let original = TaskCategory(name: "Original", colorHex: "#ffffff")
        let removed = TaskCategory(name: "Removed", colorHex: "#000000")
        model.categories = [original, removed]
        var edited = original
        edited.name = "Edited"
        edited.colorHex = "#123456"
        service.categories = [edited]

        await model.refreshCategoriesFromRemote()
        XCTAssertEqual(model.categories, [edited])
        let cached = try XCTUnwrap(defaults.data(forKey: "agenda.categories.storage"))
        XCTAssertEqual(try JSONDecoder().decode([TaskCategory].self, from: cached), [edited])

        service.categories = []
        await model.refreshCategoriesFromRemote()
        XCTAssertTrue(model.categories.isEmpty)
        let reloaded = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        XCTAssertTrue(reloaded.categories.isEmpty, "Deleted types must not reappear as defaults")
    }

    @MainActor
    func testFailedCategoryRefreshKeepsLastSuccessfulSnapshot() async {
        let suite = "CategoryRefresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = CategoryServiceStub()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        service.categories = [TaskCategory(name: "Saved", colorHex: "#123456")]
        await model.refreshCategoriesFromRemote()
        service.shouldFail = true
        await model.refreshCategoriesFromRemote()
        XCTAssertEqual(model.categories, service.categories)
        XCTAssertNotNil(model.categoryRefreshError)
        service.shouldFail = false
        await model.refreshCategoriesFromRemote()
        XCTAssertNil(model.categoryRefreshError)
    }

    @MainActor
    func testLatestCategoryRefreshWinsWhenRequestsOverlap() async {
        let suite = "CategoryRefresh-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PendingCategoryService()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        let first = Task { await model.refreshCategoriesFromRemote() }
        while service.requests.count < 1 { await Task.yield() }
        let second = Task { await model.refreshCategoriesFromRemote() }
        while service.requests.count < 2 { await Task.yield() }
        let latest = TaskCategory(name: "Latest", colorHex: "#123456")
        service.requests[1].resume(returning: [latest])
        await second.value
        service.requests[0].resume(returning: [TaskCategory(name: "Stale", colorHex: "#000000")])
        await first.value
        XCTAssertEqual(model.categories, [latest])
        XCTAssertFalse(model.isRefreshingCategories)
        XCTAssertNotNil(model.categoriesLastRefreshedAt)
    }

    func testCategoryServiceFetchesEditsAndDeletionsWithoutCache() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CategoryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = SupabaseTaskCategoryService(session: session)
        let id = UUID()
        CategoryURLProtocol.responseData = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"Before\",\"colorHex\":\"#ffffff\"}]".utf8)
        let before = try await service.importCategories()
        XCTAssertEqual(before.first?.name, "Before")
        CategoryURLProtocol.responseData = Data("[{\"id\":\"\(id.uuidString)\",\"name\":\"After\",\"colorHex\":\"#123456\"}]".utf8)
        let after = try await service.importCategories()
        XCTAssertEqual(after.first?.id, id)
        XCTAssertEqual(after.first?.name, "After")
        XCTAssertEqual(after.first?.colorHex, "#123456")
        CategoryURLProtocol.responseData = Data("[]".utf8)
        let deleted = try await service.importCategories()
        XCTAssertTrue(deleted.isEmpty)
        XCTAssertEqual(CategoryURLProtocol.lastRequest?.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertEqual(CategoryURLProtocol.lastRequest?.value(forHTTPHeaderField: "Cache-Control"), "no-cache")
    }

    @MainActor
    func testRefreshWaitsForConfirmedDeletionAndDoesNotRestoreDeletedType() async {
        let suite = "CategoryDeletion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PendingCategoryMutationService()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        let category = TaskCategory(name: "Delete", colorHex: "#123456")
        let task = TaskItem(categoryID: category.id, startIndex: 0, duration: 1)
        service.categories = [category]
        model.categories = [category]
        model.tasks = [task]

        let deletion = model.deleteCategory(category)
        while service.pendingDeletion == nil { await Task.yield() }
        XCTAssertEqual(model.categories, [category], "Keep the type until the server confirms deletion")
        XCTAssertEqual(model.tasks, [task])
        let refresh = Task { await model.refreshCategoriesFromRemote() }
        await Task.yield()
        XCTAssertEqual(service.importCount, 0, "Do not read a stale snapshot during deletion")
        service.categories = []
        service.pendingDeletion?.resume()
        await deletion.value
        await refresh.value
        XCTAssertTrue(model.categories.isEmpty)
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertNil(model.categoryMutationError)
    }

    @MainActor
    func testFailedDeletionPreservesTypeAndTasksAndShowsError() async {
        let suite = "CategoryDeletion-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PendingCategoryMutationService()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        let category = TaskCategory(name: "Keep", colorHex: "#123456")
        let task = TaskItem(categoryID: category.id, startIndex: 0, duration: 1)
        service.categories = [category]
        model.categories = [category]
        model.tasks = [task]
        let deletion = model.deleteCategory(category)
        while service.pendingDeletion == nil { await Task.yield() }
        service.pendingDeletion?.resume(throwing: URLError(.notConnectedToInternet))
        await deletion.value
        await model.refreshCategoriesFromRemote()
        XCTAssertEqual(model.categories, [category])
        XCTAssertEqual(model.tasks, [task])
        XCTAssertNotNil(model.categoryMutationError)
    }

    @MainActor
    func testCategoryEditsAreWrittenBeforeRefresh() async {
        let suite = "CategoryEdit-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let service = PendingCategoryMutationService()
        let model = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: service)
        var category = TaskCategory(name: "Before", colorHex: "#ffffff")
        service.categories = [category]
        model.categories = [category]
        category.name = "After"
        category.colorHex = "#123456"
        model.updateCategory(category)
        await model.refreshCategoriesFromRemote()
        XCTAssertEqual(service.categories, [category])
        XCTAssertEqual(model.categories, [category])
    }

    func testCategoryWritesRejectSuccessfulHTTPResponseWithNoAffectedRows() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CategoryURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = SupabaseTaskCategoryService(session: session)
        let category = TaskCategory(name: "Write", colorHex: "#123456")
        CategoryURLProtocol.responseData = Data("[]".utf8)
        do {
            try await service.deleteCategory(category.id)
            XCTFail("An HTTP success without a deleted row must not count as deletion")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Supabase no confirmó"))
        }
        do {
            try await service.updateCategory(category)
            XCTFail("An HTTP success without an updated row must not count as an edit")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Supabase no confirmó"))
        }
        XCTAssertEqual(CategoryURLProtocol.lastRequest?.value(forHTTPHeaderField: "Prefer"), "return=representation")
        CategoryURLProtocol.responseData = Data("[{\"id\":\"\(category.id.uuidString)\"}]".utf8)
        try await service.deleteCategory(category.id)
        XCTAssertEqual(CategoryURLProtocol.lastRequest?.httpMethod, "DELETE")
    }

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

private final class CategoryServiceStub: TaskCategoryRemoteService {
    var categories: [TaskCategory] = []
    var shouldFail = false

    func importCategories() async throws -> [TaskCategory] {
        if shouldFail { throw URLError(.notConnectedToInternet) }
        return categories
    }

    func createCategory(_ category: TaskCategory) async throws {}
    func updateCategory(_ category: TaskCategory) async throws {}
    func deleteCategory(_ categoryID: UUID) async throws {}
}

private final class PendingCategoryService: TaskCategoryRemoteService {
    var requests: [CheckedContinuation<[TaskCategory], Error>] = []
    func importCategories() async throws -> [TaskCategory] {
        try await withCheckedThrowingContinuation { requests.append($0) }
    }
    func createCategory(_ category: TaskCategory) async throws {}
    func updateCategory(_ category: TaskCategory) async throws {}
    func deleteCategory(_ categoryID: UUID) async throws {}
}

private final class CategoryURLProtocol: URLProtocol {
    static var responseData = Data()
    static var lastRequest: URLRequest?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lastRequest = request
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.responseData)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PendingCategoryMutationService: TaskCategoryRemoteService {
    var categories: [TaskCategory] = []
    var pendingDeletion: CheckedContinuation<Void, Error>?
    var importCount = 0
    func importCategories() async throws -> [TaskCategory] {
        importCount += 1
        return categories
    }
    func createCategory(_ category: TaskCategory) async throws { categories.append(category) }
    func updateCategory(_ category: TaskCategory) async throws {
        if let index = categories.firstIndex(where: { $0.id == category.id }) {
            categories[index] = category
        }
    }
    func deleteCategory(_ categoryID: UUID) async throws {
        try await withCheckedThrowingContinuation { pendingDeletion = $0 }
    }
}
