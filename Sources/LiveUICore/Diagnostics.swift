import Foundation

/// Produces the human-readable unified diff shown after a mutation (§28,
/// §45: "what did the tool just do to my code?").
///
/// Renders `git diff`-style hunks (a few lines of context around each
/// change, `@@ ... @@` headers) rather than the whole file — a mutation
/// that changes one line of a 500-line file should not print 500 lines.
public enum Diagnostics {

    private static let contextLines = 3

    public static func unifiedDiff(old: String, new: String, filePath: String) -> String {
        let oldLines = old.components(separatedBy: "\n")
        let newLines = new.components(separatedBy: "\n")
        let ops = numberedLineDiff(oldLines, newLines)
        let hunks = buildHunks(from: ops)

        guard !hunks.isEmpty else { return "" }

        var output = "--- \(filePath)\n+++ \(filePath)\n"
        for hunk in hunks {
            output += hunk.header + "\n"
            for op in hunk.ops {
                switch op.kind {
                case .equal: output += "  \(op.text)\n"
                case .delete: output += "- \(op.text)\n"
                case .insert: output += "+ \(op.text)\n"
                }
            }
        }
        return output
    }

    private enum OpKind {
        case equal, delete, insert
    }

    private struct NumberedOp {
        let kind: OpKind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }

    private struct Hunk {
        let header: String
        let ops: [NumberedOp]
    }

    /// Groups changed lines into hunks, each padded with `contextLines` of
    /// unchanged surrounding lines, merging hunks whose padded ranges
    /// overlap — the same shape `git diff` output has.
    private static func buildHunks(from ops: [NumberedOp]) -> [Hunk] {
        let changedIndices = ops.indices.filter {
            if case .equal = ops[$0].kind { return false }
            return true
        }
        guard !changedIndices.isEmpty else { return [] }

        var ranges: [ClosedRange<Int>] = []
        for i in changedIndices {
            let lower = max(0, i - contextLines)
            let upper = min(ops.count - 1, i + contextLines)
            if let last = ranges.last, lower <= last.upperBound + 1 {
                ranges[ranges.count - 1] = last.lowerBound...max(last.upperBound, upper)
            } else {
                ranges.append(lower...upper)
            }
        }

        return ranges.map { range in
            let slice = Array(ops[range])
            let oldStart = slice.first(where: { $0.oldLine != nil })?.oldLine ?? 0
            let newStart = slice.first(where: { $0.newLine != nil })?.newLine ?? 0
            let oldCount = slice.filter { if case .insert = $0.kind { return false }; return true }.count
            let newCount = slice.filter { if case .delete = $0.kind { return false }; return true }.count
            let header = "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            return Hunk(header: header, ops: slice)
        }
    }

    /// A minimal LCS-based line diff, annotated with 1-indexed line numbers
    /// on both sides (nil on the side a line doesn't exist on). Good enough
    /// for the small, precisely targeted changes `MutationEngine` produces
    /// (§13); not a general-purpose diff algorithm.
    private static func numberedLineDiff(_ a: [String], _ b: [String]) -> [NumberedOp] {
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

        var ops: [NumberedOp] = []
        var i = 0, j = 0
        while i < n && j < m {
            if a[i] == b[j] {
                ops.append(NumberedOp(kind: .equal, text: a[i], oldLine: i + 1, newLine: j + 1)); i += 1; j += 1
            } else if lengths[i + 1][j] >= lengths[i][j + 1] {
                ops.append(NumberedOp(kind: .delete, text: a[i], oldLine: i + 1, newLine: nil)); i += 1
            } else {
                ops.append(NumberedOp(kind: .insert, text: b[j], oldLine: nil, newLine: j + 1)); j += 1
            }
        }
        while i < n { ops.append(NumberedOp(kind: .delete, text: a[i], oldLine: i + 1, newLine: nil)); i += 1 }
        while j < m { ops.append(NumberedOp(kind: .insert, text: b[j], oldLine: nil, newLine: j + 1)); j += 1 }
        return ops
    }
}
