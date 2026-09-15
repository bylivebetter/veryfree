//
//  HistoryView.swift
//  Speakin
//

import AppKit
import SwiftUI

struct HistoryView: View {
    @ObservedObject var store: TranscriptionStore
    @ObservedObject var controller: AppController
    @State private var selectedID: String?
    @State private var query = ""

    private var filtered: [TranscriptionRecord] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return store.records }
        return store.records.filter { $0.text.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationSplitView {
            List(filtered, selection: $selectedID) { record in
                RecordRow(record: record).tag(record.id)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "Search transcriptions")
            .navigationSplitViewColumnWidth(min: 280, ideal: 340)
            .overlay {
                if filtered.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No transcriptions yet" : "No matches",
                                           systemImage: "text.quote",
                                           description: Text(query.isEmpty ? "Press \(controller.hotkey.displayString), speak, press it again." : "Try another search."))
                }
            }
        } detail: {
            if let id = selectedID, let record = store.record(withID: id) {
                RecordDetail(record: record, store: store, controller: controller)
            } else {
                ContentUnavailableView("Select a transcription", systemImage: "text.quote",
                                       description: Text("Every speech and its text is kept here — the last \(TranscriptionStore.maxRecordings) recordings and \(TranscriptionStore.maxTranscriptions) transcriptions."))
            }
        }
        .frame(minWidth: 760, minHeight: 460)
    }
}

private struct RecordRow: View {
    let record: TranscriptionRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(record.preview)
                .lineLimit(2)
                .foregroundStyle(record.status == .completed ? .primary : .secondary)
            HStack(spacing: 6) {
                Text(record.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                Text("·")
                Text(AppController.format(record.duration))
                if record.hasAudio {
                    Image(systemName: "waveform").help("Audio kept")
                }
                if record.status != .completed {
                    StatusBadge(status: record.status)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct StatusBadge: View {
    let status: TranscriptionRecord.Status

    var body: some View {
        Text(status.rawValue)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(color.opacity(0.18), in: Capsule())
            .foregroundStyle(color)
    }

    private var color: Color {
        switch status {
        case .failed: .orange
        case .completed: .green
        default: .blue
        }
    }
}

private struct RecordDetail: View {
    let record: TranscriptionRecord
    @ObservedObject var store: TranscriptionStore
    @ObservedObject var controller: AppController
    @State private var isEditing = false
    @State private var draft = ""
    @State private var learnedMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(record.createdAt, format: .dateTime.weekday(.wide).month().day().year().hour().minute())
                Text("·")
                Text(AppController.format(record.duration))
                if let locale = record.localeIdentifier {
                    Text("·")
                    Text(Locale.current.localizedString(forIdentifier: locale) ?? locale)
                }
                if let engine = record.engine.flatMap(SpeechEngineKind.init(rawValue:)) {
                    Text("·")
                    Text(engine.displayName)
                }
                if record.pasted {
                    Text("·")
                    Label("Pasted", systemImage: "checkmark").labelStyle(.titleAndIcon)
                }
                Spacer()
                if record.status != .completed { StatusBadge(status: record.status) }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if let error = record.error, record.status == .failed {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            }

            if let learnedMessage {
                Label(learnedMessage, systemImage: "graduationcap")
                    .foregroundStyle(.green)
            }

            if isEditing {
                TextEditor(text: $draft)
                    .font(.body)
                    .padding(8)
                    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
                Text("Fix any misheard names, then Save & Learn — Speakin remembers the correction for next time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(record.text.isEmpty ? "(nothing heard)" : record.text)
                        .font(.body)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let raw = record.rawText {
                        DisclosureGroup("Verbatim (before filler words were removed)") {
                            Text(raw)
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, 6)
                        }
                        .font(.callout)
                    }
                }
                .padding(14)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(16)
        .onChange(of: record.id) { _, _ in
            isEditing = false
            learnedMessage = nil
        }
        .toolbar {
            ToolbarItemGroup {
                if isEditing {
                    Button { saveEdit() } label: { Label("Save & Learn", systemImage: "graduationcap") }
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Save the text and learn the corrected names")
                    Button { isEditing = false } label: { Label("Cancel", systemImage: "xmark") }
                } else {
                    Button {
                        draft = record.text
                        learnedMessage = nil
                        isEditing = true
                    } label: { Label("Edit & Learn", systemImage: "pencil") }
                        .disabled(record.status != .completed)
                        .help("Correct misheard names; Speakin learns them")
                }
                Button { Paster.copy(record.text) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .disabled(record.text.isEmpty)
                    .help("Copy the text")
                Button { controller.retranscribe(record) } label: { Label("Re-transcribe", systemImage: "arrow.clockwise") }
                    .disabled(!record.hasAudio || record.status == .transcribing)
                    .help("Run the speech model on the recording again")
                Button {
                    if let url = store.audioURL(for: record) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                } label: { Label("Show Audio", systemImage: "folder") }
                    .disabled(!record.hasAudio)
                    .help("Reveal the recording in Finder")
                Button(role: .destructive) { store.delete(record) } label: { Label("Delete", systemImage: "trash") }
                    .help("Delete this transcription and its recording")
            }
        }
    }

    private func saveEdit() {
        let changes = TranscriptDiff.changes(from: record.text, to: draft)
        let learned = controller.vocabulary.learn(from: changes)
        var updated = record
        updated.text = draft
        store.save(updated)
        isEditing = false
        learnedMessage = learned.isEmpty
            ? "Saved."
            : "Learned: " + learned.map { "\($0.heard) → \($0.corrected)" }.joined(separator: ", ")
    }
}
