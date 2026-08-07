import SwiftUI

/// Menu-bar quick-prompt window: the same MainWindowView (transcript +
/// prompt + toolbar) hosted in a MenuBarExtra `.window` popover. Cheap reuse
/// of everything the main window already does.
struct QuickPromptView: View {
    var body: some View {
        MainWindowView(cwd: AppState.shared.defaultProject())
            .frame(width: 720, height: 560)
    }
}
