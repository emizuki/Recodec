import Foundation

public enum OutputNamer {
    public static func outputURL(forInput input: URL, container: Container, fileExists: (URL) -> Bool) -> URL {
        let dir = input.deletingLastPathComponent()
        let base = input.deletingPathExtension().lastPathComponent
        let ext = container.fileExtension
        func candidate(_ name: String) -> URL {
            dir.appendingPathComponent(name).appendingPathExtension(ext)
        }
        let first = candidate(base)
        if first != input && !fileExists(first) { return first }
        var n = 1
        while true {
            let name = (n == 1) ? "\(base) (converted)" : "\(base) (converted \(n))"
            let url = candidate(name)
            if url != input && !fileExists(url) { return url }
            n += 1
        }
    }
}
