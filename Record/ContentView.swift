import SwiftUI

struct ContentView: View {
    @State private var controller = RecordingController()
    @State private var transcripts: [Transcript] = []

    var body: some View {
        NavigationStack {
            Group {
                if controller.state == .idle {
                    transcriptList
                } else {
                    liveTranscriptView
                }
            }
            .navigationTitle("Record")
            .safeAreaInset(edge: .bottom) {
                recordButton
            }
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { controller.errorMessage != nil },
                    set: { if !$0 { controller.errorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(controller.errorMessage ?? "")
            }
        }
        .task {
            await controller.recoverPendingRecordingsIfNeeded()
            transcripts = TranscriptStore.list()
        }
        .onChange(of: controller.lastSavedTranscript) { _, saved in
            if saved != nil { transcripts = TranscriptStore.list() }
        }
    }

    private var transcriptList: some View {
        Group {
            if transcripts.isEmpty {
                ContentUnavailableView(
                    "No Recordings",
                    systemImage: "waveform",
                    description: Text("Tap the record button to capture and transcribe audio. Everything stays on this device.")
                )
            } else {
                List {
                    ForEach(transcripts) { transcript in
                        NavigationLink(value: transcript.url) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(transcript.title)
                                    .font(.headline)
                                Text(transcript.date, format: .dateTime)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for offset in offsets {
                            TranscriptStore.delete(transcripts[offset])
                        }
                        transcripts = TranscriptStore.list()
                    }
                }
                .navigationDestination(for: URL.self) { url in
                    if let transcript = transcripts.first(where: { $0.url == url }) {
                        TranscriptDetailView(transcript: transcript)
                    }
                }
            }
        }
    }

    private var liveTranscriptView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                statusLabel
                Text("\(controller.finalizedText)\(Text(controller.volatileText).foregroundStyle(.secondary))")
                    .font(.body)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding()
        }
        .defaultScrollAnchor(.bottom)
    }

    private var statusLabel: some View {
        Group {
            switch controller.state {
            case .preparing:
                Label("Preparing…", systemImage: "hourglass")
            case .downloadingModel:
                Label("Downloading speech model (one-time)…", systemImage: "arrow.down.circle")
            case .recovering:
                Label("Recovering interrupted recording…", systemImage: "arrow.trianglehead.2.clockwise.rotate.90")
            case .recording:
                Label("Listening", systemImage: "waveform")
                    .symbolEffect(.variableColor.iterative)
            case .stopping:
                Label("Finishing up…", systemImage: "hourglass")
            case .idle:
                EmptyView()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var recordButton: some View {
        Button {
            controller.toggleRecording()
        } label: {
            Image(systemName: controller.isRecording ? "stop.fill" : "mic.fill")
                .font(.title)
                .frame(width: 72, height: 72)
                .background(controller.isRecording ? Color.red : Color.accentColor, in: Circle())
                .foregroundStyle(.white)
        }
        .disabled(
            controller.state == .preparing
                || controller.state == .downloadingModel
                || controller.state == .recovering
                || controller.state == .stopping
        )
        .padding(.bottom, 8)
        .accessibilityLabel(controller.isRecording ? "Stop recording" : "Start recording")
    }
}

struct TranscriptDetailView: View {
    let transcript: Transcript
    @State private var text = ""

    var body: some View {
        ScrollView {
            Text(text)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(transcript.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ShareLink(item: transcript.url)
        }
        .task { text = TranscriptStore.load(transcript) }
    }
}

#Preview {
    ContentView()
}
