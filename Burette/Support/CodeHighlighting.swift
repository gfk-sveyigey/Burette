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
        case .javascript, .typescript, .shell, .markdown: return true
        default: return false
        }
    }
}

/// 基于正则的轻量语法高亮。
enum CodeHighlighter {
    private static let keywordAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemBlue
    ]
    private static let stringAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemRed
    ]
    private static let commentAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.secondaryLabel
    ]
    private static let numberAttributes: [NSAttributedString.Key: Any] = [
        .foregroundColor: UIColor.systemPurple
    ]

    /// 超过这个长度就跳过高亮，避免长文件卡顿。
    private static let maxHighlightLength = 120_000

    static func highlight(_ code: String, language: CodeLanguage, font: UIFont) -> NSAttributedString {
        let base: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        let result = NSMutableAttributedString(string: code, attributes: base)
        guard language != .plain else { return result }
        guard code.utf16.count <= maxHighlightLength else { return result }

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

        if let (open, close) = language.blockComment {
            apply(escape(open) + "[\\s\\S]*?" + escape(close), commentAttributes)
        }
        if let line = language.lineComment {
            apply(escape(line) + "[^\\n]*", commentAttributes)
        }
        apply("\"(?:\\\\.|[^\"\\\\\\n])*\"", stringAttributes)
        if language.allowsSingleQuotes {
            apply("'(?:\\\\.|[^'\\\\\\n])*'", stringAttributes)
        }
        if language.allowsBackticks {
            apply("\u{60}(?:\\\\.|[^\u{60}\\\\]|\\n)*\u{60}", stringAttributes)
        }
        let keywords = language.keywords
        if !keywords.isEmpty {
            apply("\\b(?:" + keywords.map(escape).joined(separator: "|") + ")\\b", keywordAttributes)
        }
        apply("\\b\\d[\\d_]*(?:\\.[\\d_]+)?\\b", numberAttributes)

        return result
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

/// 带语法高亮的可编辑文本视图（内部用 UITextView 实现）。
struct CodeEditor: UIViewRepresentable {
    @Binding var text: String
    let language: CodeLanguage

    static let font = UIFont.monospacedSystemFont(ofSize: 14, weight: .regular)

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
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
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        context.coordinator.language = language
        context.coordinator.render(text, in: textView)
        return textView
    }

    func updateUIView(_ textView: UITextView, context: Context) {
        context.coordinator.language = language
        if (textView.text ?? "") != text {
            context.coordinator.render(text, in: textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        private let text: Binding<String>
        var language: CodeLanguage = .plain

        init(text: Binding<String>) {
            self.text = text
        }

        func textViewDidChange(_ textView: UITextView) {
            let value = textView.text ?? ""
            text.wrappedValue = value
            // 中文输入法等正在组词时不要重排，避免打断候选。
            guard textView.markedTextRange == nil else { return }
            render(value, in: textView)
        }

        func render(_ value: String, in textView: UITextView) {
            let selected = textView.selectedRange
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
        }
    }
}
