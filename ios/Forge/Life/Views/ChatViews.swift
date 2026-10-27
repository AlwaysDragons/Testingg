import SwiftUI

/// Compact chat bar floating above the tab bar on Home. Tap to open the full chat.
struct ChatBar: View {
    @Environment(ChatStore.self) private var chat

    var body: some View {
        Button { chat.open() } label: {
            HStack(spacing: DS.Space.s) {
                Image(systemName: "sparkle").fontWeight(DS.symbolWeight)
                Text(chat.draft.isEmpty ? "Ask or tell me anything" : chat.draft)
                    .lineLimit(1)
                Spacer()
                if chat.isSending { ProgressView().controlSize(.small) }
            }
            .font(DS.Typo.body)
            .foregroundStyle(DS.Palette.secondary)
            .padding(.horizontal, DS.Space.m)
            .padding(.vertical, DS.Space.m - 2)
            .background(.regularMaterial, in: Capsule())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, DS.Space.m)
        .padding(.bottom, DS.Space.s)
        .accessibilityLabel("Open assistant")
    }
}

/// Full chat sheet. Swipe down to dismiss.
struct ChatSheet: View {
    @Environment(ChatStore.self) private var chat
    @FocusState private var focused: Bool

    var body: some View {
        @Bindable var chat = chat
        NavigationStack {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: DS.Space.m) {
                        if chat.messages.isEmpty {
                            EmptyState(symbol: "sparkle", title: "Your assistant",
                                       message: "Try \"remind me to call mom tomorrow at 6\" or \"how did I sleep this week?\"")
                                .padding(.top, DS.Space.xl)
                        }
                        ForEach(chat.messages) { m in
                            MessageRow(message: m).id(m.id)
                        }
                        if chat.isSending {
                            ProgressView().controlSize(.small).padding(.leading, DS.Space.s).id("pending")
                        }
                    }
                    .padding(DS.Space.m)
                }
                .scrollDismissesKeyboard(.interactively)
                .onChange(of: chat.messages.count) { _, _ in
                    withAnimation(DS.Motion.quick) {
                        if chat.isSending { proxy.scrollTo("pending", anchor: .bottom) }
                        else if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) }
                    }
                }
                .onAppear { if let last = chat.messages.last?.id { proxy.scrollTo(last, anchor: .bottom) } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(alignment: .bottom, spacing: DS.Space.s) {
                    TextField("Message", text: $chat.draft, axis: .vertical)
                        .lineLimit(1...5)
                        .focused($focused)
                        .padding(.horizontal, DS.Space.m)
                        .padding(.vertical, DS.Space.s + 2)
                        .background(DS.Palette.raised, in: RoundedRectangle(cornerRadius: DS.Radius.control, style: .continuous))
                    Button {
                        let text = chat.draft
                        chat.draft = ""
                        Task { await chat.send(text) }
                    } label: {
                        Image(systemName: "arrow.up.circle.fill").font(.title2)
                    }
                    .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isSending)
                    .accessibilityLabel("Send")
                }
                .padding(.horizontal, DS.Space.m)
                .padding(.vertical, DS.Space.s)
                .background(DS.Palette.background)
            }
            .dsScreen()
            .navigationTitle("Assistant")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear { focused = chat.messages.isEmpty || !chat.draft.isEmpty }
        }
        .presentationDragIndicator(.visible)
    }
}

private struct MessageRow: View {
    let message: ChatMessage

    var body: some View {
        let isUser = message.role == "user"
        VStack(alignment: isUser ? .trailing : .leading, spacing: DS.Space.xs) {
            Text(message.content ?? "")
                .font(DS.Typo.body)
                .foregroundStyle(message.isError ? DS.Palette.critical : DS.Palette.primary)
                .padding(.horizontal, isUser ? DS.Space.m : 0)
                .padding(.vertical, isUser ? DS.Space.s + 2 : 0)
                .background(isUser ? DS.Palette.surface : .clear, in: RoundedRectangle(cornerRadius: DS.Radius.card, style: .continuous))
                .textSelection(.enabled)
            if !message.actions.isEmpty {
                Text(message.actions.joined(separator: " · "))
                    .font(DS.Typo.caption)
                    .foregroundStyle(DS.Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: isUser ? .trailing : .leading)
    }
}
