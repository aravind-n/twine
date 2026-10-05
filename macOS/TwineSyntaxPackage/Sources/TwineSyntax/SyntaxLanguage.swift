import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterCSharp
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJSON
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTSX
import TreeSitterTypeScript
import TreeSitterYAML

/// The native grammars shipped with Twine. Unknown file types remain plain text.
public enum SyntaxLanguage: String, CaseIterable, Sendable {
    case swift, rust, python, json, javascript, typescript, tsx, toml, yaml, bash
    case html, css, c, cpp, csharp, go, java, ruby

    public var displayName: String {
        switch self {
        case .swift: "Swift"
        case .rust: "Rust"
        case .python: "Python"
        case .json: "JSON"
        case .javascript: "JavaScript"
        case .typescript: "TypeScript"
        case .tsx: "TSX"
        case .toml: "TOML"
        case .yaml: "YAML"
        case .bash: "Shell"
        case .html: "HTML"
        case .css: "CSS"
        case .c: "C"
        case .cpp: "C++"
        case .csharp: "C#"
        case .go: "Go"
        case .java: "Java"
        case .ruby: "Ruby"
        }
    }

    public static func detect(path: String, source: String) -> SyntaxLanguage? {
        let url = URL(fileURLWithPath: path)
        // Uppercase .C and .H conventionally identify C++; lowercase .h defaults to C.
        if url.pathExtension == "C" || url.pathExtension == "H" { return .cpp }
        switch url.pathExtension.lowercased() {
        case "swift": return .swift
        case "rs": return .rust
        case "py", "pyi", "pyw": return .python
        case "json", "jsonc", "jsonl": return .json
        case "js", "jsx", "mjs", "cjs": return .javascript
        case "ts", "mts", "cts": return .typescript
        case "tsx": return .tsx
        case "toml": return .toml
        case "yaml", "yml": return .yaml
        case "sh", "bash", "zsh": return .bash
        case "html", "htm", "xhtml": return .html
        case "css": return .css
        case "c", "h": return .c
        case "cpp", "cc", "cxx", "c++", "hpp", "hh", "hxx", "h++", "ipp", "tpp": return .cpp
        case "cs", "csx": return .csharp
        case "go": return .go
        case "java": return .java
        case "rb", "rake", "gemspec": return .ruby
        default: break
        }
        switch url.lastPathComponent.lowercased() {
        case ".bashrc", ".bash_profile", ".zshrc", ".zprofile", ".profile": return .bash
        case ".prettierrc", ".eslintrc", ".babelrc": return .json
        case "gemfile", "rakefile", "guardfile", "podfile", "fastfile", "brewfile": return .ruby
        default: break
        }
        // Only inspect a bounded shebang, never arbitrary source text or comments.
        let prefix = String(decoding: source.utf8.prefix(256), as: UTF8.self)
        let firstLine = String(prefix.prefix { $0 != "\n" && $0 != "\r" })
        guard firstLine.hasPrefix("#!") else { return nil }
        let words = firstLine.dropFirst(2).split(whereSeparator: { $0.isWhitespace })
        guard let first = words.first else { return nil }
        let command = first.split(separator: "/").last.map(String.init) ?? ""
        let interpreter: String
        if command == "env" {
            interpreter =
                words.dropFirst().first(where: { !$0.hasPrefix("-") && !$0.contains("=") })
                .map(String.init) ?? ""
        } else {
            interpreter = command
        }
        if interpreter == "python" || interpreter.hasPrefix("python3") || interpreter.hasPrefix("python2") {
            return .python
        }
        switch interpreter {
        case "bash", "sh", "zsh": return .bash
        case "node", "nodejs": return .javascript
        case "swift": return .swift
        case "ruby", "jruby", "truffleruby": return .ruby
        default: return nil
        }
    }

    var grammar: Language {
        switch self {
        case .swift: Language(language: tree_sitter_swift())
        case .rust: Language(language: tree_sitter_rust())
        case .python: Language(language: tree_sitter_python())
        case .json: Language(language: tree_sitter_json())
        case .javascript: Language(language: tree_sitter_javascript())
        case .typescript: Language(language: tree_sitter_typescript())
        case .tsx: Language(language: tree_sitter_tsx())
        case .toml: Language(language: tree_sitter_toml())
        case .yaml: Language(language: tree_sitter_yaml())
        case .bash: Language(language: tree_sitter_bash())
        case .html: Language(language: tree_sitter_html())
        case .css: Language(language: tree_sitter_css())
        case .c: Language(language: tree_sitter_c())
        case .cpp: Language(language: tree_sitter_cpp())
        case .csharp: Language(language: tree_sitter_c_sharp())
        case .go: Language(language: tree_sitter_go())
        case .java: Language(language: tree_sitter_java())
        case .ruby: Language(language: tree_sitter_ruby())
        }
    }

    var queryNames: [String] {
        switch self {
        case .cpp: ["c", "cpp"]
        case .typescript: ["javascript", "typescript"]
        case .tsx: ["javascript", "typescript", "jsx"]
        case .javascript: ["javascript", "jsx"]
        default: [rawValue]
        }
    }
}
