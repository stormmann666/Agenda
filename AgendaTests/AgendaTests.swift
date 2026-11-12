//
//  AgendaTests.swift
//  AgendaTests
//
//  Created by Antonio Muñoz on 23/11/25.
//

import Foundation
import Testing

struct AgendaTests {

    @Test func hostAppDeclaresCameraUsage() throws {
        let description = try #require(Bundle.main.object(forInfoDictionaryKey: "NSCameraUsageDescription") as? String)
        #expect(!description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func example() async throws {
        // Write your test here and use APIs like `#expect(...)` to check expected conditions.
    }

}
