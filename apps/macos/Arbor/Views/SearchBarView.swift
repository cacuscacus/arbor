import SwiftUI

struct SearchBarView: View {
    @Binding var query: String
    @Binding var scope: SearchScope
    var isSearching: Bool
    var resultCount: Int?
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)

                TextField(placeholder, text: $query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13))
                    .frame(minWidth: 140, idealWidth: 200, maxWidth: 260)
                    .focused(focus)

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
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))

            Picker("Scope", selection: $scope) {
                Text("Folder").tag(SearchScope.currentFolder)
                Text("Global").tag(SearchScope.global)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
            .help("Search scope")

            if let resultCount, !query.isEmpty, !isSearching {
                Text(resultLabel(resultCount))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var placeholder: String {
        switch scope {
        case .currentFolder:
            return "Search folder"
        case .global:
            return "Search home"
        }
    }

    private func resultLabel(_ count: Int) -> String {
        if count >= SearchService.resultLimit {
            return "\(SearchService.resultLimit)+"
        }
        return "\(count)"
    }
}
