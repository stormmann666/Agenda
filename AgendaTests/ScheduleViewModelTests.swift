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

    @MainActor
    func testNewSupabaseFocusRemainsSingleAfterRepeatedRefreshes() async throws {
        let suite = "FocusIdentity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FocusIdentityURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        FocusIdentityURLProtocol.rows = []
        FocusIdentityURLProtocol.createCount = 0
        let created = expectation(description: "Focus inserted once")
        FocusIdentityURLProtocol.didCreate = { created.fulfill() }
        defer { FocusIdentityURLProtocol.didCreate = nil }
        let service = SupabaseFocusService(session: session)
        let model = ScheduleViewModel(defaults: defaults, focusService: service, categoryService: CategoryServiceStub())
        let added = model.addFocus(name: "Single focus", expectedMinutes: 30, priority: 3)
        await fulfillment(of: [created], timeout: 3)

        await model.refreshFocusesFromRemote()
        await model.refreshFocusesFromRemote()

        XCTAssertEqual(FocusIdentityURLProtocol.createCount, 1)
        XCTAssertEqual(model.focuses.count, 1)
        XCTAssertEqual(model.focuses.first?.id, added.id)
        XCTAssertEqual(model.focuses.first?.name, "Single focus")
        XCTAssertEqual(model.focuses.first?.priority, 3)
    }

    @MainActor
    func testRefreshReconcilesLegacyDuplicateAndPreservesTaskLinks() async {
        let suite = "FocusIdentity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FocusIdentityURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = SupabaseFocusService(session: session)
        let model = ScheduleViewModel(defaults: defaults, focusService: service, categoryService: CategoryServiceStub())
        let legacyID = UUID(uuidString: "00000000-0000-0007-8000-000000000001")!
        let canonicalID = service.canonicalFocusID(for: legacyID)
        let task = TaskItem(categoryID: UUID(), startIndex: 0, duration: 1, focusID: legacyID)
        let anotherTask = TaskItem(categoryID: UUID(), startIndex: 1, duration: 1, focusID: canonicalID)
        model.tasks = [task, anotherTask]
        model.dayLogs = [ScheduleDayLog(date: Date(), tasks: [task])]
        model.focuses = [FocusItem(id: legacyID, name: "Original", isCompleted: true, taskIDs: [task.id]),
                         FocusItem(id: canonicalID, name: "Original", taskIDs: [anotherTask.id])]
        FocusIdentityURLProtocol.rows = [["id": 7, "Descripcion": "Remote edit", "Prioridad": 2]]
        FocusIdentityURLProtocol.createCount = 0

        await model.refreshFocusesFromRemote()

        XCTAssertEqual(model.focuses.count, 1)
        XCTAssertEqual(model.focuses.first?.id, canonicalID)
        XCTAssertEqual(model.focuses.first?.name, "Remote edit")
        XCTAssertEqual(Set(model.focuses.first?.taskIDs ?? []), Set([task.id, anotherTask.id]))
        XCTAssertEqual(model.focuses.first?.isCompleted, true)
        XCTAssertTrue(model.tasks.allSatisfy { $0.focusID == canonicalID })
        XCTAssertEqual(model.dayLogs.first?.tasks.first?.focusID, canonicalID)
        XCTAssertEqual(FocusIdentityURLProtocol.createCount, 0)
    }

    @MainActor
    func testDifferentFocusesWithSameNameAreNotMerged() async {
        let suite = "FocusIdentity-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FocusIdentityURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let service = SupabaseFocusService(session: session)
        let model = ScheduleViewModel(defaults: defaults, focusService: service, categoryService: CategoryServiceStub())
        FocusIdentityURLProtocol.rows = [["id": 7, "Descripcion": "Same name"], ["id": -7, "Descripcion": "Same name"]]
        await model.refreshFocusesFromRemote()
        XCTAssertEqual(model.focuses.count, 2)
        XCTAssertNotEqual(model.focuses.first?.id, model.focuses.last?.id)
        for focus in model.focuses {
            XCTAssertEqual(service.canonicalFocusID(for: focus.id), focus.id)
        }
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

    func testBlockAlertFollowsTaskMovesAndCompletion() throws {
        let task = makeTask(start: 2, duration: 3)
        let (viewModel, cleanup) = makeViewModel(tasks: [task])
        defer { cleanup() }

        let original = try XCTUnwrap(viewModel.blockAlerts.first)
        XCTAssertEqual(original.start, viewModel.date(for: 2))
        XCTAssertEqual(original.end, viewModel.date(for: 5))
        XCTAssertEqual(viewModel.blockAlerts.first?.id, original.id)

        viewModel.move(task: task, to: 7)
        let moved = try XCTUnwrap(viewModel.blockAlerts.first)
        XCTAssertEqual(moved.start, viewModel.date(for: 7))
        XCTAssertEqual(moved.end, viewModel.date(for: 10))
        XCTAssertNotEqual(moved.id, original.id)

        viewModel.toggleCompletion(for: task)
        XCTAssertTrue(viewModel.blockAlerts.isEmpty)
    }

    func testBlockAlarmUsesRemainingTimeOnceTheTaskHasStarted() {
        let start = Date(timeIntervalSinceReferenceDate: 3_600)
        let end = start.addingTimeInterval(1_800)
        let alert = BlockAlert(taskID: UUID(), taskName: "Tarea", start: start, end: end)

        XCTAssertEqual(alert.alarmTiming(at: start.addingTimeInterval(-60)),
                       .scheduled(end: end, duration: 1_800))
        XCTAssertEqual(alert.alarmTiming(at: start), .immediate(duration: 1_800))
        XCTAssertEqual(alert.alarmTiming(at: start.addingTimeInterval(600)), .immediate(duration: 1_200))
        XCTAssertNil(alert.alarmTiming(at: end))
    }

    func testBlockStartNotificationIsIndependentOfTheEndAlarm() {
        let start = Date(timeIntervalSinceReferenceDate: 3_600)
        let end = start.addingTimeInterval(600)
        let alert = BlockAlert(taskID: UUID(), taskName: "Facturas", start: start, end: end)
        let beforeStart = start.addingTimeInterval(-60)

        let withNativeAlarm = BlockNotification.upcoming(for: [alert], after: beforeStart,
                                                          nativeAlarmIDs: [alert.id], existingIDs: [])
        XCTAssertEqual(withNativeAlarm.map(\.title), ["Empieza: Facturas"])
        XCTAssertEqual(withNativeAlarm.map(\.date), [start])

        let withoutNativeAlarm = BlockNotification.upcoming(for: [alert], after: beforeStart,
                                                             nativeAlarmIDs: [], existingIDs: [])
        XCTAssertEqual(withoutNativeAlarm.map(\.date), [start, end])
        XCTAssertEqual(Set(withoutNativeAlarm.map(\.identifier)).count, 2)

        let withUnknownAlarmStatus = BlockNotification.upcoming(
            for: [alert], after: beforeStart, nativeAlarmIDs: nil,
            existingIDs: Set(withoutNativeAlarm.map(\.identifier))
        )
        XCTAssertEqual(withUnknownAlarmStatus.map(\.date), [start, end])

        let alreadyStarted = BlockNotification.upcoming(for: [alert], after: start,
                                                        nativeAlarmIDs: [], existingIDs: [])
        XCTAssertEqual(alreadyStarted.map(\.date), [end])

        let withScheduledActivity = BlockNotification.upcoming(
            for: [alert], after: beforeStart, nativeAlarmIDs: [], existingIDs: [],
            liveActivityIDs: [alert.id]
        )
        XCTAssertEqual(withScheduledActivity.map(\.date), [end])
    }

    func testImportQuickFocusesUsesOnlyTrailingSiempreAsDailyMarker() throws {
        let suite = "QuickFocusImport-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil)
        let existing = viewModel.addFocus(name: "Tarea existente", kind: .once)

        viewModel.importQuickFocuses(from: "Llamar al proveedor\r\n\r\n  Revisar la caja (SIEMPRE).  \nGuardar siempre el recibo\nRevisar casisiempre\nsiempre")

        let reloaded = ScheduleViewModel(defaults: defaults, focusService: nil)
        XCTAssertEqual(reloaded.focuses.first?.id, existing.id)
        XCTAssertEqual(reloaded.focuses.map(\.name), [
            "Tarea existente", "Llamar al proveedor", "Revisar la caja",
            "Guardar siempre el recibo", "Revisar casisiempre"
        ])
        XCTAssertEqual(reloaded.focuses.map(\.kind), [.once, .once, .daily, .once, .once])
    }

    func testOneTimeQuickFocusUsesOneBoxAndCanBeReopened() throws {
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        let focus = viewModel.addFocus(name: "Llamar al proveedor", kind: .once)
        let start = viewModel.date(for: 0)
        let task = try XCTUnwrap(viewModel.scheduleFocusAtCurrentTime(focus, referenceDate: start))
        XCTAssertEqual(task.focusID, focus.id)
        XCTAssertNotNil(viewModel.category(for: task.categoryID))
        XCTAssertNil(viewModel.scheduleFocusAtCurrentTime(focus, referenceDate: start))

        viewModel.toggleCompletion(for: task)
        XCTAssertTrue(viewModel.pendingQuickFocuses.isEmpty)
        XCTAssertEqual(viewModel.completedQuickFocusesToday.map(\.id), [focus.id])

        viewModel.toggleCompletion(for: task)
        XCTAssertEqual(viewModel.pendingQuickFocuses.map(\.id), [focus.id])

        viewModel.toggleCompletion(for: task)
        viewModel.endCurrentDay()
        XCTAssertTrue(viewModel.pendingQuickFocuses.isEmpty)
        XCTAssertTrue(viewModel.completedQuickFocusesToday.isEmpty)
    }

    @MainActor
    func testDailyQuickFocusReturnsAfterDayChangeAndKeepsHistoryOnReload() async throws {
        let suite = "DailyQuickFocus-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil)
        let focus = viewModel.addFocus(name: "Revisar la caja", kind: .daily)
        let task = try XCTUnwrap(viewModel.scheduleFocusAtCurrentTime(focus, referenceDate: viewModel.dayStart))
        viewModel.toggleQuickFocus(focus)
        XCTAssertEqual(viewModel.task(with: task.id)?.isCompleted, true)
        XCTAssertEqual(viewModel.completedQuickFocusesToday.map(\.id), [focus.id])
        let firstDay = viewModel.dayStart
        let secondDay = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: firstDay))

        viewModel.advanceDayIfNeeded(at: secondDay)
        XCTAssertEqual(viewModel.pendingQuickFocuses.map(\.id), [focus.id])
        XCTAssertEqual(viewModel.dayLogs.first?.tasks.first?.id, task.id)

        let reloaded = ScheduleViewModel(defaults: defaults, focusService: nil)
        await reloaded.refreshFocusesFromRemote()
        XCTAssertEqual(reloaded.pendingQuickFocuses.map(\.id), [focus.id])
        let savedFocus = try XCTUnwrap(reloaded.focus(with: focus.id))
        XCTAssertEqual(savedFocus.completions.map(\.day), [firstDay])
        XCTAssertTrue(savedFocus.taskIDs.isEmpty)
    }

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
        XCTAssertEqual(proposals.map(\.focusID), [viewModel.focuses[1].id, viewModel.focuses[0].id, viewModel.focuses[1].id])
    }

    func testApplyFocusScheduleCreatesLinkedBoxesAndRejectsStalePlan() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let focus = FocusItem(name: "Planificable", expectedMinutes: 30, proposedCategoryID: category.id, priority: 5)
        viewModel.focuses = [focus]
        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0))

        XCTAssertTrue(viewModel.applyFocusSchedule(proposals, from: viewModel.date(for: 0)))
        XCTAssertEqual(viewModel.tasks.count, 1)
        XCTAssertEqual(viewModel.tasks.first?.duration, 6)
        XCTAssertEqual(viewModel.tasks.first?.focusID, focus.id)
        XCTAssertEqual(viewModel.focus(with: focus.id)?.taskIDs, [viewModel.tasks[0].id])
        XCTAssertFalse(viewModel.applyFocusSchedule(proposals, from: viewModel.date(for: 0)),
                       "A stale preview must not overlap the boxes it already created")
    }

    func testPlannerStartsAtNextFreeBlockAfterCurrentTime() throws {
        let suite = "AgendaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: CategoryServiceStub())
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let firstBox = TaskItem(categoryID: category.id, startIndex: 13, duration: 3)
        let secondBox = TaskItem(categoryID: category.id, startIndex: 16, duration: 3)
        viewModel.categories = [category]
        viewModel.tasks = [firstBox, secondBox]
        viewModel.focuses = [
            FocusItem(name: "Planificable", expectedMinutes: 15, proposedCategoryID: category.id, priority: 5)
        ]
        let blockStart = viewModel.date(for: 10)
        let now = blockStart.addingTimeInterval(120)
        let earlierPlan = viewModel.proposeFocusSchedule(from: blockStart, oneSessionPerRound: true)

        XCTAssertEqual(earlierPlan.map(\.startIndex), [10])
        XCTAssertFalse(viewModel.applyFocusSchedule(earlierPlan, from: now))
        XCTAssertEqual(viewModel.tasks, [firstBox, secondBox])
        XCTAssertEqual(viewModel.reflowFocusSchedule(earlierPlan, from: now)?.map(\.startIndex), [19])

        let currentPlan = viewModel.proposeFocusSchedule(from: now, oneSessionPerRound: true)
        XCTAssertEqual(currentPlan.map(\.startIndex), [19])
        XCTAssertTrue(viewModel.applyFocusSchedule(currentPlan, from: now))
        XCTAssertEqual(Array(viewModel.tasks.prefix(2)), [firstBox, secondBox])
        XCTAssertEqual(viewModel.tasks.map(\.startIndex), [13, 16, 19])
    }

    func testPlannerRechecksReservedAndAvoidedBlocksBeforeAddingQuickFocus() throws {
        let suite = "AgendaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: CategoryServiceStub())
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        viewModel.categories = [category]
        let startIndex = 12 * ScheduleViewModel.blocksPerHour
        let endIndex = 15 * ScheduleViewModel.blocksPerHour
        let now = viewModel.date(for: startIndex)
        viewModel.focuses = [FocusItem(name: "Llamar", kind: .once)]

        let initialPlan = viewModel.proposeFocusSchedule(from: now, oneSessionPerRound: true)
        XCTAssertEqual(initialPlan.map(\.startIndex), [startIndex])
        let task = try XCTUnwrap(viewModel.addTask(at: startIndex, category: category))
        viewModel.resize(task: task, newDuration: endIndex - startIndex)
        let reservation = try XCTUnwrap(viewModel.task(with: task.id))
        XCTAssertFalse(viewModel.focusScheduleFits(initialPlan, from: viewModel.dayStart))
        XCTAssertFalse(viewModel.applyFocusSchedule(initialPlan, from: now))
        XCTAssertEqual(viewModel.tasks, [reservation])

        let duringReservation = now.addingTimeInterval(60 * 60)
        for oneSessionPerRound in [false, true] {
            let plan = viewModel.proposeFocusSchedule(from: duringReservation, oneSessionPerRound: oneSessionPerRound)
            XCTAssertEqual(plan.map(\.startIndex), [endIndex])
            XCTAssertTrue(viewModel.focusScheduleFits(plan, from: viewModel.dayStart))
        }

        let nextPlan = viewModel.proposeFocusSchedule(from: now, oneSessionPerRound: true)
        XCTAssertEqual(nextPlan.map(\.startIndex), [endIndex])
        let avoided = viewModel.date(for: endIndex)..<viewModel.date(for: endIndex + 2)
        XCTAssertFalse(viewModel.focusScheduleFits(nextPlan, from: viewModel.dayStart, avoiding: [avoided]))
        XCTAssertFalse(viewModel.applyFocusSchedule(nextPlan, from: now, avoiding: [avoided]))
        XCTAssertEqual(viewModel.tasks, [reservation])

        let finalPlan = viewModel.proposeFocusSchedule(from: now, oneSessionPerRound: true, avoiding: [avoided])
        XCTAssertEqual(finalPlan.map(\.startIndex), [endIndex + 2])
        XCTAssertTrue(viewModel.applyFocusSchedule(finalPlan, from: now, avoiding: [avoided]))
        XCTAssertEqual(viewModel.tasks.first, reservation)
        XCTAssertEqual(viewModel.tasks.map(\.startIndex), [startIndex, endIndex + 2])
    }

    func testPlannerAppliesSavedAvoidedHoursToTheDayBeingPlanned() throws {
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.focuses = [FocusItem(name: "Llamar", kind: .once)]
        let window = AvoidedScheduleWindow(referenceDate: viewModel.dayStart, startHour: 17, endHour: 20)
        viewModel.endCurrentDay()

        let avoided = try XCTUnwrap(window.range(on: viewModel.dayStart))
        XCTAssertEqual(avoided.lowerBound, viewModel.date(for: 12 * ScheduleViewModel.blocksPerHour))
        XCTAssertEqual(avoided.upperBound, viewModel.date(for: 15 * ScheduleViewModel.blocksPerHour))
        let now = avoided.lowerBound.addingTimeInterval(60 * 60)
        let proposals = viewModel.proposeFocusSchedule(from: now, avoiding: [avoided])
        XCTAssertEqual(proposals.map { viewModel.date(for: $0.startIndex) }, [avoided.upperBound])

        let untilMidnight = AvoidedScheduleWindow(referenceDate: window.start, startMinutes: 17 * 60, endMinutes: 24 * 60)
        let fullEvening = try XCTUnwrap(untilMidnight.range(on: viewModel.dayStart))
        XCTAssertEqual(fullEvening.upperBound, viewModel.dayEnd)
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: now, avoiding: [fullEvening]).isEmpty)
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
                                                       avoiding: [avoidedRange])

        XCTAssertTrue(proposals.allSatisfy { $0.focusID == prioritized.id })
        XCTAssertTrue(proposals.allSatisfy { $0.duration <= 3 })
        XCTAssertFalse(proposals.contains { $0.startIndex < 12 && $0.startIndex + $0.duration > 6 })
    }

    func testPlannerLimitsConsecutiveCategoriesAndIncludesPriorityOne() {
        let categoryA = TaskCategory(name: "A", colorHex: "#3366FF")
        let categoryB = TaskCategory(name: "B", colorHex: "#FF6633")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [categoryA, categoryB]
        let highA = FocusItem(name: "A alta", expectedMinutes: 90, proposedCategoryID: categoryA.id, priority: 5)
        let lowB = FocusItem(name: "B prioridad uno", expectedMinutes: 30, proposedCategoryID: categoryB.id, priority: 1)
        viewModel.focuses = [highA, lowB]

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0),
                                                       maximumSessionMinutes: 30,
                                                       maximumConsecutiveSameCategory: 1)

        XCTAssertTrue(proposals.contains { $0.focusID == lowB.id })
        XCTAssertEqual(Array(proposals.prefix(3)).map(\.categoryID), [categoryA.id, categoryB.id, categoryA.id])
    }

    func testPlannerRestartsRoundsAndDoesNotSplitOneTurnAcrossGaps() {
        let categoryA = TaskCategory(name: "A", colorHex: "#3366FF")
        let categoryB = TaskCategory(name: "B", colorHex: "#FF6633")
        let blocker = TaskItem(categoryID: categoryA.id, startIndex: 3, duration: 3)
        let (viewModel, cleanup) = makeViewModel(tasks: [blocker])
        defer { cleanup() }
        viewModel.categories = [categoryA, categoryB]
        let first = FocusItem(name: "A", expectedMinutes: 90, proposedCategoryID: categoryA.id, priority: 5)
        let second = FocusItem(name: "B", expectedMinutes: 90, proposedCategoryID: categoryB.id, priority: 4)
        viewModel.focuses = [first, second]

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true)

        XCTAssertEqual(proposals.map(\.focusID), [first.id, second.id, first.id, second.id, first.id, second.id, first.id])
        XCTAssertEqual(proposals.map(\.startIndex), [0, 6, 12, 18, 24, 30, 36])
        XCTAssertEqual(proposals.map(\.duration), [3, 6, 6, 6, 6, 6, 3])
        XCTAssertTrue(viewModel.applyFocusSchedule(proposals, from: viewModel.date(for: 0)))
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true).isEmpty)

        viewModel.endCurrentDay()

        let nextDay = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true)
        XCTAssertEqual(nextDay.map(\.focusID), [first.id, second.id, first.id, second.id, first.id, second.id])
    }

    func testPlannerRoundsKeepPriorityOrderAcrossCategoriesAndGaps() {
        let work = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let home = TaskCategory(name: "Casa", colorHex: "#FF6633")
        let blocker = TaskItem(categoryID: home.id, startIndex: 2, duration: 4)
        let (viewModel, cleanup) = makeViewModel(tasks: [blocker])
        defer { cleanup() }
        viewModel.categories = [work, home]
        let first = FocusItem(name: "A", expectedMinutes: 60, proposedCategoryID: work.id, priority: 5)
        let second = FocusItem(name: "B", expectedMinutes: 90, proposedCategoryID: work.id, priority: 5)
        let third = FocusItem(name: "C", expectedMinutes: 10, proposedCategoryID: home.id, priority: 4)
        viewModel.focuses = [third, second, first]

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0),
                                                       oneSessionPerRound: true,
                                                       maximumConsecutiveSameCategory: 1)

        XCTAssertEqual(proposals.map(\.focusID), [first.id, second.id, third.id, first.id, second.id, second.id])
        XCTAssertEqual(proposals.map(\.startIndex), [6, 12, 18, 20, 26, 32])
    }

    func testPlannerRoundsCountCompletedBoxesBeforeRepeatingPriorityOrder() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let completed = FocusItem(name: "Con sesión hecha", expectedMinutes: 90, actualMinutes: 30,
                                  proposedCategoryID: category.id, priority: 5)
        let pending = FocusItem(name: "Pendiente", expectedMinutes: 90, proposedCategoryID: category.id, priority: 4)
        let existing = TaskItem(categoryID: category.id, startIndex: 0, duration: 6,
                                isCompleted: true, focusID: completed.id)
        let (viewModel, cleanup) = makeViewModel(tasks: [existing])
        defer { cleanup() }
        viewModel.categories = [category]
        viewModel.focuses = [completed, pending]

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true)
        XCTAssertEqual(proposals.map(\.focusID), [pending.id, completed.id, pending.id, completed.id, pending.id])
        XCTAssertTrue(viewModel.applyFocusSchedule(proposals, from: viewModel.date(for: 0)))
        XCTAssertEqual(viewModel.tasks.first, existing)
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true).isEmpty)
    }

    func testPlannerRoundsUseConfiguredDurationAndFallbackTypeForIncompleteProjects() throws {
        let suite = "AgendaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: CategoryServiceStub())
        let work = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        viewModel.categories = [work]
        let noEstimate = FocusItem(name: "Sin estimación", proposedCategoryID: work.id, priority: 5)
        let noType = FocusItem(name: "Sin tipo", expectedMinutes: 10, priority: 4)
        let zeroEstimate = FocusItem(name: "Estimación cero", expectedMinutes: 0,
                                     proposedCategoryID: UUID(), priority: 1)
        let noPriority = FocusItem(name: "Sin prioridad", expectedMinutes: 30, proposedCategoryID: work.id)
        viewModel.focuses = [zeroEstimate, noType, noPriority, noEstimate]

        let start = viewModel.date(for: 0)
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: start).isEmpty)

        let avoided = viewModel.date(for: 22)..<viewModel.dayEnd
        let proposals = viewModel.proposeFocusSchedule(from: start,
                                                       maximumSessionMinutes: 25,
                                                       oneSessionPerRound: true,
                                                       avoiding: [avoided])
        XCTAssertEqual(proposals.map(\.focusID), [noEstimate.id, noType.id, zeroEstimate.id, noEstimate.id, zeroEstimate.id])
        XCTAssertEqual(proposals.map(\.duration), [5, 2, 5, 5, 5])
        XCTAssertEqual(proposals.map { viewModel.category(for: $0.categoryID)?.name },
                       ["Trabajo", "Focus", "Focus", "Trabajo", "Focus"])
        XCTAssertTrue(viewModel.applyFocusSchedule(proposals, from: start))
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: start, oneSessionPerRound: true, avoiding: [avoided]).isEmpty)
    }

    func testPlannerAddsPendingQuickFocusesAtPriorityThreeWithoutRepeatingThem() throws {
        let suite = "AgendaTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let viewModel = ScheduleViewModel(defaults: defaults, focusService: nil, categoryService: CategoryServiceStub())
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        viewModel.categories = [category]
        let high = FocusItem(name: "Alta", expectedMinutes: 60, proposedCategoryID: category.id, priority: 5)
        let medium = FocusItem(name: "Media", expectedMinutes: 30, proposedCategoryID: category.id, priority: 3)
        let low = FocusItem(name: "Baja", expectedMinutes: 30, proposedCategoryID: category.id, priority: 2)
        let once = FocusItem(name: "A puntual", kind: .once)
        let daily = FocusItem(name: "B diaria", proposedCategoryID: category.id, kind: .daily)
        let done = FocusItem(name: "Terminada", kind: .once)
        let booked = FocusItem(name: "Ya programada", kind: .once)
        viewModel.focuses = [low, once, high, daily, done, booked, medium]
        viewModel.toggleQuickFocus(done)
        let start = viewModel.date(for: 0)
        let existing = try XCTUnwrap(viewModel.scheduleFocusAtCurrentTime(booked, referenceDate: start))
        let expected = [high.id, once.id, daily.id, medium.id, low.id, high.id]

        let standardPlan = viewModel.proposeFocusSchedule(from: start, maximumConsecutiveSameCategory: 5)
        XCTAssertEqual(standardPlan.map(\.focusID), expected)
        let roundPlan = viewModel.proposeFocusSchedule(from: start, oneSessionPerRound: true)
        XCTAssertEqual(roundPlan.map(\.focusID), expected)

        let quickProposal = try XCTUnwrap(roundPlan.first { $0.focusID == once.id })
        XCTAssertEqual(viewModel.category(for: quickProposal.categoryID)?.name, "Focus")
        let dailyProposal = try XCTUnwrap(roundPlan.first { $0.focusID == daily.id })
        XCTAssertEqual(dailyProposal.categoryID, category.id)
        XCTAssertEqual([quickProposal.duration, dailyProposal.duration], [1, 1])
        let duplicate = FocusScheduleProposal(focusID: once.id, categoryID: quickProposal.categoryID,
                                              startIndex: 40, duration: 1)
        XCTAssertFalse(viewModel.applyFocusSchedule(roundPlan + [duplicate], from: start))
        XCTAssertEqual(viewModel.tasks, [existing])

        XCTAssertTrue(viewModel.applyFocusSchedule(roundPlan, from: start))
        XCTAssertTrue(viewModel.proposeFocusSchedule(from: start, oneSessionPerRound: true).isEmpty)
        let dailyTask = try XCTUnwrap(viewModel.tasks.first { $0.focusID == daily.id })
        viewModel.toggleCompletion(for: dailyTask)
        XCTAssertTrue(viewModel.completedQuickFocusesToday.contains { $0.id == daily.id })
        viewModel.endCurrentDay()
        let nextDay = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), oneSessionPerRound: true)
        XCTAssertEqual(nextDay.filter { $0.focusID == daily.id }.count, 1)
    }

    func testPlannerIncludesFocusAfterPriorityChangesFromZeroToOne() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        var focus = FocusItem(name: "Nueva prioridad", expectedMinutes: 30, proposedCategoryID: category.id, priority: 0)
        viewModel.focuses = [focus]

        XCTAssertTrue(viewModel.proposeFocusSchedule(from: viewModel.date(for: 0)).isEmpty)

        focus.priority = 1
        viewModel.updateFocus(focus)

        XCTAssertTrue(viewModel.proposeFocusSchedule(from: viewModel.date(for: 0)).contains { $0.focusID == focus.id })
    }

    func testPlannerSupportsMultipleAvoidedWindowsAndBreaks() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let focus = FocusItem(name: "Largo", expectedMinutes: 90, proposedCategoryID: category.id, priority: 3)
        viewModel.focuses = [focus]
        let firstAvoided = viewModel.date(for: 9)..<viewModel.date(for: 12)
        let secondAvoided = viewModel.date(for: 21)..<viewModel.date(for: 24)

        let proposals = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0),
                                                       maximumSessionMinutes: 15,
                                                       breakMinutes: 10,
                                                       avoiding: [firstAvoided, secondAvoided])

        XCTAssertFalse(proposals.contains { $0.startIndex < 12 && $0.startIndex + $0.duration > 9 })
        XCTAssertFalse(proposals.contains { $0.startIndex < 24 && $0.startIndex + $0.duration > 21 })
        for pair in zip(proposals, proposals.dropFirst()) where pair.0.startIndex + pair.0.duration <= pair.1.startIndex {
            XCTAssertGreaterThanOrEqual(pair.1.startIndex - (pair.0.startIndex + pair.0.duration), 2)
        }
    }

    func testReflowFocusScheduleAppliesUserOrderAndUpdatesTimes() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let first = FocusItem(name: "Primero", expectedMinutes: 30, proposedCategoryID: category.id, priority: 2)
        let second = FocusItem(name: "Segundo", expectedMinutes: 30, proposedCategoryID: category.id, priority: 1)
        viewModel.focuses = [first, second]
        let original = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), maximumSessionMinutes: 30)
        let reversed = Array(original.reversed())

        let reflowed = viewModel.reflowFocusSchedule(reversed, from: viewModel.date(for: 0), breakMinutes: 10)

        XCTAssertEqual(reflowed?.map(\.focusID), reversed.map(\.focusID))
        XCTAssertEqual(reflowed?.map(\.startIndex), [0, 8])
    }

    func testReflowFocusScheduleClosesGapAfterRemovingProposal() {
        let category = TaskCategory(name: "Trabajo", colorHex: "#3366FF")
        let (viewModel, cleanup) = makeViewModel(tasks: [])
        defer { cleanup() }
        viewModel.categories = [category]
        let focuses = (1...3).map {
            FocusItem(name: "Focus \($0)", expectedMinutes: 15, proposedCategoryID: category.id, priority: 1)
        }
        viewModel.focuses = focuses
        let original = viewModel.proposeFocusSchedule(from: viewModel.date(for: 0), maximumSessionMinutes: 15)
        let remaining = [original[0], original[2]]

        let reflowed = viewModel.reflowFocusSchedule(remaining, from: viewModel.date(for: 0), breakMinutes: 5)

        XCTAssertEqual(reflowed?.map(\.focusID), remaining.map(\.focusID))
        XCTAssertEqual(reflowed?.map(\.startIndex), [0, 4])
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

private final class FocusIdentityURLProtocol: URLProtocol {
    static var rows: [[String: Any]] = []
    static var createCount = 0
    static var didCreate: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.httpMethod == "POST" {
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 4096)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            if let row = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                Self.rows.append(row)
            }
            Self.createCount += 1
        }
        let data = (try? JSONSerialization.data(withJSONObject: request.httpMethod == "GET" ? Self.rows : [])) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
        if request.httpMethod == "POST" { Self.didCreate?() }
    }
    override func stopLoading() {}
}
