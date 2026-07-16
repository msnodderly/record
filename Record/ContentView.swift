import SwiftUI
import UIKit

struct ContentView: View {
    @State private var controller = RecordingController()
    @State private var transcripts: [Transcript] = []
    @State private var showingStopEnhancementDialog = false

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
                        NavigationLink(value: transcript) {
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
                // The pushed value is used directly rather than re-looked-up
                // in `transcripts`: a rename or enhancement changes the file's
                // URL, and a lookup by the stale URL would find nothing and
                // blank the screen. The detail view tracks changes to its own
                // transcript state.
                .navigationDestination(for: Transcript.self) { transcript in
                    TranscriptDetailView(transcript: transcript) {
                        transcripts = TranscriptStore.list()
                    }
                }
            }
        }
    }

    private var liveTranscriptView: some View {
        ScrollView {
            Text("\(controller.finalizedText)\(Text(controller.volatileText).foregroundStyle(.secondary))")
                .font(.body)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
        }
        .defaultScrollAnchor(.bottom)
        // The scroll view is anchored to the bottom of a potentially long
        // transcript, so the status has to sit outside it to stay visible.
        .safeAreaInset(edge: .top, spacing: 0) {
            statusLabel
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
                .padding(.vertical, 10)
                .background(.bar)
        }
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
                    Label(
                        controller.enhancementCancelRequested
                            ? "Stopping enhancement…"
                            : "Enhancing transcript…",
                        systemImage: "sparkles"
                    )
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
                if controller.state == .enhancing {
                    showingStopEnhancementDialog = true
                } else {
                    controller.toggleRecording()
                }
            } label: {
                Image(systemName: controller.isSessionActive ? "stop.fill" : "mic.fill")
                    .font(.title)
                    .frame(width: 72, height: 72)
                    .background(controller.isSessionActive ? Color.red : Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .disabled(recordButtonDisabled)
            .opacity(recordButtonDisabled ? 0.4 : 1)
            .accessibilityLabel(controller.isSessionActive ? "Stop recording" : "Start recording")
        }
        .padding(.bottom, 8)
        .confirmationDialog(
            "Enhancement in progress",
            isPresented: $showingStopEnhancementDialog,
            titleVisibility: .visible
        ) {
            Button("Stop Enhancing and Record", role: .destructive) {
                controller.stopEnhancingAndStartRecording()
            }
            Button("Keep Enhancing", role: .cancel) {}
        } message: {
            Text("Your transcript is already saved. Stopping skips the remaining polish — you can run Enhance later from the transcript — and starts a new recording.")
        }
    }

    private var recordButtonDisabled: Bool {
        controller.state == .preparing
            || controller.state == .downloadingModel
            || controller.state == .recovering
            || controller.state == .stopping
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
    @State private var isEnhancing = false
    @State private var enhancementTask: Task<Void, Never>?
    private let enhancer = TranscriptEnhancer()

    init(transcript: Transcript, onUpdate: @escaping () -> Void) {
        _transcript = State(initialValue: transcript)
        self.onUpdate = onUpdate
    }

    /// Enhancement is offered again as long as the pass never completed with
    /// a generated title: either no original was stashed (cancelled or failed
    /// early) or the file still carries its default "Recording" name
    /// (cancelled partway through).
    private var canEnhance: Bool {
        !transcript.hasOriginal || transcript.title.hasPrefix("Recording ")
    }

    var body: some View {
        ScrollView {
            Text(bodyText)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if isEnhancing {
                Label("Enhancing transcript…", systemImage: "sparkles")
                    .symbolEffect(.pulse)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal)
                    .padding(.vertical, 10)
                    .background(.bar)
            }
        }
        .navigationTitle(transcript.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            Button("Copy", systemImage: "doc.on.doc") {
                UIPasteboard.general.string = bodyText
            }
            Button("Rename", systemImage: "pencil") {
                renameText = transcript.title
                showingRename = true
            }
            if canEnhance {
                Button("Enhance", systemImage: "sparkles") {
                    runEnhancement()
                }
                .disabled(isEnhancing)
            }
            if transcript.hasOriginal {
                Button("View original", systemImage: "doc.text.magnifyingglass") {
                    showingOriginal = true
                }
            }
            ShareLink(item: transcript.url)
        }
        .onDisappear {
            enhancementTask?.cancel()
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

    /// Re-runs the text-only enhancement stages (cleanup, inferred speaker
    /// labels, title) on the saved transcript. The recording's audio journal
    /// is gone by now, so acoustic diarization is not part of a re-run.
    private func runEnhancement() {
        guard !isEnhancing else { return }
        isEnhancing = true
        let input = EnhancementInput(
            raw: transcript,
            rawText: bodyText,
            chunks: [],
            audioSegmentURLs: [],
            scratchDirectory: nil,
            recordedAt: transcript.date
        )
        let enhancer = self.enhancer
        enhancementTask = Task {
            let enhanced = await enhancer.enhance(input) {}
            if let enhanced {
                transcript = enhanced
                bodyText = TranscriptStore.load(enhanced)
                onUpdate()
            }
            isEnhancing = false
            enhancementTask = nil
        }
    }
}

#Preview {
    ContentView()
}
