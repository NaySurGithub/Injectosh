import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @AppStorage("selectedDLLPath") private var selectedDLLPath = ""
    @State private var processes: [GameProcess] = []
    @State private var detectedGame = false
    @State private var showingProcesses = false
    @AppStorage("selectedMinecraftPID") private var selectedPID = 0
    @State private var wines: [WineInstall] = []
    @AppStorage("selectedWinePath") private var selectedWine = ""
    @State private var prefixes: [URL] = []
    @AppStorage("selectedWinePrefix") private var selectedPrefix = ""
    @AppStorage("injectedDLLPaths") private var injectedDLLPathsStorage = ""
    @AppStorage("injectedDLLProcessID") private var injectedDLLProcessID = 0
    @State private var trackingRevision = UUID()
    @State private var showingPicker = false
    @State private var isRunning = false
    @State private var status = "Ready"
    @State private var lastRefresh = Date()
    private let timer = Timer.publish(every: 2, on: .main, in: .common).autoconnect()
    private var dllURL: URL? { selectedDLLPath.isEmpty ? nil : URL(fileURLWithPath: selectedDLLPath) }
    private var injectedDLLPaths: [String] { injectedDLLPathsStorage.split(separator: "\n").map(String.init) }

    var body: some View {
        ScrollView(.vertical) {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 12) {
                Image(systemName: "shippingbox.fill")
                    .font(.system(size: 25, weight: .semibold))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Injectosh").font(.system(size: 22, weight: .bold))
                    Text("Minecraft · macOS · Wine").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer()
                Circle().fill(detectedGame ? .green : .gray).frame(width: 8, height: 8)
                Text(detectedGame ? "Game detected" : "Game not found").font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary)
            }

            GroupBox("DLL File") {
                HStack(spacing: 12) {
                    Image(systemName: "doc.zipper").font(.title2).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                    Text(dllURL?.lastPathComponent ?? "No DLL selected").fontWeight(.medium).lineLimit(1)
                    Text(dllURL?.path ?? "Choose a file to continue").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Button("Choose…") { showingPicker = true }
                }.padding(.vertical, 4)
            }

            if !detectedGame {
            GroupBox("Process") {
                HStack {
                    Button {
                        showingProcesses.toggle()
                    } label: {
                        HStack {
                            Text(processes.first(where: { Int($0.pid) == selectedPID })
                                .map { "\($0.executable) · PID \($0.pid)" } ?? "Select a process…")
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.down")
                        }
                    }
                    .popover(isPresented: $showingProcesses) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 2) {
                                ForEach(processes) { process in
                                    Button {
                                        selectedPID = Int(process.pid)
                                        showingProcesses = false
                                    } label: {
                                        HStack {
                                            Text("\(process.executable) · PID \(process.pid)").lineLimit(1)
                                            Spacer()
                                            if Int(process.pid) == selectedPID { Image(systemName: "checkmark") }
                                        }.padding(6).contentShape(Rectangle())
                                    }.buttonStyle(.plain).help(process.path)
                                }
                            }.padding(8)
                        }.frame(width: 420, height: 280)
                    }
                    Button { refreshAll() } label: { Image(systemName: "arrow.clockwise") }.help("Refresh")
                }.padding(.vertical, 3)
            }
            }

            GroupBox("Wine / Blockintosh") {
                VStack(spacing: 9) {
                    HStack {
                        Label(wines.isEmpty ? "Wine not found" : "\(wines.count) installation(s) found", systemImage: wines.isEmpty ? "exclamationmark.triangle" : "checkmark.circle.fill")
                            .foregroundStyle(wines.isEmpty ? .orange : .green)
                        Spacer()
                        if !wines.isEmpty {
                            Picker("Wine", selection: $selectedWine) {
                                ForEach(wines) { wine in Text(wine.source).tag(wine.id) }
                            }.labelsHidden().frame(maxWidth: 190)
                        }
                    }
                    HStack {
                        Text("Prefix").foregroundStyle(.secondary)
                        Spacer()
                        Picker("Prefix", selection: $selectedPrefix) {
                            Text("No prefix found").tag("")
                            ForEach(prefixes, id: \.path) { prefix in Text(prefix.lastPathComponent).tag(prefix.path) }
                        }.labelsHidden().frame(maxWidth: 220)
                    }
                }.padding(.vertical, 3)
            }

            if !injectedDLLPaths.isEmpty {
                GroupBox("Injected DLLs") {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(injectedDLLPaths, id: \.self) { path in
                                HStack(spacing: 8) {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: path).lastPathComponent).font(.caption.weight(.medium)).lineLimit(1)
                                        Text(path).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                                    }
                                    Spacer(minLength: 4)
                                    Button("Uninject") { uninject(path) }
                                        .disabled(isRunning || selectedPID == 0 || selectedWine.isEmpty)
                                }
                            }
                        }
                    }.frame(maxHeight: 115)
                }
            }

            HStack {
                Text(status).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                Spacer()
                Text(lastRefresh, style: .time).font(.caption2).foregroundStyle(.tertiary)
            }
            Divider()
            HStack {
                Spacer()
                Button("Run") { runAction() }
                    .buttonStyle(.borderedProminent).tint(.mint)
                    .disabled(isRunning || dllURL == nil || selectedPID == 0 || selectedWine.isEmpty)
            }
        }
        .padding(22)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .fileImporter(isPresented: $showingPicker, allowedContentTypes: [.dll, .item], allowsMultipleSelection: false) { result in
            switch result {
            case .success(let urls): selectedDLLPath = urls.first?.path ?? ""; status = "DLL selected"
            case .failure(let error): status = error.localizedDescription
            }
        }
        .onAppear { refreshAll() }
        .onReceive(timer) { _ in refreshProcesses() }
    }

    private func refreshProcesses() {
        let games = Discovery.minecraftProcesses()
        detectedGame = !games.isEmpty
        processes = detectedGame ? games : Discovery.runningProcesses()
        if detectedGame {
            showingProcesses = false
            if !games.contains(where: { Int($0.pid) == selectedPID }) {
                selectedPID = Int(games[0].pid)
            }
        } else if !processes.contains(where: { Int($0.pid) == selectedPID }) {
            selectedPID = 0
        }
        if !detectedGame || injectedDLLProcessID != selectedPID {
            if !injectedDLLPathsStorage.isEmpty || injectedDLLProcessID != 0 {
                injectedDLLPathsStorage = ""
                injectedDLLProcessID = 0
                trackingRevision = UUID()
            }
        }
        lastRefresh = Date()
    }

    private func refreshAll() {
        refreshProcesses()
        wines = Discovery.wineInstalls()
        if !wines.contains(where: { $0.id == selectedWine }) { selectedWine = wines.first?.id ?? "" }
        prefixes = Discovery.prefixes()
        if !prefixes.contains(where: { $0.path == selectedPrefix }) { selectedPrefix = prefixes.first?.path ?? "" }
        Task { await reconcileInjectedDLLs() }
    }

    private func runAction() {
        guard let dllURL,
              let game = processes.first(where: { Int($0.pid) == selectedPID }),
              let wine = wines.first(where: { $0.id == selectedWine }) else {
            status = "Invalid selection or process has exited"
            return
        }
        let prefix = prefixes.first(where: { $0.path == selectedPrefix })
        let revision = trackingRevision
        isRunning = true
        status = "Injecting…"
        Task {
            do {
                try await InjectionAction.run(dll: dllURL, processID: game.pid, wine: wine.wine, prefix: prefix)
                refreshProcesses()
                guard detectedGame, selectedPID == Int(game.pid), trackingRevision == revision else {
                    status = "Game session ended or changed"
                    isRunning = false
                    return
                }
                injectedDLLProcessID = Int(game.pid)
                if !injectedDLLPaths.contains(dllURL.path) {
                    injectedDLLPathsStorage = (injectedDLLPaths + [dllURL.path]).joined(separator: "\n")
                }
                status = "Injection complete"
            } catch {
                status = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func uninject(_ path: String) {
        guard let game = processes.first(where: { Int($0.pid) == selectedPID }),
              let wine = wines.first(where: { $0.id == selectedWine }) else {
            status = "Invalid selection or process has exited"
            return
        }
        isRunning = true
        status = "Uninjecting…"
        Task {
            do {
                try await InjectionAction.uninject(dll: URL(fileURLWithPath: path), processID: game.pid,
                    wine: wine.wine, prefix: prefixes.first(where: { $0.path == selectedPrefix }))
                injectedDLLPathsStorage = injectedDLLPaths.filter { $0 != path }.joined(separator: "\n")
                status = "DLL unloaded"
            } catch {
                status = error.localizedDescription
            }
            isRunning = false
        }
    }

    private func reconcileInjectedDLLs() async {
        guard let game = processes.first(where: { Int($0.pid) == selectedPID }),
              let wine = wines.first(where: { $0.id == selectedWine }), !injectedDLLPaths.isEmpty else { return }
        let prefix = prefixes.first(where: { $0.path == selectedPrefix })
        let revision = trackingRevision
        let paths = injectedDLLPaths
        var stillLoaded: [String] = []
        for path in paths {
            do {
                if try await InjectionAction.isLoaded(dll: URL(fileURLWithPath: path), processID: game.pid,
                    wine: wine.wine, prefix: prefix) {
                    stillLoaded.append(path)
                }
            } catch {
                return
            }
        }
        guard trackingRevision == revision, selectedPID == Int(game.pid), injectedDLLPaths == paths else { return }
        injectedDLLPathsStorage = stillLoaded.joined(separator: "\n")
    }
}

private extension UTType {
    static let dll = UTType(filenameExtension: "dll") ?? .data
}
