//
//  OneThingService.swift
//  Agenda
//
//  Created by Codex on 09/12/25.
//

import Foundation

#if canImport(Supabase)
import Supabase
#endif

struct OneThingEntry: Identifiable, Codable, Hashable {
    let id: UUID
    var date: Date
    var series: String
    var url: String
    var details: String
    var reviewCount: Int

    init(id: UUID = UUID(),
         date: Date,
         series: String,
         url: String,
         details: String,
         reviewCount: Int = 0) {
        self.id = id
        self.date = date
        self.series = series
        self.url = url
        self.details = details
        self.reviewCount = reviewCount
    }

    var formattedDate: String {
        OneThingEntry.dateFormatter.string(from: date)
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func parse(dateString: String) -> Date {
        dateFormatter.date(from: dateString) ?? Date()
    }
}

protocol OneThingRemoteService {
    func fetchEntries() async throws -> [OneThingEntry]
    func createEntry(_ entry: OneThingEntry) async throws
    func updateEntry(_ entry: OneThingEntry) async throws
    func deleteEntry(_ entryID: UUID) async throws
}

private struct SupabaseOneThingRow: Codable {
    let id: Int64?
    let date: String?
    let series: String?
    let url: String?
    let details: String?
    let reviewCount: Int?
}

final class SupabaseOneThingService: OneThingRemoteService {
    static let shared = SupabaseOneThingService()

    #if canImport(Supabase)
    private let client: SupabaseClient
    #endif

    private let projectURL = URL(string: "https://gpylcuqovfyjbhpttcsc.supabase.co")!
    private let apiKey = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6ImdweWxjdXFvdmZ5amJocHR0Y3NjIiwicm9sZSI6ImFub24iLCJpYXQiOjE3NjQzNDYwOTcsImV4cCI6MjA3OTkyMjA5N30.M0pslu02-ZJPU-ypyNSGhafo2KheVqEOl_NPhYOkD5g"
    private let tableName = "OneThing"

    private init() {
        #if canImport(Supabase)
        client = SupabaseClient(supabaseURL: projectURL, supabaseKey: apiKey)
        #endif
    }

    func fetchEntries() async throws -> [OneThingEntry] {
        let rows = try await fetchRemoteRows()
        return rows.map { row in
            let identifier = uuid(from: row.id ?? 0)
            let dateValue = OneThingEntry.parse(dateString: row.date ?? "")
            return OneThingEntry(id: identifier,
                                 date: dateValue,
                                 series: row.series ?? "",
                                 url: row.url ?? "",
                                 details: row.details ?? "",
                                 reviewCount: row.reviewCount ?? 0)
        }
    }

    func createEntry(_ entry: OneThingEntry) async throws {
        let payload = payload(from: entry)
        #if canImport(Supabase)
        try await client.database.from(tableName).insert(payload).execute()
        #else
        try await performREST(method: "POST", body: payload)
        #endif
    }

    func updateEntry(_ entry: OneThingEntry) async throws {
        let payload = payload(from: entry)
        let identifier = numericID(for: entry)
        #if canImport(Supabase)
        try await client.database.from(tableName)
            .update(payload)
            .eq("id", value: identifier)
            .execute()
        #else
        try await performREST(method: "PATCH", body: payload, id: identifier)
        #endif
    }

    func deleteEntry(_ entryID: UUID) async throws {
        let identifier = numericID(from: entryID)
        #if canImport(Supabase)
        try await client.database.from(tableName).delete().eq("id", value: identifier).execute()
        #else
        try await performREST(method: "DELETE", id: identifier)
        #endif
    }

    // MARK: - Helpers

    private func fetchRemoteRows() async throws -> [SupabaseOneThingRow] {
        #if canImport(Supabase)
        let rows: [SupabaseOneThingRow] = try await client.database.from(tableName).select().execute().value
        return rows
        #else
        var components = URLComponents(url: projectURL, resolvingAgainstBaseURL: false)
        components?.path = "/rest/v1/\(tableName)"
        components?.queryItems = [URLQueryItem(name: "select", value: "*")]
        guard let url = components?.url else {
            throw NSError(domain: "SupabaseOneThingService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
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
            throw NSError(domain: "SupabaseOneThingService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
        let decoder = JSONDecoder()
        return try decoder.decode([SupabaseOneThingRow].self, from: data)
        #endif
    }

    private func payload(from entry: OneThingEntry) -> [String: Any] {
        [
            "id": numericID(for: entry),
            "date": isoDateString(from: entry.date),
            "series": entry.series,
            "url": entry.url,
            "details": entry.details,
            "reviewCount": entry.reviewCount
        ]
    }

    private func isoDateString(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func numericID(for entry: OneThingEntry) -> Int64 {
        numericID(from: entry.id)
    }

    private func numericID(from uuid: UUID) -> Int64 {
        let hex = uuid.uuidString.replacingOccurrences(of: "-", with: "")
        let prefix = hex.prefix(16)
        let unsigned = UInt64(prefix, radix: 16) ?? 0
        return Int64(bitPattern: unsigned)
    }

    private func uuid(from identifier: Int64) -> UUID {
        let unsigned = UInt64(bitPattern: identifier)
        let hex = String(format: "%016llx", unsigned)
        let repeated = hex + hex
        let parts = [
            String(repeated.prefix(8)),
            String(repeated.dropFirst(8).prefix(4)),
            String(repeated.dropFirst(12).prefix(4)),
            String(repeated.dropFirst(16).prefix(4)),
            String(repeated.dropFirst(20).prefix(12))
        ]
        let uuidString = parts.joined(separator: "-")
        return UUID(uuidString: uuidString) ?? UUID()
    }

    private func performREST(method: String, body: [String: Any]? = nil, id: Int64? = nil) async throws {
        var endpoint = projectURL.absoluteString + "/rest/v1/\(tableName)"
        if let id {
            endpoint += "?id=eq.\(id)"
        }
        guard let url = URL(string: endpoint) else {
            throw NSError(domain: "SupabaseOneThingService", code: -1, userInfo: [NSLocalizedDescriptionKey: "URL inválida"])
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
            throw NSError(domain: "SupabaseOneThingService", code: status, userInfo: [NSLocalizedDescriptionKey: "Error del servidor (\(status)): \(snippet)"])
        }
    }
}
