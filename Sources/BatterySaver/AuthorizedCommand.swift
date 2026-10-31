import Foundation

/// Administrator prompts and cancellation handling belong to the UI, not the helper.
enum AuthorizedCommand {
    struct Outcome {
        var error: String?
        var cancelled = false
        var succeeded: Bool { error == nil && !cancelled }
    }

    static func run(executable: String, arguments: [String], completion: @escaping (Outcome) -> Void) {
        let command = ([executable] + arguments).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        let literal = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            process.arguments = ["-e", "do shell script \"\(literal)\" with administrator privileges"]
            let output = Pipe()
            process.standardError = output
            process.standardOutput = FileHandle.nullDevice
            var result = Outcome()
            do {
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                if process.terminationStatus != 0 {
                    let detail = String(decoding: data, as: UTF8.self)
                    result.cancelled = detail.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("(-128)")
                    if !result.cancelled { result.error = detail }
                }
            } catch { result.error = error.localizedDescription }
            DispatchQueue.main.async { completion(result) }
        }
    }
}
