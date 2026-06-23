import SwiftUI

struct SearchBarView: View {
    @Binding var text: String
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white.opacity(0.66))

            TextField("Search", text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.white)
                .focused($isFocused)
                .submitLabel(.go)
        }
        .padding(.horizontal, 14)
        .frame(height: 36)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(
            Capsule()
                .strokeBorder(.white.opacity(0.08), lineWidth: 1)
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
