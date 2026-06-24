//
//  Markdown.swift
//  A small, dependency-free Markdown renderer for the phone transcript.
//
//  The watch forces the agent into plain text; the phone asks the backend for RICH output
//  (see RenderMode), so assistant replies can contain Markdown — headings, lists, fenced
//  code, and diffs. Rather than pull in a heavyweight Markdown package, this is a compact
//  block parser that covers what a coding agent actually emits, rendering each block to a
//  native SwiftUI view. Inline emphasis (bold/italic/`code`/links) is handled by Apple's
//  AttributedString Markdown parser within each paragraph/list item.
//
//  Fenced ```diff blocks (and unified diffs) route to DiffView for green/red line coloring.
//

import SwiftUI

// MARK: - Block model

enum MarkdownBlock: Identifiable {
    case paragraph(String)
    case heading(level: Int, text: String)
    case bullets([String])
    case numbered([String])
    case quote([String])
    case code(language: String?, content: String)
    case rule

    var id: String {
        switch self {
        case .paragraph(let s):        return "p:\(s.hashValue)"
        case .heading(let l, let s):   return "h\(l):\(s.hashValue)"
        case .bullets(let xs):         return "ul:\(xs.joined().hashValue)"
        case .numbered(let xs):        return "ol:\(xs.joined().hashValue)"
        case .quote(let xs):           return "q:\(xs.joined().hashValue)"
        case .code(let lang, let c):   return "code:\(lang ?? "")-\(c.hashValue)"
        case .rule:                    return "hr:\(UUID().uuidString)"
        }
    }
}

// MARK: - Parser

enum MarkdownParser {
    static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        // Normalize newlines, keep blank lines (they delimit paragraphs).
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")

        var i = 0
        func flushParagraph(_ buf: inout [String]) {
            guard !buf.isEmpty else { return }
            blocks.append(.paragraph(buf.joined(separator: "\n")))
            buf.removeAll()
        }

        var paragraph: [String] = []

        while i < lines.count {
            let raw = lines[i]
            let line = raw
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code block: ``` or ```lang
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var body: [String] = []
                i += 1
                while i < lines.count {
                    let l = lines[i]
                    if l.trimmingCharacters(in: .whitespaces).hasPrefix("```") { break }
                    body.append(l)
                    i += 1
                }
                blocks.append(.code(language: lang.isEmpty ? nil : lang,
                                    content: body.joined(separator: "\n")))
                i += 1 // skip closing fence
                continue
            }

            // Blank line ends a paragraph.
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                i += 1
                continue
            }

            // Horizontal rule.
            if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushParagraph(&paragraph)
                blocks.append(.rule)
                i += 1
                continue
            }

            // Heading.
            if let h = headingLevel(trimmed) {
                flushParagraph(&paragraph)
                let content = String(trimmed.drop(while: { $0 == "#" })).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: h, text: content))
                i += 1
                continue
            }

            // Bullet list (consume the run).
            if isBullet(trimmed) {
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isBullet(t) else { break }
                    items.append(stripBulletMarker(t))
                    i += 1
                }
                blocks.append(.bullets(items))
                continue
            }

            // Numbered list (consume the run).
            if isNumbered(trimmed) {
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard isNumbered(t) else { break }
                    items.append(stripNumberMarker(t))
                    i += 1
                }
                blocks.append(.numbered(items))
                continue
            }

            // Blockquote (consume the run).
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quoted: [String] = []
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    guard t.hasPrefix(">") else { break }
                    quoted.append(String(t.dropFirst()).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quoted))
                continue
            }

            // Otherwise accumulate into the current paragraph.
            paragraph.append(line)
            i += 1
        }
        flushParagraph(&paragraph)
        return blocks
    }

    // MARK: helpers

    private static func headingLevel(_ s: String) -> Int? {
        guard s.hasPrefix("#") else { return nil }
        let hashes = s.prefix(while: { $0 == "#" }).count
        guard hashes >= 1, hashes <= 6 else { return nil }
        // Require a space after the hashes (so "#hashtag" isn't a heading).
        let after = s.dropFirst(hashes)
        return after.first == " " ? hashes : nil
    }

    private static func isBullet(_ s: String) -> Bool {
        s.hasPrefix("- ") || s.hasPrefix("* ") || s.hasPrefix("+ ")
    }

    private static func stripBulletMarker(_ s: String) -> String {
        String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
    }

    private static func isNumbered(_ s: String) -> Bool {
        // "1. text" / "12) text"
        var idx = s.startIndex
        var sawDigit = false
        while idx < s.endIndex, s[idx].isNumber { sawDigit = true; idx = s.index(after: idx) }
        guard sawDigit, idx < s.endIndex else { return false }
        let sep = s[idx]
        guard sep == "." || sep == ")" else { return false }
        let next = s.index(after: idx)
        return next < s.endIndex && s[next] == " "
    }

    private static func stripNumberMarker(_ s: String) -> String {
        guard let sepIdx = s.firstIndex(where: { $0 == "." || $0 == ")" }) else { return s }
        let after = s.index(after: sepIdx)
        return String(s[after...]).trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Inline rendering

enum MarkdownInline {
    /// Render inline Markdown (bold/italic/`code`/links) to a SwiftUI Text. Falls back to plain.
    static func text(_ s: String) -> Text {
        let options = AttributedString.MarkdownParsingOptions(
            interpretedSyntax: .inlineOnlyPreservingWhitespace
        )
        if let attr = try? AttributedString(markdown: s, options: options) {
            return Text(attr)
        }
        return Text(s)
    }
}

// MARK: - View

struct MarkdownView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(MarkdownParser.parse(text)) { block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func blockView(_ block: MarkdownBlock) -> some View {
        switch block {
        case .paragraph(let s):
            MarkdownInline.text(s)
                .fixedSize(horizontal: false, vertical: true)

        case .heading(let level, let s):
            MarkdownInline.text(s)
                .font(headingFont(level))
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 2)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("•").foregroundStyle(PinchTheme.accent)
                        MarkdownInline.text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("\(idx + 1).")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        MarkdownInline.text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

        case .quote(let lines):
            HStack(spacing: 8) {
                Rectangle()
                    .fill(PinchTheme.accent.opacity(0.6))
                    .frame(width: 3)
                MarkdownInline.text(lines.joined(separator: "\n"))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

        case .code(let language, let content):
            if (language ?? "").lowercased() == "diff" || looksLikeDiff(content) {
                DiffView(content: content)
            } else {
                CodeBlockView(language: language, content: content)
            }

        case .rule:
            Divider().padding(.vertical, 2)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1:  return .title2.bold()
        case 2:  return .title3.bold()
        case 3:  return .headline
        default: return .subheadline.bold()
        }
    }

    private func looksLikeDiff(_ s: String) -> Bool {
        let lines = s.split(separator: "\n", omittingEmptySubsequences: true).prefix(6)
        let hints = lines.filter { $0.hasPrefix("@@") || $0.hasPrefix("+++") || $0.hasPrefix("---") || $0.hasPrefix("diff --git") }
        return hints.count >= 1
    }
}

// MARK: - Code block

struct CodeBlockView: View {
    let language: String?
    let content: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.top, 8)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(content)
                    .font(.system(.footnote, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PinchTheme.codeBackground)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
