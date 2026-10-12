import TwineSyntax

/// A file tab's presentation preference; source bytes and disk state do not depend on it.
enum FileSyntaxMode: Hashable {
    case automatic
    case plainText
    case language(SyntaxLanguage)

    func language(path: String, source: String) -> SyntaxLanguage? {
        switch self {
        case .automatic: SyntaxLanguage.detect(path: path, source: source)
        case .plainText: nil
        case .language(let language): language
        }
    }
}
