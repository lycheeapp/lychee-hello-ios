import SwiftUI
import Observation

/// Payment history: everything the caller paid and received, newest first, searched on the server by
/// who, a code or a reference. Each entry opens as a receipt that can be shared or paid again.
@Observable
@MainActor
final class HistoryModel {

    private(set) var entries: [HistoryEntry] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var loaded = false
    private(set) var errorMessage: String?
    private var nextCursor: Int64?
    private var loadedQuery = ""

    var query = ""

    private let repository: HelloRepositoryProtocol

    init(repository: HelloRepositoryProtocol) {
        self.repository = repository
    }

    func search() async {
        let current = query
        isLoading = true
        defer { isLoading = false }
        do {
            let page = try await repository.paymentHistory(query: current, before: nil)
            guard current == query else { return }
            entries = page.entries
            nextCursor = page.nextCursor
            loadedQuery = current
            loaded = true
            errorMessage = nil
        } catch {
            guard current == query, !Task.isCancelled else { return }
            if let error = error as? APIError {
                CrashReporter.recordAPIFailure(endpoint: "payments/history", error: error)
                errorMessage = error.userMessage
            } else {
                errorMessage = L("history_error_load")
            }
        }
    }

    func loadMore() async {
        guard let cursor = nextCursor, !isLoading, !isLoadingMore else { return }
        isLoadingMore = true
        defer { isLoadingMore = false }
        let current = loadedQuery
        guard let page = try? await repository.paymentHistory(query: current, before: cursor),
              current == loadedQuery else { return }
        let known = Set(entries.map(\.id))
        entries += page.entries.filter { !known.contains($0.id) }
        nextCursor = page.nextCursor
    }

    /// Entries by day, newest day first, each labelled as the chat labels its days.
    var days: [(label: String, entries: [HistoryEntry])] {
        let calendar = Calendar.current
        var groups: [(label: String, entries: [HistoryEntry])] = []
        var currentDay: Date?
        for entry in entries {
            let day = entry.at.map { calendar.startOfDay(for: $0) }
            if groups.isEmpty || day != currentDay {
                let label = day.map { ChatRowBuilder.dayLabel(for: $0, now: Date(), calendar: calendar) } ?? ""
                groups.append((label, [entry]))
                currentDay = day
            } else {
                groups[groups.count - 1].entries.append(entry)
            }
        }
        return groups
    }
}

struct HistoryView: View {

    /// Opens the Pay sheet for a payee from a receipt.
    var onPay: (PayeeRef) -> Void = { _ in }

    @State private var model = HistoryModel(repository: HelloRepository())
    @State private var open: HistoryEntry?

    var body: some View {
        // As on the Stores tab: the list is always the root, so the navigation bar and its search
        // field track it from the first frame; loading and empty states sit over it.
        List {
            ForEach(Array(model.days.enumerated()), id: \.offset) { _, day in
                Section {
                    ForEach(day.entries) { entry in
                        Button {
                            open = entry
                        } label: {
                            HistoryRow(entry: entry)
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Tokens.Colour.surface)
                        .onAppear {
                            if entry.id == model.entries.last?.id {
                                Task { await model.loadMore() }
                            }
                        }
                    }
                } header: {
                    Text(day.label)
                }
            }
            if model.isLoadingMore {
                HStack { Spacer(); ProgressView(); Spacer() }
                    .listRowBackground(Tokens.Colour.surface)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .overlay {
            if model.entries.isEmpty {
                if model.isLoading {
                    ProgressView()
                } else {
                    emptyState
                }
            }
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
        .navigationTitle(L("history_title"))
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $model.query, prompt: L("history_search"))
        .task(id: model.query) {
            if model.loaded {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            await model.search()
        }
        .sheet(item: $open) { entry in
            ReceiptSheet(entry: entry) { payee in
                open = nil
                onPay(payee)
            }
            .presentationDetents([.large])
            .presentationDragIndicator(.visible)
        }
    }

    private var emptyState: some View {
        let searching = !model.query.trimmingCharacters(in: .whitespaces).isEmpty
        return VStack(spacing: Tokens.Spacing.md) {
            Image(systemName: "list.bullet.rectangle.portrait")
                .font(.system(size: 44))
                .foregroundStyle(Tokens.Colour.textSecondary)
            Text(model.errorMessage != nil ? L("history_error_title")
                 : searching ? L("history_no_match_title") : L("history_empty_title"))
                .font(Tokens.Typography.headline)
                .foregroundStyle(Tokens.Colour.textPrimary)
            Text(model.errorMessage
                 ?? (searching ? L("history_no_match_body", model.query.trimmingCharacters(in: .whitespaces).bidiIsolated)
                     : L("history_empty_body")))
                .font(Tokens.Typography.body)
                .foregroundStyle(model.errorMessage != nil ? Tokens.Colour.danger : Tokens.Colour.textSecondary)
                .multilineTextAlignment(.center)
            if model.errorMessage != nil {
                Button(L("common_try_again")) { Task { await model.search() } }
                    .foregroundStyle(Tokens.Colour.brandAccessible)
            }
        }
        .padding(.horizontal, Tokens.Spacing.xl)
    }
}

/// How the history names an entry and its kind.
enum HistoryCopy {
    /// Who was paid or who paid; for a withdrawal or top-up with no one named, what it was.
    static func counterparty(_ entry: HistoryEntry) -> String {
        if let name = entry.counterparty, !name.isEmpty { return name.bidiIsolated }
        if entry.isReceived { return L("history_received") }
        switch entry.paymentKind {
        case .withdrawal: return L("history_kind_withdrawal")
        case .topUp: return L("history_kind_top_up")
        default: return L("history_paid")
        }
    }

    static func kind(_ entry: HistoryEntry) -> String {
        if entry.isReceived { return L("history_received") }
        switch entry.paymentKind {
        case .voucher: return L("history_kind_voucher")
        case .withdrawal: return L("history_kind_withdrawal")
        case .topUp: return L("history_kind_top_up")
        default: return L("history_paid")
        }
    }

    /// "−₪20" for money out, "+₪12.50" for money in.
    static func signedAmount(_ entry: HistoryEntry) -> String {
        (entry.isReceived ? "+" : "\u{2212}") + Money.format(entry.shownAmount)
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry

    var body: some View {
        HStack(spacing: Tokens.Spacing.md) {
            Image(systemName: entry.isReceived ? "arrow.down.left" : "arrow.up.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(entry.isReceived ? Tokens.Chat.success : Tokens.Colour.navy)
                .frame(width: 44, height: 44)
                .background(Circle().fill(entry.isReceived ? Tokens.Colour.positiveFill : Tokens.Colour.surfaceMuted))

            VStack(alignment: .leading, spacing: 2) {
                Text(HistoryCopy.counterparty(entry))
                    .font(Tokens.Typography.body.weight(.semibold))
                    .foregroundStyle(Tokens.Colour.textPrimary)
                    .lineLimit(1)
                Text([entry.at.map { $0.formatted(Date.FormatStyle(time: .shortened).locale(AppLanguage.locale)) }, HistoryCopy.kind(entry)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Tokens.Typography.caption)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(HistoryCopy.signedAmount(entry))
                .font(Tokens.Typography.body.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(entry.isReceived ? Tokens.Chat.success : Tokens.Colour.textPrimary)
                .environment(\.layoutDirection, .leftToRight)
        }
        .frame(minHeight: Tokens.Hit.minimum)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }
}

/// One entry as a receipt: the figures, then share it (image or PDF) or pay again.
struct ReceiptSheet: View {
    let entry: HistoryEntry
    let onPayAgain: (PayeeRef) -> Void

    @State private var files: ReceiptFiles?

    var body: some View {
        ScrollView {
            VStack(spacing: Tokens.Spacing.lg) {
                ReceiptCard(entry: entry, compact: false)

                if let files {
                    HStack(spacing: Tokens.Spacing.md) {
                        ShareLink(item: files.image) {
                            Label(L("history_share_image"), systemImage: "photo")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                        ShareLink(item: files.pdf) {
                            Label(L("history_share_pdf"), systemImage: "doc.richtext")
                                .frame(maxWidth: .infinity, minHeight: 48)
                        }
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .tint(Tokens.Colour.navy)
                } else {
                    ProgressView()
                }

                if let payee = entry.payAgain {
                    LHPrimaryButton(title: L("history_pay_again", payee.name.bidiIsolated)) {
                        onPayAgain(payee)
                    }
                }
            }
            .padding(Tokens.Spacing.gutter)
        }
        .background(Tokens.Colour.surface.ignoresSafeArea())
        // Shared receipts are files: written once, when the receipt opens, in the app's language.
        .task { files = await ReceiptFiles.make(for: entry) }
    }
}

/// The receipt as the sheet shows it and as it is shared — one view for both, so the image, the PDF
/// and the screen never disagree.
struct ReceiptCard: View {
    let entry: HistoryEntry
    /// For sharing: the brand band on top, a white card that stands on its own.
    var compact: Bool = true

    var body: some View {
        VStack(spacing: 0) {
            if compact {
                HStack {
                    Text(L("app_name"))
                        .font(.system(size: 20, weight: .bold))
                    Spacer()
                    Text(L("receipt_title"))
                        .font(.system(size: 13))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 24)
                .frame(height: 60)
                .background(Tokens.Colour.brand)
            }

            VStack(spacing: 4) {
                Image(systemName: entry.isReceived ? "arrow.down.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(Tokens.Chat.success)
                    .padding(.bottom, 6)
                Text(HistoryCopy.kind(entry))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Tokens.Chat.success)
                Text(Money.format(entry.shownAmount))
                    .font(.system(size: 38, weight: .bold))
                    .monospacedDigit()
                    .foregroundStyle(Tokens.Colour.navy)
                    .environment(\.layoutDirection, .leftToRight)
                Text(L(entry.isReceived ? "receipt_from" : "receipt_to", HistoryCopy.counterparty(entry)))
                    .font(.headline)
                    .foregroundStyle(Tokens.Colour.navy)
                    .multilineTextAlignment(.center)
                if !entry.isReceived,
                   let summary = PaymentRecipient.summary(type: entry.counterpartyType, category: entry.counterpartyCategory, code: nil) {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                }
            }
            .padding(.top, compact ? 28 : 8)
            .padding(.horizontal, 24)

            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { Divider() }
                    HStack {
                        Text(row.label)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                        Spacer(minLength: 12)
                        Text(row.value)
                            .fontWeight(.medium)
                            .foregroundStyle(Tokens.Colour.navy)
                            .lineLimit(1)
                    }
                    .font(.subheadline)
                    .padding(.vertical, 10)
                }
            }
            .padding(.horizontal, 16)
            .background(
                RoundedRectangle(cornerRadius: Tokens.Radius.card, style: .continuous)
                    .fill(compact ? Color(white: 0.97) : Tokens.Colour.surfaceElevated)
            )
            .padding(.horizontal, compact ? 24 : 0)
            .padding(.top, 20)

            if compact {
                Text(L("receipt_footer"))
                    .font(.caption2)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    .padding(.vertical, 20)
            }
        }
        .background(compact ? Color.white : Color.clear)
    }

    private var rows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let at = entry.at {
            rows.append((L("receipt_date"),
                         at.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(AppLanguage.locale))))
        }
        if let reference = entry.txnReference, !reference.isEmpty {
            rows.append((L("receipt_reference"), reference))
        }
        if !entry.isReceived, let code = entry.counterpartyCode, !code.isEmpty {
            rows.append((L(entry.paymentKind == .withdrawal ? "receipt_iban" : "receipt_payee_code"), code))
        }
        if let fee = entry.feeAmount, fee > 0 {
            rows.append((L("receipt_amount"), Money.format(entry.amount)))
            rows.append((L("receipt_fee"), Money.format(fee)))
            rows.append((L("receipt_total"), Money.format(entry.totalAmount ?? entry.amount)))
        }
        if let voucher = entry.voucherCodeMasked, !voucher.isEmpty {
            rows.append((L("receipt_voucher"), voucher))
        }
        if let balance = entry.newBalance {
            rows.append((L("receipt_new_balance"), Money.format(balance)))
        }
        return rows
    }
}

/// A receipt written out for sharing: a PNG and a one-page PDF, in the temporary folder.
@MainActor
struct ReceiptFiles {
    let image: URL
    let pdf: URL

    static func make(for entry: HistoryEntry) -> ReceiptFiles? {
        let card = ReceiptCard(entry: entry, compact: true)
            .frame(width: 360)
            // A shared receipt is a white document whichever theme the phone is in.
            .environment(\.colorScheme, .light)
            .environment(\.layoutDirection, AppLanguage.layoutDirection)
            .environment(\.locale, AppLanguage.locale)
        let renderer = ImageRenderer(content: card)
        renderer.scale = 3

        let name = "Lychee-receipt-" + (entry.txnReference.flatMap { $0.isEmpty ? nil : $0 } ?? String(entry.id.prefix(12)))
        let safe = name.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("receipts", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let imageURL = folder.appendingPathComponent(String(safe) + ".png")
        let pdfURL = folder.appendingPathComponent(String(safe) + ".pdf")

        guard let png = renderer.uiImage?.pngData() else { return nil }
        do {
            try png.write(to: imageURL, options: .atomic)
        } catch {
            return nil
        }

        var wrote = false
        renderer.render { size, draw in
            var box = CGRect(origin: .zero, size: size)
            guard let context = CGContext(pdfURL as CFURL, mediaBox: &box, nil) else { return }
            context.beginPDFPage(nil)
            draw(context)
            context.endPDFPage()
            context.closePDF()
            wrote = true
        }
        return wrote ? ReceiptFiles(image: imageURL, pdf: pdfURL) : nil
    }
}
