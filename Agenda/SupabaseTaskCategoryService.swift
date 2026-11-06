//
//  SupabaseTaskCategoryService.swift
//  Agenda
//
//  Created by Codex on 05/12/25.
//

import Foundation

struct SupabaseTaskCategoryRow: Identifiable, Codable {
    let id: String?
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

    private let projectURL = URL(string: "https://gpylcuqovfyjbhpttcsc.supabase.co")!
    private let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdweWxjdXFvdmZ5amJocHR0Y3NjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQzNDYwOTcsImV4cCI6MjA3OTkyMjA5N30.M0pslu02-ZJPU-ypyNSGhafo2KheVqEOl_NPhYOkD5g"
    private let tableName = "Categorias"

    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func importCategories() async throws -> [TaskCategory] {
        let rows = try await fetchRemoteRows()
        return rows.map { row in
            let identifier = UUID(uuidString: row.id ?? "") ?? UUID()
            return TaskCategory(id: identifier,
                         name: row.name ?? "Tipo remoto",
                         colorHex: row.colorHex ?? "#ffffff")
        }
    }

    func createCategory(_ category: TaskCategory) async throws {
        try await performREST(method: "POST", body: categoryPayload(from: category), expectedID: category.id)
    }

    func updateCategory(_ category: TaskCategory) async throws {
        try await performREST(method: "PATCH", body: categoryPayload(from: category), expectedID: category.id)
    }

    func deleteCategory(_ categoryID: UUID) async throws {
        try await performREST(method: "DELETE", expectedID: categoryID)
    }

    private func fetchRemoteRows() async throws -> [SupabaseTaskCategoryRow] {
        var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false)
        components?.path = "/rest/v1/\(tableName)"
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else {
            throw NSError(domain: "SupabaseTaskCategoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.httpMethod = "GET"
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
            throw NSError(domain: "SupabaseTaskCategoryService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
        let decoder = JSONDecoder()
        return try decoder.decode([SupabaseTaskCategoryRow].self, from: data)
    }

    private func categoryPayload(from category: TaskCategory) -> [String: Any] {
        [
            "id": category.id.uuidString,
            "name": category.name,
            "colorHex": category.colorHex
        ]
    }

    private func performREST(method: String, body: [String: Any]? = nil, expectedID: UUID) async throws {
        var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false)!
        components.path = "/rest/v1/\(tableName)"
        components.queryItems = [URLQueryItem(name: "select", value: "id")]
        if method != "POST" {
            components.queryItems?.append(URLQueryItem(name: "id", value: "eq.\(expectedID.uuidString)"))
        }
        guard let url = components.url else {
            throw NSError(domain: "SupabaseTaskCategoryService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.addValue("application/json", forHTTPHeaderField: "Content-Type")
        request.addValue("application/json", forHTTPHeaderField: "Accept")
        request.addValue("return=representation", forHTTPHeaderField: "Prefer")
        request.addValue(apiKey, forHTTPHeaderField: "apikey")
        request.addValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [])
        }
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, 200..<300 ~= httpResponse.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let snippet = String(data: data, encoding: .utf8) ?? "<sin cuerpo>"
            throw NSError(domain: "SupabaseTaskCategoryService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
        let affected = try JSONDecoder().decode([SupabaseTaskCategoryRow].self, from: data)
        guard affected.contains(where: { UUID(uuidString: $0.id ?? "") == expectedID }) else {
            throw NSError(domain: "SupabaseTaskCategoryService", code: -2, userInfo: [
                NSLocalizedDescriptionKey: "Supabase no confirmó el cambio del tipo. Comprueba los permisos de escritura (RLS) de la tabla Categorias."
            ])
        }
    }
}
