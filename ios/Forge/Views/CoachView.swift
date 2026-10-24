import SwiftUI

struct CoachView: View {
    @Environment(AppModel.self) private var model
    @State private var input = ""
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 14) {
                            if model.chat.isEmpty { intro }
                            ForEach(Array(model.chat.enumerated()), id: \.offset) { i, m in
                                Bubble(message: m).id(i)
                            }
                            if model.isThinking {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text("Analyzing your data…").font(.footnote).foregroundStyle(Theme.secondary)
                                }
                                .id("thinking")
                            }
                        }
                        .padding(16)
                    }
                    .onChange(of: model.chat.count) { _, n in
                        withAnimation { proxy.scrollTo(n - 1, anchor: .top) }
                    }
                }
                inputBar
            }
            .screen()
            .navigationTitle("AI Coach")
            .toolbar {
                if !model.chat.isEmpty {
                    Button { model.chat = [] } label: { Image(systemName: "square.and.pencil") }
                }
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Card(padding: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Image(systemName: "sparkles").font(.largeTitle).foregroundStyle(Theme.gradient)
                    Text("Your AI coach").font(.title2.weight(.bold))
                    Text("Has every Hevy workout, your Apple Health trends, volume per muscle, stalled lifts and your OneLife recovery plan. Ask anything.")
                        .font(.subheadline).foregroundStyle(Theme.secondary)
                    if !model.hasClaude {
                        Text("Add a Claude API key in Settings to start.").font(.footnote.weight(.semibold)).foregroundStyle(Theme.amber)
                    }
                }
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CoachContext.quickPrompts, id: \.title) { q in
                    Button { send(q.prompt) } label: {
                        VStack(alignment: .leading, spacing: 8) {
                            Image(systemName: q.icon).font(.title3).foregroundStyle(Theme.gradient)
                            Text(q.title).font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        }
                        .frame(maxWidth: .infinity, minHeight: 74, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).strokeBorder(Theme.stroke))
                    }
                    .disabled(!model.hasClaude)
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Ask your coach…", text: $input, axis: .vertical)
                .lineLimit(1...5)
                .focused($focused)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(Capsule().fill(Theme.card))
                .overlay(Capsule().strokeBorder(Theme.stroke))
            Button { send(input) } label: {
                Image(systemName: "arrow.up").font(.headline.weight(.bold)).foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(Circle().fill(Theme.gradient))
            }
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || model.isThinking || !model.hasClaude)
            .opacity(input.isEmpty ? 0.5 : 1)
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.ultraThinMaterial)
    }

    private func send(_ text: String) {
        let t = text
        input = ""
        focused = false
        Task { await model.ask(t) }
    }
}

private struct Bubble: View {
    let message: ClaudeClient.Message
    var isUser: Bool { message.role == "user" }

    var body: some View {
        HStack {
            if isUser { Spacer(minLength: 40) }
            Group {
                if isUser { Text(message.content) } else { MarkdownText(text: message.content) }
            }
            .font(.subheadline)
            .textSelection(.enabled)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(isUser ? AnyShapeStyle(Theme.gradient) : AnyShapeStyle(Theme.card))
            )
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).strokeBorder(isUser ? .clear : Theme.stroke))
            if !isUser { Spacer(minLength: 0) }
        }
    }
}
