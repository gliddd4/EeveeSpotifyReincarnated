import SwiftUI
import UIKit

/// Standalone editor for local-file metadata. Lists every `spotify:local:` URI
/// in the edit store (seeded by the write path) and lets the user edit
/// title/artist/album: the edits are written to the on-disk file through
/// MetadataEditorFileService AND persisted to MetadataEditorStore, which the
/// FTP Local Files list / Now Playing getters overlay. Deliberately has no
/// dependency on Spotify internals — v1 does not enumerate the Local Files list.
struct MetadataEditorSettingsView: View {
    @State private var uris: [String] = []
    @State private var editingItem: EditSheetItem?

    var body: some View {
        List {
            if uris.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("No local files found.")
                            .font(.headline)
                            .foregroundColor(.white)
                        Text("Open the Local Files tab in Spotify first so your tracks appear here, then tap one to edit its title, artist, or album.")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Section(header: Text("Local Files")) {
                    ForEach(uris, id: \.self) { uri in
                        Button {
                            editingItem = EditSheetItem(uri: uri)
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(displayName(for: uri))
                                        .font(.headline)
                                        .foregroundColor(.white)
                                    Text(uri)
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets {
                            MetadataEditorStore.remove(forURI: uris[index])
                        }
                        refresh()
                    }
                }

                Section {
                    Button("Clear All Edits") {
                        MetadataEditorStore.clear()
                        refresh()
                    }
                    .foregroundColor(.red)
                }
            }
        }
        .listStyle(GroupedListStyle())

        .navigationTitle("metadataEditor".localized)
        .sheet(item: $editingItem) { item in
            MetadataEditorFormView(uri: item.uri) {
                refresh()
            }
        }
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: MetadataEditorStore.changedNotification)) { _ in
            refresh()
        }
    }

    private func refresh() {
        uris = MetadataEditorStore.knownURIs.sorted()
    }

    private func displayName(for uri: String) -> String {
        if let edit = MetadataEditorStore.edits(forURI: uri),
           let title = edit.title, !title.isEmpty {
            return title
        }
        let parts = uri.split(separator: ":")
        if parts.count >= 6 {
            let title = parts[parts.count - 2].removingPercentEncoding ?? String(parts[parts.count - 2])
            if !title.isEmpty { return title }
        }
        return uri
    }

    private struct EditSheetItem: Identifiable {
        let uri: String
        var id: String { uri }
    }
}

/// Title/artist/album form for one local-track URI. "Apply" persists the edit
/// to MetadataEditorStore (display interception) and writes it to the on-disk
/// file on a background queue; empty fields are left untouched.
private struct MetadataEditorFormView: View {
    let uri: String
    let onSaved: () -> Void

    @Environment(\.presentationMode) private var presentationMode
    @State private var title: String = ""
    @State private var artist: String = ""
    @State private var album: String = ""
    @State private var isApplying = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Title")) {
                    TextField("Title", text: $title)
                }
                Section(header: Text("Artist")) {
                    TextField("Artist", text: $artist)
                }
                Section(header: Text("Album")) {
                    TextField("Album", text: $album)
                }
                Section {
                    Button(isApplying ? "Applying..." : "Apply") {
                        apply()
                    }
                    .disabled(isApplying)
                }
            }
            .navigationTitle("Edit Metadata")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        presentationMode.wrappedValue.dismiss()
                    }
                }
            }
        }
        .onAppear(perform: prefill)
    }

    private func prefill() {
        DispatchQueue.global(qos: .userInitiated).async {
            let storeEdit = MetadataEditorStore.edits(forURI: uri)
            let fileMetadata = MetadataEditorFileService.readMetadata(forURI: uri)
            let title = storeEdit?.title ?? fileMetadata?.title
            let artist = storeEdit?.artist ?? fileMetadata?.artist
            let album = storeEdit?.album ?? fileMetadata?.album
            DispatchQueue.main.async {
                self.title = title ?? ""
                self.artist = artist ?? ""
                self.album = album ?? ""
            }
        }
    }

    private func apply() {
        let edit = MetadataEdit(
            title: normalized(title),
            artist: normalized(artist),
            album: normalized(album)
        )
        MetadataEditorStore.set(edit, forURI: uri)
        isApplying = true

        DispatchQueue.global(qos: .userInitiated).async {
            // The store edit is already persisted, so display interception works
            // even if the file write fails (unsupported format / missing file).
            // Failures are logged by the service; nothing to surface here.
            _ = MetadataEditorFileService.apply(edit, forURI: uri)
            DispatchQueue.main.async {
                isApplying = false
                onSaved()
                presentationMode.wrappedValue.dismiss()
            }
        }
    }

    private func normalized(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
