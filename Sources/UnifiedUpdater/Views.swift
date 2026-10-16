import AppKit
import SwiftUI
import UpdaterCore

private let accent = Color(red: 0.08, green: 0.66, blue: 0.56)
// Explicit type lookup avoids a State macro name collision in newer SDKs.
private typealias ViewState<Value> = SwiftUI.State<Value>

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    Image(nsImage: NSApplication.shared.applicationIconImage).resizable().scaledToFit().frame(width: 38, height: 38)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Unified Updater").font(.headline)
                        Text("A little less to keep up with.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 16).padding(.vertical, 25)
                List(selection: $model.screen) {
                    Section("LIBRARY") {
                        ForEach([Screen.updates, .installed, .appStore]) { screen in sidebarRow(screen) }
                    }
                    Section("MANAGE") {
                        ForEach([Screen.activity, .cleanup, .sources, .settings]) { screen in sidebarRow(screen) }
                    }
                }.listStyle(.sidebar)
                VStack(alignment: .leading, spacing: 8) {
                    Label("LOCAL FIRST", systemImage: "lock.shield").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    HStack { Text("Version 0.1.2"); Spacer(); Text("ALPHA").fontWeight(.semibold) }.font(.caption2).foregroundStyle(.tertiary)
                }.padding(20)
            }.navigationSplitViewColumnWidth(min: 220, ideal: 235, max: 270)
        } detail: {
            VStack(spacing: 0) {
                pageHeader
                Divider()
                Group {
                    if model.settingUp {
                        setupPage
                    } else {
                        switch model.screen ?? .updates {
                        case .updates, .installed, .appStore: inventoryPage
                        case .activity: activityPage
                        case .cleanup: cleanupPage
                        case .sources: sourcesPage
                        case .settings: settingsPage
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                if !model.settingUp && model.setupNeedsAttention {
                    HStack {
                        Label("Some update sources could not be prepared.", systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("View Setup") { model.screen = .sources }
                        Button("Retry Setup", action: model.prepareSources).disabled(model.busy)
                    }.font(.callout).padding(14).background(Color.orange.opacity(0.08))
                }
                Divider()
                HStack(spacing: 9) {
                    if model.busy { ProgressView().controlSize(.small) }
                    else { Image(systemName: "circle.fill").font(.system(size: 6)).foregroundStyle(accent) }
                    Text(model.status).lineLimit(1)
                    Spacer()
                    if let date = model.lastScan { Text(date, style: .relative); Text("ago").padding(.leading, -5) }
                }.font(.caption).foregroundStyle(.secondary).padding(.horizontal, 22).padding(.vertical, 12)
            }.background(Color(nsColor: .windowBackgroundColor))
        }
        .tint(accent)
        .frame(minWidth: 1080, minHeight: 720)
        .sheet(isPresented: $model.showingReview) { ReviewSheet().environmentObject(model) }
        .sheet(item: $model.inspected) { app in AppDetailSheet(app: app).environmentObject(model) }
        .alert("Needs attention", isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    func sidebarRow(_ screen: Screen) -> some View {
        HStack {
            Label(screen.rawValue, systemImage: screen.symbol)
            Spacer()
            if screen == .updates && !model.eligible.isEmpty {
                Text("\(model.eligible.count)").font(.caption.weight(.medium)).padding(.horizontal, 7).padding(.vertical, 2).background(accent.opacity(0.12), in: Capsule())
            }
        }.padding(.vertical, 5).tag(screen)
    }
    var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                Text((model.screen ?? .updates).rawValue).font(.system(size: 27, weight: .semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if model.updating {
                Button(model.cancelRequested ? "Cancel requested" : "Cancel Remaining") { model.cancelRequested = true }.disabled(model.cancelRequested)
            } else {
                Button { model.scan() } label: { Label("Check for Updates", systemImage: "arrow.clockwise") }
                    .disabled(model.busy).keyboardShortcut("r", modifiers: .command)
                if [.updates, .appStore].contains(model.screen ?? .updates) {
                    Button("Update All (\(updateAllCandidates.count))") { model.prepare(updateAllCandidates) }
                        .buttonStyle(.borderedProminent).disabled(model.busy || updateAllCandidates.isEmpty)
                }
            }
        }.padding(26)
    }
    var updateAllCandidates: [AppRecord] { model.eligible.filter { model.screen != .appStore || $0.source == .appStore } }
    var subtitle: String {
        switch model.screen ?? .updates {
        case .updates: return "One place for the updates your sources can find."
        case .installed: return "Your applications, their sources, and what we could check."
        case .appStore: return "Store updates, without losing sight of the rest."
        case .activity: return "Every attempt, with a verified outcome."
        case .cleanup: return "Finish the update. Leave less behind."
        case .sources: return "Know where every update comes from."
        case .settings: return "Make update checks work for you."
        }
    }
    var inventoryPage: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                MetricCard(title: "APPLICATIONS", value: model.lastScan == nil && !model.scanning ? "—" : "\(model.apps.count)", subtitle: "In your scan folders", symbol: "square.grid.2x2")
                MetricCard(title: "READY TO UPDATE", value: model.lastScan == nil && !model.scanning ? "—" : "\(updateAllCandidates.count)", subtitle: "Eligible, non-ignored apps", symbol: "arrow.up.circle", highlighted: true)
                MetricCard(title: "CHECK COVERAGE", value: model.lastScan == nil && !model.scanning ? "—" : "\(model.checkedCount)/\(model.checkableCount)", subtitle: "Third-party apps · \(model.systemAppCount) managed by macOS", symbol: "checkmark.shield")
            }.padding(24)
            if !model.warnings.isEmpty || model.sources.contains(where: { $0.error != nil }) {
                HStack(alignment: .top) {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Some checks need attention").font(.callout.weight(.medium))
                        Text((model.warnings + model.sources.compactMap { $0.error == nil ? nil : "\($0.source.title): check incomplete" }).joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer()
                    Button("View Sources") { model.screen = .sources }
                }.padding(14).background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 10)).padding(.horizontal, 24).padding(.bottom, 18)
            }
            HStack(spacing: 12) {
                HStack { Image(systemName: "magnifyingglass").foregroundStyle(.secondary); TextField("Search applications", text: $model.search).textFieldStyle(.plain) }
                    .padding(9).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 7)).frame(maxWidth: 290)
                Picker("Source", selection: $model.sourceFilter) {
                    Text("All sources").tag(nil as UpdateSource?)
                    ForEach(UpdateSource.allCases) { source in Text(source.title).tag(Optional(source)) }
                }.labelsHidden().frame(width: 150)
                Toggle("Show ignored", isOn: $model.showIgnored).toggleStyle(.checkbox).font(.caption)
                Spacer()
                Text("\(model.filteredApps.count) \(model.filteredApps.count == 1 ? "app" : "apps")").font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal, 24).padding(.bottom, 16)
            if model.lastScan == nil && model.apps.isEmpty && !model.scanning {
                EmptyState(symbol: "arrow.triangle.2.circlepath", title: "Your apps, one place.", message: "Check your application folders and available sources. Nothing is installed or updated until you review a plan.", action: "Check for Updates", perform: model.scan)
            } else if model.filteredApps.isEmpty {
                EmptyState(symbol: model.scanning ? "hourglass" : "checkmark.circle", title: model.scanning ? "Checking your sources…" : "No apps in this view", message: emptyMessage)
            } else {
                HStack {
                    Text("APPLICATION").frame(maxWidth: .infinity, alignment: .leading)
                    Text("VERSION").frame(width: 145, alignment: .leading)
                    Text("SOURCE").frame(width: 95, alignment: .leading)
                    Text("STATUS / ACTION").frame(width: 170, alignment: .leading)
                }.font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 61).padding(.trailing, 24).padding(.bottom, 8)
                Divider().padding(.horizontal, 24)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.filteredApps) { app in
                            AppRow(app: app).environmentObject(model)
                            Divider().padding(.leading, 74)
                        }
                    }.padding(.horizontal, 24)
                }
            }
            if !model.selected.isEmpty {
                HStack {
                    Text("\(model.selected.count) selected").font(.callout)
                    Button("Clear") { model.selected.removeAll() }.buttonStyle(.plain).foregroundStyle(.secondary)
                    Spacer()
                    Button("Update Selected") { model.prepare(model.eligible.filter { model.selected.contains($0.id) }) }.buttonStyle(.borderedProminent).disabled(model.busy)
                }.padding(16).background(accent.opacity(0.07))
            }
        }
    }
    var emptyMessage: String {
        if !model.search.isEmpty || model.sourceFilter != nil { return "Try another search or source filter." }
        if model.screen == .installed { return "No readable applications were found in your scan folders. Review the locations in Settings." }
        if model.screen == .appStore { return "No App Store apps were identified in the scanned folders." }
        return "No available updates in this view. \(model.checkedCount) of \(model.apps.count) apps were checked. Review Installed Apps for unchecked applications."
    }
    var setupResults: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 16) {
                Text("Update source setup").font(.headline)
                Text("Maccet prepares enabled sources and their required tools when you open the app. macOS may ask for administrator permission. Application updates still require your review.")
                    .font(.callout).foregroundStyle(.secondary)
                ForEach(model.setupItems) { item in
                    HStack(alignment: .top, spacing: 12) {
                        if item.phase == .running { ProgressView().controlSize(.small).frame(width: 20) }
                        else { Image(systemName: item.phase == .ready ? "checkmark.circle.fill" : item.phase == .failed ? "exclamationmark.circle" : "circle")
                            .foregroundStyle(item.phase == .failed ? Color.orange : item.phase == .ready ? accent : Color.secondary).frame(width: 20) }
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(item.title).font(.callout.weight(.medium))
                                Spacer()
                                Text(item.phase.title).font(.caption).foregroundStyle(.secondary)
                            }
                            if let source = item.dependencyFor {
                                Text("Required for \(source.title)").font(.caption).foregroundStyle(.secondary)
                            }
                            Text(item.message).font(.caption).foregroundStyle(.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                if !model.settingUp {
                    Button(model.setupNeedsAttention ? "Retry Setup" : "Prepare Sources Again", action: model.prepareSources).disabled(model.busy)
                }
            }.padding(14).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    var setupPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Getting your update sources ready").font(.title2.weight(.semibold))
                Text("Setup can take a few minutes. Keep Maccet open while installers finish.").foregroundStyle(.secondary)
                setupResults
            }.padding(26)
        }
    }
    var sourcesPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                setupResults
                ForEach(model.sources) { source in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 15) {
                            HStack {
                                Image(systemName: source.source.symbol).font(.title2).foregroundStyle(accent).frame(width: 36)
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(source.source.title).font(.headline)
                                    Text(source.version.isEmpty ? "Optional integration" : source.version).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                StatusPill(title: model.preferences.disabledSources.contains(source.source) ? "Disabled" : source.error != nil ? "Needs attention" : source.available ? "Available" : "Missing", color: source.error != nil ? .orange : source.available ? accent : .secondary)
                            }
                            Text(source.message).foregroundStyle(.secondary)
                            if let path = source.executable { Text(path).font(.caption.monospaced()).textSelection(.enabled) }
                            if let error = source.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
                            HStack {
                                Toggle("Enable this source", isOn: Binding(get: { !model.preferences.disabledSources.contains(source.source) }, set: { enabled in
                                    if enabled { model.preferences.disabledSources.remove(source.source) } else { model.preferences.disabledSources.insert(source.source) }
                                    model.savePreferences(); model.invalidateInventory()
                                })).toggleStyle(.switch).disabled(model.busy)
                                Spacer()
                                Link("Setup & documentation ↗", destination: URL(string: source.source.documentationURL)!)
                            }
                        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Text("Each app appears once. When several installed managers claim it, choose one update route in the app's Details. A catalog match alone cannot take over an existing installation.").font(.callout).foregroundStyle(.secondary)
                Label("These switches control checks and future source preparation. A disabled manager may still be needed for the enabled App Store helper. Sparkle and vendor adapters are planned for a later release.", systemImage: "info.circle").font(.callout).foregroundStyle(.secondary)
            }.padding(26)
        }
    }
    var activityPage: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack { Text("UPDATE HISTORY").font(.caption.weight(.semibold)).foregroundStyle(.secondary); Spacer(); Button("Export Report…", action: model.exportReport) }.padding(24)
            if model.history.isEmpty {
                EmptyState(symbol: "clock.arrow.circlepath", title: "A clear record of every update", message: "Update attempts appear here with their verification and cleanup results.")
            } else {
                List(model.history) { entry in
                    VStack(alignment: .leading, spacing: 9) {
                        HStack {
                            Text(entry.appName).font(.headline)
                            Text("\(entry.fromVersion) → \(entry.targetVersion)").font(.caption.monospaced()).foregroundStyle(.secondary)
                            Spacer()
                            StatusPill(title: entry.state.title, color: entry.state == .succeeded ? accent : entry.state == .failed || entry.state == .interrupted ? .orange : .secondary)
                        }
                        Text(entry.message).font(.callout).textSelection(.enabled)
                        if let cleanup = entry.cleanupMessage { Label(cleanup, systemImage: "sparkles").font(.caption).foregroundStyle(.secondary) }
                        HStack { Text(entry.source?.title ?? "Unknown source"); Text("·"); Text(entry.date, style: .date); Text(entry.date, style: .time) }.font(.caption2).foregroundStyle(.tertiary)
                        if [.failed, .deferred, .interrupted].contains(entry.state) {
                            Button("Rescan Before Retrying", action: model.scan).font(.caption).disabled(model.busy)
                        }
                    }.padding(.vertical, 12)
                }.listStyle(.inset)
            }
        }
    }
    var cleanupPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 18) {
                    Image(systemName: "sparkles").font(.system(size: 34)).foregroundStyle(accent).padding(22).background(accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 18))
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Clean up after a verified update").font(.title2.weight(.semibold))
                        Text("Each Homebrew update uses an isolated download folder. Only that verified update's files are removed. App Store manages its own downloads.").foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                GroupBox {
                    Toggle("Remove isolated update downloads after successful verification", isOn: $model.preferences.cleanupAfterSuccess)
                        .padding(14).onChange(of: model.preferences.cleanupAfterSuccess) { _ in model.savePreferences() }.disabled(model.busy)
                }
                Text("CLEANUP RESULTS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                let records = model.history.filter { $0.cleanupMessage != nil }
                if records.isEmpty { Text("No cleanup has run yet. Results will appear after update attempts.").foregroundStyle(.secondary) }
                ForEach(records) { entry in
                    GroupBox {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack { Text(entry.appName).font(.headline); Spacer(); Text(entry.date, style: .date).font(.caption).foregroundStyle(.secondary) }
                            Text(entry.cleanupMessage ?? "").font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                    }
                }
                Text("Shared Homebrew caches and app data are preserved. This release does not provide a broad cache cleaner or space-saved estimates. Failed-attempt downloads are retained.").font(.caption).foregroundStyle(.secondary)
            }.padding(26)
        }
    }
    var settingsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("SCAN LOCATIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(model.preferences.scanRoots, id: \.self) { path in
                            HStack {
                                Label(path, systemImage: "folder").font(.callout).textSelection(.enabled)
                                Spacer()
                                Button { model.preferences.scanRoots.removeAll { $0 == path }; model.savePreferences(); model.invalidateInventory() } label: { Image(systemName: "minus.circle") }.buttonStyle(.plain).disabled(model.busy)
                            }
                            Divider()
                        }
                        Button("Add Folder…", action: model.addFolder).disabled(model.busy)
                        Toggle("Include macOS applications in the inventory", isOn: Binding(get: { model.preferences.includeSystemApplications ?? true }, set: { value in
                            model.preferences.includeSystemApplications = value; model.savePreferences(); model.invalidateInventory()
                        })).disabled(model.busy)
                        Text("Rescan after changing folders. System apps are listed for reference; nested app helpers are excluded.").font(.caption).foregroundStyle(.secondary)
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("EXCLUSIONS").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(model.preferences.ignoredPaths.count) ignored apps · \(model.preferences.skippedReleases.count) skipped releases")
                        Text("Manage individual exclusions from an app's details. Ignored apps stay visible in the inventory when Show ignored is enabled.").font(.callout).foregroundStyle(.secondary)
                        Button("Reset All Exclusions") { model.preferences.ignoredPaths = []; model.preferences.skippedReleases = [:]; model.savePreferences() }.disabled(model.busy || (model.preferences.ignoredPaths.isEmpty && model.preferences.skippedReleases.isEmpty))
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("PRIVACY & BEHAVIOR").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Inventory and history stay on this Mac.", systemImage: "lock.shield")
                        Label("Setup and checks contact GitHub, Homebrew, MacPorts, and Apple services.", systemImage: "network")
                        Label("Updates require your review. Apps are never force-quit.", systemImage: "hand.raised")
                        Label("Sources are prepared automatically at launch; app updates require review.", systemImage: "checkmark.shield")
                        Text("Stores up to 1,000 recent update records. Background scheduling and vendor-specific updates are planned for a later release.").font(.caption).foregroundStyle(.secondary)
                    }.font(.callout).padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(26)
        }
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppRecord
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(app.name)", isOn: Binding(get: { model.selected.contains(app.id) }, set: { on in
                if on { model.selected.insert(app.id) } else { model.selected.remove(app.id) }
            })).labelsHidden().toggleStyle(.checkbox).disabled(model.busy || !model.preferences.isEligible(app)).frame(width: 20)
            Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 36, height: 36).accessibilityHidden(true)
            Button { model.inspected = app } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.callout.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                    Text(model.preferences.ignoredPaths.contains(app.id) ? "Ignored" : app.bundleID).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain)
            VStack(alignment: .leading, spacing: 4) {
                Text(app.version).foregroundStyle(.secondary)
                if let target = app.targetVersion { Text("→ \(target)").foregroundStyle(accent) }
            }.font(.caption.monospaced()).lineLimit(1).frame(width: 145, alignment: .leading)
            Text(app.state == .systemManaged ? "macOS" : app.source?.title ?? ((app.routes?.count ?? 0) > 1 ? "Multiple" : app.sparkleFeed != nil ? "Sparkle feed" : "Unknown")).font(.caption).foregroundStyle(.secondary).frame(width: 95, alignment: .leading)
            VStack(alignment: .leading, spacing: 7) {
                Text(app.state.title).font(.caption).foregroundStyle(app.hasUpdate ? accent : .secondary)
                if model.preferences.isEligible(app) {
                    Button("Review Update") { model.prepare([app]) }.controlSize(.small).disabled(model.busy)
                } else if app.state == .ambiguous && (app.routes?.count ?? 0) > 1 {
                    Button("Choose Manager") { model.inspected = app }.controlSize(.small).disabled(model.busy)
                } else if app.hasStoreReceipt || (app.source == .homebrew && app.hasUpdate) {
                    Button(app.hasStoreReceipt ? "Open App Store ↗" : "View Source ↗") { model.openSource(for: app) }.buttonStyle(.plain).font(.caption).foregroundStyle(accent)
                }
            }.frame(width: 170, alignment: .leading)
        }.padding(.vertical, 15)
        .contextMenu {
            Button("Details") { model.inspected = app }
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
            Button(model.preferences.ignoredPaths.contains(app.id) ? "Stop Ignoring" : "Ignore App") { model.toggleIgnored(app) }.disabled(model.busy)
            if app.hasUpdate { Button("Skip This Release") { model.skip(app) }.disabled(model.busy) }
        }
    }
}

struct MetricCard: View {
    var title: String; var value: String; var subtitle: String; var symbol: String
    var highlighted = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Text(title).font(.system(size: 10, weight: .semibold)); Spacer(); Image(systemName: symbol).font(.callout) }.foregroundStyle(highlighted ? accent : .secondary)
            Text(value).font(.system(size: 31, weight: .semibold, design: .rounded)).foregroundStyle(highlighted ? accent : .primary)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        }.padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? accent.opacity(0.06) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(highlighted ? accent.opacity(0.2) : Color.primary.opacity(0.06)))
    }
}

struct StatusPill: View {
    let title: String; let color: Color
    var body: some View { Text(title).font(.caption.weight(.medium)).foregroundStyle(color).padding(.horizontal, 9).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule()) }
}

struct EmptyState: View {
    var symbol: String; var title: String; var message: String
    var action: String? = nil; var perform: (() -> Void)? = nil
    var body: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 30)
            Image(systemName: symbol).font(.system(size: 43, weight: .light)).foregroundStyle(accent).padding(.bottom, 4)
            Text(title).font(.title2.weight(.semibold))
            Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
            if let action, let perform { Button(action, action: perform).buttonStyle(.borderedProminent).padding(.top, 5) }
            Spacer(minLength: 30)
        }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var requestQuit = false
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Label("Review updates", systemImage: "arrow.up.circle").font(.title2.weight(.semibold))
            Text("\(model.review.count == 1 ? "This application is" : "These \(model.review.count) applications are") included. Each target and installed identity will be rechecked before installation.").foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(model.review) { item in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 8) {
                                HStack { Text(item.app.name).font(.headline); Spacer(); Text("\(item.app.version) → \(item.app.targetVersion ?? "")").font(.caption.monospaced()) }
                                Text(item.app.source?.title ?? "").font(.caption).foregroundStyle(.secondary)
                                Text(item.preview).font(.caption).textSelection(.enabled)
                            }.frame(maxWidth: .infinity, alignment: .leading).padding(10)
                        }
                    }
                }
            }
            Toggle("Request a normal quit for running apps", isOn: $requestQuit)
            Text(requestQuit ? "Save your work before continuing. Apps that do not quit will be deferred. Nothing is force-quit." : "Running apps will be deferred. Close them first, or enable the quit request above.").font(.caption).foregroundStyle(.secondary)
            Text(model.preferences.cleanupAfterSuccess ? "After verification: remove this attempt's isolated Homebrew downloads. Shared caches and app data are preserved." : "Post-update cleanup is disabled.").font(.caption).foregroundStyle(.secondary)
            Divider()
            HStack { Button("Cancel", action: model.cancelReview).keyboardShortcut(.cancelAction); Spacer(); Button("Start Updates") { model.startUpdates(requestQuit: requestQuit) }.buttonStyle(.borderedProminent) }
        }.padding(28).frame(width: 650, height: 610).tint(accent)
    }
}

struct AppDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) var dismiss
    let app: AppRecord
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: app.path)).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 5) { Text(app.name).font(.title2.weight(.semibold)); Text(app.bundleID).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                Spacer(); Button("Done") { dismiss() }
            }
            Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 12) {
                detail("Installed version", app.version)
                detail("Build", app.build.isEmpty ? "Unknown" : app.build)
                detail("Target release", app.targetVersion ?? "Not established")
                detail("Update source", app.source?.title ?? "No supported match")
                detail("Source identity", app.packageID ?? "Unknown")
                detail("Status", app.state.title)
                detail("Path", app.path)
            }.textSelection(.enabled)
            Text(app.detail).font(.callout).foregroundStyle(.secondary)
            if let routes = app.routes, routes.count > 1 {
                Picker("Update using", selection: Binding(get: { model.preferences.preferredSources?[app.id] }, set: { model.chooseSource($0, for: app) })) {
                    Text("Choose one manager").tag(nil as UpdateSource?)
                    ForEach(routes) { route in Text("\(route.source.title) · \(route.targetVersion ?? route.state.title)").tag(Optional(route.source)) }
                }.disabled(model.busy)
                Text("Only the selected manager will execute this app's update.").font(.caption).foregroundStyle(.secondary)
            }
            if app.sparkleFeed != nil { Label("A Sparkle feed was found. Feed checking is planned for a later release.", systemImage: "info.circle").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            HStack {
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                Button(model.preferences.ignoredPaths.contains(app.id) ? "Stop Ignoring" : "Ignore App") { model.toggleIgnored(app) }.disabled(model.busy)
                if app.hasUpdate { Button("Skip Release") { model.skip(app); dismiss() }.disabled(model.busy) }
                Spacer()
                if model.preferences.isEligible(app) { Button("Review Update") { dismiss(); model.prepare([app]) }.buttonStyle(.borderedProminent).disabled(model.busy) }
                else if app.source != nil || app.hasStoreReceipt { Button("Open Source") { model.openSource(for: app) } }
            }
        }.padding(28).frame(width: 730, height: 550).tint(accent)
    }
    func detail(_ title: String, _ value: String) -> some View {
        GridRow { Text(title).foregroundStyle(.secondary); Text(value).lineLimit(2) }.font(.callout)
    }
}
