import SwiftUI

struct CoachView: View {
    @Environment(AppState.self) private var state
    @State private var messages: [AgentMessage] = []
    @State private var input = ""
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.bg.ignoresSafeArea()
                VStack(spacing: 0) {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 10) {
                                if messages.isEmpty && !sending {
                                    emptyState
                                }
                                ForEach(messages) { msg in
                                    bubble(msg)
                                }
                                if sending {
                                    HStack {
                                        ProgressView()
                                            .tint(Theme.hrv)
                                        Text("Myra is looking at your data…")
                                            .font(.caption)
                                            .foregroundStyle(Theme.textSecondary)
                                        Spacer()
                                    }
                                    .padding(.horizontal)
                                    .id("typing")
                                }
                            }
                            .padding(.vertical)
                        }
                        .onChange(of: messages.count) {
                            if let last = messages.last {
                                withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                            }
                        }
                    }
                    inputBar
                }
            }
            .navigationTitle("Coach")
            .task { messages = (try? await APIClient.shared.chatHistory()) ?? [] }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right")
                .font(.system(size: 40))
                .foregroundStyle(Theme.hrv)
            Text("Ask me anything about your body")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            VStack(alignment: .leading, spacing: 8) {
                suggestion("Why was my HRV low this week?")
                suggestion("When should I train today?")
                suggestion("What's hurting my deep sleep?")
            }
        }
        .padding(.top, 60)
    }

    private func suggestion(_ text: String) -> some View {
        Button {
            input = text
        } label: {
            Text(text)
                .font(.subheadline)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.card, in: Capsule())
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func bubble(_ msg: AgentMessage) -> some View {
        let isUser = msg.kind == "chat_user"
        return HStack {
            if isUser { Spacer(minLength: 48) }
            Text(msg.content)
                .font(.subheadline)
                .lineSpacing(3)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(
                    isUser ? Theme.readiness.opacity(0.25) : Theme.card,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .foregroundStyle(Theme.textPrimary)
            if !isUser { Spacer(minLength: 48) }
        }
        .padding(.horizontal)
        .id(msg.id)
    }

    private var inputBar: some View {
        HStack(spacing: 10) {
            TextField("Message Myra…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
                .foregroundStyle(Theme.textPrimary)

            Button {
                send()
            } label: {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(input.isEmpty ? Theme.textSecondary : Theme.readiness)
            }
            .disabled(input.isEmpty || sending)
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(Theme.bg)
    }

    private func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        input = ""
        messages.append(AgentMessage(id: Int.random(in: 1_000_000...9_999_999), kind: "chat_user", content: text, created_at: ""))
        sending = true
        Task {
            defer { sending = false }
            do {
                // On-device Apple model when the user has cut over and the model
                // is available; otherwise the backend Claude path (unchanged).
                let reply: String
                if AgentEngine.current == .onDeviceApple, MyraAgent.isAvailable {
                    reply = try await MyraAgent.shared.chat(text)
                } else {
                    reply = try await APIClient.shared.sendChat(text)
                }
                messages.append(AgentMessage(id: Int.random(in: 1_000_000...9_999_999), kind: "chat_assistant", content: reply, created_at: ""))
            } catch {
                messages.append(AgentMessage(id: Int.random(in: 1_000_000...9_999_999), kind: "chat_assistant", content: "Couldn't reach the backend: \(error.localizedDescription)", created_at: ""))
            }
        }
    }
}
