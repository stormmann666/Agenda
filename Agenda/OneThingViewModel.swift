//
//  OneThingViewModel.swift
//  Agenda
//
//  Created by Codex on 09/12/25.
//

import Foundation

@MainActor
final class OneThingViewModel: ObservableObject {
    @Published private(set) var entries: [OneThingEntry] = []
    @Published var selectedDate: Date
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var statusMessage: String?

    private let calendar: Calendar
    private let remoteService: OneThingRemoteService

    init(selectedDate: Date = Date(),
         calendar: Calendar = .current,
         remoteService: OneThingRemoteService = SupabaseOneThingService.shared) {
        self.calendar = calendar
        self.remoteService = remoteService
        self.selectedDate = calendar.startOfDay(for: selectedDate)
    }

    var currentEntry: OneThingEntry? {
        entry(for: selectedDate)
    }

    var isTodaySelected: Bool {
        calendar.isDateInToday(selectedDate)
    }

    var displayDate: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: selectedDate)
    }

    func loadEntries() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let fetched = try await remoteService.fetchEntries()
            entries = fetched.sorted { $0.date > $1.date }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func refreshSelectedDate() {
        selectedDate = calendar.startOfDay(for: selectedDate)
    }

    func goToPreviousDay() {
        if let newDate = calendar.date(byAdding: .day, value: -1, to: selectedDate) {
            selectedDate = calendar.startOfDay(for: newDate)
        }
    }

    func goToNextDay() {
        if let newDate = calendar.date(byAdding: .day, value: 1, to: selectedDate) {
            selectedDate = calendar.startOfDay(for: newDate)
        }
    }

    func incrementReviewCount() {
        guard var entry = currentEntry else { return }
        entry.reviewCount += 1
        applyLocalUpdate(entry)
        Task {
            await persistUpdate(entry)
        }
    }

    func createEntry(series: String, url: String, details: String) {
        let newEntry = OneThingEntry(date: selectedDate,
                                     series: series,
                                     url: url,
                                     details: details,
                                     reviewCount: 0)
        entries.append(newEntry)
        entries.sort { $0.date > $1.date }
        Task {
            await persistCreation(newEntry)
        }
    }

    func deleteCurrentEntry() {
        guard let entry = currentEntry else { return }
        entries.removeAll { $0.id == entry.id }
        Task {
            await persistDeletion(entry)
        }
    }

    func entry(for date: Date) -> OneThingEntry? {
        entries.first {
            calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    // MARK: - Persistence

    private func applyLocalUpdate(_ entry: OneThingEntry) {
        if let index = entries.firstIndex(where: { $0.id == entry.id }) {
            entries[index] = entry
            entries.sort { $0.date > $1.date }
        }
    }

    private func persistUpdate(_ entry: OneThingEntry) async {
        do {
            try await remoteService.updateEntry(entry)
            statusMessage = "Guardado"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func persistCreation(_ entry: OneThingEntry) async {
        do {
            try await remoteService.createEntry(entry)
            statusMessage = "Creado"
        } catch {
            errorMessage = error.localizedDescription
            entries.removeAll { $0.id == entry.id }
        }
    }

    private func persistDeletion(_ entry: OneThingEntry) async {
        do {
            try await remoteService.deleteEntry(entry.id)
            statusMessage = "Eliminado"
        } catch {
            errorMessage = error.localizedDescription
            entries.append(entry)
            entries.sort { $0.date > $1.date }
        }
    }
}
