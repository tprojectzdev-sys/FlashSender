import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct SendView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var transfers: FileTransferService
    @EnvironmentObject private var webSocket: WebSocketService

    @State private var showPicker = false
    @State private var isUploading = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Image(systemName: "doc.badge.plus")
                    .font(.system(size: 56))
                    .foregroundStyle(Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255))
                    .padding(.top, 32)

                Text("Choose files to send to your PC. Large files are streamed in 512 KB chunks.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                Button {
                    showPicker = true
                } label: {
                    Label("Select Files", systemImage: "folder.badge.plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(webSocket.status != .connected || isUploading)
                .padding(.horizontal)

                if isUploading {
                    ProgressView("Uploading…")
                }

                Spacer()
            }
            .navigationTitle("Send Files")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showPicker) {
                DocumentPicker { urls in
                    Task { await upload(urls: urls) }
                }
            }
            .alert(
                "Could Not Send File",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { if !$0 { errorMessage = nil } }
                )
            ) {
                Button("OK") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func upload(urls: [URL]) async {
        guard !urls.isEmpty else { return }
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        do {
            try await transfers.upload(urls: urls)
            if transfers.alertMessage == nil {
                dismiss()
            }
        } catch {
            errorMessage = transfers.alertMessage ?? error.localizedDescription
        }
    }
}

// MARK: - Document Picker

struct DocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.item, .data, .content, .pdf, .image, .movie, .audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void

        init(onPick: @escaping ([URL]) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {}
    }
}
