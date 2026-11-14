import SwiftUI

// MARK: - Arcade Pulse (epic #172, foundation #173)
//
// One source of truth for the visual design of Discover, playable cards,
// player entry and creator actions. These are UI colors only: a colorful
// fallback is never a recorded preview, real user engagement metric, or
// replacement for source artwork.
enum ArcadePulseTheme {
    static let canvas = Color(red: 0.045, green: 0.034, blue: 0.087)
    static let surface = Color(red: 0.094, green: 0.072, blue: 0.153)
    static let raisedSurface = Color(red: 0.150, green: 0.112, blue: 0.227)
    static let electricViolet = Color(red: 0.57, green: 0.36, blue: 0.99)
    static let neonMagenta = Color(red: 0.96, green: 0.26, blue: 0.74)
    static let playOrange = Color(red: 1.0, green: 0.70, blue: 0.29)
    static let playOrangeDeep = Color(red: 1.0, green: 0.48, blue: 0.30)
    static let textPrimary = Color.white
    static let textSecondary = Color.white.opacity(0.86)
    static let subtleBorder = Color.white.opacity(0.20)

    static let pillRadius: CGFloat = 14
    static let surfaceRadius: CGFloat = 22
    static let minimumTarget: CGFloat = 44
    static let playHeight: CGFloat = 48

    // Fallback palette choices are per-game, not an invented poster. Keep
    // the same five color-pairs as the already validated feed while moving
    // the two duplicated definitions to one shared location.
    static let fallbackPalettes: [[Color]] = [
        [Color(red: 0.31, green: 0.20, blue: 0.67), Color(red: 0.10, green: 0.55, blue: 0.69)],
        [Color(red: 0.86, green: 0.29, blue: 0.48), Color(red: 0.98, green: 0.57, blue: 0.31)],
        [Color(red: 0.10, green: 0.48, blue: 0.39), Color(red: 0.55, green: 0.69, blue: 0.30)],
        [Color(red: 0.16, green: 0.33, blue: 0.68), Color(red: 0.39, green: 0.63, blue: 0.92)],
        [Color(red: 0.49, green: 0.24, blue: 0.59), Color(red: 0.82, green: 0.40, blue: 0.63)]
    ]

    static func fallbackPalette(gameID: String) -> [Color] {
        fallbackPalettes[ForYouPageLayout.fallbackPaletteIndex(
            gameID: gameID, paletteCount: fallbackPalettes.count)]
    }

    static func playGradient(highContrast: Bool = false) -> LinearGradient {
        // Reduce the two-color blend to a solid, very legible button when
        // the user requests increased contrast. No animated glow is required.
        LinearGradient(
            colors: highContrast ? [playOrange, playOrange] : [playOrange, playOrangeDeep],
            startPoint: .leading, endPoint: .trailing
        )
    }
}

// The legacy platform-neutral tokens are retained for List, form, library
// and system-sheet presentation. Arcade Pulse tokens above intentionally
// apply only where a dark, media-dominant context is actually being used.
enum HephaestusDesign {
    static let pageBackground = Color(uiColor: .systemGroupedBackground)
    static let cardBackground = Color(uiColor: .secondarySystemGroupedBackground)
    static let elevatedBackground = Color(uiColor: .tertiarySystemGroupedBackground)
    static let cardRadius: CGFloat = 22
    static let compactCardRadius: CGFloat = 14
    static let sectionRadius: CGFloat = 20
    static let horizontalInset: CGFloat = 16
    static let sectionSpacing: CGFloat = 16
    static let minimumActionHeight: CGFloat = 44
    static let cardPadding: CGFloat = 24
    static let stateCardMaxWidth: CGFloat = 360
    static let stateIconSize: CGFloat = 40
    static let subtleBorder = Color(uiColor: .separator).opacity(0.18)
}

// MARK: - Shared native primitives

/// A real action; never mount a zero-distance DragGesture here. In a
/// swipe-to-browse feed that would steal the pager's vertical contact.
struct ArcadePulsePlayCTA: View {
    @Environment(\.colorSchemeContrast) private var contrast
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label("Play now", systemImage: "play.fill")
                // Semantic type scales with the user's chosen text size.
                // The previous fixed 20pt accessibility font stopped scaling
                // and failed the large-text design contract in #173.
                .font(.system(.headline, design: .rounded).weight(.bold))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.vertical, 8)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity, minHeight: ArcadePulseTheme.playHeight)
                .background(
                    ArcadePulseTheme.playGradient(highContrast: contrast == .increased),
                    in: RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius, style: .continuous)
                        .strokeBorder(contrast == .increased ? .black : .clear, lineWidth: 2)
                }
                .contentShape(RoundedRectangle(cornerRadius: ArcadePulseTheme.pillRadius))
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("game.play")
        .accessibilityHint("Opens this game in the player")
    }
}

/// Real creator name/approved avatar supplied by FeedGame; no fake avatar,
/// follower count, or invented identity is displayed.
struct ArcadePulseCreatorIdentity: View {
    let name: String
    let avatarURL: String?
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Group {
                    if let avatarURL, let url = URL(string: avatarURL) {
                        AsyncImage(url: url) { phase in
                            if let image = phase.image {
                                image.resizable().scaledToFill()
                            } else {
                                Image(systemName: "person.crop.circle.fill")
                                    .resizable().scaledToFit()
                            }
                        }
                    } else {
                        Image(systemName: "person.crop.circle")
                            .resizable().scaledToFit()
                    }
                }
                .frame(width: 26, height: 26)
                .clipShape(Circle())
                .accessibilityHidden(true)
                Text(name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .frame(minHeight: ArcadePulseTheme.minimumTarget)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(foreground)
        .accessibilityLabel("View profile for \(name)")
    }
}

/// One shared native action anatomy for Button, Menu and ShareLink in the
/// Arcade Pulse social rail. Fixed 10pt text failed Dynamic Type and three
/// copies of this layout drifted independently. Compact visual captions are
/// supplementary; the parent control always supplies its complete, truthful
/// VoiceOver label.
struct ArcadePulseActionGlyph: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let symbol: String
    let caption: String?

    /// When captions become too large for a narrow one-post social rail,
    /// preserve the full 48pt icon target and let the parent's accessibility
    /// label carry the name. Never shrink accessibility text to 8pt.
    static func showsCaption(_ caption: String?, for size: DynamicTypeSize) -> Bool {
        guard let caption, !caption.isEmpty else { return false }
        return !usesAccessibleMenu(for: size)
    }

    /// A single visibly labeled Actions menu keeps social actions discoverable
    /// to large-text users *without* requiring VoiceOver or squeezing Play.
    static func usesAccessibleMenu(for size: DynamicTypeSize) -> Bool {
        size >= .xxLarge
    }

    var body: some View {
        let showCaption = Self.showsCaption(caption, for: dynamicTypeSize)
        VStack(spacing: 1) {
            Image(systemName: symbol)
                .font(.system(size: dynamicTypeSize.isAccessibilitySize ? 22 : 18,
                              weight: .semibold))
                .frame(width: 44, height: 44)
            if showCaption, let caption {
                Text(caption)
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 48, minHeight: showCaption ? 60 : 48)
        .contentShape(Rectangle())
    }
}

/// Identical action targets in portrait rail and compact landscape row.
/// Captions never imply invented engagement counts or override VoiceOver.
struct ArcadePulseAction: View {
    let symbol: String
    let accessibilityLabel: String
    let caption: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ArcadePulseActionGlyph(symbol: symbol, caption: caption)
        }
        .buttonStyle(.plain)
        .foregroundStyle(ArcadePulseTheme.textPrimary)
        .accessibilityLabel(accessibilityLabel)
    }
}
