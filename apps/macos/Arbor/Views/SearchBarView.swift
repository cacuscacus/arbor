import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    @Binding var scope: SearchScope
    var isSearching: Bool
    var resultCount: Int?
    var focus: FocusState<Bool>.Binding
    var onDismiss: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 160, idealWidth: 220, maxWidth: 280)
                    .focused(focus)

                // Keep a stable trailing slot so ProgressView ↔ clear-button
                // swaps don't recreate the TextField and drop keyboard focus.
                ZStack {
                    if isSearching {
                        ProgressView()
                            .controlSize(.mini)
                    } else if !query.isEmpty {
                        Button {
                            query = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Clear search")
                    }
                }
                .frame(width: 14, height: 14)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            Picker("Scope", selection: $scope) {
                Text("Folder").tag(SearchScope.currentFolder)
                Text("Global").tag(SearchScope.global)
            }
            .labelsHidden()
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Search scope")

            Text(resultCount.map(resultLabel) ?? " ")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .frame(minWidth: 36, alignment: .trailing)
                .opacity(resultCount != nil && !query.isEmpty && !isSearching ? 1 : 0)
                .accessibilityHidden(resultCount == nil || query.isEmpty || isSearching)

            if let onDismiss {
                Button {
                    onDismiss()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Close search")
            }
        }
        .padding(.leading, 4)
        .padding(.trailing, 2)
    }

    private var placeholder: String {
        switch scope {
        case .currentFolder:
            return "Search folder — try *.json"
        case .global:
            return "Search home — try blabla*.json"
        }
    }

    private func resultLabel(_ count: Int) -> String {
        if count >= SearchService.resultLimit {
            return "\(SearchService.resultLimit)+"
        }
        return "\(count)"
    }
}
