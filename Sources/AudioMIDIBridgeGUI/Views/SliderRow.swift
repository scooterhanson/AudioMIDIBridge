import SwiftUI

/// Shared labeled-slider rows used by both the Levels and Advanced tabs.
func sliderRow(title: String, value: Double, range: ClosedRange<Double>,
                onChange: @escaping (Double) -> Void) -> some View {
    HStack {
        Text(title)
            .frame(width: 130, alignment: .leading)
            .font(AppFont.caption)
        Slider(value: Binding(get: { value }, set: onChange), in: range)
        Text(String(format: "%.4f", value))
            .font(AppFont.captionMonospaced)
            .frame(width: 60, alignment: .trailing)
    }
}

func intSliderRow(title: String, value: Int, range: ClosedRange<Int>,
                   onChange: @escaping (Int) -> Void) -> some View {
    HStack {
        Text(title)
            .frame(width: 130, alignment: .leading)
            .font(AppFont.caption)
        Slider(
            value: Binding(get: { Double(value) }, set: { onChange(Int($0.rounded())) }),
            in: Double(range.lowerBound)...Double(range.upperBound),
            step: 1
        )
        Text("\(value)")
            .font(AppFont.captionMonospaced)
            .frame(width: 60, alignment: .trailing)
    }
}
