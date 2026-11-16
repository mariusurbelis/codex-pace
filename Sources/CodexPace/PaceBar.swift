import AppKit
import SwiftUI

/// Blue is the allowance up to the pace marker; green is the surplus beyond it.
struct PaceBar: View {
    let remaining: Double
    let target: Double?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let remainingWidth = width * clamped(remaining) / 100
            let targetWidth = target.map { width * clamped($0) / 100 }

            ZStack(alignment: .topLeading) {
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(.quaternary)
                    Rectangle()
                        .fill(Color.blue)
                        .frame(width: remainingWidth)
                    if let targetWidth, remainingWidth > targetWidth {
                        Rectangle()
                            .fill(PacePalette.surplus)
                            .frame(width: remainingWidth - targetWidth)
                            .offset(x: targetWidth)
                    }
                }
                .frame(height: 10)
                .clipShape(Capsule())
                .offset(y: 4)

                if let targetWidth {
                    RoundedRectangle(cornerRadius: 1)
                        .fill(.primary)
                        .frame(width: 2, height: 18)
                        .offset(x: max(0, min(width - 2, targetWidth - 1)))

                    Text("Even pace")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .frame(width: 64)
                        .offset(x: max(0, min(width - 64, targetWidth - 32)), y: 21)
                }
            }
        }
        .frame(height: target == nil ? 18 : 35)
        .help(accessibilitySummary + " Blue is the allowance up to the pace marker. Green is above pace. Gray is already used.")
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Allowance remaining")
        .accessibilityValue(accessibilitySummary)
    }

    private func clamped(_ value: Double) -> Double {
        value.isFinite ? min(100, max(0, value)) : 0
    }

    private var accessibilitySummary: String {
        let remainingValue = clamped(remaining).formatted(.number.precision(.fractionLength(1)))
        if let target {
            let targetValue = clamped(target).formatted(.number.precision(.fractionLength(1)))
            let gap = clamped(remaining) - clamped(target)
            let gapValue = abs(gap).formatted(.number.precision(.fractionLength(1)))
            return "\(remainingValue) percent remaining. Even-use pace: \(targetValue) percent. \(gapValue) percentage points \(gap < 0 ? "below" : "above") pace."
        }
        return "\(remainingValue) percent remaining. Pace unavailable."
    }
}

enum PacePalette {
    /// Darker than system green in light mode so the status remains readable.
    static let surplus = Color(nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0.24, green: 0.84, blue: 0.43, alpha: 1)
            : NSColor(srgbRed: 0.10, green: 0.47, blue: 0.23, alpha: 1)
    })
}
