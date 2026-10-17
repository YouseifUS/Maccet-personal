import AppKit
import SwiftUI
import UpdaterCore

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        GeometryReader { geometry in
        HSplitView {
            sidebar.frame(minWidth: 220, idealWidth: 232, maxWidth: 270).frame(height: geometry.size.height)
            VStack(spacing: 0) {
                if !model.settingUp { pageHeader }
                Group {
                    if model.settingUp { SetupPage() }
                    else {
                        switch model.screen ?? .updates {
                        case .updates, .installed, .appStore: inventoryPage
                        case .activity: ActivityPage()
                        case .cleanup: CleanupPage()
                        case .sources: SourcesPage()
                        case .settings: SettingsPage()
                        }
                    }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
                statusStrip
            }.background(Maccet.background).frame(maxWidth: .infinity).frame(height: geometry.size.height)
        }
        }
        .tint(Maccet.accent).foregroundStyle(Maccet.text)
        .frame(minWidth: 1080, minHeight: 720)
        .sheet(isPresented: $model.showingReview, onDismiss: { if !model.updating { model.cancelReview() } }) { ReviewSheet().environmentObject(model) }
        .sheet(item: $model.vendorReview) { plan in VendorHandoffSheet(plan: plan) }
        .sheet(item: $model.inspected) { app in AppDetailSheet(app: app).environmentObject(model) }
        .alert(model.errorTitle, isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 10) {
                BrandIcon(size: 36)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Maccet").font(.system(size: 20, weight: .semibold)).foregroundStyle(Maccet.sidebarText)
                    Text("Your Mac updates, together.").font(.system(size: 11)).foregroundStyle(Maccet.sidebarSecondary).fixedSize(horizontal: false, vertical: true)
                }
            }.padding(.horizontal, 20).padding(.top, 28).padding(.bottom, 32)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    navigationGroup("LIBRARY", screens: [.updates, .installed, .appStore])
                    navigationGroup("MANAGE", screens: [.activity, .cleanup, .sources, .settings])
                }.padding(.horizontal, 12)
            }
            VStack(alignment: .leading, spacing: 8) {
                Label("Local to this Mac", systemImage: "lock.shield").font(.system(size: 11))
                Text("\(Maccet.version) · Alpha").font(.system(size: 11))
            }.foregroundStyle(Maccet.sidebarSecondary).padding(24)
        }.frame(maxWidth: .infinity, maxHeight: .infinity).background(Maccet.sidebar)
    }
    private func navigationGroup(_ title: String, screens: [Screen]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(Maccet.sidebarSecondary).padding(.leading, 12).padding(.bottom, 6)
            ForEach(screens) { screen in
                NavigationItem(screen: screen, selected: model.screen == screen, count: screen == .updates ? model.eligible.count : 0, attention: screen == .sources && (model.setupNeedsAttention || model.sourceChecksNeedAttention)) { model.screen = screen }
            }
        }
    }
    private var pageHeader: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 7) {
                Text((model.screen ?? .updates).rawValue).font(.system(size: 28, weight: .semibold))
                Text(subtitle).font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                if model.updating {
                    Button(model.cancelRequested ? "Cancel requested" : "Cancel Remaining") { model.cancelRequested = true }.disabled(model.cancelRequested)
                } else if [.updates, .installed, .appStore].contains(model.screen ?? .updates) {
                    Button("Check for Updates", action: model.scan).disabled(model.busy).keyboardShortcut("r", modifiers: .command)
                    if model.screen != .installed {
                        Button(updateAllCandidates.isEmpty ? "Update All" : "Update All (\(updateAllCandidates.count))") { model.prepare(updateAllCandidates) }
                            .buttonStyle(PrimaryButtonStyle()).disabled(model.busy || updateAllCandidates.isEmpty)
                            .help(model.busy ? "Wait for the current operation to finish." : updateAllCandidates.isEmpty ? "No eligible updates are available." : model.screen == .appStore ? "Review all eligible App Store updates, regardless of search." : "Review all eligible updates, regardless of search or source filters.")
                    }
                } else if model.screen == .activity { Button("Export Report…", action: model.exportReport) }
            }.controlSize(.large)
        }.padding(28)
    }
    private var statusStrip: some View {
        HStack(spacing: 8) {
            if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Operation in progress") }
            Text(model.status).lineLimit(1).help(model.status)
            Spacer(minLength: 8)
            if let date = model.lastScan {
                Text("Last checked \(date.formatted(date: .omitted, time: .shortened))").fixedSize()
            }
        }.font(.system(size: 11)).foregroundStyle(Maccet.secondary).padding(.horizontal, 28).frame(height: 32)
            .background(Maccet.surface).overlay(alignment: .top) { Rectangle().fill(Maccet.border).frame(height: 1) }
    }
    private var subtitle: String {
        switch model.screen ?? .updates {
        case .updates: return "One place for the updates your sources can find."
        case .installed: return "Your applications, their sources, and what we could check."
        case .appStore: return "Store updates, alongside the rest of your apps."
        case .activity: return "Every attempt, with its outcome."
        case .cleanup: return "Finish the update. Leave less behind."
        case .sources: return "Know where every update comes from."
        case .settings: return "Make update checks work for you."
        }
    }
    private var storeView: Bool { model.screen == .appStore }
    private var inventory: [AppRecord] { model.apps.filter { !storeView || $0.hasStoreReceipt } }
    private var updateAllCandidates: [AppRecord] { model.eligible.filter { !storeView || $0.hasStoreReceipt && $0.source == .appStore } }
    private var hasResults: Bool { model.lastScan != nil || !model.apps.isEmpty }
    private var sourceAttention: Bool { model.setupNeedsAttention || !model.warnings.isEmpty || model.sourceChecksNeedAttention }
    private var inventoryPage: some View {
        VStack(spacing: 20) {
            HStack(alignment: .top, spacing: 16) {
                MetricCard(title: storeView ? "Store apps" : "Applications", value: hasResults ? "\(inventory.count)" : "—", subtitle: storeView ? "In your scan folders" : "In your scan folders", symbol: storeView ? "app.badge" : "square.grid.2x2")
                MetricCard(title: "Ready to update", value: hasResults ? "\(updateAllCandidates.count)" : "—", subtitle: "Ready for review", symbol: "arrow.up.circle", highlighted: true)
                MetricCard(title: storeView ? "Checked store apps" : "Checked", value: hasResults ? "\(inventory.filter { $0.state.isChecked }.count) / \(inventory.filter { $0.state != .systemManaged }.count)" : "—", subtitle: storeView ? "Checked / discovered store apps" : "\(model.systemAppCount) updated with macOS", symbol: "checkmark.shield")
            }
            if sourceAttention { AttentionBanner() }
            filters
            VStack(spacing: 0) {
                if !model.filteredApps.isEmpty {
                    tableHeader
                    Divider().overlay(Maccet.border)
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(model.filteredApps) { app in
                                AppRow(app: app)
                                Divider().overlay(Maccet.border).padding(.leading, 52)
                            }
                        }
                    }
                } else { inventoryEmptyState }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Maccet.surface, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Maccet.border))
            if !selectedCandidates.isEmpty && model.screen != .installed {
                HStack(spacing: 12) {
                    Text("\(selectedCandidates.count) selected").font(.system(size: 13, weight: .medium))
                    Button("Clear") { model.selected.removeAll() }.buttonStyle(.plain).foregroundStyle(Maccet.secondary)
                    Spacer()
                    Button("Update Selected") { model.prepare(selectedCandidates) }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy || selectedCandidates.isEmpty)
                }.padding(12).background(Maccet.selection, in: RoundedRectangle(cornerRadius: 8))
            }
        }.padding(.horizontal, 28).padding(.bottom, 24)
    }
    private var selectedCandidates: [AppRecord] { model.eligible.filter { model.selected.contains($0.id) && (!storeView || $0.hasStoreReceipt && $0.source == .appStore) } }
    private var filters: some View {
        HStack(spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Maccet.secondary).accessibilityHidden(true)
                TextField("Search applications", text: $model.search).textFieldStyle(.plain).accessibilityLabel("Search applications")
                if !model.search.isEmpty { Button { model.search = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(Maccet.secondary).accessibilityLabel("Clear search") }
            }.padding(.horizontal, 10).frame(height: 32).frame(maxWidth: 280).background(Maccet.surface, in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Maccet.border))
            if storeView { Text("App Store · via mas").font(.system(size: 12)).foregroundStyle(Maccet.secondary) }
            else {
                Picker("Source", selection: $model.sourceFilter) {
                    Text("All sources").tag(nil as UpdateSource?)
                    ForEach(UpdateSource.allCases) { source in Text(source.title).tag(Optional(source)) }
                }.labelsHidden().frame(width: 135).accessibilityLabel("Filter by source")
            }
            Toggle("Show ignored", isOn: $model.showIgnored).toggleStyle(.checkbox).font(.system(size: 12))
            Spacer(minLength: 0)
            Text("\(model.filteredApps.count) apps").font(.system(size: 11)).foregroundStyle(Maccet.tertiary).fixedSize()
        }
    }
    private var tableHeader: some View {
        HStack(spacing: 12) {
            Text("APPLICATION").frame(maxWidth: .infinity, alignment: .leading)
            Text("VERSION").frame(width: 108, alignment: .leading)
            Text("SOURCE").frame(width: 80, alignment: .leading)
            Text("STATUS / ACTION").frame(width: 156, alignment: .leading)
        }.font(.system(size: 10, weight: .semibold)).tracking(0.5).foregroundStyle(Maccet.tertiary).padding(.leading, 52).padding(.trailing, 16).padding(.vertical, 12)
    }
    @ViewBuilder private var inventoryEmptyState: some View {
        if model.scanning {
            EmptyState(symbol: "hourglass", title: "Checking your sources…", message: "Available results appear while the remaining sources are checked.", loading: true)
        } else if !model.search.isEmpty || (!storeView && model.sourceFilter != nil) || (!model.showIgnored && (model.screen == .updates ? inventory.filter { $0.hasUpdate || $0.state == .ambiguous } : inventory).contains { model.preferences.ignoredPaths.contains($0.id) || model.preferences.skippedReleases[$0.id] == $0.releaseIdentity }) {
            EmptyState(symbol: "magnifyingglass", title: "No apps match this view.", message: "Try another search or clear the current filters.", action: "Clear search & filters", perform: { model.search = ""; model.sourceFilter = nil; model.showIgnored = true })
        } else if model.lastScan == nil {
            EmptyState(symbol: "arrow.triangle.2.circlepath", title: "Your apps, one place.", message: "Check your folders and available sources. Application updates begin only after you review a plan.", action: "Check for Updates", perform: model.scan)
        } else if model.screen == .installed {
            EmptyState(symbol: "folder", title: "No applications found", message: "No readable apps were found in your scan folders.", action: "Open Settings", perform: { model.screen = .settings })
        } else if storeView, model.sources.contains(where: { $0.source == .appStore && ($0.error != nil || (!model.preferences.disabledSources.contains(.appStore) && !$0.available)) }) {
            EmptyState(symbol: "exclamationmark.triangle", title: "App Store checks need attention", message: "Store checking could not complete. View Sources for the reason and next step.", action: "View Sources", perform: { model.screen = .sources })
        } else if storeView {
            EmptyState(symbol: "app.badge", title: "No App Store apps found in these folders.", message: "Store apps are identified by their receipts. You can adjust the scan folders in Settings.")
        } else {
            EmptyState(symbol: "checkmark.circle", title: "No updates found in the checked apps.", message: "Checked \(model.checkedCount) of \(model.checkableCount) third-party apps. Unchecked apps may still have updates.", action: "View Installed Apps", perform: { model.screen = .installed })
        }
    }
}

private struct NavigationItem: View {
    let screen: Screen
    let selected: Bool
    let count: Int
    let attention: Bool
    let action: () -> Void
    @ViewState private var hovering = false
    @Environment(\.isFocused) private var focused
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: screen.symbol).font(.system(size: 14)).frame(width: 18).foregroundStyle(selected ? Maccet.sidebarText : Maccet.sidebarSecondary).accessibilityHidden(true)
                Text(screen.rawValue).font(.system(size: 13, weight: selected ? .medium : .regular))
                Spacer(minLength: 0)
                if count > 0 { Text("\(count)").font(.system(size: 11, weight: .semibold)).padding(.horizontal, 7).padding(.vertical, 2).background(Maccet.sidebarText.opacity(0.12), in: Capsule()) }
                if attention { Image(systemName: "exclamationmark.triangle").font(.system(size: 11)).foregroundStyle(Maccet.color(0xF5D084, 0xF5D084)).accessibilityLabel("Setup needs attention") }
            }.foregroundStyle(Maccet.sidebarText).padding(.horizontal, 12).frame(minHeight: 36)
                .background(selected ? Maccet.sidebarSelection : hovering ? Maccet.sidebarSelection.opacity(0.6) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .leading) { if selected { RoundedRectangle(cornerRadius: 2).fill(Maccet.orange).frame(width: 3, height: 18) } }
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(focused ? Maccet.orange : .clear, lineWidth: 2))
        }.buttonStyle(.plain).onHover { hovering = $0 }.accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct AppRow: View {
    @EnvironmentObject var model: AppModel
    let app: AppRecord
    @ViewState private var hovering = false
    private var excluded: Bool { model.preferences.ignoredPaths.contains(app.id) || model.preferences.skippedReleases[app.id] == app.releaseIdentity }
    private var canSelect: Bool { model.preferences.isEligible(app) && model.screen != .installed }
    private var eligibilityReason: String { model.busy ? "Wait for the current operation to finish." : excluded ? "This app or release is excluded." : "\(app.state.title). \(app.detail)" }
    var body: some View {
        HStack(spacing: 12) {
            Toggle("Select \(app.name)", isOn: Binding(get: { model.selected.contains(app.id) }, set: { if $0 { model.selected.insert(app.id) } else { model.selected.remove(app.id) } }))
                .labelsHidden().toggleStyle(.checkbox).disabled(model.busy || !canSelect).frame(width: 20).help(canSelect ? "Include \(app.name) in selected updates" : eligibilityReason).accessibilityHint(eligibilityReason)
            ApplicationIcon(path: app.path)
            Button { model.inspected = app } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(app.name).font(.system(size: 13, weight: .medium)).foregroundStyle(Maccet.text).lineLimit(1)
                    Text(excluded ? (model.preferences.ignoredPaths.contains(app.id) ? "Ignored" : "Release skipped") : duplicateName ? (app.path as NSString).deletingLastPathComponent : app.bundleID).font(.system(size: 11)).foregroundStyle(Maccet.tertiary).lineLimit(1)
                }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).help("\(app.name) · \(app.path)")
                .accessibilityLabel("\(app.name), installed \(app.version), target \(app.targetVersion ?? "not established"), \(sourceName), \(app.state.title). Open details.")
            VStack(alignment: .leading, spacing: 5) {
                Text(app.version.isEmpty ? "Unknown" : app.version).foregroundStyle(Maccet.secondary)
                if let target = app.targetVersion { Text("→ \(target)").foregroundStyle(Maccet.accent) }
            }.font(.system(size: 11, design: .monospaced)).lineLimit(1).help("Installed: \(app.version)\nTarget: \(app.targetVersion ?? "Not established")").frame(width: 108, alignment: .leading)
            Text(sourceName).font(.system(size: 11)).foregroundStyle(Maccet.secondary).frame(width: 80, alignment: .leading)
            VStack(alignment: .leading, spacing: 6) {
                StatusPill(title: app.state.title, tone: .forCheck(app.state))
                if model.preferences.isEligible(app) {
                    Button("Review Update") { model.prepare([app]) }.controlSize(.small).disabled(model.busy)
                } else if app.state == .ambiguous && (app.routes?.count ?? 0) > 1 {
                    Button("Choose Manager") { model.inspected = app }.controlSize(.small).disabled(model.busy)
                } else if app.hasStoreReceipt || (app.source != nil && app.hasUpdate) {
                    Button(app.hasStoreReceipt ? "Open App Store ↗" : "Open Source ↗") { model.openSource(for: app) }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Maccet.accent)
                }
            }.frame(width: 156, alignment: .leading)
        }.padding(.horizontal, 16).padding(.vertical, 12).frame(minHeight: 76)
            .background(model.selected.contains(app.id) ? Maccet.selection : hovering ? Maccet.secondarySurface : Maccet.surface)
            .onHover { hovering = $0 }
            .contextMenu {
                Button("Details") { model.inspected = app }
                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)]) }
                Button(model.preferences.ignoredPaths.contains(app.id) ? "Stop Ignoring" : "Ignore App") { model.toggleIgnored(app) }.disabled(model.busy)
                if app.hasUpdate { Button("Skip This Release") { model.skip(app) }.disabled(model.busy) }
            }
    }
    private var duplicateName: Bool { model.apps.filter { $0.name == app.name }.count > 1 }
    private var sourceName: String { app.state == .systemManaged ? "macOS" : app.source?.title ?? ((app.routes?.count ?? 0) > 1 ? "Multiple" : app.vendorObservation != nil ? "Google" : app.sparkleObservation != nil ? "Sparkle feed" : "Unknown") }
}
