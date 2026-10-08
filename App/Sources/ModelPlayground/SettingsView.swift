import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var state

    var body: some View {
        @Bindable var state = state
        Form {
            Section("Storage") {
                LabeledContent("Models folder") {
                    HStack {
                        Text((state.modelsFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Change...") { state.chooseModelsFolder() }
                    }
                }
                Toggle("Include models from the Hugging Face cache", isOn: $state.includeHFCache)
                LabeledContent("Chats and history") {
                    Button("Show in Finder") { NSWorkspace.shared.open(AppState.dataDirectory) }
                }
            }
            Section {
                Picker("Free model memory when idle", selection: $state.idleUnloadMinutes) {
                    Text("After 2 minutes").tag(2)
                    Text("After 5 minutes").tag(5)
                    Text("After 15 minutes").tag(15)
                    Text("Never").tag(0)
                }
                Picker("Default engine", selection: $state.preferredEngine) {
                    Text("MLX (fast)").tag("mlx")
                    Text("AirLLM when the model supports it").tag("airllm")
                }
                Text("AirLLM runs full-precision Llama-style models (Llama 3.x, Mistral, TinyLlama, SmolLM2) by streaming one layer at a time from disk. It uses very little memory but generates about 0.2 tokens per second and caps prompts at 512 tokens. You can also switch engines per chat in the message box.")
                    .font(.caption).foregroundStyle(.secondary)
            } header: {
                Text("Inference")
            }
            Section {
                LabeledContent("Python") {
                    HStack {
                        Text((state.pythonPath as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose...") { state.choosePython() }
                    }
                }
                LabeledContent("Port") {
                    HStack {
                        TextField("Auto", value: $state.preferredPort, format: .number.grouping(.never))
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Text(state.preferredPort == 0 ? "automatic (now \(state.port))" : "fixed")
                            .foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Text(statusText).foregroundStyle(.secondary).lineLimit(2)
                    Spacer()
                    Button("Unload Model") { Task { await state.api.unload(); await state.refreshModels() } }
                        .disabled(state.serverState != .running)
                    Button("Restart Engine") { Task { await state.restartServer() } }
                }
                HStack {
                    Button(state.isInstallingEnv ? "Installing..." : "Reinstall Python Environment") { state.installEnvironment() }
                        .disabled(state.isInstallingEnv)
                    Spacer()
                }
            } header: {
                Text("Engine")
            } footer: {
                Text("The engine is a local Python server using mlx-lm and AirLLM. It only listens on 127.0.0.1. Set the port to 0 to choose a free one automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Engine log") {
                ScrollView {
                    Text(state.serverLog.isEmpty ? "No output yet." : String(state.serverLog.suffix(10000)))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .defaultScrollAnchor(.bottom)
                .frame(height: 170)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .navigationTitle("Settings")
    }

    private var statusText: String {
        switch state.serverState {
        case .running: "Running on port \(state.port)" + (state.loadedModel.map { " · \($0) loaded" } ?? "")
        case .starting: "Starting..."
        case .stopped: "Stopped"
        case .failed(let m): m
        }
    }
}
