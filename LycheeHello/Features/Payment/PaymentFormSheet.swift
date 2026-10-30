import SwiftUI

/// The guided forms behind "+": the structured alternative to typing a WhatsApp command.
///
/// One view with a mode rather than near-identical sheets: duplicating the amount handling is how
/// they would drift. Whatever the mode, the server composes the canonical command from the fields
/// and runs the same parser as free text — `payee [voucher] amount`, `<IBAN> [amount]`,
/// `topup <phone> <amount> <pin>` — so a form can never accept something a message would not.
struct PaymentFormSheet: View {

    enum Mode: Identifiable {
        case balance
        case voucher
        /// Money to a bank account (WhatsApp's `<IBAN> [amount]`).
        case withdraw
        /// An operator's top-up for a customer (WhatsApp's `topup <phone> <amount> <pin>`).
        case topUp

        var id: Self { self }

        var title: String {
            switch self {
            case .balance: return L("form_title_balance")
            case .voucher: return L("attach_voucher")
            case .withdraw: return L("form_title_withdraw")
            case .topUp: return L("form_title_top_up")
            }
        }

        var needsVoucher: Bool { self == .voucher }

        /// Paying from the balance and withdrawing spend the wallet, so they wait for it to be
        /// active. A voucher pays for itself and a top-up comes from the operator's float: as on
        /// WhatsApp, neither needs the wallet — someone new to Lychee can pay with a voucher.
        var needsPayableWallet: Bool { self == .balance || self == .withdraw }
    }

    /// What the form asks the server to do.
    enum Submission {
        case payment(payee: String, voucherCode: String?, amount: Double)
        case withdrawal(iban: String, amount: Double?)
        case topUp(recipientPhone: String, amount: Double, pin: String)
    }

    @Environment(\.dismiss) private var dismiss
    @State private var payee = ""
    @State private var voucherCode = ""
    @State private var amountText = ""
    @State private var iban = ""
    @State private var phone = ""
    @State private var pin = ""

    let mode: Mode
    let onSubmit: (Submission) -> Void

    /// Voucher codes are 6 characters (decision U1).
    private let voucherLength = 6

    private var amount: Double? { Double(amountText.replacingOccurrences(of: ",", with: ".")) }

    /// IBANs are handled compact platform-wide; spaces are a reading aid only.
    private var compactIban: String {
        iban.replacingOccurrences(of: " ", with: "").uppercased()
    }

    private var canSubmit: Bool {
        switch mode {
        case .balance, .voucher:
            let hasPayee = !payee.trimmingCharacters(in: .whitespaces).isEmpty
            let hasVoucher = !mode.needsVoucher || voucherCode.count == voucherLength
            return hasPayee && hasVoucher && (amount ?? 0) > 0
        case .withdraw:
            // Shape only — the server validates the IBAN properly and says what is wrong with it.
            // An empty amount is allowed: it withdraws the whole balance.
            return compactIban.count >= 15 && (amountText.isEmpty || (amount ?? 0) > 0)
        case .topUp:
            return phone.filter(\.isNumber).count >= 9 && (amount ?? 0) > 0 && (4...8).contains(pin.count)
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                switch mode {
                case .balance, .voucher:
                    paymentFields
                case .withdraw:
                    withdrawalFields
                case .topUp:
                    topUpFields
                }
            }
            .navigationTitle(mode.title)
            .navigationBarTitleDisplayMode(.inline)
            // The amount field uses decimalPad — no return key, so it needs an explicit escape.
            .keyboardDoneToolbar()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(L("common_cancel")) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(L("common_continue")) {
                        if let submission {
                            onSubmit(submission)
                        }
                        dismiss()
                    }
                    .disabled(!canSubmit)
                }
            }
        }
    }

    @ViewBuilder
    private var paymentFields: some View {
        Section(L("form_pay_to")) {
            TextField(L("form_payee"), text: $payee)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
        }
        if mode.needsVoucher {
            Section(L("receipt_voucher")) {
                TextField(L("form_voucher_placeholder", voucherLength), text: $voucherCode)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.characters)
                    .onChange(of: voucherCode) { _, value in
                        voucherCode = String(value.prefix(voucherLength))
                    }
            }
        }
        amountSection(footer: nil)
    }

    @ViewBuilder
    private var withdrawalFields: some View {
        Section {
            TextField("PS92 PALS 0000 …", text: $iban)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .font(.body.monospaced())
        } header: {
            Text(L("receipt_iban"))
        } footer: {
            Text(L("form_iban_hint"))
        }
        amountSection(footer: L("form_withdraw_hint"))
    }

    @ViewBuilder
    private var topUpFields: some View {
        Section(L("review_customer")) {
            TextField(L("form_customer_phone"), text: $phone)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
        }
        amountSection(footer: nil)
        Section {
            SecureField(L("form_pin_short"), text: $pin)
                .keyboardType(.numberPad)
                .onChange(of: pin) { _, value in
                    pin = String(value.filter(\.isNumber).prefix(8))
                }
        } header: {
            Text(L("form_pin"))
        } footer: {
            Text(L("form_pin_hint"))
        }
    }

    private func amountSection(footer: String?) -> some View {
        Section {
            HStack {
                Text(Money.symbol).foregroundStyle(Tokens.Colour.textSecondary)
                TextField("0", text: $amountText).keyboardType(.decimalPad)
            }
        } header: {
            Text(L("receipt_amount"))
        } footer: {
            if let footer {
                Text(footer)
            }
        }
    }

    private var submission: Submission? {
        switch mode {
        case .balance, .voucher:
            guard let amount else { return nil }
            return .payment(
                payee: payee.trimmingCharacters(in: .whitespaces),
                voucherCode: mode.needsVoucher ? voucherCode : nil,
                amount: amount
            )
        case .withdraw:
            return .withdrawal(iban: compactIban, amount: amountText.isEmpty ? nil : amount)
        case .topUp:
            guard let amount else { return nil }
            return .topUp(recipientPhone: phone.filter { $0.isNumber || $0 == "+" }, amount: amount, pin: pin)
        }
    }
}
