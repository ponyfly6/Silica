import Foundation
import Markdown

nonisolated enum AgentMarkdownBlock: Sendable {
    case paragraph(AttributedString)
    case heading(Int, AttributedString)
    case list(start: UInt?, items: [[Self]])
    case quote([Self])
    case code(language: String?, source: String)
    case table([[AttributedString]])
    case divider

    @concurrent static func parse(_ source: String) async -> [Self] {
        blocks(Document(parsing: source))
    }

    private static func blocks(_ parent: any Markup) -> [Self] {
        parent.children.map { node in
            switch node {
            case let heading as Heading: return .heading(heading.level, inline(heading))
            case let list as OrderedList: return .list(start: list.startIndex, items: list.children.map(blocks))
            case let list as UnorderedList: return .list(start: nil, items: list.children.map(blocks))
            case let quote as BlockQuote: return .quote(blocks(quote))
            case let code as CodeBlock: return .code(language: code.language, source: code.code)
            case let table as Table:
                return .table([table.head.children.map(inline)] + table.body.children.map { $0.children.map(inline) })
            case is ThematicBreak: return .divider
            case let html as HTMLBlock: return .paragraph(AttributedString(html.rawHTML))
            default: return .paragraph(inline(node))
            }
        }
    }

    private static func inline(_ node: any Markup, intent: InlinePresentationIntent = [], link: URL? = nil) -> AttributedString {
        var intent = intent
        var link = link
        let text: String
        switch node {
        case let literal as Markdown.Text: text = literal.string
        case let code as InlineCode: text = code.code; intent.insert(.code)
        case is SoftBreak: text = " "
        case is LineBreak: text = "\n"
        case let html as InlineHTML: text = html.rawHTML
        default:
            switch node {
            case is Strong: intent.insert(.stronglyEmphasized)
            case is Emphasis: intent.insert(.emphasized)
            case is Strikethrough: intent.insert(.strikethrough)
            case let item as Markdown.Link:
                if let destination = item.destination {
                    // A bare "File.swift:42" would otherwise be parsed as a URL scheme.
                    let relativeLine = !destination.contains("/") && destination.split(separator: ":").count == 2
                        && Int(destination.split(separator: ":").last ?? "") != nil
                    link = URL(string: relativeLine ? "./" + destination : destination)
                }
            default: break
            }
            return node.children.reduce(into: AttributedString()) { $0 += inline($1, intent: intent, link: link) }
        }
        var result = AttributedString(text)
        if !intent.isEmpty { result.inlinePresentationIntent = intent }
        result.link = link
        return result
    }

    private static func inline(_ node: any Markup) -> AttributedString {
        inline(node, intent: [])
    }
}
