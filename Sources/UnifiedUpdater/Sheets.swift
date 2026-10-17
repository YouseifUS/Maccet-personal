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
