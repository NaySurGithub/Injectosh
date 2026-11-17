import AppKit
import Darwin
import Foundation

struct GameProcess: Identifiable, Hashable {
    let pid: Int32
    let executable: String
    let path: String
    var id: Int32 { pid }
}

struct WineInstall: Identifiable, Hashable {
    let wine: URL
    let source: String
    var id: String { wine.path }
}

enum Discovery {
    static func runningProcesses() -> [GameProcess] {
        var capacity = 256
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [] }
            if Int(count) >= capacity && capacity < 65_536 {
                capacity *= 2
                continue
            }
            return pids.prefix(min(Int(count), capacity)).compactMap { pid in
                guard pid > 0 else { return nil }
                var buffer = [CChar](repeating: 0, count: 4096)
                let path = proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 ? String(cString: buffer) : ""
                let name = path.isEmpty ? "Unknown process" : URL(fileURLWithPath: path).lastPathComponent
                return GameProcess(pid: pid, executable: name, path: path)
            }.sorted {
                let order = $0.executable.localizedCaseInsensitiveCompare($1.executable)
                return order == .orderedSame ? $0.pid < $1.pid : order == .orderedAscending
            }
        }
    }

    static func minecraftProcesses() -> [GameProcess] {
        var capacity = 256
        while true {
            var pids = [pid_t](repeating: 0, count: capacity)
            let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [] }
            if Int(count) < capacity { return processes(in: pids.prefix(Int(count))) }
            capacity *= 2
            if capacity > 32_768 { return processes(in: pids) }
        }
    }

    private static func processes<S: Sequence>(in pids: S) -> [GameProcess] where S.Element == pid_t {
        pids.compactMap { pid in
            guard pid > 0 else { return nil }
            let executablePath = processPath(pid)
            guard let executablePath else { return nil }
            return GameProcess(pid: pid, executable: "Minecraft.Windows.exe", path: executablePath)
        }
        .sorted { $0.pid < $1.pid }
    }

    private static func processPath(_ pid: pid_t) -> String? {
        var pathBuffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0 {
            let path = String(cString: pathBuffer)
            if URL(fileURLWithPath: path).lastPathComponent
                .localizedCaseInsensitiveCompare("Minecraft.Windows.exe") == .orderedSame {
                return path
            }
        }

        guard let argument = firstArgument(pid),
              argument.split(whereSeparator: { $0 == "/" || $0 == "\\" }).last
                .map(String.init)?.localizedCaseInsensitiveCompare("Minecraft.Windows.exe") == .orderedSame else {
            return nil
        }
        return argument
    }

    private static func firstArgument(_ pid: pid_t) -> String? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0,
              size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctl(&mib, u_int(mib.count), &buffer, &size, nil, 0) == 0 else { return nil }
        let bytes = buffer.prefix(size).map { UInt8(bitPattern: $0) }
        let data = Data(bytes)
        guard var cursor = data[MemoryLayout<Int32>.size...].firstIndex(of: 0) else { return nil }
        while cursor < data.count && data[cursor] == 0 { cursor += 1 }
        guard cursor < data.count else { return nil }
        let end = data[cursor...].firstIndex(of: 0) ?? data.endIndex
        guard end > cursor else { return nil }
        return String(data: data[cursor..<end], encoding: .utf8)
    }

    static func wineInstalls() -> [WineInstall] {
        var candidates: [(URL, String)] = []
        let environment = ProcessInfo.processInfo.environment
        if let custom = environment["CORTISOL_WINE"], !custom.isEmpty {
            candidates.append((URL(fileURLWithPath: custom), "CORTISOL_WINE"))
        }
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                candidates.append((URL(fileURLWithPath: String(directory)).appendingPathComponent("wine"), "PATH"))
            }
        }

        let apps = NSWorkspace.shared.runningApplications.compactMap { $0.bundleURL } + [
            URL(fileURLWithPath: "/Applications/Blockintosh.app"),
            URL(fileURLWithPath: "/Applications/Blockintosh-Beta.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Blockintosh.app"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Blockintosh-Beta.app")
        ]
        for app in apps where app.pathExtension == "app" {
            candidates.append((app.appendingPathComponent("Contents/Resources/backend/runtime/wine/bin/wine"), app.lastPathComponent))
            candidates.append((app.appendingPathComponent("Contents/Resources/backend/runtime/blockintosh-wine-3.0/Blockintosh Wine.app/Contents/MacOS/wine"), app.lastPathComponent))
            candidates.append((app.appendingPathComponent("Contents/Resources/backend/runtime/wine/Blockintosh Wine x86_64.app/Contents/MacOS/wine"), app.lastPathComponent))
        }

        var seen = Set<String>()
        return candidates.compactMap { url, source in
            guard seen.insert(url.standardizedFileURL.path).inserted,
                  FileManager.default.isExecutableFile(atPath: url.path) else { return nil }
            return WineInstall(wine: url.standardizedFileURL, source: source)
        }
    }

    static func prefixes() -> [URL] {
        let fileManager = FileManager.default
        let home = fileManager.homeDirectoryForCurrentUser
        let knownPrefixRoot = home.appendingPathComponent("Library/Application Support/BedrockOnMacOS/default/prefixes")
        if let entries = try? fileManager.contentsOfDirectory(at: knownPrefixRoot, includingPropertiesForKeys: [.contentModificationDateKey]) {
            let known = entries.filter { fileManager.fileExists(atPath: $0.appendingPathComponent("system.reg").path) }
            if !known.isEmpty { return sortPrefixes(known) }
        }

        var candidates = activeWinePrefixes()
        let defaultPrefix = home.appendingPathComponent(".wine")
        if fileManager.fileExists(atPath: defaultPrefix.appendingPathComponent("system.reg").path) {
            candidates.append(defaultPrefix)
        }
        return sortPrefixes(Array(Set(candidates.map(\.standardizedFileURL))))
    }

    private static func sortPrefixes(_ prefixes: [URL]) -> [URL] {
        prefixes.sorted {
            let a = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let b = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return a > b
        }
    }

    private static func activeWinePrefixes() -> [URL] {
        var capacity = 256
        var pids: [pid_t] = []
        while true {
            pids = [pid_t](repeating: 0, count: capacity)
            let count = proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.stride))
            guard count > 0 else { return [] }
            if Int(count) < capacity {
                pids = Array(pids.prefix(Int(count)))
                break
            }
            capacity *= 2
            if capacity > 32_768 { break }
        }

        return pids.compactMap { pid in
            guard pid > 0 else { return nil }
            var pathBuffer = [CChar](repeating: 0, count: 4096)
            guard proc_pidpath(pid, &pathBuffer, UInt32(pathBuffer.count)) > 0,
                  String(cString: pathBuffer).lowercased().contains("wineserver") else { return nil }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 0
            guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
            var arguments = [CChar](repeating: 0, count: size)
            guard sysctl(&mib, u_int(mib.count), &arguments, &size, nil, 0) == 0 else { return nil }
            let bytes = arguments.prefix(size).map { UInt8(bitPattern: $0) }
            let data = Data(bytes)
            let marker = Data("WINEPREFIX=".utf8)
            guard let range = data.range(of: marker),
                  range.lowerBound == 0 || data[range.lowerBound - 1] == 0 else { return nil }
            let value = data[range.upperBound...].prefix { $0 != 0 }
            guard let path = String(bytes: value, encoding: .utf8), !path.isEmpty else { return nil }
            return URL(fileURLWithPath: path)
        }
    }
}
