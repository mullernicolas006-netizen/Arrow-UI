import Foundation

/// Newline-delimited JSON framing shared by `BridgeClient` (runs inside the
/// app under development) and `BridgeServer` (runs inside the LiveUI
/// desktop app). Kept intentionally simple — no length prefixes, no binary
/// framing — so a connection can be eyeballed with `nc localhost <port>`
/// while debugging (§56: performance/dev-experience over cleverness here).
enum Framing {
    static func encode(_ data: Data) -> Data {
        var framed = data
        framed.append(0x0A)
        return framed
    }

    /// Pulls every complete (newline-terminated) line out of `buffer`,
    /// leaving any trailing partial line in place for the next read.
    static func extractLines(from buffer: inout Data) -> [Data] {
        var lines: [Data] = []
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            lines.append(buffer[buffer.startIndex..<newlineIndex])
            buffer.removeSubrange(buffer.startIndex...newlineIndex)
        }
        return lines
    }
}
