import AppKit
import SwiftUI
import UpdaterCore

struct SetupSteps: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.setupItems.enumerated()), id: \.element.id) { index, item in
                HStack(alignment: .top, spacing: 14) {
                    Group {
                        if item.phase == .running { ProgressView().controlSize(.small) }
                        else { Image(systemName: item.phase == .ready ? "checkmark.circle.fill" : item.phase.needsAttention ? "exclamationmark.circle.fill" : "circle").foregroundStyle(item.phase.needsAttention ? StatusTone.failure.foreground : item.phase == .ready ? StatusTone.success.foreground : Maccet.tertiary) }
                    }.frame(width: 20, height: 20).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text(item.title).font(.system(size: 13, weight: .medium))
                            Spacer()
                            Text(phaseLabel(item.phase)).font(.system(size: 11)).foregroundStyle(item.phase.needsAttention ? StatusTone.failure.foreground : Maccet.secondary)
                        }
                        Text(item.message).font(.system(size: 12)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let path = item.executablePath { Text(path).font(.system(size: 11, design: .monospaced)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        if let source = item.dependencyFor {
                            Text("Required for \(source.title)").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        }
                    }
                }.padding(.vertical, 16).accessibilityElement(children: .combine)
                if index < model.setupItems.count - 1 { Divider().overlay(Maccet.border).padding(.leading, 34) }
            }
        }
    }
    private func phaseLabel(_ phase: SetupPhase) -> String {
        phase.title
    }
}
struct SetupPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                BrandIcon(size: 64)
                VStack(alignment: .leading, spacing: 10) {
                    Text(model.maintainingSources ? "Preparing update sources" : "Checking source readiness").font(.system(size: 28, weight: .semibold))
                    Text(model.maintainingSources ? "Installing and maintaining sources required by discovered applications." : "Checking installed tools before scanning applications.").font(.system(size: 13)).foregroundStyle(Maccet.secondary)
                }
                Surface { SetupSteps() }
                Label(model.maintainingSources ? "macOS may ask for administrator permission. Keep Maccet open until installers finish." : "Use Sources to install or maintain tools. Launch checks do not request authorization.", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: 680, alignment: .leading).padding(40).frame(maxWidth: .infinity)
        }
    }
}
struct SourcesPage: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var showSteps = true
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        HStack {
                            VStack(alignment: .leading, spacing: 5) {
                                Text("Source readiness and preparation").font(.system(size: 15, weight: .semibold))
                                Text("Launch checks readiness. Prepare Sources installs missing tools and refreshes required sources.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                            }
                            Spacer()
                            Button(model.setupActionTitle, action: model.prepareSources).disabled(model.busy)
                        }
                        if model.sources.first(where: { $0.source == .macPorts })?.available != true {
                            Toggle("Include optional MacPorts installation", isOn: $model.includeMacPortsInPreparation)
                                .toggleStyle(.checkbox).font(.system(size: 12))
                                .disabled(model.busy || model.preferences.disabledSources.contains(.macPorts))
                            Text("Choose this if you use MacPorts, then prepare sources. Other applications do not require installing this manager.")
                                .font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        }
                        DisclosureGroup("Readiness and preparation results", isExpanded: $showSteps) { SetupSteps() }
                    }
                }
                ForEach(model.sources) { source in SourceCard(source: source) }
                Text("These switches control checks and future source preparation. A disabled manager may still be needed for the enabled App Store helper.").font(.system(size: 12, weight: .medium)).foregroundStyle(Maccet.secondary)
                if !model.warnings.isEmpty {
                    Surface {
                        VStack(alignment: .leading, spacing: 10) {
                            Label("Scan diagnostics", systemImage: "exclamationmark.triangle").foregroundStyle(StatusTone.attention.foreground)
                            ForEach(Array(model.warnings.enumerated()), id: \.offset) { _, warning in Text(warning).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        }
                    }
                }
                Text("Each installed copy uses one verified manager. Choose between conflicting routes in the application's Details.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
}
private struct SourceCard: View {
    @EnvironmentObject var model: AppModel
    let source: SourceHealth
    private var disabled: Bool { model.preferences.disabledSources.contains(source.source) }
    private var setup: SetupItem? { model.setupItems.first { $0.id == (source.source == .homebrew ? "brew" : source.source == .macPorts ? "port" : "mas") } }
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Image(systemName: source.source.symbol).font(.system(size: 23, weight: .light)).foregroundStyle(Maccet.secondary).frame(width: 32).accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(source.source == .appStore ? "App Store via mas" : source.source.title).font(.system(size: 15, weight: .semibold))
                        if !source.version.isEmpty { Text(source.version).font(.system(size: 11, design: .monospaced)).foregroundStyle(Maccet.secondary).textSelection(.enabled) }
                    }
                    Spacer()
                    if !disabled && source.checkRequired != false { StatusPill(title: source.available ? "Tool available" : "Tool missing", tone: source.available ? .success : .attention) }
                    StatusPill(title: disabled ? "Checks disabled" : source.checkRequired == false ? (source.source == .macPorts && !source.available ? "Optional" : "Not needed") : source.error != nil ? "Check failed" : "Checks enabled", tone: disabled || source.checkRequired == false ? .neutral : source.error != nil ? .failure : .neutral)
                }
                Text(disabled ? "Application checks are disabled for this source." : source.message).font(.system(size: 13)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                if let setup, setup.phase == .failed {
                    Label("Setup failed: \(setup.message)", systemImage: "exclamationmark.circle").font(.system(size: 12)).foregroundStyle(StatusTone.failure.foreground).textSelection(.enabled)
                }
                if let error = source.error { Text(error).font(.system(size: 12)).foregroundStyle(StatusTone.failure.foreground).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                if source.source == .macPorts { Text("App checks use the local MacPorts index.").font(.system(size: 12)).foregroundStyle(Maccet.secondary) }
                DisclosureGroup("Technical details") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(source.executable ?? "No supported executable found").font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let setup { Text("Preparation: \(setup.message)").font(.system(size: 12)).textSelection(.enabled) }
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.top, 8)
                }.font(.system(size: 12))
                Divider().overlay(Maccet.border)
                HStack {
                    Toggle("Use this source for app checks", isOn: Binding(get: { !disabled }, set: { enabled in
                        if enabled { model.preferences.disabledSources.remove(source.source) } else { model.preferences.disabledSources.insert(source.source) }
                        model.savePreferences(); model.invalidateInventory()
                    })).toggleStyle(.switch).controlSize(.small).disabled(model.busy).accessibilityLabel("Use \(source.source.title) for app checks")
                    Spacer()
                    Link("Setup & documentation ↗", destination: URL(string: source.source.documentationURL)!)
                }.font(.system(size: 12))
            }
        }
    }
}

struct ActivityPage: View {
    @EnvironmentObject var model: AppModel
    private var current: ActivityRecord? { model.history.first { [.preflight, .installing, .verifying].contains($0.state) } ?? model.history.last { $0.state == .queued } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if model.updating, let entry = current {
                    Surface {
                        VStack(alignment: .leading, spacing: 16) {
                            Text("Current update").font(.system(size: 15, weight: .semibold))
                            HStack(spacing: 12) {
                                ApplicationIcon(path: entry.appPath)
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.appName).font(.system(size: 15, weight: .semibold))
                                    Text("\(entry.fromVersion) → \(entry.targetVersion) · \(entry.source?.title ?? "Unknown source")").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                                }
                                Spacer()
                                ProgressView().controlSize(.small)
                            }
                            HStack(spacing: 8) {
                                ForEach(Array(["Queued", "Checking", "Installing", "Verifying", "Result"].enumerated()), id: \.offset) { index, title in
                                    if index > 0 { Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Maccet.tertiary) }
                                    Text(title).font(.system(size: 11, weight: stage(entry.state) == index ? .semibold : .regular)).foregroundStyle(stage(entry.state) == index ? Maccet.accent : Maccet.secondary)
                                }
                                Spacer()
                                Text("\(model.history.filter { $0.state == .queued }.count) queued").font(.system(size: 11)).foregroundStyle(Maccet.tertiary)
                            }.accessibilityLabel("Current stage: \(entry.state == .preflight ? "Checking" : entry.state.title)")
                            Text(entry.message).font(.system(size: 12)).foregroundStyle(Maccet.secondary).textSelection(.enabled)
                        }
                    }
                }
                if model.history.isEmpty {
                    EmptyState(symbol: "clock.arrow.circlepath", title: "No update attempts yet", message: "Your update history will appear here, including verification results and any interrupted attempts.").frame(minHeight: 340)
                } else {
                    Text("Update history").font(.system(size: 15, weight: .semibold))
                    ForEach(model.history) { entry in HistoryCard(entry: entry) }
                }
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
    private func stage(_ state: TaskState) -> Int { switch state { case .queued: return 0; case .preflight: return 1; case .installing: return 2; case .verifying: return 3; default: return 4 } }
}
private struct HistoryCard: View {
    @EnvironmentObject var model: AppModel
    let entry: ActivityRecord
    var body: some View {
        Surface {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    ApplicationIcon(path: entry.appPath)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(entry.appName).font(.system(size: 13, weight: .semibold))
                        Text("\(entry.fromVersion) → \(entry.targetVersion)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Maccet.secondary)
                    }
                    Spacer()
                    StatusPill(title: entry.state == .preflight ? "Checking" : entry.state.title, tone: .forTask(entry.state))
                }
                Text(entry.message).font(.system(size: 13)).lineLimit(3).textSelection(.enabled)
                HStack {
                    Text(entry.source?.title ?? "Unknown source")
                    Text("·")
                    Text(entry.date, format: .dateTime.month(.abbreviated).day().hour().minute())
                }.font(.system(size: 11)).foregroundStyle(Maccet.tertiary)
                DisclosureGroup("Attempt details") {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(entry.message)
                        Text(entry.appPath).font(.system(size: 11, design: .monospaced))
                        if let cleanup = entry.cleanupMessage { Label(cleanup, systemImage: "sparkles") }
                    }.font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.top, 10)
                }.font(.system(size: 12))
                if [.failed, .deferred, .interrupted].contains(entry.state) {
                    Button("Rescan Before Retrying", action: model.scan).disabled(model.busy)
                }
            }
        }
    }
}
struct CleanupPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Label("Cleanup after verification", systemImage: "sparkles").font(.system(size: 15, weight: .semibold))
                        Text("Each Homebrew update uses an isolated download folder. Only files from a successfully verified attempt can be removed.").font(.system(size: 13)).foregroundStyle(Maccet.secondary)
                        Toggle("Remove update downloads after successful verification", isOn: $model.preferences.cleanupAfterSuccess).toggleStyle(.switch).controlSize(.small).onChange(of: model.preferences.cleanupAfterSuccess) { _ in model.savePreferences() }.disabled(model.busy)
                    }
                }
                Text("Cleanup results").font(.system(size: 15, weight: .semibold))
                let records = model.history.filter { $0.cleanupMessage != nil }
                if records.isEmpty { EmptyState(symbol: "sparkles", title: "No cleanup results yet.", message: "Results appear after update attempts.").frame(minHeight: 230) }
                ForEach(records) { entry in
                    Surface {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack { Text(entry.appName).font(.system(size: 13, weight: .semibold)); Spacer(); if let outcome = CleanupOutcome(message: entry.cleanupMessage ?? "") { StatusPill(title: outcome.title, tone: outcome.tone) }; Text(entry.date, style: .date).font(.system(size: 11)).foregroundStyle(Maccet.tertiary) }
                            // The captured cleanup message is the authority; update success alone is not a cleanup result.
                            Label(entry.cleanupMessage ?? "", systemImage: "sparkles").font(.system(size: 12)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Text("Shared caches and application data are preserved. Failed attempts retain their downloads. App Store manages its own downloads.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
            }.padding(.horizontal, 28).padding(.bottom, 28)
        }
    }
}
struct SettingsPage: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Scan locations").font(.system(size: 15, weight: .semibold))
                        ForEach(model.preferences.scanRoots, id: \.self) { path in
                            HStack(alignment: .top, spacing: 12) {
                                Image(systemName: "folder").foregroundStyle(Maccet.secondary).accessibilityHidden(true)
                                Text(path).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                Spacer(minLength: 4)
                                Button("Remove") { model.preferences.scanRoots.removeAll { $0 == path }; model.savePreferences(); model.invalidateInventory() }.disabled(model.busy).accessibilityLabel("Remove scan folder \(path)")
                            }
                            Divider().overlay(Maccet.border)
                        }
                        Button("Add Folder…", action: model.addFolder).disabled(model.busy)
                        Toggle("Include macOS applications in the inventory", isOn: Binding(get: { model.preferences.includeSystemApplications ?? true }, set: { model.preferences.includeSystemApplications = $0; model.savePreferences(); model.invalidateInventory() })).disabled(model.busy)
                        Text("Changing folders requires a new scan. System apps are updated through macOS; nested helpers are excluded.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Exclusions").font(.system(size: 15, weight: .semibold))
                        Text("\(model.preferences.ignoredPaths.count) ignored apps · \(model.preferences.skippedReleases.count) skipped releases").font(.system(size: 13))
                        Text("Reset immediately clears only Maccet's ignore and skipped-release preferences. Manage individual exclusions in application Details.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        Button("Reset All Exclusions") { model.preferences.ignoredPaths = []; model.preferences.skippedReleases = [:]; model.savePreferences() }.disabled(model.busy || (model.preferences.ignoredPaths.isEmpty && model.preferences.skippedReleases.isEmpty))
                    }
                }
                Surface {
                    VStack(alignment: .leading, spacing: 16) {
                        Text("Privacy & behavior").font(.system(size: 15, weight: .semibold))
                        Label("Inventory and history stay on this Mac. Up to 1,000 recent attempts are kept.", systemImage: "lock.shield")
                        Label("Source preparation and checks contact GitHub, Homebrew, MacPorts, and Apple services.", systemImage: "network")
                        Label("Application updates require your review and revalidation.", systemImage: "checkmark.shield")
                        Label("Running apps can be asked to quit normally. Apps are never force-quit.", systemImage: "hand.raised")
                    }.font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                }
            }.frame(maxWidth: 840, alignment: .leading).padding(.horizontal, 28).padding(.bottom, 28).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
