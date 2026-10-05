import Foundation

/// Applies the AutoSave preset exactly once per launch.
///
/// The restore used to live in `TweaksView`, which made the launch order load
/// bearing in a way that was never stated anywhere: the Home page's "N enabled"
/// and "N of 40 groups" badges read `tweakSelection`, and that selection was
/// only populated once the Tweaks tab was built. A fresh launch therefore showed
/// zeroes on the cards until you happened to visit the page — and since the
/// cards are what you read *before* deciding to visit anything, the app looked
/// like it had forgotten the selection when it had not.
///
/// The identity is needed by the restore (device version, model, iPhone/iPad
/// split, all of which the import filters on), and identity comes from lockdown
/// asynchronously. So the restore runs from the first `.task` that has one, and
/// the guard makes the second caller a no-op rather than a second apply.
enum AutoSaveBootstrap {
    private static let lock = NSLock()
    private static var applied = false

    /// The report from the apply, for whoever ran it. Later callers get nil --
    /// not because nothing happened, but because it already happened.
    @discardableResult
    static func apply(into selection: inout TweakSelection,
                      identity: DeviceIdentity) -> TweakImportReport? {
        lock.lock()
        if applied {
            lock.unlock()
            return nil
        }
        applied = true
        lock.unlock()
        return GoldenNuggetAutosave.restore(into: &selection, identity: identity)
    }

}
