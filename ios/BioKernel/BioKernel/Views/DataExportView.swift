//
//  DataExportView.swift
//  BioKernel
//

import SwiftUI

struct DataExportView: View {
    @Environment(\.composition) private var composition
    @State private var publishedFiles: [URL] = []
    @State private var aiApps: [AiAppFiles] = []
    @State private var isConfirmingReset = false
    @State private var storeSnapshot: URL?
    @State private var loopStoreSnapshot: URL?

    var body: some View {
        Form {
            // The AI interface files live in the shared app-group container,
            // which neither Xcode's Download Container nor devicectl can reach —
            // both only offer the app's own container. Sharing and clearing them
            // from here is the only way to work with what we publish.
            Section {
                if publishedFiles.isEmpty {
                    Text("Nothing published yet")
                        .foregroundStyle(.secondary)
                } else {
                    ShareLink(items: publishedFiles) {
                        Label("Share published data", systemImage: "square.and.arrow.up")
                    }
                    ForEach(publishedFiles, id: \.self) { url in
                        LabeledContent(url.lastPathComponent, value: fileSize(of: url))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                Button(role: .destructive) {
                    isConfirmingReset = true
                } label: {
                    Label("Reset published data", systemImage: "trash")
                }
            } header: {
                Text("AI interface: GlucOS")
            } footer: {
                // The list is scoped, so say so rather than letting three files
                // read as "three days is all there is".
                if !publishedFiles.isEmpty {
                    Text("The newest \(AiInterfaceContainer.exportInDays) days of finalized insulin and glucose records, plus the current dosing file. GlucOS keeps \(AiInterfaceContainer.retentionInDays) days of each on the device.")
                }
            }

            // The other half of the container: the meal data AI apps wrote for
            // us. Kept in its own section because it is somebody else's data —
            // we share it and nothing more, so there is deliberately no reset
            // button here, and the one above stays scoped to our own files.
            //
            // One share row per app rather than one for the whole section: every
            // app writes the same `meal_announcements.<UTC_DAY>.jsonl` name, so
            // two apps' files in a single share sheet would land in the same
            // folder under the same name.
            Section {
                if aiApps.isEmpty {
                    Text("No AI app has published anything yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(aiApps, id: \.bundleIdentifier) { app in
                        ShareLink(items: app.urls) {
                            Label("Share \(app.bundleIdentifier)", systemImage: "square.and.arrow.up")
                        }
                        ForEach(app.urls, id: \.self) { url in
                            LabeledContent(url.lastPathComponent, value: fileSize(of: url))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            } header: {
                Text("AI interface: AI apps")
            } footer: {
                // Trimmed the same way as our own list. Says nothing about
                // retention: these files are theirs, and GlucOS deletes none of
                // them however long they sit here.
                if !aiApps.isEmpty {
                    Text("The newest \(AiInterfaceContainer.exportInDays) days per app.")
                }
            }

            // The store itself, VACUUMed into a shareable copy. Everything worth
            // asking about insulin history — how much we hold, where the clamp's
            // edges are, whether a pod change or a suspend or an outage happened —
            // is a query against this file and cannot be asked of the app's own
            // display.
            if let storeSnapshot {
                Section {
                    ShareLink(item: storeSnapshot) {
                        Label("Share insulin record store", systemImage: "square.and.arrow.up")
                    }
                    LabeledContent(storeSnapshot.lastPathComponent, value: fileSize(of: storeSnapshot))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Insulin record store")
                }
            }

            // Was "Share closed loop data", pointing at
            // `closed_loop_results.json` by name. That file is no longer written:
            // what each loop tick decided, and the machine-learning budget ledger
            // beside it, are now two tables in one database. Same `VACUUM INTO`
            // treatment as the insulin store above, and for the same reason — a
            // share sheet hands over one file, and this database needs its
            // journal sidecar to open consistently.
            if let loopStoreSnapshot {
                Section {
                    ShareLink(item: loopStoreSnapshot) {
                        Label("Share loop record store", systemImage: "square.and.arrow.up")
                    }
                    LabeledContent(loopStoreSnapshot.lastPathComponent, value: fileSize(of: loopStoreSnapshot))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Loop record store")
                } footer: {
                    Text("Every loop tick GlucOS ran in the last \(Int(LoopRecordStorePolicy.retention / 1.daysToSeconds())) days, and the machine-learning insulin ledger beside it.")
                }
            }
        }
        .modifier(NavigationModifier())
        .navigationTitle("Data export")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reloadPublishedFiles)
        .task { await reloadStoreSnapshot() }
        .confirmationDialog(
            "Delete everything GlucOS has published?",
            isPresented: $isConfirmingReset,
            titleVisibility: .visible
        ) {
            Button("Delete published data", role: .destructive, action: resetPublishedData)
        } message: {
            Text("Insulin delivery is not affected, and files published by AI apps are left alone. GlucOS republishes the last 24 hours of insulin on its next pump sync, and glucose from its next CGM reading back.")
        }
    }

    private func reloadPublishedFiles() {
        publishedFiles = AiInterfaceContainer.publishedFileURLs()
        aiApps = AiInterfaceContainer.aiFilesForExport()
    }

    /// nil when there is no store, or when it could not produce a copy — the
    /// section disappears rather than offering a share of nothing.
    private func reloadStoreSnapshot() async {
        if let store = composition?.insulinRecordStore {
            storeSnapshot = await store.exportSnapshotURL()
        }
        if let store = composition?.loopRecordStore {
            loopStoreSnapshot = await store.exportSnapshotURL()
        }
    }

    private func resetPublishedData() {
        guard let aiInterfaceStorage = composition?.aiInterfaceStorage else { return }
        Task {
            await aiInterfaceStorage.resetPublishedData()
            reloadPublishedFiles()
        }
    }

    private func fileSize(of url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }
}

#Preview {
    NavigationStack {
        DataExportView()
    }
}
