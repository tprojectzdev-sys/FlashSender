import Foundation

enum TransferDirection: String, Codable, CaseIterable {
    case sent
    case received
}

struct TransferRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let filename: String
    let direction: TransferDirection
    let timestamp: Date
    let byteCount: Int64

    init(
        id: UUID = UUID(),
        filename: String,
        direction: TransferDirection,
        timestamp: Date = Date(),
        byteCount: Int64
    ) {
        self.id = id
        self.filename = filename
        self.direction = direction
        self.timestamp = timestamp
        self.byteCount = byteCount
    }
}

@MainActor
final class TransferHistoryStore: ObservableObject {
    @Published private(set) var records: [TransferRecord] = []

    private let storageURL: URL

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        storageURL = docs.appendingPathComponent("transfer_history.json")
        load()
    }

    var lastSent: TransferRecord? {
        records.first { $0.direction == .sent }
    }

    var lastReceived: TransferRecord? {
        records.first { $0.direction == .received }
    }

    func append(_ record: TransferRecord) {
        records.insert(record, at: 0)
        save()
    }

    func delete(at offsets: IndexSet) {
        records.remove(atOffsets: offsets)
        save()
    }

    func delete(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    private func load() {
        guard let data = try? Data(contentsOf: storageURL),
              let decoded = try? JSONDecoder().decode([TransferRecord].self, from: data) else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        try? data.write(to: storageURL, options: .atomic)
    }
}
