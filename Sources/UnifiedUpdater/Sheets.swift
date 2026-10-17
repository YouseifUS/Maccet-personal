import AppKit
import SwiftUI
import UpdaterCore

struct ReviewSheet: View {
    @EnvironmentObject var model: AppModel
    @ViewState private var requestQuit = false
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Review updates").font(.system(size: 23, weight: .semibold))
                Text("\(model.review.count) \(model.review.count == 1 ? "app" : "apps") included").font(.system(size: 13)).foregroundStyle(Maccet.secondary)
            }.padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(model.review) { item in
                        Surface {
                            VStack(alignment: .leading, spacing: 14) {
                                HStack(spacing: 12) {
                                    ApplicationIcon(path: item.app.path)
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(item.app.name).font(.system(size: 13, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
                                        Text(item.app.source?.title ?? "Unknown source").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                                    }
                                    Spacer()
                                    Text("\(item.app.version) → \(item.app.targetVersion ?? "Unknown")").font(.system(size: 12, design: .monospaced)).foregroundStyle(Maccet.accent)
                                }
                                // No structured dependency summary is available. Keep the source preview visible.
                                Text(item.preview).font(.system(size: 12, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 12) {
                        Toggle("Request a normal quit for running apps", isOn: $requestQuit).toggleStyle(.checkbox)
                        Text(requestQuit ? "Save your work before continuing. Apps that refuse to quit will be deferred. Nothing is force-quit." : "Running apps will be deferred. Save your work and close them first, or enable the quit request.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        Text(model.preferences.cleanupAfterSuccess ? "Cleanup: isolated Homebrew downloads after successful verification." : "Cleanup: downloads will be retained.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        Label("The installed identity and target release will be checked again before installation.", systemImage: "checkmark.shield").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                    }.padding(.vertical, 8)
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            HStack {
                Button("Cancel", action: model.cancelReview).keyboardShortcut(.cancelAction)
                Spacer()
                // Deliberately no defaultAction/Return shortcut for installation.
                Button("Start Updates") { model.startUpdates(requestQuit: requestQuit) }.buttonStyle(PrimaryButtonStyle()).disabled(model.review.isEmpty || model.busy)
            }.padding(20).background(Maccet.surface).overlay(alignment: .top) { Rectangle().fill(Maccet.border).frame(height: 1) }
        }.frame(width: 720, height: 640).background(Maccet.background).foregroundStyle(Maccet.text).tint(Maccet.accent)
    }
}

struct AppDetailSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let app: AppRecord
    private var current: AppRecord { model.apps.first { $0.id == app.id } ?? app }
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 16) {
                ApplicationIcon(path: current.path, size: 56)
                VStack(alignment: .leading, spacing: 6) {
                    Text(current.name).font(.system(size: 23, weight: .semibold)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    Text(current.bundleID).font(.system(size: 12)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(28)
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if let target = current.targetVersion {
                        HStack {
                            Text(current.version.isEmpty ? "Unknown" : current.version)
                            Image(systemName: "arrow.right").foregroundStyle(Maccet.accent).accessibilityHidden(true)
                            Text(target)
                            Spacer()
                            StatusPill(title: current.state.title, tone: .forCheck(current.state))
                        }.font(.system(size: 13, design: .monospaced)).padding(16).background(Maccet.secondarySurface, in: RoundedRectangle(cornerRadius: 8))
                    }
                    detailSection("Installation") {
                        detail("Installed version", current.version.isEmpty ? "Unknown" : current.version)
                        detail("Build", current.build.isEmpty ? "Unknown" : current.build)
                        detail("Path", current.path)
                    }
                    detailSection("Update") {
                        detail("Target release", current.targetVersion ?? "Not established")
                        StatusPill(title: current.state.title, tone: .forCheck(current.state))
                        Text(current.detail).font(.system(size: 13)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    if OfficialVendorService.recognizes(current), current.source == nil, !current.hasStoreReceipt, (current.routes ?? []).isEmpty {
                        detailSection("Official vendor check") {
                            Text(current.vendorObservation?.message ?? "Enable supported vendor checks in Sources, then confirm this copy's channel from Chrome's settings or administrator policy.")
                                .font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
                            Picker("Installed Chrome channel", selection: Binding(get: { model.preferences.discoveryChannelReviews?[current.id]?.channel }, set: { model.reviewDiscoveryChannel($0, for: current) })) {
                                Text("Unknown — do not assume Stable").tag(nil as String?)
                                ForEach(OfficialVendorService.channels, id: \.self) { Text($0.capitalized).tag(Optional($0)) }
                            }.disabled(model.busy)
                            Link("Official Chrome update instructions", destination: OfficialVendorService.instructionsURL).font(.system(size: 12))
                        }
                    }
                    if let candidates = current.catalogCandidates, !candidates.isEmpty {
                        detailSection("Discovery candidates") {
                            ForEach(candidates) { candidate in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text("\(candidate.source.rawValue.capitalized) · \(candidate.packageID ?? candidate.id)").font(.system(size: 13, weight: .medium))
                                    Text(candidate.message).font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
                                    if let host = candidate.metadataURL?.host { Text("Publisher metadata: " + host).font(.system(size: 11)).foregroundStyle(Maccet.tertiary) }
                                }
                            }
                            let channels = Array(Set(candidates.compactMap(\.channel))).sorted()
                            if !channels.isEmpty {
                                Picker("Installed release channel", selection: Binding(get: { model.preferences.discoveryChannelReviews?[current.id]?.channel }, set: { model.reviewDiscoveryChannel($0, for: current) })) {
                                    Text("Unknown — keep provisional").tag(nil as String?)
                                    ForEach(channels, id: \.self) { Text($0).tag(Optional($0)) }
                                }.disabled(model.busy)
                                Text("Confirm a channel only from the application's own release settings. This review does not authorize a manager to adopt or update the app.").font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    detailSection("Source") {
                        detail("Chosen source", current.source?.title ?? "No verified route selected")
                        detail("Package identity", current.packageID ?? "Unknown")
                        if let routes = current.routes, routes.count > 1, !current.hasStoreReceipt {
                            Text("Update using").font(.system(size: 13, weight: .medium))
                            Picker("Update using", selection: Binding(get: { current.source }, set: { model.chooseSource($0, for: current) })) {
                                Text("Choose one manager").tag(nil as UpdateSource?)
                                ForEach(routes) { route in Text("\(route.source.title) · \(route.targetVersion ?? route.state.title)").tag(Optional(route.source)) }
                            }.pickerStyle(.radioGroup).labelsHidden().disabled(model.busy)
                            ForEach(routes) { route in Text("\(route.source.title): \(route.detail)").font(.system(size: 12)).foregroundStyle(Maccet.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                            Text("Only the selected manager will update this copy.").font(.system(size: 12, weight: .medium)).foregroundStyle(Maccet.secondary)
                        }
                        if current.hasStoreReceipt { Label("App Store receipt ownership is protected.", systemImage: "lock.shield").font(.system(size: 12)).foregroundStyle(Maccet.secondary) }
                        if let observation = current.sparkleObservation {
                            Label("Sparkle · read-only feed check", systemImage: "info.circle").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                            Text(observation.message).font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
                            if let build = observation.build { detail("Feed release/build", "\(observation.version ?? build) / \(build)") }
                        } else if current.sparkleFeed != nil {
                            Text("An embedded Sparkle feed was found. Verified manager routes take priority over feed observations.").font(.system(size: 12)).foregroundStyle(Maccet.secondary)
                        }
                    }
                }.padding(.horizontal, 28).padding(.bottom, 24)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { secondaryActions; Spacer(minLength: 8); trailingAction }
                VStack(alignment: .leading, spacing: 12) { HStack { secondaryActions }; HStack { Spacer(); trailingAction } }
            }.padding(20).background(Maccet.surface).overlay(alignment: .top) { Rectangle().fill(Maccet.border).frame(height: 1) }
        }.frame(width: 760, height: 620).background(Maccet.background).foregroundStyle(Maccet.text).tint(Maccet.accent)
    }
    private var secondaryActions: some View {
        Group {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: current.path)]) }
            Button(model.preferences.ignoredPaths.contains(current.id) ? "Stop Ignoring" : "Ignore App") { model.toggleIgnored(current) }.disabled(model.busy)
            if current.hasUpdate { Button("Skip Release") { model.skip(current); dismiss() }.disabled(model.busy) }
        }
    }
    @ViewBuilder private var trailingAction: some View {
        if model.preferences.isEligible(current) {
            Button("Review Update") { let candidate = current; dismiss(); model.prepare([candidate]) }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
        } else if current.vendorObservation?.state == .updateAvailable {
            Button("Review Assisted Update") { let candidate = current; dismiss(); model.prepareVendorUpdate(candidate) }.buttonStyle(PrimaryButtonStyle()).disabled(model.busy)
        } else if current.source != nil || current.hasStoreReceipt { Button("Open Source") { model.openSource(for: current) } }
    }
    private func detailSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Text(title).font(.system(size: 15, weight: .semibold)); content() }
    }
    private func detail(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 11)).foregroundStyle(Maccet.tertiary)
            Text(value).font(.system(size: 12)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct DiscoveryCatalogSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ViewState private var endpoint = ""
    @ViewState private var keyID = ""
    @ViewState private var publicKey = ""
    @ViewState private var minimumRevision = "1"
    @ViewState private var problem: String?
    private var configuration: DiscoveryCatalogConfiguration? {
        guard let url = URL(string: endpoint), let revision = UInt64(minimumRevision) else { return nil }
        return DiscoveryCatalogConfiguration(endpoint: url, keyID: keyID, publicKey: publicKey, minimumRevision: revision)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Discovery publisher").font(.title2.weight(.semibold))
            Text("Use a publisher and public key you trust independently. Maccet does not obtain a trust key from the downloaded catalog, and no default publisher is configured.")
                .font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            TextField("HTTPS catalog endpoint", text: $endpoint)
            TextField("Publisher key ID", text: $keyID)
            TextField("Ed25519 public key (base64)", text: $publicKey)
            TextField("Trusted minimum catalog revision", text: $minimumRevision)
            if let configuration, (try? configuration.validate()) != nil {
                Text("Public-key SHA-256: " + configuration.fingerprint).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text("Verify the fingerprint through your publisher's trusted channel before saving. Saving does not fetch data; use Refresh Discovery Catalog in Sources. Publisher changes use separate cache namespaces.")
                .font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            if let problem { Text(problem).font(.system(size: 12)).foregroundStyle(StatusTone.failure.foreground).fixedSize(horizontal: false, vertical: true) }
            HStack {
                if model.preferences.discoveryCatalog != nil {
                    Button("Disable Discovery") {
                        do { try model.configureDiscoveryCatalog(nil); dismiss() } catch { problem = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Trust Publisher and Save") {
                    do {
                        guard let configuration else { throw UpdaterError("Enter a valid endpoint, key and revision.") }
                        try model.configureDiscoveryCatalog(configuration); dismiss()
                    } catch { problem = error.localizedDescription }
                }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620).onAppear {
            if let current = model.preferences.discoveryCatalog {
                endpoint = current.endpoint.absoluteString; keyID = current.keyID; publicKey = current.publicKey; minimumRevision = String(current.minimumRevision)
            }
        }
    }
}

struct VendorHandoffSheet: View {
    @EnvironmentObject var model: AppModel
    let plan: VendorHandoffPlan
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Review vendor-assisted update").font(.title2.weight(.semibold))
            Text(plan.app.name).font(.headline)
            Text("\(plan.app.version) → \(plan.targetVersion) · \(plan.channelReview.channel)").font(.system(size: 13, design: .monospaced))
            Text(plan.app.path).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            Text("Maccet will open Google's instructions and record this reviewed target. In Chrome, use Help → About Google Chrome, confirm compatibility and any managed policy, then complete the update. Save your work before relaunching Chrome. Close the application before choosing Verify Reviewed Result in Activity.")
                .font(.system(size: 13)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            Text("This is a guided handoff. Maccet does not run a vendor installer, change Chrome policies or clean its downloads.")
                .font(.system(size: 12)).foregroundStyle(Maccet.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel") { model.vendorReview = nil }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Record Handoff and Open Instructions") { model.startVendorHandoff(plan) }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 620)
    }
}
