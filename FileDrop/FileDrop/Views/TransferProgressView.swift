import SwiftUI

struct TransferProgressView: View {
    let transfer: ActiveTransfer
    let onCancel: () -> Void

    private var accent: Color {
        transfer.direction == .sent
            ? Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
            : Color(red: 34 / 255, green: 197 / 255, blue: 94 / 255)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: transfer.direction == .sent ? "arrow.up.circle.fill" : "arrow.down.circle.fill")
                    .font(.title2)
                    .foregroundStyle(accent)
                VStack(alignment: .leading, spacing: 4) {
                    Text(transfer.filename)
                        .font(.headline)
                        .lineLimit(1)
                    Text(transfer.direction == .sent ? "Sending to PC…" : "Receiving from PC…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text("\(Int(transfer.progress))%")
                    .font(.title3.monospacedDigit())
                    .bold()
                    .foregroundStyle(accent)
            }

            ProgressView(value: transfer.progress, total: 100)
                .tint(accent)

            Button(role: .destructive, action: onCancel) {
                Label("Cancel", systemImage: "xmark.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .padding()
        .background(Color(red: 22 / 255, green: 22 / 255, blue: 24 / 255))
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(accent.opacity(0.35), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.4), radius: 20, y: 10)
        .padding(.horizontal)
    }
}
