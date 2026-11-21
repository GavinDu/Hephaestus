import Foundation
import Testing
@testable import Hephaestus

/// Actual sRGB Arcade Pulse canvas + source field token contrast, not a
/// screenshot substitute or synthetic public user/post/content.
struct ArcadePulseCreatePublishInputContrastTests {
    private func channel(_ value: Double) -> Double {
        value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }

    private func luminance(_ rgb: (red: Double, green: Double, blue: Double)) -> Double {
        0.2126 * channel(rgb.red) +
        0.7152 * channel(rgb.green) +
        0.0722 * channel(rgb.blue)
    }

    private func whiteOverCanvas(opacity: Double) -> (red: Double, green: Double, blue: Double) {
        let bg = ArcadePulseTheme.canvasRGB
        return (
            red: opacity + (1 - opacity) * bg.red,
            green: opacity + (1 - opacity) * bg.green,
            blue: opacity + (1 - opacity) * bg.blue
        )
    }

    private func contrast(overCanvas opacity: Double) -> Double {
        let foreground = luminance(whiteOverCanvas(opacity: opacity))
        let background = luminance(ArcadePulseTheme.canvasRGB)
        return (foreground + 0.05) / (background + 0.05)
    }

    @Test func promptOnActualDarkCanvasMeetsNormalTextContrast() {
        #expect(contrast(overCanvas: ArcadePulseCreateFieldTokens.promptOpacity) >= 4.5)
    }

    @Test func actualOutlineHasMinimumControlBoundaryContrast() {
        #expect(contrast(overCanvas: ArcadePulseCreateFieldTokens.outlineOpacity) >= 3.0)
    }

    @Test func bothPublicFormFieldsUseAtLeastNative44ptInput() {
        #expect(ArcadePulseCreateFieldTokens.minimumHeight >= 44)
    }
}
