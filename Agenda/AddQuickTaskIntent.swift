import AppIntents
import Foundation

struct AddQuickTaskIntent: AppIntent {
    static let title: LocalizedStringResource = "Añadir tarea simple"
    static let description = IntentDescription("Guarda una tarea pendiente en los Focus rápidos de Agenda.")

    @Parameter(title: "Nombre de la tarea", requestValueDialog: "¿Qué tarea quieres añadir?")
    var taskName: String

    static var parameterSummary: some ParameterSummary {
        Summary("Añadir la tarea \(\.$taskName)")
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let name = taskName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            throw $taskName.needsValueError()
        }

        let focus = AgendaApp.schedule.addFocus(name: name, kind: .once)
        return .result(dialog: "He añadido «\(focus.name)» a Agenda.")
    }
}

struct AgendaShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: AddQuickTaskIntent(),
            phrases: [
                "Add a task in \(.applicationName)",
                "Add task in \(.applicationName)"
            ],
            shortTitle: "Añadir tarea simple",
            systemImageName: "plus.circle"
        )
    }
}
