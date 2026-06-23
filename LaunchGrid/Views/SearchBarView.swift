import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))

            TextField("搜索", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($isFocused)
                .submitLabel(.go)

            Image(systemName: "ellipsis.circle")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))
        }
        .padding(.horizontal, 13)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.28), lineWidth: 1)
        )
        .onAppear {
            focusSearch()
        }
        .onReceive(NotificationCenter.default.publisher(for: .launchGridFocusSearch)) { _ in
            focusSearch()
        }
    }

    private func focusSearch() {
        DispatchQueue.main.async {
            isFocused = true
        }
    }
}
