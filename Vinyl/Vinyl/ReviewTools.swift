import SwiftUI
import UIKit

@MainActor
final class ReviewSettings: ObservableObject {
    @Published var outlines = ProcessInfo.processInfo.arguments.contains("--review-check")
}

private struct ReviewAnchor {
    let title: String
    let font: CGFloat?
    let radius: CGFloat?
    let note: String
    let bounds: Anchor<CGRect>
}

private struct ReviewPreference: PreferenceKey {
    static var defaultValue: [String: ReviewAnchor] = [:]
    static func reduce(value: inout [String: ReviewAnchor], nextValue: () -> [String: ReviewAnchor]) {
        value.merge(nextValue()) { $1 }
    }
}

struct ReviewMeasurement: Identifiable, Equatable {
    let id: String
    let title: String
    let frame: CGRect
    let font: CGFloat?
    let radius: CGFloat?
    let note: String
}

extension View {
    func reviewElement(_ id: String, _ title: String, font: CGFloat? = nil,
                       radius: CGFloat? = nil, note: String = "") -> some View {
        transformAnchorPreference(key: ReviewPreference.self, value: .bounds) { value, anchor in
            value[id] = ReviewAnchor(title: title, font: font, radius: radius, note: note, bounds: anchor)
        }
    }
    func reviewHost() -> some View { modifier(ReviewHost()) }
    func reviewVisible(_ visible: Bool) -> some View {
        transformPreference(ReviewPreference.self) { if !visible { $0.removeAll() } }
    }
    func coverShadow() -> some View {
        shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 3)
            .shadow(color: .black.opacity(0.04), radius: 1, x: 0, y: 1)
    }
}

private struct ReviewHost: ViewModifier {
    @EnvironmentObject private var settings: ReviewSettings
    @State private var showing = false
    @State private var elements: [ReviewMeasurement] = []
    @State private var containerWidth: CGFloat = 0
    @State private var tabFrame: CGRect?
    @State private var detent: PresentationDetent = .medium

    func body(content: Content) -> some View {
        content
            .overlayPreferenceValue(ReviewPreference.self) { anchors in
                GeometryReader { proxy in
                    let measured = measure(anchors, proxy: proxy)
                    ZStack(alignment: .topLeading) {
                        if settings.outlines {
                            ForEach(measured) { element in
                                RoundedRectangle(cornerRadius: element.radius ?? 0)
                                    .stroke(.blue.opacity(0.8), style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                                    .frame(width: element.frame.width, height: element.frame.height)
                                    .position(x: element.frame.midX, y: element.frame.midY)
                            }
                        }
                    }
                    .allowsHitTesting(false)
                    .onAppear { update(measured, width: proxy.size.width) }
                    .onChange(of: measured) { _, value in update(value, width: proxy.size.width) }
                }
            }
            .background {
                NativeTabProbe { frame in if tabFrame != frame { tabFrame = frame } }
                    .frame(width: 0, height: 0)
            }
            .overlay(alignment: .bottomTrailing) {
                Button("验收", systemImage: "ruler") { showing = true }
                    .font(.system(size: 12, weight: .semibold))
                    .buttonStyle(.bordered)
                    .background(.regularMaterial, in: Capsule())
                    .accessibilityIdentifier("layout-review")
                    .padding(.trailing, DS.controlInset)
                    .padding(.bottom, 120)
            }
            .sheet(isPresented: $showing) {
                ReviewPanel(elements: elements, width: containerWidth)
                    .environmentObject(settings)
                    .presentationDetents([.medium, .large], selection: $detent)
            }
            .task {
                if ProcessInfo.processInfo.arguments.contains("--review-check") {
                    try? await Task.sleep(for: .seconds(
                        ProcessInfo.processInfo.arguments.contains("--review-detail") ? 4 : 2))
                    detent = .large
                    showing = true
                }
            }
    }

    private func measure(_ anchors: [String: ReviewAnchor], proxy: GeometryProxy) -> [ReviewMeasurement] {
        var result = anchors.map { id, value in
            ReviewMeasurement(id: id, title: value.title, frame: proxy[value.bounds],
                              font: value.font, radius: value.radius, note: value.note)
        }.filter { $0.frame.intersects(CGRect(origin: .zero, size: proxy.size)) }
        if let tabFrame {
            let origin = proxy.frame(in: .global).origin
            result.append(ReviewMeasurement(id: "native-tabs", title: "系统导航容器",
                frame: tabFrame.offsetBy(dx: -origin.x, dy: -origin.y), font: nil, radius: nil,
                note: "UIKit 容器边界，包含安全区域；非内部玻璃胶囊轮廓"))
        }
        return result.sorted {
            if $0.frame.minY != $1.frame.minY { return $0.frame.minY < $1.frame.minY }
            if $0.frame.minX != $1.frame.minX { return $0.frame.minX < $1.frame.minX }
            return $0.id < $1.id
        }
    }

    private func update(_ measured: [ReviewMeasurement], width: CGFloat) {
        elements = measured
        containerWidth = width
        guard ProcessInfo.processInfo.arguments.contains("--review-check") else { return }
        let report: [[String: Any]] = measured.map {
            var item: [String: Any] = ["id": $0.id, "title": $0.title,
                                       "x": $0.frame.minX, "y": $0.frame.minY,
                                       "width": $0.frame.width, "height": $0.frame.height,
                                       "note": $0.note]
            if let font = $0.font { item["font"] = font }
            if let radius = $0.radius { item["radius"] = radius }
            return item
        }
        if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]),
           let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
            try? data.write(to: documents.appendingPathComponent("layout-review.json"), options: .atomic)
        }
    }
}

/// Read-only geometry probe. Does not replace or modify the native tab bar.
private struct NativeTabProbe: UIViewRepresentable {
    let report: (CGRect?) -> Void
    func makeUIView(context: Context) -> UIView { UIView() }
    func updateUIView(_ view: UIView, context: Context) {
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            func find(_ node: UIView) -> UITabBar? {
                if let tab = node as? UITabBar, !tab.isHidden, tab.alpha > 0.5 { return tab }
                for child in node.subviews { if let tab = find(child) { return tab } }
                return nil
            }
            report(find(window).map { $0.convert($0.bounds, to: window) })
        }
    }
}

private struct ReviewPanel: View {
    @EnvironmentObject private var settings: ReviewSettings
    @Environment(\.dismiss) private var dismiss
    let elements: [ReviewMeasurement]
    let width: CGFloat
    @State private var first = ""
    @State private var second = ""
    @State private var query = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("显示元素边框", isOn: $settings.outlines)
                    Text("尺寸和位置来自当前界面的实际布局，单位 pt。字号为控件使用的 SF 字体配置；阴影不计入边界。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("元素间距") {
                    Picker("元素 A", selection: $first) {
                        Text("选择").tag("")
                        ForEach(elements) { Text($0.title).tag($0.id) }
                    }
                    Picker("元素 B", selection: $second) {
                        Text("选择").tag("")
                        ForEach(elements) { Text($0.title).tag($0.id) }
                    }
                    if let a = elements.first(where: { $0.id == first }),
                       let b = elements.first(where: { $0.id == second }) {
                        let horizontal = max(0, max(a.frame.minX - b.frame.maxX, b.frame.minX - a.frame.maxX))
                        let vertical = max(0, max(a.frame.minY - b.frame.maxY, b.frame.minY - a.frame.maxY))
                        Text("水平净距 \(pt(horizontal)) · 垂直净距 \(pt(vertical))")
                        Text("左边缘差 \(pt(abs(a.frame.minX - b.frame.minX)))")
                    }
                }
                Section("字号、图片尺寸与圆角") {
                    ForEach(elements.filter { query.isEmpty || $0.title.localizedCaseInsensitiveContains(query) }) { item in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.title).font(.subheadline.weight(.semibold))
                            Text("\(pt(item.frame.width)) × \(pt(item.frame.height)) · 左 \(pt(item.frame.minX)) · 右 \(pt(width - item.frame.maxX))")
                            if let font = item.font { Text("SF 字号 \(pt(font))") }
                            if let radius = item.radius { Text("圆角 \(pt(radius))") }
                            if !item.note.isEmpty { Text(item.note).foregroundStyle(.secondary) }
                        }.font(.caption.monospacedDigit())
                    }
                }
            }
            .navigationTitle("布局验收")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, prompt: "搜索标题、图标、图片")
            .toolbar { Button("完成") { dismiss() } }
        }
    }

    private func pt(_ value: CGFloat) -> String { String(format: "%.1fpt", value) }
}
