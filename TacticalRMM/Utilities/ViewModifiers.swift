import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private struct PrimaryButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content
            .buttonStyle(.borderedProminent)
            .tint(appTheme.accent)
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

private struct SecondaryButtonModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
        content
            .buttonStyle(.bordered)
            .tint(appTheme.accent.opacity(0.75))
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle(radius: 14))
    }
}

private struct KeyboardDismissToolbarModifier: ViewModifier {
    @Environment(\.appTheme) private var appTheme

    func body(content: Content) -> some View {
#if os(iOS) && !targetEnvironment(macCatalyst)
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    UIApplication.shared.dismissKeyboard()
                } label: {
                    Image(systemName: "keyboard.chevron.compact.down")
                }
                .tint(appTheme.accent)
            }
        }
#else
        content
#endif
    }
}

extension View {
    func primaryButton() -> some View {
        modifier(PrimaryButtonModifier())
    }

    func secondaryButton() -> some View {
        modifier(SecondaryButtonModifier())
    }

    func keyboardDismissToolbar() -> some View {
        modifier(KeyboardDismissToolbarModifier())
    }

    @ViewBuilder
    func settingsPresentation(isPresented: Binding<Bool>, fullScreen: Bool, content: @escaping () -> some View) -> some View {
#if os(iOS)
        if fullScreen {
            self.fullScreenCover(isPresented: isPresented, content: content)
        } else {
            self.sheet(isPresented: isPresented, content: content)
        }
#else
        self.sheet(isPresented: isPresented, content: content)
#endif
    }

    @ViewBuilder
    func settingsPresentation<Item: Identifiable, Content: View>(item: Binding<Item?>, fullScreen: Bool, content: @escaping (Item) -> Content) -> some View {
#if os(iOS)
        if fullScreen {
            self.fullScreenCover(item: item, content: content)
        } else {
            self.sheet(item: item, content: content)
        }
#else
        self.sheet(item: item, content: content)
#endif
    }
}
