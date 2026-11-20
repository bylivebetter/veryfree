//
//  SessionsView.swift
//  Speakin
//

import AppKit
import SwiftUI

struct SessionsView: View {
    @ObservedObject var store: SessionStore
    @ObservedObject var controller: SessionController
    @State private var selectedID: String?

    private var selected: SessionRecord? {
        guard let selectedID else { return nil }
        return store.sessions.first { $0.id == selectedID }
    }

    var body: some View {
        NavigationSplitView {
            List(store.sessions, selection: $selectedID) { session in
                SessionRow(session: session, size: store.fileSize(for: session)).tag(session.id)
            }
            .navigationSplitViewColumnWidth(min: 280, ideal: 330)
            .overlay {
                if store.sessions.isEmpty {
                    ContentUnavailableView("No recordings yet", systemImage: "waveform.circle",
                                           description: Text("Press \(Hotkey.session.displayString) to record what your Mac is playing — a call, a video, anything — plus your microphone."))
                }
            }
            .safeAreaInset(edge: .bottom) {
                HStack {
                    Button { store.openFolder() } label: { Label("Open Folder", systemImage: "folder") }
                    Spacer()
                    Button { store.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                .padding(8)
                .background(.bar)
            }
        } detail: {
            if let session = selected {
                SessionDetail(session: session, store: store, controller: controller)
            } else {
                ContentUnavailableView("Select a recording", systemImage: "waveform",
                                       description: Text("Recordings are plain .m4a files in \(store.folderURL.path), with the transcript beside them as .txt."))
            }
        }
        .frame(minWidth: 780, minHeight: 460)
        .onAppear { store.refresh() }
    }
}

private struct SessionRow: View {
    let session: SessionRecord
    let size: Int64

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(session.displayName).lineLimit(1)
            HStack(spacing: 6) {
                Text(AppController.format(session.duration))
                Text("·")
                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                if session.includedMicrophone {
                    Image(systemName: "mic.fill").help(session.microphoneName.map { "Your voice from \($0)" } ?? "Microphone mixed in")
                }
                switch session.transcriptStatus {
                case .done: Image(systemName: "text.quote").help("Transcribed")
                case .running, .pending: ProgressView().controlSize(.mini)
                case .failed: Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                case .none, .empty: EmptyView()
                }
                if !session.capturedSystemAudio && session.status == .completed {
                    Image(systemName: "speaker.slash").foregroundStyle(.orange).help("No system audio was captured")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

private struct SessionDetail: View {
    let session: SessionRecord
    @ObservedObject var store: SessionStore
    @ObservedObject var controller: SessionController

    private var transcript: String? { store.transcript(for: session) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(session.createdAt, format: .dateTime.weekday(.wide).month().day().hour().minute())
                Text("·")
                Text(AppController.format(session.duration))
                Text("·")
                Text(session.sourceName)
                if session.includedMicrophone {
                    Text("·")
                    Label(session.microphoneName.map { "with your voice (\($0))" } ?? "with mic", systemImage: "mic.fill")
                        .labelStyle(.titleAndIcon)
                }
                Spacer()
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if !session.capturedSystemAudio && session.status == .completed {
                HStack {
                    Label("No system audio was captured — only the microphone.", systemImage: "speaker.slash")
                        .foregroundStyle(.orange)
                    Button("Open Audio Recording Settings…") { controller.openAudioRecordingSettings() }
                        .buttonStyle(.link)
                }
                .font(.callout)
            }
            if let error = session.error {
                Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.orange).textSelection(.enabled)
            }

            ScrollView {
                Group {
                    if let transcript, !transcript.isEmpty {
                        Text(transcript)
                            .font(.body)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        switch session.transcriptStatus {
                        case .running, .pending:
                            HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Transcribing…") }
                        case .failed:
                            Text("Transcription failed.").foregroundStyle(.secondary)
                        case .empty:
                            Text("No speech was detected in this recording.").foregroundStyle(.secondary)
                        default:
                            Text("No transcript. Use Transcribe to make one.").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding(14)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
        }
        .padding(16)
        .toolbar {
            ToolbarItemGroup {
                Button { store.open(session) } label: { Label("Play", systemImage: "play.fill") }
                    .help("Open the recording in your audio player")
                Button { store.reveal(session) } label: { Label("Reveal", systemImage: "folder") }
                    .help("Show the .m4a in Finder")
                Button { controller.transcribeSession(session) } label: { Label("Transcribe", systemImage: "text.quote") }
                    .disabled(session.transcriptStatus == .running || session.transcriptStatus == .pending)
                    .help("Transcribe on this Mac and save a .txt beside the recording")
                if let transcript, !transcript.isEmpty {
                    Button { Paster.copy(transcript) } label: { Label("Copy Transcript", systemImage: "doc.on.doc") }
                }
                Button(role: .destructive) { store.trash(session) } label: { Label("Move to Trash", systemImage: "trash") }
                    .help("Move the recording and its transcript to the Trash")
            }
        }
    }
}
