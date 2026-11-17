import Foundation

enum InjectionAction {
    static func run(dll: URL, processID: Int32, wine: URL, prefix: URL?) async throws {
        _ = try await execute("inject", dll: dll, processID: processID, wine: wine, prefix: prefix)
    }

    static func uninject(dll: URL, processID: Int32, wine: URL, prefix: URL?) async throws {
        _ = try await execute("uninject", dll: dll, processID: processID, wine: wine, prefix: prefix)
    }

    static func isLoaded(dll: URL, processID: Int32, wine: URL, prefix: URL?) async throws -> Bool {
        let output = try await execute("status", dll: dll, processID: processID, wine: wine, prefix: prefix)
        return output == "ok loaded"
    }

    private static func execute(_ command: String, dll: URL, processID: Int32, wine: URL, prefix: URL?) async throws -> String {
        guard FileManager.default.isReadableFile(atPath: dll.path), dll.pathExtension.lowercased() == "dll" else {
            throw failure("DLL file is missing or unreadable.")
        }
        guard FileManager.default.isExecutableFile(atPath: wine.path) else {
            throw failure("Wine executable is missing or not executable.")
        }
        guard kill(processID, 0) == 0 else { throw failure("The selected game process has exited.") }
        guard let helper = Bundle.module.url(forResource: "InjectoshInjector", withExtension: "exe"),
              FileManager.default.isReadableFile(atPath: helper.path) else {
            throw failure("Injectosh helper is missing. Rebuild the app with Scripts/package-app.sh.")
        }
        let dllPath = "Z:" + dll.standardizedFileURL.path.replacingOccurrences(of: "/", with: "\\")
        var environment = ProcessInfo.processInfo.environment
        environment["WINEDEBUG"] = "-all"
        if let prefix { environment["WINEPREFIX"] = prefix.path }

        let process = Process()
        process.executableURL = wine
        process.arguments = [helper.path, command, dllPath]
        process.environment = environment
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let message = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            guard process.terminationStatus == 0 else {
                throw failure(message.isEmpty ? "Injector helper exited with code \(process.terminationStatus)." : message)
            }
            guard message.hasPrefix("ok ") else {
                throw failure(message.isEmpty ? "The injector helper returned no result." : message)
            }
            return message
        } catch let error as NSError where error.domain == "Injectosh" {
            throw error
        } catch {
            throw failure("Could not start Wine: \(error.localizedDescription)")
        }
    }

    private static func failure(_ message: String) -> NSError {
        NSError(domain: "Injectosh", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
