import SwiftUI
import UIKit

/// Keyboard dismissal helpers.
///
/// ## Why this is needed at all
/// `phonePad`, `numberPad` and `decimalPad` have **no return key**. A `TextField` using one is
/// therefore unclosable by default — the user has no gesture and no button, and the keyboard covers
/// the screen until they navigate away. Every numeric input in this app hits that: the phone field
/// on the welcome screen, and the amount fields in the payment forms.
///
/// Two complementary escapes, because neither alone is enough:
/// - a **Done bar** above the keyboard, which is discoverable and works even when the content
///   behind is fully covered;
/// - **tap-outside-to-dismiss**, which is what people reflexively try first.
enum KeyboardDismisser {

    /// Resigns first responder app-wide.
    ///
    /// Uses the responder-chain action rather than tracking focus state: it works regardless of
    /// which field is active or which view owns the `@FocusState`, so a helper attached at screen
    /// level closes a keyboard raised by a field several layers down.
    static func dismiss() {
        UIApplication.shared.sendAction(
            #selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }
}

private struct KeyboardDoneToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(L("common_done")) { KeyboardDismisser.dismiss() }
                    .font(Tokens.Typography.callout.weight(.semibold))
                    .foregroundStyle(Tokens.Colour.brand)
            }
        }
    }
}

private struct TapToDismissKeyboard: ViewModifier {
    func body(content: Content) -> some View {
        content
            // `simultaneousGesture` rather than `onTapGesture`: a plain tap gesture on a container
            // swallows taps destined for buttons and list rows inside it, which would break every
            // control on the screen it is applied to.
            .simultaneousGesture(
                TapGesture().onEnded { KeyboardDismisser.dismiss() }
            )
    }
}

public extension View {

    /// Adds a "Done" button to the keyboard accessory bar.
    ///
    /// Apply to any screen containing a numeric field — those keyboards have no return key, so this
    /// is the only affordance the user has.
    func keyboardDoneToolbar() -> some View {
        modifier(KeyboardDoneToolbar())
    }

    /// Dismisses the keyboard when the user taps outside a field, without blocking other controls.
    func dismissesKeyboardOnTap() -> some View {
        modifier(TapToDismissKeyboard())
    }
}
