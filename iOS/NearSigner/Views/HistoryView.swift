import NearSignerCore
import SwiftUI
import UIKit

struct HistoryView: View {
    let model: AppModel
    @State private var search = ""
    @State private var confirmClear = false

    private struct Day: Identifiable {
        let date: Date
        var records: [HistoryRecord]
        var id: Date { date }
    }

    private var filtered: [HistoryRecord] {
        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !query.isEmpty else { return model.history }
        return model.history.filter { record in
            [record.title, record.signerId, record.receiverId, record.hash, model.accountLabel(for: record)]
                .compactMap { $0?.lowercased() }
                .contains { $0.contains(query) }
        }
    }

    /// Records grouped by calendar day, newest first.
    private var days: [Day] {
        let calendar = Calendar.current
        var result: [Day] = []
        for record in filtered {
            let date = calendar.startOfDay(for: record.date)
            if result.last?.date == date {
                result[result.count - 1].records.append(record)
            } else {
                result.append(Day(date: date, records: [record]))
            }
        }
        return result
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(days) { day in
                    Section(HistoryView.title(for: day.date)) {
                        ForEach(day.records) { record in
                            NavigationLink(value: record.id) {
                                HistoryRow(record: record, accountName: model.accountLabel(for: record))
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { model.deleteHistory(day.records[index]) }
                        }
                    }
                }
            }
            .overlay {
                if model.history.isEmpty {
                    ContentUnavailableView("No activity yet", systemImage: "clock",
                                           description: Text("Requests from your computer appear here, whether you approve them or not."))
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search activity")
            .navigationTitle("History")
            .navigationDestination(for: UUID.self) { id in
                if let record = model.history.first(where: { $0.id == id }) {
                    HistoryDetailView(model: model, record: record)
                }
            }
            .toolbar {
                if !model.history.isEmpty {
                    Menu {
                        Button("Delete all history", systemImage: "trash", role: .destructive) { confirmClear = true }
                    } label: {
                        // On iOS 26 and later, the toolbar's glass draws the circle.
                        if #available(iOS 26, *) {
                            Image(systemName: "ellipsis")
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .accessibilityLabel("More")
                }
            }
            .confirmationDialog("Delete all history?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Delete all history", role: .destructive) { model.clearHistory() }
            } message: {
                Text("This removes the record of past requests from this phone. It doesn't affect your accounts.")
            }
            .refreshable { await model.reloadHistory() }
        }
    }

    private static func title(for day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(date: .complete, time: .omitted)
    }
}

private struct HistoryRow: View {
    let record: HistoryRecord
    let accountName: String?

    private var subtitle: String {
        [accountName ?? record.signerId, record.date.formatted(date: .omitted, time: .shortened)]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(symbol: record.displaySymbol,
                        tint: record.outcome == .approved ? .accentColor : .secondary,
                        size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(record.title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            OutcomeBadge(record: record)
        }
        .padding(.vertical, 2)
    }
}

struct HistoryDetailView: View {
    let model: AppModel
    let record: HistoryRecord
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    private var explorerLink: String? {
        guard record.kind == .transaction, record.outcome == .approved, let hash = record.hash else { return nil }
        return (record.network == "testnet" ? "https://testnet.nearblocks.io/txns/" : "https://nearblocks.io/txns/") + hash
    }

    var body: some View {
        let display = PreparedRequest(record: record)?.display
        List {
            Section {
                VStack(spacing: 10) {
                    SymbolBadge(symbol: record.displaySymbol, size: 56)
                    Text(record.title)
                        .font(.title3.bold())
                        .multilineTextAlignment(.center)
                    OutcomeBadge(record: record)
                    Text(record.date.formatted(date: .long, time: .shortened))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                if let account = model.accountLabel(for: record) {
                    LabeledContent("Account", value: account)
                }
                if let signer = record.signerId {
                    LabeledContent("From", value: signer)
                }
                if let receiver = record.receiverId {
                    LabeledContent(record.kind == .message ? "App" : "To", value: receiver)
                }
                if let network = record.network {
                    LabeledContent("Network", value: network.capitalized)
                }
            }

            if let reason = record.failureReason {
                Section("What Happened") {
                    Text(reason).foregroundStyle(record.outcome == .failed ? Color.red : Color.secondary)
                }
            }

            if let display, !display.primarySections.isEmpty {
                Section("What You Saw") {
                    VStack(spacing: 12) {
                        if let highlight = display.highlight {
                            HighlightCard(highlight: highlight, ownAccount: model.ownAccountLabel(for:))
                        }
                        if !display.extras.isEmpty {
                            SectionCard(section: DisplaySection(title: "Also in this request", fields: display.extras))
                        }
                        ForEach(display.warnings, id: \.self) { warning in
                            WarningCard(text: warning)
                        }
                        if display.highlight == nil {
                            RequestSectionsView(sections: display.primarySections)
                        }
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                // The card summarizes; every field is one tap away.
                if display.highlight != nil {
                    Section {
                        DisclosureGroup("Details") {
                            RequestSectionsView(sections: display.primarySections)
                                .padding(.vertical, 8)
                        }
                    }
                }
            }

            Section {
                DisclosureGroup("Technical details") {
                    if let hash = record.hash {
                        TechnicalValue(label: record.kind == .transaction ? "Transaction hash" : "Signed digest", value: hash)
                    }
                    if let signature = record.signature {
                        TechnicalValue(label: "Signature", value: signature)
                    }
                    if let publicKey = record.publicKey {
                        TechnicalValue(label: "Public key", value: publicKey)
                    }
                    TechnicalValue(label: "Derivation path", value: record.path)
                    TechnicalValue(label: "Connection", value: record.transport)
                    if let display {
                        // The hash is shown above with a copy button.
                        let fields = display.technicalSections.flatMap(\.fields)
                            .filter { $0.label != "Transaction hash" && $0.label != "Signed digest" }
                        ForEach(Array(fields.enumerated()), id: \.offset) { _, field in
                            TechnicalValue(label: field.label, value: field.value)
                        }
                    }
                    if !record.payload.isEmpty {
                        RawPayloadRow(payload: record.payload)
                    } else if let size = record.payloadSize, size > 0 {
                        Text("The request's bytes (\(NearFormat.byteSize(size))) aren't kept for requests refused without being shown, or for older ones.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Text(ValueMenuHint.text)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            // This phone is meant to stay offline, so the link goes to another device as a QR code.
            if let explorerLink {
                Section {
                    VStack(spacing: 12) {
                        QRCodeView(value: explorerLink)
                            .frame(maxWidth: 200)
                        Text("Scan with another phone's camera to see this transaction on nearblocks.io.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                } header: {
                    Text("Check on an Explorer")
                } footer: {
                    Text(record.network == nil
                        ? "It appears once your computer has sent the transaction. The network can't be told from the account names; this link is for mainnet."
                        : "It appears once your computer has sent the transaction.")
                }
            }

            Section {
                Button("Delete from history", role: .destructive) { confirmDelete = true }
            }
        }
        .navigationTitle(record.kind.label)
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Delete this entry?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                model.deleteHistory(record)
                dismiss()
            }
        }
    }
}

/// A label and value; touch and hold to copy the value or show it as a QR code.
private struct TechnicalValue: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.footnote.monospaced())
                .lineLimit(8)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .valueMenu(value, title: label)
    }
}

/// The signed bytes. A contract deployment can be megabytes, so only the start is shown; the
/// menu copies everything (and offers a QR code when it fits in one).
private struct RawPayloadRow: View {
    let payload: Data

    private static let previewBytes = 300

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Raw request (Borsh, base64), \(NearFormat.byteSize(payload.count))")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(payload.prefix(RawPayloadRow.previewBytes).base64EncodedString()
                + (payload.count > RawPayloadRow.previewBytes ? "…" : ""))
                .font(.footnote.monospaced())
                .lineLimit(6)
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .modifier(ValueMenu(value: { payload.base64EncodedString() },
                            fitsQRCode: (payload.count + 2) / 3 * 4 <= QRCode.capacity, title: "Raw request"))
    }
}
