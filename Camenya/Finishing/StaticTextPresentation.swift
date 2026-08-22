import QuartzCore
import UIKit

enum StaticTextPresentation {
    static func font(for appearance: TextAppearance, baseSize: CGFloat) -> UIFont {
        let size = baseSize * {
            switch appearance.fontScale {
            case .small: 0.8
            case .standard: 1
            case .large: 1.25
            }
        }()
        let weight: UIFont.Weight = switch appearance.fontWeight {
        case .regular: .regular
        case .semibold: .semibold
        case .bold: .bold
        case .heavy: .heavy
        }
        if appearance.fontDesign == .monospaced {
            return .monospacedSystemFont(ofSize: size, weight: weight)
        }
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let design: UIFontDescriptor.SystemDesign = switch appearance.fontDesign {
        case .system, .monospaced: .default
        case .rounded: .rounded
        case .serif: .serif
        }
        return base.fontDescriptor.withDesign(design).map {
            UIFont(descriptor: $0, size: size)
        } ?? base
    }

    static func attributedText(
        _ text: String,
        appearance: TextAppearance,
        font: UIFont
    ) -> NSAttributedString {
        NSAttributedString(
            string: text,
            attributes: attributes(appearance: appearance, font: font)
        )
    }

    static func attributes(
        appearance: TextAppearance,
        font: UIFont
    ) -> [NSAttributedString.Key: Any] {
        var result: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: color(appearance.color),
            .paragraphStyle: paragraphStyle(appearance.alignment)
        ]
        if appearance.outline != .none {
            result[.strokeColor] = outlineColor(for: appearance.color)
            result[.strokeWidth] = appearance.outline == .thin ? -2.2 : -4.5
        }
        return result
    }

    static func paragraphStyle(_ alignment: TextHorizontalAlignment) -> NSParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = textAlignment(alignment)
        paragraph.lineBreakMode = .byWordWrapping
        return paragraph
    }

    static func alignmentMode(_ alignment: TextHorizontalAlignment) -> CATextLayerAlignmentMode {
        switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }

    private static func color(_ color: TextColor) -> UIColor {
        UIColor(red: color.red, green: color.green, blue: color.blue, alpha: color.alpha)
    }

    private static func outlineColor(for color: TextColor) -> UIColor {
        let luminance = 0.2126 * color.red + 0.7152 * color.green + 0.0722 * color.blue
        return luminance > 0.55 ? .black : .white
    }

    private static func textAlignment(_ alignment: TextHorizontalAlignment) -> NSTextAlignment {
        switch alignment {
        case .leading: .left
        case .center: .center
        case .trailing: .right
        }
    }
}
