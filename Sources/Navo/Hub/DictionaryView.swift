import SwiftUI

struct DictionaryView: View {
    private enum Action: String, CaseIterable, Identifiable {
        case spelling
        case replace
        case remove

        var id: String { rawValue }

        var title: String {
            switch self {
            case .spelling: return "Spell it this way"
            case .replace: return "Replace with"
            case .remove: return "Remove it"
            }
        }
    }

    @EnvironmentObject private var store: HistoryStore
    @State private var term = ""
    @State private var replacement = ""
    @State private var action: Action = .spelling

    private var canAdd: Bool {
        let hasTerm = !term.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let hasReplacement = !replacement.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return hasTerm && (action != .replace || hasReplacement)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Dictionary")
                        .font(.system(size: 30, weight: .semibold))
                    Text("Names, brands and terms Navo should spell your way, words to always replace, and words to always remove. Replacements and removals are applied exactly, after the cleanup model.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $action) {
                        ForEach(Action.allCases) { action in
                            Text(action.title).tag(action)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(maxWidth: 460)

                    HStack(spacing: 10) {
                        TextField(action == .spelling ? "Word or name, e.g. Navo" : "Word or phrase as it appears", text: $term)
                            .textFieldStyle(.roundedBorder)
                            .onSubmit(add)
                        if action == .replace {
                            Image(systemName: "arrow.right")
                                .foregroundStyle(.secondary)
                            TextField("Replace with", text: $replacement)
                                .textFieldStyle(.roundedBorder)
                                .onSubmit(add)
                        }
                        Button("Add", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdd)
                    }
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if store.vocabulary.isEmpty {
                    ContentUnavailableView(
                        "No words yet",
                        systemImage: "character.book.closed",
                        description: Text("Add product names, people, places or technical terms you use often.")
                    )
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 30)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(store.vocabulary.enumerated()), id: \.element.id) { index, item in
                            row(item)
                            if index < store.vocabulary.count - 1 {
                                Divider()
                            }
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                }
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 32)
            .frame(maxWidth: 900, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
    }

    private var hint: String {
        switch action {
        case .spelling: return "Guides the cleanup model to spell this name or term the way you wrote it."
        case .replace: return "Every time the recognizer writes the first text, Navo writes the second one instead."
        case .remove: return "Every time this appears in a transcript, Navo deletes it. Recognizer markers like <hesitation> are already removed automatically."
        }
    }

    private func row(_ item: VocabularyItem) -> some View {
        HStack(spacing: 10) {
            Text(item.term)
                .font(.system(size: 14, weight: .medium))
            if let replacement = item.replacement {
                Image(systemName: "arrow.right")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                if replacement.isEmpty {
                    Text("removed")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .italic()
                } else {
                    Text(replacement)
                        .font(.system(size: 14))
                }
            } else {
                Text("spelling")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.primary.opacity(0.06)))
            }
            Spacer()
            Button {
                store.deleteVocabulary(item)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help("Remove from the dictionary")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    private func add() {
        guard canAdd else { return }
        switch action {
        case .spelling:
            store.addVocabulary(term: term, replacement: nil)
        case .replace:
            store.addVocabulary(term: term, replacement: replacement)
        case .remove:
            store.addVocabulary(term: term, replacement: "")
        }
        term = ""
        replacement = ""
    }
}
