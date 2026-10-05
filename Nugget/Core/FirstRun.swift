import Foundation
import SwiftUI

/// Whether the one-time setup guide has been finished — or skipped, which counts
/// as finished because a gate the user cannot get past is not a gate.
///
/// Persisted rather than `@State`, because the gate has to hold across launches;
/// that is the entire reason the screen exists. An in-memory flag would show the
/// guide on every cold start, which is how an onboarding screen becomes the thing
/// users learn to dismiss without reading.
///
/// Observed as an `ObservableObject` rather than mirrored with a second
/// `@AppStorage` at the gate, because `@AppStorage` in this class *is* the store:
/// `RootView` observes this object so finishing the guide lifts the gate in the
/// same run that set the flag, with no second copy of the key to keep in step.
final class FirstRunSettings: ObservableObject {
    static let shared = FirstRunSettings()

    /// `@AppStorage("FirstRunCompleted")` — false until the guide is finished.
    ///
    /// Named apart from `PairingRecord`'s keys on purpose: this is the app's own
    /// bookkeeping, not part of a pairing record, and a user who resets the record
    /// must land back on the guide rather than on a home page that cannot connect.
    @AppStorage("FirstRunCompleted") private var completed = false

    private init() {}

    var isComplete: Bool { completed }

    /// Leave the guide, for either reason.
    ///
    /// - Parameter reason: what the log says happened. Both are logged with their
    ///   own wording, because "the user skipped setup" and "the user finished
    ///   setup" are different facts about a device and a bug report will want to
    ///   tell them apart — a first report that starts with a guide the user never
    ///   dismissed looks like a broken launch.
    func complete(reason: String) {
        let wasComplete = completed
        completed = true
        GoldenNuggetEngine.shared.log(wasComplete
            ? "setup guide re-opened and closed again (\(reason))"
            : "setup guide finished (\(reason))")
    }
}