import SwiftUI

extension View {
    /// 左滑只显示一个圆形删除按钮（图标 + 红色，支持全滑删除）。
    ///
    /// 统一入口，方便后续随 iOS 26 的滑动样式调整。
    func circularDeleteSwipe(_ onDelete: @escaping () -> Void) -> some View {
        swipeActions(edge: .trailing, allowsFullSwipe: true) {
            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash.fill")
                    .font(.body.weight(.semibold))
                    .frame(width: 28, height: 28)
            }
            .tint(.red)
            .buttonBorderShape(.circle)
            .accessibilityLabel("删除")
        }
    }
}
