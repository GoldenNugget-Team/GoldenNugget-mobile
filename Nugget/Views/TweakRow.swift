import SwiftUI

/// One tweak: its title, the control its kind calls for, and its id.
///
/// Shared by the Tweaks and Daemons pages so a daemon row is not a lookalike of
/// a tweak row but literally the same view.
///
/// The toggle's read and write are injected rather than read off the selection,
/// because the two pages disagree about what "on" means: a tweak is on when its
/// flag is set, a daemon group is on when every launchd label in it has to be
/// written as disabled, and only the second one needs a value written alongside
/// the flag. Everything else -- the text field, the numeric editor -- reads and
/// writes the selection directly in both pages, so the selection is always
/// carried rather than made optional: a row whose kind happens to be `.text`
/// must not lose its editor because its toggle had a special meaning.
struct TweakRow: View {
    let spec: TweakSpec
    @Binding private var selection: TweakSelection
    private let readOn: () -> Bool
    private let writeOn: (Bool) -> Void

    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.init(spec: spec, selection: selection, readOn: nil, writeOn: nil)
    }

    /// The daemon shape: same row, but the page decides what the switch means.
    init(spec: TweakSpec, selection: Binding<TweakSelection>,
         isOn: @escaping () -> Bool, setOn: @escaping (Bool) -> Void) {
        self.init(spec: spec, selection: selection, readOn: isOn, writeOn: setOn)
    }

    /// The one that actually assigns.
    ///
    /// Its labels are `readOn`/`writeOn` — the stored properties' names — and not
    /// `isOn`/`setOn` with optional types.  It used to be the latter, which made
    /// the three-argument initializer above resolve *to itself* (the compiler
    /// said so: "function call causes an infinite recursion") instead of to this
    /// one, so every daemon row recursed until the stack ran out.  Distinct
    /// labels make the choice unambiguous rather than a question of which
    /// overload wins.
    private init(spec: TweakSpec, selection: Binding<TweakSelection>,
                 readOn: (() -> Bool)?, writeOn: ((Bool) -> Void)?) {
        self.spec = spec
        self._selection = selection
        self.readOn = readOn ?? { selection.wrappedValue.isOn(spec) }
        self.writeOn = writeOn ?? { selection.wrappedValue.setOn($0, for: spec) }
    }

    var body: some View {
        Group {
            switch spec.kind {
            case .toggle:
                Toggle(isOn: toggleBinding) {
                    TweakRowLabel(title: spec.title, id: spec.id, detail: spec.detail)
                }
            case .text:
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.title)
                    TextField("(empty = clear)", text: textBinding)
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TweakRowCaption(id: spec.id, detail: spec.detail)
                }
            case .number:
                VStack(alignment: .leading, spacing: 6) {
                    Text(spec.title)
                    TweakNumberField(spec: spec, selection: $selection)
                    TweakRowCaption(id: spec.id, detail: spec.numberHint)
                }
            }
        }
    }

    private var toggleBinding: Binding<Bool> {
        Binding(get: readOn, set: writeOn)
    }

    private var textBinding: Binding<String> {
        Binding(get: {
            if case .string(let value) = selection.value(for: spec) { return value }
            return selection.value(for: spec).display
        }, set: { selection.setValue(.string($0), for: spec) })
    }
}

/// A numeric editor that keeps its own draft text.
///
/// Binding the field straight to the selection would fight the user: the value
/// is clamped and re-typed on every keystroke, so an intermediate `""` or `1`
/// would snap the field back mid-edit.  The draft holds what was typed, the
/// selection holds what is valid, and committing on submit shows the latter.
struct TweakNumberField: View {
    let spec: TweakSpec
    @Binding var selection: TweakSelection
    @State private var draft: String

    /// The draft is seeded here, once, and never re-seeded.
    ///
    /// It used to be seeded in `onAppear` — and that assignment is a *change*
    /// like any other, so `onChange(of: draft)` read it as "the user typed this"
    /// and `setValue`, which switches the tweak on the way the reference's
    /// `toggle_enabled=True` does, switched on every number tweak whose row
    /// scrolled into view.  The page then reported 42 tweaks enabled after two
    /// switches were flipped, 38 of them Liquid Glass: 39 of the 41 value-shaped
    /// Liquid Glass specs are numbers, and the row that had not been scrolled to
    /// yet was the difference.  The count grew as the user scrolled, which is
    /// why it was the number on the way *out* that looked wrong.
    ///
    /// A flag set in the same `onAppear` cannot guard this, because `onChange`
    /// runs in the update *after* it, when the flag is already set.  The only
    /// way to keep the seed out of `onChange` is to not make it a change at all.
    init(spec: TweakSpec, selection: Binding<TweakSelection>) {
        self.spec = spec
        self._selection = selection
        self._draft = State(initialValue: selection.wrappedValue.value(for: spec).display)
    }

    var body: some View {
        TextField("value", text: $draft)
            // `.decimalPad` has no Return key: on a phone the keyboard would
            // be impossible to dismiss.
            .keyboardType(.decimalPad)
            .nativeKeyboardDone()
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .textFieldStyle(.roundedBorder)
            .onChange(of: draft) { newValue in
                if let value = spec.numberValue(from: newValue) {
                    selection.setValue(value, for: spec)
                }
            }
            .onSubmit { draft = selection.value(for: spec).display }
    }
}

/// A toggle row's label: the title, its registry id in the caption style, and
/// the registry's description when it has one.
private struct TweakRowLabel: View {
    let title: String
    let id: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            Text(id)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let detail {
                NativeNote(detail)
            }
        }
    }
}

/// The caption block under a field row: the registry id, then the hint or
/// description.
private struct TweakRowCaption: View {
    let id: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(id)
                .font(.caption)
                .foregroundStyle(.tertiary)
            if let detail {
                NativeNote(detail)
            }
        }
    }
}
