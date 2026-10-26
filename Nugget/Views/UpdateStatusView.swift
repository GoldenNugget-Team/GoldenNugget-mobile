import SwiftUI

/// Shared launch notice and Settings controls. Checks never install anything;
/// release links open the mobile repository's signed-by-the-user IPA workflow.
struct UpdateStatusSection: View {
    @ObservedObject private var updates = AppUpdateService.shared

    var body: some View {
        Section("Updates") {
            if let release = updates.available {
                Label("GoldenNugget Mobile \(release.tag_name) is available", systemImage: "arrow.down.circle")
                if let notes = release.body, !notes.isEmpty {
                    Text(notes).font(.footnote).textSelection(.enabled)
                }
                Link("View release", destination: release.pageURL ?? AppRelease.latestURL)
                if let download = release.downloadURL {
                    Link("Download IPA", destination: download)
                    NativeNote("Install the downloaded IPA with your sideloading tool.")
                }
            } else if updates.noReleases && updates.error == nil {
                Text("No mobile releases have been published yet.")
            } else if updates.checkedAt != nil && updates.error == nil {
                Text("You're up to date.")
            }
            if let error = updates.error { NativeNote(error) }
            Button {
                Task { await updates.refresh(force: true) }
            } label: {
                HStack {
                    Text(updates.checking ? "Checking…" : "Check for updates")
                    if updates.checking { Spacer(); ProgressView() }
                }
            }
            .disabled(updates.checking)
            if let date = updates.checkedAt {
                LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct HotLoadSettingsSection: View {
    @ObservedObject private var hotload = HotLoadService.shared

    var body: some View {
        Section("HotLoad") {
            Toggle("HotLoad safety rules", isOn: $hotload.enabled)
                .onChange(of: hotload.enabled) { _, enabled in
                    if enabled { Task { await hotload.refresh() } }
                }
            NativeNote("Checks mobile safety rules at launch and keeps a local copy for offline use. Rules can warn about tweaks, hide features, force daemon settings, or require an update.")
            if hotload.enabled {
                LabeledContent("Rules version", value: "\(hotload.rules.version)")
                if let error = hotload.error { NativeNote(error) }
                Button(hotload.checking ? "Refreshing…" : "Refresh safety rules") {
                    Task { await hotload.refresh() }
                }.disabled(hotload.checking)
                if let date = hotload.checkedAt {
                    LabeledContent("Last checked", value: date.formatted(date: .abbreviated, time: .shortened))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// An in-place gate, not a dismissible sheet or an intentional process crash.
/// Fresh rules and identity changes reevaluate it through RootView's observers.
struct HotLoadGateView: View {
    let policy: HotLoadPolicy
    @ObservedObject private var updates = AppUpdateService.shared
    @ObservedObject private var hotload = HotLoadService.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(policy.blockingReason == nil ? "Update required" : "GoldenNugget is unavailable", systemImage: "exclamationmark.triangle")
                        .font(.headline)
                    Text(policy.gateReason ?? "")
                    if let version = policy.requiredVersion { Text("Required release: \(version)") }
                    NativeNote("Install an updated mobile build and reopen the app. Downloading an IPA does not unblock this build.")
                }
                UpdateStatusSection()
                Section {
                    Link("Mobile releases", destination: updates.releaseURL)
                    Button("Refresh safety rules") { Task { await hotload.refresh() } }
                        .disabled(hotload.checking)
                    if let error = hotload.error { NativeNote(error) }
                }
            }
            .navigationTitle("GoldenNugget")
        }
    }
}
