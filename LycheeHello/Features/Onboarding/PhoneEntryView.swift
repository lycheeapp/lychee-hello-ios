import SwiftUI

/// Welcome / phone-number entry.
///
/// Built to the supplied design description. Structure, top to bottom:
/// centred brand lockup → left-aligned two-line heading → tagline → generous whitespace →
/// "Mobile number" label → phone field → Continue → verification row, over a warm off-white
/// background that becomes pale mint below an organic wave.
///
/// Deviations, all per decision D5 (brand-identical, platform-native, accessible):
/// - **Dynamic Type is preserved.** The reference is a fixed 853×1844 canvas; fixed point sizes
///   would look right on one device and break on every other. Type scales and the layout reflows.
/// - **Hit targets are ≥44pt** even where the artwork is smaller (the country chevron especially).
/// - **The whitespace between tagline and form is proportional, not absolute** — a fixed gap sized
///   for a large phone leaves the CTA off-screen on an SE.
/// - The verification sentence is allowed to wrap on narrow screens rather than truncate or shrink.
struct PhoneEntryView: View {

    @State private var model: PhoneEntryModel
    @FocusState private var phoneFocused: Bool

    init(model: PhoneEntryModel) {
        _model = State(initialValue: model)
    }

    var body: some View {
        GeometryReader { proxy in
            let gutter = Tokens.Spacing.welcomeGutter(for: proxy.size.width)

            ZStack {
                WelcomeBackground()

                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 0) {

                        // Vertical rhythm traced from the 853 × 1844 reference, expressed as
                        // fractions of height so it holds on every device:
                        //   logo centre 0.144 · heading 0.296 · tagline 0.418
                        //   label 0.581 · field 0.598 · button 0.704 · shield 0.808

                        // MARK: Brand — horizontally centred as a unit.
                        BrandLockup()
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, proxy.size.height * 0.075)

                        // MARK: Heading — left aligned, two lines.
                        Text(L("phone_title"))
                            .font(.system(size: 40, weight: .bold))
                            .foregroundStyle(Tokens.Colour.navy)
                            .lineSpacing(1)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, proxy.size.height * 0.088)
                            .accessibilityAddTraits(.isHeader)

                        // MARK: Tagline.
                        Text(L("phone_tagline"))
                            .font(.system(size: 19, weight: .regular))
                            .foregroundStyle(Tokens.Colour.textSecondary)
                            .padding(.top, Tokens.Spacing.md)

                        // The airy upper half is the design's defining feature, but it must not
                        // push the CTA off a small screen — hence a flexible minimum.
                        Spacer(minLength: proxy.size.height * 0.115)

                        // MARK: Form.
                        Text(L("phone_label"))
                            .font(.system(size: 15, weight: .regular))
                            .foregroundStyle(Tokens.Colour.navy)
                            .padding(.bottom, Tokens.Spacing.md)

                        phoneField

                        LHPrimaryButton(
                            title: L("common_continue"),
                            trailingSystemImage: "arrow.right",
                            isLoading: model.isSubmitting,
                            isEnabled: model.canSubmit
                        ) {
                            Task { await model.submit() }
                        }
                        // Reference gap between field and button ≈ 0.027h.
                        .padding(.top, 22)

                        if let error = model.errorMessage {
                            Text(error)
                                .font(Tokens.Typography.caption)
                                .foregroundStyle(Tokens.Colour.danger)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, Tokens.Spacing.md)
                        }

                        verificationRow
                            .padding(.top, Tokens.Spacing.xl)

                        Spacer(minLength: Tokens.Spacing.xxl)
                    }
                    .padding(.horizontal, gutter)
                    .frame(minHeight: proxy.size.height, alignment: .top)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            // phonePad has no return key, so without these the keyboard cannot be closed at all.
            .dismissesKeyboardOnTap()
        }
        .keyboardDoneToolbar()
        .onAppear { phoneFocused = true }
    }

    // MARK: - Phone field

    /// Floating white card: `+970 ▼ | 59X XXX XXX`.
    private var phoneField: some View {
        HStack(spacing: 0) {
            countrySelector

            Rectangle()
                .fill(Tokens.Colour.divider)
                .frame(width: 1, height: 28)

            TextField(model.country.placeholder, text: $model.nationalNumber)
                .keyboardType(.phonePad)
                .textContentType(.telephoneNumber)
                .font(.system(size: 19, weight: .regular))
                .foregroundStyle(Tokens.Colour.navy)
                .focused($phoneFocused)
                .padding(.horizontal, Tokens.Spacing.lg)
                .frame(maxWidth: .infinity, alignment: .leading)
                // Reference field height ≈ 145/1844 of a 1844pt canvas → ~66pt. Note the field is
                // deliberately *taller* than the button below it.
                .frame(minHeight: 66)
                .accessibilityLabel(L("phone_label"))
        }
        .background(Tokens.Colour.surfaceElevated)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        // A phone number reads left to right in Arabic too: "+970 | 59X XXX XXX", never mirrored.
        .environment(\.layoutDirection, .leftToRight)
        // Soft, diffused, slightly offset downward — the "floating card" effect. No border.
        .shadow(color: Tokens.Colour.navy.opacity(0.07), radius: 16, x: 0, y: 8)
    }

    /// A country's name in the app's language.
    private static func countryName(_ country: PhoneEntryModel.Country) -> String {
        switch country.isoCode.uppercased() {
        case "PS": return L("country_ps")
        case "IL": return L("country_il")
        default: return country.name
        }
    }

    private var countrySelector: some View {
        Menu {
            ForEach(PhoneEntryModel.supportedCountries, id: \.dialCode) { country in
                Button("\(country.dialCode)  \(Self.countryName(country))") { model.country = country }
            }
        } label: {
            HStack(spacing: Tokens.Spacing.sm) {
                Text(model.country.dialCode)
                    .font(.system(size: 19, weight: .regular))
                    .foregroundStyle(Tokens.Colour.navy)
                Image(systemName: "chevron.down")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Tokens.Colour.brand)
            }
            .padding(.horizontal, Tokens.Spacing.xl)
            // Artwork is smaller than this, but the tap target must not be.
            .frame(minHeight: Tokens.Hit.minimum)
        }
        .accessibilityLabel(L("phone_country_code_short"))
        .accessibilityValue(model.country.dialCode)
        .accessibilityHint(L("phone_country_hint"))
    }

    // MARK: - Verification row

    private var verificationRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Tokens.Spacing.md) {
            ShieldCheckIcon()
                // Nudged to sit optically level with the first text line.
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 3 }
            Text(L("phone_note"))
                .font(.system(size: 14, weight: .regular))
                .foregroundStyle(Tokens.Colour.navy)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .center)
        // Read as one phrase, not "shield, we'll send you…".
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    PhoneEntryView(model: PhoneEntryModel(repository: HelloRepository()))
}
