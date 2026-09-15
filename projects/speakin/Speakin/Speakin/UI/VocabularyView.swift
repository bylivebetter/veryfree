//
//  VocabularyView.swift
//  Speakin
//

import SwiftUI

struct VocabularyView: View {
    @ObservedObject var vocabulary: VocabularyStore
    @State private var newWord = ""
    @State private var filter = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Add a name or term…", text: $newWord)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .disabled(newWord.trimmingCharacters(in: .whitespaces).isEmpty)
                Divider().frame(height: 18)
                TextField("Filter", text: $filter)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 160)
                Button {
                    Task { await vocabulary.rescan() }
                } label: {
                    Label(vocabulary.isScanning ? "Scanning…" : "Rescan Mac", systemImage: "arrow.clockwise")
                }
                .disabled(vocabulary.isScanning)
            }
            .padding(12)

            List {
                if !vocabulary.corrections.isEmpty {
                    Section("Corrections you taught") {
                        ForEach(vocabulary.corrections.sorted(by: { $0.key < $1.key }), id: \.key) { heard, right in
                            HStack {
                                Text(heard).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(right)
                                Spacer()
                                removeButton { vocabulary.removeCorrection(heard: heard) }
                            }
                        }
                    }
                }
                ForEach(VocabularyStore.Source.allCases, id: \.self) { source in
                    let items = entries(for: source)
                    if !items.isEmpty {
                        Section("\(source.label) (\(items.count))") {
                            ForEach(items) { entry in
                                HStack {
                                    Text(entry.text)
                                    Spacer()
                                    removeButton { vocabulary.remove(entry) }
                                }
                            }
                        }
                    }
                }
                if !hiddenIDs.isEmpty {
                    Section("Hidden (\(hiddenIDs.count))") {
                        ForEach(hiddenIDs, id: \.self) { id in
                            HStack {
                                Text(id).foregroundStyle(.secondary)
                                Spacer()
                                Button("Unhide") { vocabulary.unhide(id) }.buttonStyle(.borderless)
                            }
                        }
                    }
                }
            }

            Text("Speakin learns these on its own from your project folders, Xcode projects, installed apps, macOS learned spellings and your name (Documents, Desktop and Downloads are not scanned) — and from any transcription you correct in History. Names are passed to the speech model and used to fix misheard words.\(vocabulary.lastScan.map { " Last scan: \($0.formatted(date: .abbreviated, time: .shortened))." } ?? "")")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
        }
        .frame(minWidth: 480, minHeight: 400)
    }

    private var hiddenIDs: [String] {
        vocabulary.ignored.sorted().filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) }
    }

    private func entries(for source: VocabularyStore.Source) -> [VocabularyStore.Entry] {
        vocabulary.entries
            .filter { $0.source == source && !vocabulary.ignored.contains($0.id) }
            .filter { filter.isEmpty || $0.text.localizedCaseInsensitiveContains(filter) }
            .sorted { $0.text.localizedStandardCompare($1.text) == .orderedAscending }
    }

    private func add() {
        vocabulary.addManual(newWord)
        newWord = ""
    }

    private func removeButton(_ action: @escaping () -> Void) -> some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "xmark.circle")
        }
        .buttonStyle(.borderless)
        .help("Remove")
    }
}
