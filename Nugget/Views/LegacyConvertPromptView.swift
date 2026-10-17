import SwiftUI

/// The legacy-format question, as `PosterboardTweak`'s import-time dialog.
///
/// One view modifier for both places a pack can arrive — the PosterBoard page's
/// picker and the wallpaper downloader — because the question and its two answers
/// are the same either way, and two copies of a dialog that has to stay
/// word-compatible with the desktop build is two copies to drift.
///
/// The dismissal rule is the reference's: `prompt_legacy_convert` returns
/// `clickedButton() is convert`, so anything that is not the Convert button means
/// "install as is". A pack is never silently converted and never dropped.
struct LegacyConvertPromptModifier: ViewModifier {
    @Binding var prompt: LegacyConvertPrompt?
    /// Store the answer. The caller clears `prompt` and reloads the selection, so
    /// the answer is applied to the pack the caller already has rather than
    /// returned here.
    let answer: (LegacyConvertPrompt, Bool) -> Void

    /// The question this modifier already answered, so dismissing `prompt` — which
    /// the act of answering does, and which is not a second answer — cannot record
    /// "install as is" over a "convert".
    @State private var answeredID: String?

    func body(content: Content) -> some View {
        content.alert(
            "Legacy Wallpaper Format",
            isPresented: Binding(
                get: { prompt != nil },
                set: { if !$0 { dismiss() } }),
            presenting: prompt
        ) { prompt in
            Button(LegacyConvertPrompt.convertTitle) { resolve(prompt, true) }
            Button(LegacyConvertPrompt.asIsTitle, role: .cancel) { resolve(prompt, false) }
        } message: { prompt in
            // The reference puts the pack and its families in bold above the
            // explanation. An alert's message is the only body it has, so the two
            // are separated rather than styled.
            Text(prompt.title + "\n\n" + LegacyConvertPrompt.message)
        }
    }

    private func resolve(_ prompt: LegacyConvertPrompt, _ convert: Bool) {
        guard answeredID != prompt.id else { return }
        answeredID = prompt.id
        answer(prompt, convert)
    }

    /// Closed without choosing: the reference's Escape, which resolves to
    /// "install as is".
    private func dismiss() {
        guard let prompt, answeredID != prompt.id else { return }
        answeredID = prompt.id
        answer(prompt, false)
    }
}

extension View {
    func legacyConvertPrompt(_ prompt: Binding<LegacyConvertPrompt?>,
                             answer: @escaping (LegacyConvertPrompt, Bool) -> Void) -> some View {
        modifier(LegacyConvertPromptModifier(prompt: prompt, answer: answer))
    }
}
