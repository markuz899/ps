import Foundation

/// Start offsets of every line, kept up to date incrementally after each edit so that
/// "offset -> line number" stays a binary search even on very large files.
public final class LineIndex {
    public private(set) var starts: [Int] = [0]

    public init() {}

    public var lineCount: Int { starts.count }

    public func rebuild(_ text: NSString) {
        starts = [0]
        appendStarts(in: text, range: NSRange(location: 0, length: text.length))
    }

    /// `edited` is the range in the new text; `delta` is the change in length.
    public func update(_ text: NSString, edited: NSRange, delta: Int) {
        let oldEnd = NSMaxRange(edited) - delta
        // Drop line starts produced by newlines inside the replaced range: (location, oldEnd].
        let lower = firstIndex(greaterThan: edited.location)
        let upper = firstIndex(greaterThan: oldEnd)
        var replacement: [Int] = []
        scan(text, range: edited) { replacement.append($0) }
        for index in upper..<starts.count { starts[index] += delta }
        starts.replaceSubrange(lower..<upper, with: replacement)
    }

    /// 0-based line containing `offset`.
    public func line(at offset: Int) -> Int {
        max(0, firstIndex(greaterThan: offset) - 1)
    }

    public func start(ofLine line: Int) -> Int {
        starts[min(max(0, line), starts.count - 1)]
    }

    private func firstIndex(greaterThan value: Int) -> Int {
        var low = 0
        var high = starts.count
        while low < high {
            let mid = (low + high) / 2
            if starts[mid] > value { high = mid } else { low = mid + 1 }
        }
        return low
    }

    private func appendStarts(in text: NSString, range: NSRange) {
        scan(text, range: range) { starts.append($0) }
    }

    private func scan(_ text: NSString, range: NSRange, _ found: (Int) -> Void) {
        let chunk = 65_536
        var buffer = [unichar](repeating: 0, count: chunk)
        var location = range.location
        let end = NSMaxRange(range)
        while location < end {
            let length = min(chunk, end - location)
            text.getCharacters(&buffer, range: NSRange(location: location, length: length))
            for i in 0..<length where buffer[i] == 10 {
                found(location + i + 1)
            }
            location += length
        }
    }
}
