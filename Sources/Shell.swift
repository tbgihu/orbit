import Foundation

/// Just enough shell grammar to find a line's simple commands and where their words are: quotes, escapes,
/// operators, assignments and redirections. A line using more (substitutions, subshells, groups, keywords,
/// here-documents) can't be read with certainty, so it gives nil and nothing is changed or inferred from it.
enum Shell {
    struct Word {
        /// Where it is in the line, in UTF-8 offsets.
        let range: Range<Int>
        /// Its value with quotes and escapes removed; nil when it expands something (`$x`, `${x}`, `$'…'`).
        let value: String?
        /// As written in the line.
        let text: String

        /// Whether it is an operand and can't be an option, even when what it expands to is unknown: it doesn't
        /// begin with `-`, and it is quoted or has a `/` as a path does (`"$dir"`, `$HOME/x`). A bare `$OPTS` could
        /// hold options.
        var isOperand: Bool {
            if let value { return !value.hasPrefix("-") }
            return !text.drop { "\"'$".contains($0) }.hasPrefix("-") && (text.hasPrefix("\"") || text.contains("/"))
        }

        /// The program a command word names: its last path component.
        var name: String? { value.map { ($0 as NSString).lastPathComponent } }
    }

    /// A simple command: its words, leading assignments and redirections left out.
    typealias Command = [Word]
    /// What runs between `;`, `&&`, `||`, `&` and line breaks: commands joined by pipes.
    typealias Step = [Command]

    static func steps(_ line: String) -> [Step]? {
        var lexer = Lexer(Array(line.utf8))
        var steps: [Step] = [], step: Step = [], command: Command = []
        var redirecting = false
        func endCommand() -> Bool {
            guard !command.isEmpty else { return false }
            step.append(command)
            command = []
            return true
        }
        while let token = lexer.next() {
            switch token {
            case .invalid: return nil
            case .redirect: redirecting = true
            case .word(let word, let assignment):
                if redirecting { redirecting = false; continue }
                if command.isEmpty {
                    if assignment { continue }
                    if let value = word.value, reserved.contains(value) { return nil }
                }
                command.append(word)
            case .pipe:
                guard !redirecting, endCommand() else { return nil }
            case .separator:
                guard !redirecting else { return nil }
                if !endCommand(), !step.isEmpty { return nil }      // `a | ;`
                if !step.isEmpty { steps.append(step); step = [] }
            }
        }
        guard !redirecting else { return nil }
        if !endCommand(), !step.isEmpty { return nil }
        if !step.isEmpty { steps.append(step) }
        return steps
    }

    /// Words that start compound commands, which this parser doesn't handle.
    private static let reserved: Set<String> = [
        "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "select",
        "function", "time", "coproc", "repeat", "foreach", "end", "!", "{", "}", "[[", "]]",
    ]

    /// `line` with each text inserted at its UTF-8 offset.
    static func inserting(_ insertions: [(at: Int, text: String)], into line: String) -> String {
        var bytes = Array(line.utf8)
        for insertion in insertions.sorted(by: { $0.at > $1.at }) {
            bytes.insert(contentsOf: Array(insertion.text.utf8), at: insertion.at)
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private enum Token {
        case word(Word, assignment: Bool)
        case redirect, pipe, separator, invalid
    }

    private struct Lexer {
        let b: [UInt8]
        var i = 0

        init(_ bytes: [UInt8]) { b = bytes }

        private func at(_ index: Int) -> UInt8? { index < b.count ? b[index] : nil }
        private func isOperator(_ c: UInt8) -> Bool { ";&|<>()\n \t".utf8.contains(c) }

        mutating func next() -> Token? {
            while let c = at(i) {
                if c == 32 || c == 9 { i += 1 }
                else if c == 92, at(i + 1) == 10 { i += 2 }                           // line continuation
                else if c == 35 { while let c = at(i), c != 10 { i += 1 } }         // # comment
                else { break }
            }
            guard let c = at(i) else { return nil }
            let n = at(i + 1)
            switch c {
            case 10: i += 1; return .separator
            case 59: i += 1; return n == 59 ? .invalid : .separator                 // ;;
            case 38:                                                                // &
                if n == 38 || n == 124 || n == 33 { i += 2; return .separator }     // && &| &!
                if n == 62 { i += at(i + 2) == 62 ? 3 : 2; return .redirect }       // &> &>>
                i += 1; return .separator
            case 124:                                                               // |
                if n == 124 { i += 2; return .separator }
                i += n == 38 ? 2 : 1; return .pipe
            case 60, 62: return redirect()
            case 40, 41: return .invalid                                            // ( )
            default: return word()
            }
        }

        /// `<`, `>`, `>>`, `>|`, `>!`, `>&`, `<&`, `<>`; here-documents and process substitution aren't supported.
        private mutating func redirect() -> Token {
            let c = b[i], n = at(i + 1)
            if c == 60, n == 60 || n == 40 { return .invalid }                    // << <(
            if c == 62, n == 40 { return .invalid }                               // >(
            i += 1
            if let n, c == 62 ? ">|!&".utf8.contains(n) : "&>".utf8.contains(n) { i += 1 }
            return .redirect
        }

        private mutating func word() -> Token {
            let start = i
            var value: [UInt8] = [], expands = false
            while let c = at(i), !isOperator(c) {
                switch c {
                case 92:                                                            // \x
                    guard let n = at(i + 1) else { return .invalid }
                    if n != 10 { value.append(n) }
                    i += 2
                case 39:                                                            // '…'
                    guard let end = b[(i + 1)...].firstIndex(of: 39) else { return .invalid }
                    value += b[(i + 1)..<end]
                    i = end + 1
                case 34:                                                            // "…"
                    i += 1
                    while true {
                        guard let c = at(i) else { return .invalid }
                        if c == 34 { i += 1; break }
                        if c == 96 { return .invalid }
                        if c == 92, let n = at(i + 1), "$`\"\\\n".utf8.contains(n) {
                            if n != 10 { value.append(n) }
                            i += 2
                            continue
                        }
                        if c == 36 {
                            guard dollar() else { return .invalid }
                            expands = true
                            continue
                        }
                        value.append(c)
                        i += 1
                    }
                case 96: return .invalid                                            // `…`
                case 36:
                    if at(i + 1) == 39 {                                            // $'…'
                        i += 2
                        while true {
                            guard let c = at(i) else { return .invalid }
                            i += c == 92 ? 2 : 1
                            if c == 39 { break }
                        }
                    } else {
                        guard dollar() else { return .invalid }
                    }
                    expands = true
                default:
                    value.append(c)
                    i += 1
                }
            }
            // a number right before < or > is the redirection's file descriptor (2>&1)
            if let c = at(i), c == 60 || c == 62, !value.isEmpty, value.allSatisfy({ $0 >= 48 && $0 <= 57 }), !expands,
               i - start == value.count {
                return redirect()
            }
            let word = Word(range: start..<i, value: expands ? nil : String(decoding: value, as: UTF8.self),
                            text: String(decoding: b[start..<i], as: UTF8.self))
            return .word(word, assignment: isAssignment(start))
        }

        /// `$name`, `${…}` (no substitutions inside), or a lone `$`; false for `$(…)`.
        private mutating func dollar() -> Bool {
            i += 1
            guard let c = at(i) else { return true }
            if c == 40 { return false }
            if c == 123 {
                guard let end = b[i...].firstIndex(of: 125) else { return false }
                if b[i..<end].contains(where: { $0 == 40 || $0 == 96 || $0 == 34 || $0 == 39 }) { return false }
                i = end + 1
                return true
            }
            while let c = at(i), c == 95 || (c >= 48 && c <= 57) || (c | 32 >= 97 && c | 32 <= 122) { i += 1 }
            if i < b.count, "?#@*$!-0123456789".utf8.contains(b[i]), b[i - 1] == 36 { i += 1 }
            return true
        }

        /// NAME= at the word's start, the name unquoted.
        private func isAssignment(_ start: Int) -> Bool {
            var j = start
            guard let first = at(j), first == 95 || (first | 32 >= 97 && first | 32 <= 122) else { return false }
            while let c = at(j), c == 95 || (c >= 48 && c <= 57) || (c | 32 >= 97 && c | 32 <= 122) { j += 1 }
            return at(j) == 61 || (at(j) == 43 && at(j + 1) == 61)
        }
    }
}
