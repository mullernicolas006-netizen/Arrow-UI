import Foundation

/// Produces the human-readable unified diff shown after a mutation (§28,
/// §45: "what did the tool just do to my code?").
public enum Diagnostics {

    public static func unifiedDiff(old: String, new: String, filePath: String) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = lineDiff(oldLines, newLines)

        var output = "--- \(filePath)\n+++ \(filePath)\n"
        for op in ops {
            switch op {
            case .equal(let line): output += "  \(line)\n"
            case .delete(let line): output += "- \(line)\n"
            case .insert(let line): output += "+ \(line)\n"
            }
        }
        return output
    }

    private enum DiffOp {
        case equal(String)
        case delete(String)
        case insert(String)
    }

    /// A minimal LCS-based line diff. Good enough for the small, precisely
    /// targeted changes `MutationEngine` produces (§13); not a general-
    /// purpose diff algorithm and not intended to replace `git diff` for
    /// large hand-written changes.
    private static func lineDiff(_ a: [String], _ b: [String]) -> [DiffOp] {
        let n = a.count, m = b.count
        var lengths = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)

        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                if a[i] == b[j] {
                    lengths[i][j] = lengths[i + 1][j + 1] + 1
                } else {
                    lengths[i][j] = max(lengths[i + 1][j], lengths[i][j + 1])
                }
            }
        }

        var ops: [DiffOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(.equal(a[i])); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                ops.append(.delete(a[i])); i += 1
            } else {
                ops.append(.insert(b[j])); j += 1
            }
        }
        while i < n { ops.append(.delete(a[i])); i += 1 }
        while j < m { ops.append(.insert(b[j])); j += 1 }
        return ops
    }
}
