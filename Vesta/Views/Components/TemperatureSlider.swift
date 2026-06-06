import SwiftUI

/// A temperature slider (whole °C). Built on the native `Slider` so it mirrors
/// correctly in RTL and stays accessible; the tint shifts blue (cold) → red
/// (warm) as a visual cue. `onCommit` fires when the user lets go.
struct TemperatureSlider: View {
    @Binding var celsius: Int
    let range: ClosedRange<Int>
    var onCommit: (Int) -> Void = { _ in /* no callback unless a caller opts in */ }

    var body: some View {
        Slider(
            value: Binding(
                get: { Double(celsius) },
                set: { celsius = Int($0.rounded()) }
            ),
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1
        ) { editing in
            if !editing { onCommit(celsius) }
        }
        .tint(Self.color(forCelsius: celsius, in: range))
    }

    /// Hue 0.6 (blue) at the cold end → 0.0 (red) at the warm end.
    static func color(forCelsius celsius: Int, in range: ClosedRange<Int>) -> Color {
        let span = Double(max(1, range.upperBound - range.lowerBound))
        let fraction = min(max(0, Double(celsius - range.lowerBound) / span), 1)
        return Color(hue: (1 - fraction) * 0.6, saturation: 0.8, brightness: 0.9)
    }
}
