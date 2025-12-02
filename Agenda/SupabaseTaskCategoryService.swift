//
//  SupabaseTaskCategoryService.swift
//  Agenda
//
//  Created by Codex on 05/12/25.
//

import Foundation

#if canImport(Supabase)
import Supabase
#endif

struct SupabaseTaskCategoryRow: Identifiable, Codable {
    let id: UUID?
    let name: String?
    let colorHex: String?

    enum CodingKeys: String, CodingKey {
        case id = "id"
        case name = "name"
        case colorHex = "colorHex"
    }
}

final class SupabaseTaskCategoryService: TaskCategoryRemoteService {
    static let shared = SupabaseTaskCategoryService()

    #if canImport(Supabase)
    private let client: SupabaseClient
    #endif

    private let projectURL = URL(string: "https://gpylcuqovfyjbhpttcsc.supabase.co")!
    private let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdweWxjdXFvdmZ5amJocHR0Y3NjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQzNDYwOTcsImV4cCI6MjA3OTkyMjA5N30.M0pslu02-ZJPU-ypyNSGhafo2KheVqEOl_NPhYOkD5g"
    private let tableName = "Categories"

    private init() {
        #if canImport(Supabase)
        client = SupabaseClient(supabaseURL: projectURL, supabaseKey: apiKey)
        #endif
    }

    func importCategories() async throws -> [TaskCategory] {
        let rows = try await fetchRemoteRows()
        return rows.map { row in
            TaskCategory(id: row.id ?? UUID(),
                         name: row.name ?? "Tipo remoto",
                         colorHex: row.colorHex ?? "#ffffff")
        }
    }

    func createCategory(_ category: TaskCategory) async throws {
        let payload = categoryPayload(from: category)
        #if canImport(Supabase)
        try await client.database.from(tableName.lowercased()).insert(payload).execute()
        #else
        try await performREST(method: "POST", body: payload)
        #endif
    }

    func updateCategory(_ category: TaskCategory) async throws {
        let payload = categoryPayload(from: category)
        #if canImport(Supabase)
        try await client.database.from(tableName.lowercased()).update(payload).eq("id", value: category.id.uuidString).execute()
        #else
        try await performREST(method: "PATCH", body: payload, id: category.id)
        #endif
    }

    func deleteCategory(_ categoryID: UUID) async throws {
        #if canImport(Supabase)
        try await client.database.from(tableName.lowercased()).delete().eq("id", value: categoryID.uuidString).execute()
        #else
        try await performREST(method: "DELETE", id: categoryID)
        #endif
    }

    private func fetchRemoteRows() async throws -> [SupabaseTaskCategoryRow] {
        #if canImport(Supabase)
        let rows: [SupabaseTaskCategoryRow] = try await client.database.from(tableName.lowercased()).select().execute().value
        return rows
        #else
        var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false)
        components?.path = "/rest/v1/\(tableName)"
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else {
            throw NSError(domain: "SupabaseTaskCategoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
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
            throw NSError(domain: "SupabaseTaskCategoryService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
        let decoder = JSONDecoder()
        return try decoder.decode([SupabaseTaskCategoryRow].self, from: data)
        #endif
    }

    private func categoryPayload(from category: TaskCategory) -> [String: Any] {
        [
            "id": category.id.uuidString,
            "name": category.name,
            "colorHex": category.colorHex
        ]
    }

    private func performREST(method: String, body: [String: Any]? = nil, id: UUID? = nil) async throws {
        var endpoint = projectURL.absoluteString + "/rest/v1/\(tableName)"
        if let id {
            endpoint += "?id=eq.\(id.uuidString)"
        }
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "SupabaseTaskCategoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
            throw NSError(domain: "SupabaseTaskCategoryService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
    }
}
