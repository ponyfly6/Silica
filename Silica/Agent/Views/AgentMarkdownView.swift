import SwiftUI

struct AgentMarkdownView: View {
    let source: String
    @State private var blocks: [AgentMarkdownBlock] = []
    @State private var input: AsyncStream<String>.Continuation?

    var body: some View {
        AgentMarkdownBlocks(blocks: blocks)
            .font(.callout).textSelection(.enabled)
            .task {
                // Parse off the UI thread, coalescing flushes while a large answer is rendering.
                let (stream, continuation) = AsyncStream<String>.makeStream(bufferingPolicy: .bufferingNewest(1))
                input = continuation
                continuation.yield(source)
                for await text in stream {
                    let parsed = await AgentMarkdownBlock.parse(text)
                    guard !Task.isCancelled else { return }
                    blocks = parsed
                }
            }
            .onChange(of: source) { _, text in input?.yield(text) }
    }
}

private struct AgentMarkdownBlocks: View {
    let blocks: [AgentMarkdownBlock]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(blocks.indices, id: \.self) { index in block(blocks[index]) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private func block(_ block: AgentMarkdownBlock) -> some View {
        switch block {
        case let .paragraph(text):
            Text(text).fixedSize(horizontal: false, vertical: true)
        case let .heading(level, text):
            Text(text).font(level == 1 ? .title3 : level == 2 ? .headline : .callout).bold()
                .accessibilityAddTraits(.isHeader)
        case let .list(start, items):
            VStack(alignment: .leading, spacing: 4) {
                ForEach(items.indices, id: \.self) { index in
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(start.map { "\($0 + UInt(index))." } ?? "•").foregroundStyle(.secondary)
                        AgentMarkdownBlocks(blocks: items[index])
                    }
                }
            }
        case let .quote(children):
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2).fill(.tertiary).frame(width: 3)
                AgentMarkdownBlocks(blocks: children)
            }
            .foregroundStyle(.secondary)
        case let .code(language, source):
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if let language { Text(language).font(.caption) }
                    Spacer()
                    AgentCopyButton(text: source, label: "Copy code")
                }.foregroundStyle(.secondary)
                ScrollView(.horizontal) {
                    Text(verbatim: source.hasSuffix("\n") ? String(source.dropLast()) : source)
                        .font(.system(.caption, design: .monospaced)).fixedSize()
                }
            }
            .padding(9).background(.primary.opacity(0.05), in: .rect(cornerRadius: 8))
        case let .table(rows):
            ScrollView(.horizontal) {
                Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                    ForEach(rows.indices, id: \.self) { row in
                        GridRow {
                            ForEach(rows[row].indices, id: \.self) { column in
                                Text(rows[row][column]).fontWeight(row == 0 ? .semibold : .regular)
                                    .padding(.horizontal, 7).padding(.vertical, 4)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .border(.quaternary, width: 0.5)
                            }
                        }
                        .background(.primary.opacity(row == 0 ? 0.05 : 0))
                    }
                }.font(.caption)
            }
        case .divider: Divider()
        }
    }
}

struct AgentCopyButton: View {
    let text: String
    let label: String

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .buttonStyle(.borderless).help(label).accessibilityLabel(label)
    }
}
