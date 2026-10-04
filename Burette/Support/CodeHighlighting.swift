import SwiftUI
import UIKit

/// 按扩展名推断的语法高亮语言。
enum CodeLanguage: Equatable {
    case swift
    case javascript
    case typescript
    case python
    case json
    case yaml
    case markdown
    case cLike
    case shell
    case html
    case css
    case plain

    static func from(path: String) -> CodeLanguage {
        switch (path as NSString).pathExtension.lowercased() {
        case "swift": return .swift
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "tsx": return .typescript
        case "py", "pyw": return .python
        case "json", "jsonc": return .json
        case "yml", "yaml": return .yaml
        case "md", "markdown", "mdx": return .markdown
        case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm", "java", "kt", "kts",
             "go", "rs", "cs", "scala", "php", "groovy": return .cLike
        case "sh", "bash", "zsh", "fish", "env": return .shell
        case "html", "htm", "xml", "svg", "vue": return .html
        case "css", "scss", "less": return .css
        default: return .plain
        }
    }

    /// 展示用名称。
    var displayName: String {
        switch self {
        case .swift: return "Swift"
        case .javascript: return "JavaScript"
        case .typescript: return "TypeScript"
        case .python: return "Python"
        case .json: return "JSON"
        case .yaml: return "YAML"
        case .markdown: return "Markdown"
        case .cLike: return "C-like"
        case .shell: return "Shell"
        case .html: return "HTML"
        case .css: return "CSS"
        case .plain: return "纯文本"
        }
    }

    /// 关键字（会被着色）。
    var keywords: [String] {
        switch self {
        case .swift:
            return ["actor", "any", "as", "associatedtype", "async", "await", "break", "case",
                    "catch", "class", "continue", "default", "defer", "deinit", "do", "else",
                    "enum", "extension", "fallthrough", "false", "fileprivate", "for", "func",
                    "guard", "if", "import", "in", "init", "inout", "internal", "is", "let",
                    "nil", "open", "operator", "private", "protocol", "public", "repeat",
                    "return", "self", "static", "struct", "subscript", "super", "switch",
                    "throw", "throws", "true", "try", "typealias", "var", "where", "while",
                    "some", "lazy", "weak", "unowned", "mutating", "nonmutating", "convenience",
                    "override", "final", "required"]
        case .javascript, .typescript:
            return ["async", "await", "break", "case", "catch", "class", "const", "continue",
                    "debugger", "default", "delete", "do", "else", "export", "extends", "false",
                    "finally", "for", "function", "if", "import", "in", "instanceof", "let",
                    "new", "null", "of", "return", "static", "super", "switch", "this", "throw",
                    "true", "try", "typeof", "undefined", "var", "void", "while", "yield",
                    "interface", "type", "enum", "implements", "readonly", "public", "private"]
        case .python:
            return ["and", "as", "assert", "async", "await", "break", "class", "continue", "def",
                    "del", "elif", "else", "except", "False", "finally", "for", "from", "global",
                    "if", "import", "in", "is", "lambda", "None", "nonlocal", "not", "or",
                    "pass", "raise", "return", "True", "try", "while", "with", "yield", "self"]
        case .json:
            return ["true", "false", "null"]
        case .yaml:
            return ["true", "false", "null", "yes", "no", "on", "off"]
        case .shell:
            return ["if", "then", "else", "elif", "fi", "for", "while", "do", "done", "case",
                    "esac", "function", "in", "return", "export", "local", "echo", "printf",
                    "cd", "source", "sudo", "set", "unset", "exit"]
        case .cLike:
            return ["abstract", "as", "async", "await", "auto", "bool", "break", "byte", "case",
                    "catch", "char", "class", "const", "continue", "default", "defer", "delete",
                    "do", "double", "else", "enum", "extends", "extern", "false", "final",
                    "finally", "float", "fn", "for", "func", "goto", "if", "implements",
                    "import", "in", "inline", "instanceof", "int", "interface", "internal",
                    "let", "long", "namespace", "new", "nil", "null", "package", "private",
                    "protected", "public", "return", "short", "signed", "sizeof", "static",
                    "struct", "super", "switch", "template", "this", "throw", "true", "try",
                    "typedef", "typename", "union", "unsigned", "using", "var", "virtual",
                    "void", "volatile", "while"]
        case .html:
            return ["html", "head", "body", "div", "span", "script", "style", "link", "meta",
                    "title", "class", "id", "href", "src", "type", "xmlns", "true", "false"]
        case .css:
            return ["import", "media", "supports", "keyframes", "from", "to", "important",
                    "inherit", "initial", "unset", "none", "auto", "block", "flex", "grid",
                    "absolute", "relative", "fixed", "sticky", "solid", "dashed"]
        case .markdown, .plain:
            return []
        }
    }

    var lineComment: String? {
        switch self {
        case .swift, .javascript, .typescript, .cLike: return "//"
        case .python, .shell, .yaml: return "#"
        default: return nil
        }
    }

    var blockComment: (String, String)? {
        switch self {
        case .swift, .javascript, .typescript, .cLike, .css, .html: return ("/*", "*/")
        default: return nil
        }
    }

    var allowsSingleQuotes: Bool {
        switch self {
        case .swift, .javascript, .typescript, .python, .cLike, .shell, .css: return true
        default: return false
        }
    }

    var allowsBackticks: Bool {
        switch self {
        case .javascript, .typescript, .shell: return true
        default: return false
        }
    }
}

/// 基于正则的轻量语法高亮。
///
/// 在无第三方依赖的前提下尽量覆盖常见语言的主要词法元素：
/// 注释、字符串、数字、关键字、类型、函数调用、装饰器，
/// 以及 JSON/YAML 的键、Markdown 的标题与链接、HTML 标签、CSS 选择器等。
enum CodeHighlighter {
    private static let keywordAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemPink
    ]
    private static let stringAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemRed
    ]
    private static let numberAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemPurple
    ]
    private static let typeAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemTeal
    ]
    private static let functionAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemIndigo
    ]
    private static let attributeAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemOrange
    ]
    private static let propertyAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemBlue
    ]
    private static let tagAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemBlue
    ]

    /// 超过这个长度就跳过高亮，避免长文件卡顿。
    private static let maxHighlightLength = 200_000

    static func highlight(_ code: String, language: CodeLanguage, font: UIFont) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 2
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label,
            .paragraphStyle: paragraph
        ]
        let result = NSMutableAttributedString(string: code, attributes: base)
        guard language != .plain else { return result }
        guard code.utf16.count <= maxHighlightLength else { return result }

        let commentAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.secondaryLabel,
            .font: italicFont(font)
        ]
        let boldKeywordAttributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: UIColor.systemPink,
            .font: boldFont(font)
        ]

        var occupied: [NSRange] = []

        func apply(_ pattern: String, _ attributes: [NSAttributedString.Key: Any]) {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { return }
            let range = NSRange(location: 0, length: (code as NSString).length)
            for match in regex.matches(in: code, options: [], range: range) {
                let matchRange = match.range
                guard matchRange.location != NSNotFound, matchRange.length > 0 else { continue }
                if occupied.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) { continue }
                result.addAttributes(attributes, range: matchRange)
                occupied.append(matchRange)
            }
        }

        // 1. 注释
        if let (open, close) = language.blockComment {
            apply(escape(open) + "[\\s\\S]*?" + escape(close), commentAttributes)
        }
        if let line = language.lineComment {
            apply(escape(line) + "[^\\n]*", commentAttributes)
        }

        // 2. 结构化数据语言的键（必须先于字符串，避免被字符串规则占位）
        switch language {
        case .json:
            apply("\"(?:\\\\.|[^\"\\\\\\n])*\"(?=\\s*:)", propertyAttributes)
        case .yaml:
            apply("(?m)^[ \\t]*[A-Za-z_][A-Za-z0-9_.-]*(?=\\s*:)", propertyAttributes)
            apply("[&*][A-Za-z0-9_-]+", attributeAttributes)
        default:
            break
        }

        // 3. 字符串
        apply("\"(?:\\\\.|[^\"\\\\\\n])*\"", stringAttributes)
        if language.allowsSingleQuotes {
            apply("'(?:\\\\.|[^'\\\\\\n])*'", stringAttributes)
        }
        if language.allowsBackticks {
            apply("\u{60}(?:\\\\.|[^\u{60}\\\\]|\\n)*\u{60}", stringAttributes)
        }

        // 4. 数字
        apply("\\b(?:0[xX][0-9A-Fa-f_]+|0[bB][01_]+|\\d[\\d_]*(?:\\.[\\d_]+)?(?:[eE][+-]?\\d+)?)\\b", numberAttributes)

        // 5. 关键字
        let keywords = language.keywords
        if !keywords.isEmpty {
            apply("\\b(?:" + keywords.map(escape).joined(separator: "|") + ")\\b", keywordAttributes)
        }

        // 6. 各语言特有规则
        switch language {
        case .markdown:
            apply("(?m)^ {0,3}#{1,6}[^\\n]*", boldKeywordAttributes)
            apply("(?m)^ {0,3}>[^\\n]*", commentAttributes)
            apply("(?m)^ {0,3}(?:[-*+]|\\d+\\.)\\s", numberAttributes)
            apply("\\*\\*[^*\\n]+\\*\\*", boldKeywordAttributes)
            apply("\\[[^\\]\\n]*\\]\\([^)\\n]*\\)", functionAttributes)
            apply("\u{60}[^\u{60}\\n]+\u{60}", stringAttributes)
        case .html:
            apply("</?[A-Za-z][A-Za-z0-9:_-]*", tagAttributes)
            apply("/?>", tagAttributes)
            apply("\\b[A-Za-z_:][-A-Za-z0-9_:.]*(?=\\s*=)", attributeAttributes)
        case .css:
            apply("@[A-Za-z-]+", keywordAttributes)
            apply("(?m)^[^{}\\n]+(?=\\{)", typeAttributes)
            apply("[a-zA-Z-]+(?=\\s*:)", propertyAttributes)
        case .shell:
            apply("\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?", propertyAttributes)
            apply("(?<=\\s)-{1,2}[A-Za-z][A-Za-z0-9-]*", attributeAttributes)
        case .swift:
            apply("@[A-Za-z_][A-Za-z0-9_]*", attributeAttributes)
            apply("#[A-Za-z]+", attributeAttributes)
        case .yaml:
            apply("(?m)^\\s*-\\s", numberAttributes)
        default:
            break
        }

        // 7. 类型（首字母大写的标识符）
        if language != .markdown && language != .html && language != .css {
            apply("\\b[A-Z][A-Za-z0-9_]*\\b", typeAttributes)
        }

        // 8. 装饰器 / 指令
        if language == .python {
            apply("@[A-Za-z_][A-Za-z0-9_.]*", attributeAttributes)
        }

        // 9. 函数调用
        if language != .markdown {
            apply("\\b[A-Za-z_][A-Za-z0-9_]*(?=\\s*\\()", functionAttributes)
        }

        return result
    }

    private static func italicFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitItalic) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func boldFont(_ font: UIFont) -> UIFont {
        guard let descriptor = font.fontDescriptor.withSymbolicTraits(.traitBold) else { return font }
        return UIFont(descriptor: descriptor, size: font.pointSize)
    }

    private static func escape(_ token: String) -> String {
        let specials = CharacterSet(charactersIn: "\\^$.|?*+()[]{}")
        var out = ""
        for scalar in token.unicodeScalars {
            if specials.contains(scalar) {
                out.append("\\")
            }
            out.append(Character(scalar))
        }
        return out
    }
}

/// 带行号栏的可编辑文本视图。
final class LineNumberTextView: UITextView {
    static let gutterWidth: CGFloat = 44

    override func layoutSubviews() {
        super.layoutSubviews()
        setNeedsDisplay()
    }

    override func draw(_ rect: CGRect) {
        super.draw(rect)
        drawGutter()
    }

    private func drawGutter() {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
            .foregroundColor: UIColor.tertiaryLabel
        ]

        UIColor.separator.setStroke()
        let separator = UIBezierPath()
        separator.move(to: CGPoint(x: Self.gutterWidth - 0.5, y: 0))
        separator.addLine(to: CGPoint(x: Self.gutterWidth - 0.5, y: max(contentSize.height, bounds.height)))
        separator.lineWidth = 1.0 / traitCollection.displayScale
        separator.stroke()

        let manager = layoutManager
        let container = textContainer
        let glyphRange = manager.glyphRange(for: container)
        guard glyphRange.length > 0 else { return }

        var lineNumber = 1
        var glyphIndex = glyphRange.location
        let top = textContainerInset.top
        while glyphIndex < NSMaxRange(glyphRange) {
            var lineRange = NSRange()
            let fragment = manager.lineFragmentRect(forGlyphAt: glyphIndex, effectiveRange: &lineRange)
            if lineRange.length == 0 { break }
            let label = "\(lineNumber)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(
                at: CGPoint(x: Self.gutterWidth - size.width - 8, y: top + fragment.minY),
                withAttributes: attributes
            )
            lineNumber += 1
            glyphIndex = NSMaxRange(lineRange)
        }
    }
}
/// 编辑器对外控制接口：把 SwiftUI 侧的查找 / 替换输入栏接到 UITextView 上。
final class CodeEditorController: ObservableObject {
    fileprivate weak var coordinator: CodeEditor.Coordinator?

    /// 在文本里查找，命中后选中并滚动；返回是否命中。
    @discardableResult
    func find(_ query: String, forward: Bool = true) -> Bool {
        coordinator?.find(query, forward: forward) ?? false
    }

    /// 替换当前选中（或第一个）匹配项；返回是否替换了。
    @discardableResult
    func replaceCurrent(_ query: String, with replacement: String) -> Bool {
        coordinator?.replaceCurrent(query, with: replacement) ?? false
    }

    /// 全部替换；返回替换数量。
    @discardableResult
    func replaceAll(_ query: String, with replacement: String) -> Int {
        coordinator?.replaceAll(query, with: replacement) ?? 0
    }

    /// 收起查找栏时取消选中。
    func clearSelection() {
        guard let textView = coordinator?.textView else { return }
        textView.selectedRange = NSRange(location: textView.selectedRange.location, length: 0)
    }
}

/// 括号匹配：给定光标位置，返回应高亮的两个括号范围（忽略字符串 / 注释内的括号）。
enum BracketMatcher {
    private static let pairs: [(open: unichar, close: unichar)] = [
        (0x28, 0x29), // ( )
        (0x5B, 0x5D), // [ ]
        (0x7B, 0x7D)  // { }
    ]

    static func match(in text: String, selection: NSRange) -> [NSRange] {
        let ns = text as NSString
        let length = ns.length
        guard length > 0 else { return [] }
        for position in [selection.location, selection.location - 1] where position >= 0 && position < length {
            let character = ns.character(at: position)
            if let pair = pairs.first(where: { $0.open == character }),
               let match = scanForward(ns, from: position, open: pair.open, close: pair.close) {
                return [NSRange(location: position, length: 1), NSRange(location: match, length: 1)]
            }
            if let pair = pairs.first(where: { $0.close == character }),
               let match = scanBackward(ns, from: position, open: pair.open, close: pair.close) {
                return [NSRange(location: match, length: 1), NSRange(location: position, length: 1)]
            }
        }
        return []
    }

    private static func scanForward(_ ns: NSString, from index: Int, open: unichar, close: unichar) -> Int? {
        var depth = 0
        var i = index
        while i < ns.length {
            let character = ns.character(at: i)
            if character == open {
                depth += 1
            } else if character == close {
                depth -= 1
                if depth == 0 { return i }
            }
            i += 1
        }
        return nil
    }

    private static func scanBackward(_ ns: NSString, from index: Int, open: unichar, close: unichar) -> Int? {
        var depth = 0
        var i = index
        while i >= 0 {
            let character = ns.character(at: i)
            if character == close {
                depth += 1
            } else if character == open {
                depth -= 1
                if depth == 0 { return i }
            }
            i -= 1
        }
        return nil
    }
}

/// 带语法高亮的可编辑文本视图（内部用 UITextView 实现）。
///
/// 除了高亮与行号，还内置：回车自动缩进（含大括号换行补全）、
/// 光标处括号匹配高亮、以及供查找替换栏调用的选中 / 替换能力。
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage
    /// 查找 / 替换栏通过它驱动编辑器；不传也能正常编辑。
    var controller: CodeEditorController? = nil

    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeUIView(context: Context) -> LineNumberTextView {
        let textView = LineNumberTextView()
        // 提前触发 TextKit 1 回退，保证行号栏能拿到 layoutManager。
        _ = textView.layoutManager
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.font = Self.font
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = UIEdgeInsets(
            top: 12,
            left: LineNumberTextView.gutterWidth + 6,
            bottom: 24,
            right: 12
        )
        context.coordinator.language = language
        context.coordinator.textView = textView
        context.coordinator.controller = controller
        controller?.coordinator = context.coordinator
        context.coordinator.render(text, in: textView)
        return textView
    }

    func updateUIView(_ textView: LineNumberTextView, context: Context) {
        context.coordinator.language = language
        context.coordinator.controller = controller
        controller?.coordinator = context.coordinator
        if (textView.text ?? "") != text {
            context.coordinator.render(text, in: textView)
        }
    }

    static func dismantleUIView(_ uiView: LineNumberTextView, coordinator: Coordinator) {
        coordinator.controller?.coordinator = nil
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        var language: CodeLanguage = .plain
        weak var textView: UITextView?
        weak var controller: CodeEditorController?

        /// 高亮中的括号范围，切换光标时先清掉。
        private var bracketRanges: [NSRange] = []
        /// 自动缩进使用的单位（默认四空格，检测到 Tab 缩进的文件时改用 Tab）。
        private var indentUnit = "    "

        init(text: Binding<String>) {
            self.text = text
        }

        // MARK: 文本变更

        func textViewDidChange(_ textView: UITextView) {
            let value = textView.text ?? ""
            text.wrappedValue = value
            detectIndentUnit(in: value)
            // 中文输入法等正在组词时不要重排，避免打断候选。
            guard textView.markedTextRange == nil else { return }
            render(value, in: textView)
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            updateBracketHighlight(in: textView)
        }

        /// 回车时按当前行缩进自动补位；光标在括号之间时补出成对的闭合行。
        func textView(
            _ textView: UITextView,
            shouldChangeTextIn range: NSRange,
            replacementText replacement: String
        ) -> Bool {
            guard replacement == "\n" else { return true }
            return insertSmartNewline(in: textView, at: range)
        }

        private func insertSmartNewline(in textView: UITextView, at range: NSRange) -> Bool {
            let ns = textView.text as NSString
            guard range.location <= ns.length else { return true }

            let lineRange = ns.lineRange(for: NSRange(location: range.location, length: 0))
            let currentLine = ns.substring(with: lineRange)
            let indentation = String(currentLine.prefix { $0 == " " || $0 == "\t" })

            let prefixLength = range.location - lineRange.location
            let linePrefix = ns.substring(with: NSRange(location: lineRange.location, length: max(0, prefixLength)))
            let trimmedPrefix = linePrefix.replacingOccurrences(
                of: "[ \\t]+$",
                with: "",
                options: .regularExpression
            )
            let opensBlock = trimmedPrefix.last.map { "{(:[".contains($0) } ?? false

            let hasClosingAfter = range.location < ns.length
                && ")}]".contains(ns.substring(with: NSRange(location: range.location, length: 1)))

            let extra = opensBlock ? indentUnit : ""
            let insertion: String
            if hasClosingAfter {
                insertion = "\n" + indentation + extra + "\n" + indentation
            } else {
                insertion = "\n" + indentation + extra
            }
            let cursorOffset = ("\n" + indentation + extra).utf16.count

            textView.textStorage.replaceCharacters(in: range, with: insertion)
            let value = textView.text ?? ""
            text.wrappedValue = value
            render(value, in: textView)
            textView.selectedRange = NSRange(location: range.location + cursorOffset, length: 0)
            textView.scrollRangeToVisible(textView.selectedRange)
            updateBracketHighlight(in: textView)
            return false
        }

        /// 推断缩进单位：扫描前若干行，遇到 Tab 或空格缩进就沿用。
        private func detectIndentUnit(in value: String) {
            var scanned = 0
            for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
                scanned += 1
                if scanned > 400 { return }
                let lead = line.prefix { $0 == " " || $0 == "\t" }
                guard !lead.isEmpty else { continue }
                if lead.first == "\t" {
                    indentUnit = "\t"
                } else {
                    indentUnit = String(repeating: " ", count: min(lead.count, 8))
                }
                return
            }
        }

        // MARK: 高亮

        func render(_ value: String, in textView: UITextView) {
            let selected = textView.selectedRange
            self.textView = textView
            let highlighted = CodeHighlighter.highlight(value, language: language, font: CodeEditor.font)
            textView.attributedText = highlighted
            textView.typingAttributes = [
                .font: CodeEditor.font,
                .foregroundColor: UIColor.label
            ]
            let length = (textView.text as NSString).length
            if selected.location <= length {
                textView.selectedRange = NSRange(location: selected.location, length: 0)
            }
            textView.setNeedsDisplay()
            updateBracketHighlight(in: textView)
        }

        /// 用 layoutManager 的临时属性高亮光标两侧的匹配括号。
        private func updateBracketHighlight(in textView: UITextView) {
            let layoutManager = textView.layoutManager
            let previous = bracketRanges
            for range in previous {
                layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: range)
            }

            let matches = BracketMatcher.match(in: textView.text ?? "", selection: textView.selectedRange)
            bracketRanges = matches

            if !matches.isEmpty {
                let color = UIColor.systemYellow.withAlphaComponent(0.35)
                for range in matches {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
                }
            }

            let changed = previous + matches
            guard !changed.isEmpty else { return }
            var lower = Int.max
            var upper = 0
            for range in changed {
                lower = min(lower, range.location)
                upper = max(upper, NSMaxRange(range))
            }
            if lower < upper {
                layoutManager.invalidateDisplay(forCharacterRange: NSRange(location: lower, length: upper - lower))
            }
        }

        // MARK: 查找 / 替换

        private static let searchOptions: NSString.CompareOptions = [.caseInsensitive, .diacriticInsensitive]

        @discardableResult
        func find(_ query: String, forward: Bool) -> Bool {
            guard let textView, !query.isEmpty else { return false }
            let ns = textView.text as NSString
            guard ns.length > 0 else { return false }
            let current = textView.selectedRange

            var found = NSRange(location: NSNotFound, length: 0)
            if forward {
                let start = min(NSMaxRange(current), ns.length)
                found = ns.range(of: query, options: Self.searchOptions, range: NSRange(location: start, length: ns.length - start))
                if found.location == NSNotFound {
                    found = ns.range(of: query, options: Self.searchOptions, range: NSRange(location: 0, length: start))
                }
            } else {
                let start = max(0, current.location)
                found = ns.range(of: query, options: [Self.searchOptions, .backwards], range: NSRange(location: 0, length: start))
                if found.location == NSNotFound {
                    found = ns.range(of: query, options: [Self.searchOptions, .backwards], range: NSRange(location: start, length: ns.length - start))
                }
            }
            guard found.location != NSNotFound else { return false }
            textView.selectedRange = found
            textView.scrollRangeToVisible(found)
            return true
        }

        @discardableResult
        func replaceCurrent(_ query: String, with replacement: String) -> Bool {
            guard let textView, !query.isEmpty else { return false }
            let ns = textView.text as NSString
            var target = textView.selectedRange
            if !matches(ns, target, query) {
                guard find(query, forward: true) else { return false }
                target = textView.selectedRange
            }
            guard target.location != NSNotFound, NSMaxRange(target) <= ns.length else { return false }

            textView.textStorage.replaceCharacters(in: target, with: replacement)
            let value = textView.text ?? ""
            text.wrappedValue = value
            render(value, in: textView)
            let newRange = NSRange(location: target.location, length: (replacement as NSString).length)
            textView.selectedRange = newRange
            textView.scrollRangeToVisible(newRange)
            updateBracketHighlight(in: textView)
            return true
        }

        @discardableResult
        func replaceAll(_ query: String, with replacement: String) -> Int {
            guard let textView, !query.isEmpty else { return 0 }
            let value = textView.text ?? ""
            let ns = value as NSString
            var result = ""
            var index = 0
            var count = 0
            while index < ns.length {
                let searchRange = NSRange(location: index, length: ns.length - index)
                let found = ns.range(of: query, options: Self.searchOptions, range: searchRange)
                if found.location == NSNotFound { break }
                result += ns.substring(with: NSRange(location: index, length: found.location - index))
                result += replacement
                index = NSMaxRange(found)
                count += 1
            }
            guard count > 0 else { return 0 }
            result += ns.substring(from: index)
            text.wrappedValue = result
            render(result, in: textView)
            return count
        }

        private func matches(_ ns: NSString, _ range: NSRange, _ query: String) -> Bool {
            guard range.length > 0, NSMaxRange(range) <= ns.length else { return false }
            return ns.substring(with: range).compare(query, options: Self.searchOptions) == .orderedSame
        }
    }
}
