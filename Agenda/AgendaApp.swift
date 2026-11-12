//
//  AgendaApp.swift
//  Agenda
//
//  Created by Antonio Muñoz on 22/11/25.
//

import SwiftUI

@main
struct AgendaApp: App {
    @MainActor static let blockAlertScheduler = BlockAlertScheduler()
    @MainActor static let schedule = ScheduleViewModel()

    init() {
        AgendaShortcuts.updateAppShortcutParameters()
    }

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: Self.schedule)
        }
    }
}
