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
                        TranscriptDetailView(transcript: transcript) {
                            transcripts = TranscriptStore.list()
                        }
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
            case .paused:
                Label("Paused", systemImage: "pause.fill")
            case .stopping:
                Label("Finishing up…", systemImage: "hourglass")
            case .enhancing:
                VStack(alignment: .leading, spacing: 6) {
                    Label("Enhancing transcript…", systemImage: "sparkles")
                        .symbolEffect(.pulse)
                    if let progress = controller.enhancementProgress {
                        ProgressView(value: progress)
                    }
                }
            case .idle:
                EmptyView()
            }
        }
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }

    private var recordButton: some View {
        HStack(spacing: 24) {
            if controller.isSessionActive {
                Button {
                    if controller.state == .paused {
                        controller.resumeRecording()
                    } else {
                        controller.pauseRecording()
                    }
                } label: {
                    Image(systemName: controller.state == .paused ? "play.fill" : "pause.fill")
                        .font(.title2)
                        .frame(width: 56, height: 56)
                        .background(.thinMaterial, in: Circle())
                }
                .accessibilityLabel(controller.state == .paused ? "Resume recording" : "Pause recording")
            }

            Button {
                controller.toggleRecording()
            } label: {
                Image(systemName: controller.isSessionActive ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(controller.isSessionActive ? Color.red : Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(
                controller.state == .preparing
                    || controller.state == .downloadingModel
                    || controller.state == .recovering
                    || controller.state == .stopping
                    || controller.state == .enhancing
            )
            .accessibilityLabel(controller.isSessionActive ? "Stop recording" : "Start recording")
        }
        .padding(.bottom, 8)
    }
}

struct TranscriptDetailView: View {
    @State private var transcript: Transcript
    private let onUpdate: () -> Void
    @State private var bodyText = ""
    @State private var showingOriginal = false
    @State private var showingRename = false
    @State private var renameText = ""
    @State private var renameErrorMessage: String?

    init(transcript: Transcript, onUpdate: @escaping () -> Void) {
        _transcript = State(initialValue: transcript)
        self.onUpdate = onUpdate
    }

    var body: some View {
        ScrollView {
            Text(bodyText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle(transcript.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Rename", systemImage: "pencil") {
                renameText = transcript.title
                showingRename = true
            }
            if transcript.hasOriginal {
                Button("View original", systemImage: "doc.text.magnifyingglass") {
                    showingOriginal = true
                }
            }
            ShareLink(item: transcript.url)
        }
        .alert("Rename Transcript", isPresented: $showingRename) {
            TextField("Title", text: $renameText)
            Button("Rename") {
                do {
                    transcript = try TranscriptStore.rename(transcript, to: renameText)
                    onUpdate()
                } catch {
                    renameErrorMessage = error.localizedDescription
                }
            }
            Button("Cancel", role: .cancel) {}
        }
        .alert(
            "Couldn't Rename",
            isPresented: Binding(
                get: { renameErrorMessage != nil },
                set: { if !$0 { renameErrorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(renameErrorMessage ?? "")
        }
        .sheet(isPresented: $showingOriginal) {
            NavigationStack {
                ScrollView {
                    Text(TranscriptStore.loadOriginal(transcript) ?? "")
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .textSelection(.enabled)
                }
                .navigationTitle("Original transcript")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    Button("Done") { showingOriginal = false }
                }
            }
        }
        .task { bodyText = TranscriptStore.load(transcript) }
    }
}

#Preview {
    ContentView()
}
