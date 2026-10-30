import SwiftUI

/// Verification-code screen.
///
/// Not in the supplied screenshots, so it is composed from the same tokens and follows the welcome
/// screen's layout language.
///
/// The visible boxes are decorative: a single hidden `TextField` owns the input so paste,
/// autofill (`.oneTimeCode`) and the delete key behave natively. Per-digit fields are a common
/// pattern and a common accessibility failure — VoiceOver reads them as six unlabelled fields, and
/// SMS autofill does not populate them.
struct OtpEntryView: View {

    @State private var model: OtpEntryModel
    @FocusState private var focused: Bool

    init(model: OtpEntryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        ZStack {
            Tokens.Colour.surface.ignoresSafeArea()

            VStack(alignment: .leading, spacing: Tokens.Spacing.xl) {
                VStack(alignment: .leading, spacing: Tokens.Spacing.sm) {
                    Text(L("otp_title"))
                        .font(Tokens.Typography.largeTitle)
                        .foregroundStyle(Tokens.Colour.textPrimary)
                    Text(L("otp_sent_to", model.codeLength, model.maskedPhone.bidiIsolated))
                        .font(Tokens.Typography.body)
                        .foregroundStyle(Tokens.Colour.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, Tokens.Spacing.xxl)

                codeInput

                if let error = model.errorMessage {
                    Text(error)
                        .font(Tokens.Typography.caption)
                        .foregroundStyle(Tokens.Colour.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }

                if model.isVerifying {
                    HStack(spacing: Tokens.Spacing.sm) {
                        ProgressView()
                        Text(L("otp_verifying"))
                            .font(Tokens.Typography.callout)
                            .foregroundStyle(Tokens.Colour.textSecondary)
                    }
                }

                resendRow
                Spacer()
            }
            .padding(.horizontal, Tokens.Spacing.gutter)
        }
        .navigationBarTitleDisplayMode(.inline)
        // numberPad has no return key either.
        .keyboardDoneToolbar()
        .onAppear {
            focused = true
            model.startResendCountdown()
        }
        // Deterministic teardown. Without it the countdown ticks on until the model deallocates.
        .onDisappear { model.stopCountdown() }
    }

    private var codeInput: some View {
        ZStack {
            TextField("", text: $model.code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)   // enables SMS autofill
                .focused($focused)
                .opacity(0.01)                   // present but invisible; must not be `hidden`
                .accessibilityLabel(L("otp_code_label"))

            HStack(spacing: Tokens.Spacing.md) {
                ForEach(0..<model.codeLength, id: \.self) { index in
                    digitBox(at: index)
                }
            }
            .allowsHitTesting(false)
        }
        // The code's digits run left to right in Arabic too, as the SMS shows them.
        .environment(\.layoutDirection, .leftToRight)
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
        // The boxes are decoration; the field above carries the real value for VoiceOver.
        .accessibilityElement(children: .contain)
    }

    private func digitBox(at index: Int) -> some View {
        let characters = Array(model.code)
        let value = index < characters.count ? String(characters[index]) : ""
        let isActive = index == characters.count

        return Text(value)
            .font(Tokens.Typography.title)
            .foregroundStyle(Tokens.Colour.textPrimary)
            .frame(maxWidth: .infinity)
            .frame(height: 60)
            .background(Tokens.Colour.surfaceElevated)
            .clipShape(RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Tokens.Radius.field, style: .continuous)
                    .stroke(isActive ? Tokens.Colour.brand : Tokens.Colour.divider,
                            lineWidth: isActive ? 2 : 1)
            )
            .accessibilityHidden(true)
    }

    private var resendRow: some View {
        HStack(spacing: Tokens.Spacing.xs) {
            Text(L("otp_didnt_get_it"))
                .font(Tokens.Typography.callout)
                .foregroundStyle(Tokens.Colour.textSecondary)

            if model.canResend {
                Button(L("otp_resend_short")) {
                    Task { await model.resend() }
                }
                .font(Tokens.Typography.callout.weight(.semibold))
                .foregroundStyle(Tokens.Colour.brand)
                .frame(minHeight: Tokens.Hit.minimum)
            } else {
                Text(L("otp_resend_in_short", model.secondsUntilResend))
                    .font(Tokens.Typography.callout)
                    .foregroundStyle(Tokens.Colour.textSecondary)
                    // Otherwise VoiceOver announces every tick.
                    .accessibilityRespondsToUserInteraction(false)
            }
        }
        .frame(maxWidth: .infinity)
    }
}
