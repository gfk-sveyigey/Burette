import SwiftUI

/// 对 iOS 26 Liquid Glass 的封装。
///
/// - iOS 26 及以上：使用系统玻璃材质 glassEffect。
/// - iOS 17–25：降级为 ultraThinMaterial，观感接近但不是系统玻璃。
///
/// 全项目只在这里调用玻璃 API，方便后续随 SDK 调整。
extension View {
    @ViewBuilder
    func liquidGlass(
        cornerRadius: CGFloat = 20,
        tint: Color? = nil,
        interactive: Bool = false
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                LiquidGlassStyle.make(tint: tint, interactive: interactive),
                in: .rect(cornerRadius: cornerRadius)
            )
        } else {
            self.background(
                .ultraThinMaterial,
                in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            )
        }
    }

    /// 胶囊形状（发送键等）。
    @ViewBuilder
    func liquidGlassCapsule(tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(
                LiquidGlassStyle.make(tint: tint, interactive: interactive),
                in: .capsule
            )
        } else {
            self.background(tint?.opacity(0.18) ?? Color.clear, in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
        }
    }
}

@available(iOS 26.0, *)
enum LiquidGlassStyle {
    static func make(tint: Color?, interactive: Bool) -> Glass {
        var style: Glass = .regular
        if let tint {
            style = style.tint(tint)
        }
        if interactive {
            style = style.interactive()
        }
        return style
    }
}
