import SwiftUI

/// A bounded numeric field with native increment/decrement controls. Percent
/// conversion belongs to the UI; existing projects continue storing ratios.
struct NumberInput: View {
    @Environment(\.vmmTextSize) private var textSize
    let title: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double? = nil
    var unit: String = ""
    var percent = false
    var fractionalDigits:Int=3
    private var factor: Double { percent ? 100 : 1 }
    private var percentage:Bool {percent || unit == "%"}
    var increment:Double {1}
    var display: Binding<Double> {
        Binding(get: { value * factor }, set: { candidate in
            guard candidate.isFinite else { return }
            // Quantize in displayed percent units, retaining five decimal
            // places in the stored ratio (12.345% becomes 0.12345).
            let entered=percentage ? (candidate*1000).rounded()/1000:candidate
            value = min(range.upperBound, max(range.lowerBound, entered / factor))
        })
    }
    var formatter: NumberFormatter {
        let format = NumberFormatter()
        format.numberStyle = .decimal; format.usesGroupingSeparator = false
        format.allowsFloats = true
        format.minimumFractionDigits = percentage ? 3:0; format.maximumFractionDigits = percentage ? 3:fractionalDigits
        format.minimum = NSNumber(value: range.lowerBound * factor)
        format.maximum = NSNumber(value: range.upperBound * factor)
        return format
    }
    var body: some View {
        HStack(spacing: 5) {
            Text(L(title))
            Spacer(minLength: 4)
            NumberTextField(value:display,formatter:formatter,range:(range.lowerBound*factor)...(range.upperBound*factor),title:L(title),points:textSize)
                .frame(width:max(76,textSize*Double(max(6,fractionalDigits+3)))).accessibilityLabel(L(title))
            Stepper(L(title), onIncrement: { display.wrappedValue += increment }, onDecrement: { display.wrappedValue -= increment })
                .labelsHidden().fixedSize().accessibilityLabel(VMMLocalization.language == .english ? "Adjust \(L(title))":title + "を増減")
            if percent || !unit.isEmpty { Text(percent ? "%" : L(unit)).foregroundColor(.secondary).frame(minWidth: 12) }
        }
    }
}
