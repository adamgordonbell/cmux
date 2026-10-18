import SwiftUI

/// Fork: clicking the file path in a preview/markdown panel header copies the
/// full path to the clipboard and flashes a short "Copied" confirmation in
/// place. Right-click → Copy Text still works via `copyOnlyTextSelection`.
struct PanelFilePathCopyOnClick: ViewModifier {
    let filePath: String
    @State private var showCopied = false
    @State private var generation = 0

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture { copy() }
            .help(String(localized: "panel.filePath.clickToCopy", defaultValue: "Click to copy full path"))
            .overlay(alignment: .leading) {
                if showCopied {
                    Text(String(localized: "panel.filePath.copied", defaultValue: "Copied path"))
                        .cmuxFont(size: 11, weight: .medium)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 6)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 4))
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.15), value: showCopied)
    }

    private func copy() {
        WorkspaceSurfaceIdentifierClipboardText.copy(filePath)
        generation &+= 1
        let current = generation
        showCopied = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard generation == current else { return }
            showCopied = false
        }
    }
}

extension View {
    func copyFilePathOnClick(_ filePath: String) -> some View {
        modifier(PanelFilePathCopyOnClick(filePath: filePath))
    }
}
