//
//  AuthorMapAgentPanel.swift
//  Knowledge Space
//
//  The Map assistant: a conversation panel beside the volume. The agent
//  acts on the map through the same commands the hand does — selection by
//  criteria, layout, connections — and its moves appear live.
//

#if os(visionOS)
import SwiftUI

struct AuthorMapAgentPanel: View {
    @Bindable var state: AuthorMapState
    @AppStorage("anthropicAPIKey") private var apiKey = ""
    @State private var input = ""
    @State private var showingKeyField = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            conversation
            Divider()
            composer
            if showingKeyField || apiKey.isEmpty {
                keyField
            }
        }
        .frame(width: 340, height: 520)
        .glassBackgroundEffect(in: RoundedRectangle(cornerRadius: 22))
    }

    private var header: some View {
        HStack {
            Label("Map Assistant", systemImage: "sparkles")
                .font(.headline)
            Spacer()
            Button {
                showingKeyField.toggle()
            } label: {
                Image(systemName: "key")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if state.chat.isEmpty {
                        Text("Ask for anything a hand can do — and more.\n\n“Select everything about history and pull it toward me.”\n“Line the people up alphabetically.”\n“Push the citations to the back.”")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(.top, 8)
                    }
                    ForEach(state.chat) { entry in
                        chatRow(entry)
                            .id(entry.id)
                    }
                    if state.agentIsWorking {
                        ProgressView()
                            .padding(.top, 4)
                    }
                }
                .padding(12)
            }
            .onChange(of: state.chat.count) {
                if let last = state.chat.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chatRow(_ entry: AgentChatEntry) -> some View {
        switch entry.role {
        case .user:
            Text(entry.text)
                .padding(10)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .frame(maxWidth: .infinity, alignment: .trailing)
        case .assistant:
            Text(entry.text)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity:
            Label(entry.text, systemImage: "gearshape")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Tell the map what to do…", text: $input, axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.plain)
                .onSubmit(send)
            Button(action: send) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(input.trimmingCharacters(in: .whitespaces).isEmpty || state.agentIsWorking)
        }
        .padding(12)
    }

    private var keyField: some View {
        VStack(alignment: .leading, spacing: 4) {
            SecureField("Anthropic API key", text: $apiKey)
                .textFieldStyle(.roundedBorder)
            Text("Stored on this device. Used only to talk to the Map assistant.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }

    private func send() {
        let text = input
        input = ""
        state.sendToAgent(text, apiKey: apiKey)
    }
}
#endif
