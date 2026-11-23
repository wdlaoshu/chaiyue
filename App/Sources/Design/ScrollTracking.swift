import Observation
import SwiftUI

/// 滚动偏移的独立存放处：只有读取它的小视图（环境光视差、下拉圈）随滚动刷新，页面主体不重算
@Observable
final class ScrollTracker {
    /// 向上滚动的距离（顶部为 0）
    var offset: CGFloat = 0
    /// 顶部继续下拉的距离
    var pull: CGFloat = 0
}

extension View {
    func track(_ tracker: ScrollTracker) -> some View {
        onScrollOffset { value in
            tracker.offset = max(0, value)
            tracker.pull = max(0, -value)
        }
    }
}

/// 环境光随滚动上移（原型 translateY(-y * 0.4)）
struct ParallaxAmbient: View {
    let tracker: ScrollTracker
    var first: Color
    var second: Color

    var body: some View {
        AmbientGlow(first: first, second: second)
            .offset(y: -min(tracker.offset, 500) * 0.4)
            .animation(.easeOut(duration: 1), value: first)
            .ignoresSafeArea()
    }
}

/// 下拉刷新：拉动时圆环渐满，过阈值变明黄并轻震，松手后转圈（原型 `.ptr`）
struct PullToRefresh: ViewModifier {
    let tracker: ScrollTracker
    @Binding var refreshing: Bool
    var threshold: CGFloat = 74
    let action: () async -> Void

    func body(content: Content) -> some View {
        content
            .onScrollRelease {
                guard !refreshing, tracker.pull >= threshold else { return }
                refreshing = true
                UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                Task {
                    await action()
                    withAnimation(.soft) { refreshing = false }
                }
            }
    }
}

struct PullIndicator: View {
    let tracker: ScrollTracker
    let refreshing: Bool
    var threshold: CGFloat = 74
    @State private var armed = false

    var body: some View {
        let pull = refreshing ? max(tracker.pull, 60) : tracker.pull
        let progress = min(1, pull / threshold)
        let ready = progress >= 1 || refreshing
        ZStack {
            Circle().stroke(Tok.fill2, lineWidth: 2.4)
            Circle()
                .trim(from: 0, to: refreshing ? 0.72 : progress * 0.92)
                .stroke(ready ? Tok.accent : Tok.fg2, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .modifier(Spin(active: refreshing))
        }
        .frame(width: 26, height: 26)
        .scaleEffect(0.6 + progress * 0.4)
        .scaleEffect(armed ? 1.18 : 1)
        .opacity(refreshing ? 1 : min(1, max(0, (pull - 8) / CGFloat(30))))
        .offset(y: pull * 0.5 - 22)
        .onChange(of: progress >= 1) { _, reached in
            guard reached, !refreshing else { return }
            UISelectionFeedbackGenerator().selectionChanged()
            withAnimation(.easeOut(duration: 0.12)) { armed = true }
            withAnimation(.bouncy.delay(0.12)) { armed = false }
        }
        .allowsHitTesting(false)
    }
}

private struct Spin: ViewModifier {
    let active: Bool
    @State private var angle: Double = 0

    func body(content: Content) -> some View {
        content
            .rotationEffect(.degrees(angle))
            .onChange(of: active, initial: true) { _, on in
                if on {
                    angle = 0
                    withAnimation(.linear(duration: 0.8).repeatForever(autoreverses: false)) { angle = 360 }
                } else {
                    withAnimation(.linear(duration: 0)) { angle = 0 }
                }
            }
    }
}

extension View {
    func pullToRefresh(_ tracker: ScrollTracker, refreshing: Binding<Bool>, action: @escaping () async -> Void) -> some View {
        modifier(PullToRefresh(tracker: tracker, refreshing: refreshing, action: action))
    }
}

/// 首次出现的错落入场（原型 shelfIntro）
struct Entrance: ViewModifier {
    let shown: Bool
    var delay: Double = 0
    var rise: CGFloat = 26
    var scale: CGFloat = 1

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown ? 0 : rise)
            .scaleEffect(shown ? 1 : scale)
            .animation(.soft.delay(delay), value: shown)
    }
}

extension View {
    func entrance(_ shown: Bool, delay: Double = 0, rise: CGFloat = 26, scale: CGFloat = 1) -> some View {
        modifier(Entrance(shown: shown, delay: delay, rise: rise, scale: scale))
    }
}

extension EnvironmentValues {
    /// 封面到详情页的缩放转场命名空间
    @Entry var heroNamespace: Namespace.ID?
}

extension View {
    @ViewBuilder
    func zoomSource(_ id: String?) -> some View {
        if let id {
            modifier(ZoomSource(id: id))
        } else {
            self
        }
    }
}

private struct ZoomSource: ViewModifier {
    let id: String
    @Environment(\.heroNamespace) private var namespace

    func body(content: Content) -> some View {
        // iOS 17 没有导航缩放转场，退回系统默认推入
        if #available(iOS 18, *), let namespace {
            content.matchedTransitionSource(id: id, in: namespace) { $0.clipShape(RoundedRectangle(cornerRadius: Metrics.coverRadius)) }
        } else {
            content
        }
    }
}

struct ZoomDestination: ViewModifier {
    let id: String?
    @Environment(\.heroNamespace) private var namespace

    func body(content: Content) -> some View {
        if #available(iOS 18, *), let id, let namespace {
            content.navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            content
        }
    }
}
