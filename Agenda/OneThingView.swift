//
//  OneThingView.swift
//  Agenda
//
//  Created by Codex on 09/12/25.
//

import SwiftUI

struct OneThingView: View {
    @StateObject private var viewModel = OneThingViewModel()
    @State private var newSeries: String = ""
    @State private var newURL: String = ""
    @State private var newDescription: String = ""

    var body: some View {
        NavigationStack {
            Form {
                navigationSection
                currentEntrySection
                creationSection
                if let error = viewModel.errorMessage {
                    Section("Error") {
                        Text(error)
                            .foregroundColor(.red)
                    }
                }
                if let status = viewModel.statusMessage {
                    Section("Estado") {
                        Text(status)
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("OneThing")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.isLoading {
                        ProgressView()
                    } else {
                        Button {
                            Task { await viewModel.loadEntries() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                }
            }
            .task {
                await viewModel.loadEntries()
            }
        }
    }

    private var navigationSection: some View {
        Section("Fecha") {
            HStack {
                Button {
                    viewModel.goToPreviousDay()
                    syncInputsWithCurrentEntry()
                } label: {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)

                Spacer()
                Text(viewModel.displayDate)
                    .font(.headline)
                Spacer()

                Button {
                    viewModel.goToNextDay()
                    syncInputsWithCurrentEntry()
                } label: {
                    Image(systemName: "chevron.right")
                }
                .buttonStyle(.borderless)
            }
        }
    }

    private var currentEntrySection: some View {
        Section("Detalle") {
            if let entry = viewModel.currentEntry {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Serie: \(entry.series)")
                    if let url = URL(string: entry.url), !entry.url.isEmpty {
                        Link(entry.url, destination: url)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else if !entry.url.isEmpty {
                        Text(entry.url)
                            .font(.callout)
                            .foregroundColor(.secondary)
                    }
                    Text(entry.details)
                        .font(.body)
                    HStack {
                        Text("Repasos: \(entry.reviewCount)")
                        Spacer()
                        Button("+1 repaso") {
                            viewModel.incrementReviewCount()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    Button("Eliminar este OneThing", role: .destructive) {
                        viewModel.deleteCurrentEntry()
                    }
                }
            } else {
                Text("No hay registro para esta fecha.")
                    .foregroundColor(.secondary)
            }
        }
    }

    private var creationSection: some View {
        Group {
            if viewModel.isTodaySelected && viewModel.currentEntry == nil {
                Section("Crear OneThing de hoy") {
                    TextField("Serie", text: $newSeries)
                    TextField("URL", text: $newURL)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.URL)
                    TextEditor(text: $newDescription)
                        .frame(minHeight: 100)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8)
                                .stroke(Color.secondary.opacity(0.2))
                        )
                    Button("Guardar OneThing de hoy") {
                        viewModel.createEntry(series: newSeries, url: newURL, details: newDescription)
                        clearInputs()
                    }
                    .disabled(newSeries.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              newDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func clearInputs() {
        newSeries = ""
        newURL = ""
        newDescription = ""
    }

    private func syncInputsWithCurrentEntry() {
        if let entry = viewModel.currentEntry {
            newSeries = entry.series
            newURL = entry.url
            newDescription = entry.details
        } else {
            clearInputs()
        }
    }
}
