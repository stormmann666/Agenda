//
//  SupabaseFocusService.swift
//  Agenda
//
//  Created by Codex on 27/11/25.
//

import Foundation

#if canImport(Supabase)
import Supabase
#endif

struct SupabaseFocusRow: Identifiable, Codable {
    let id: Int64
    let descripcion: String?
    let tipoAsociado: String?
    let prioridad: Int?
    let duracionEstimanda: Int?
    let trabajado: Int?

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case descripcion = "Descripcion"
        case tipoAsociado = "Tipo Asociado"
        case prioridad = "Prioridad"
        case duracionEstimanda = "Duracion Estimada"
        case trabajado = "Trabajado"
    }
}

final class SupabaseFocusService: FocusRemoteService {
    static let shared = SupabaseFocusService()

    #if canImport(Supabase)
    private let client: SupabaseClient
    #endif

    private let projectURL = URL(string: "https://gpylcuqovfyjbhpttcsc.supabase.co")!
    private let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdweWxjdXFvdmZ5amJocHR0Y3NjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQzNDYwOTcsImV4cCI6MjA3OTkyMjA5N30.M0pslu02-ZJPU-ypyNSGhafo2KheVqEOl_NPhYOkD5g"

    private init() {
        #if canImport(Supabase)
        client = SupabaseClient(supabaseURL: projectURL, supabaseKey: apiKey)
        #endif
    }

    func importFocuses() async throws -> [FocusItem] {
        let rows = try await fetchRemoteRows()
        return rows.map { row in
            FocusItem(id: UUID(),
                      name: row.descripcion ?? "Focus remoto",
                      expectedMinutes: row.duracionEstimanda,
                      actualMinutes: row.trabajado ?? 0,
                      taskIDs: [],
                      priority: row.prioridad ?? 0)
        }
    }

    func exportFocuses(_ focuses: [FocusItem]) async throws {
        // Placeholder
    }

    func createFocus(_ focus: FocusItem) async throws {
        // Placeholder
    }

    func updateFocus(_ focus: FocusItem) async throws {
        // Placeholder
    }

    func deleteFocus(_ focusID: UUID) async throws {
        // Placeholder
    }

    func fetchRemoteRows() async throws -> [SupabaseFocusRow] {
        #if canImport(Supabase)
        let rows: [SupabaseFocusRow] = try await client.database.from("focuses").select().execute().value
        return rows
        #else
        guard let url = URL(string: projectURL.absoluteString + "/rest/v1/Focuses?select=*") else {
            throw NSError(domain: "SupabaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
            throw NSError(domain: "SupabaseService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
        let decoder = JSONDecoder()
        return try decoder.decode([SupabaseFocusRow].self, from: data)
        #endif
    }

    private func numericID(for focus: FocusItem) -> String {
        let hex = focus.id.uuidString.replacingOccurrences(of: "-", with: "")
        return String(hex.prefix(16))
    }

    private func focusPayload(from focus: FocusItem) -> [String: Any] {
        return [
            "id": numericID(for: focus),
            "Descripcion": focus.name,
            "Prioridad": focus.priority,
            "Duracion Estimada": focus.expectedMinutes ?? 0,
            "Trabajado": focus.actualMinutes ?? 0
        ]
    }

    private func performREST(method: String, body: [String: Any]? = nil, id: String? = nil) async throws {
        var endpoint = projectURL.absoluteString + "/rest/v1/focuses"
        if let id = id {
            endpoint += "?id=eq.\(id)"
        }
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "SupabaseService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw NSError(domain: "SupabaseService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status))"])
        }
    }
}
