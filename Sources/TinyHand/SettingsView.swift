import AppKit
import ApplicationServices
import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, pointers, appearance, drawing, sound, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .pointers: return "Pointers"
        case .appearance: return "Appearance"
        case .drawing: return "Drawing"
        case .sound: return "Sound"
        case .about: return "About"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .pointers: return "hand.point.up.left.fill"
        case .appearance: return "sparkles"
        case .drawing: return "pencil.tip"
        case .sound: return "speaker.wave.2.fill"
        case .about: return "info.circle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .general: return Color(white: 0.55)
        case .pointers: return Color(red: 0.55, green: 0.42, blue: 0.95)
        case .appearance: return Color(red: 0.95, green: 0.45, blue: 0.6)
        case .drawing: return Color(red: 0.96, green: 0.58, blue: 0.2)
        case .sound: return Color(red: 0.2, green: 0.55, blue: 0.98)
        case .about: return Color(white: 0.45)
        }
    }
}

final class SettingsModel: ObservableObject {
    @Published var section: SettingsSection = .general
    @Published var pinMessage: String?
    @Published private var revision = 0

    var applyToggleShortcut: ((Shortcut) -> Bool)?
    var applyClearShortcut: ((Shortcut) -> Bool)?
    var onRecording: ((Bool) -> Void)?
    var updater: Updater?
    @Published var shortcutError: String?

    private var observer: Any?

    init() {
        observer = NotificationCenter.default.addObserver(forName: Preferences.changed, object: nil, queue: .main) { [weak self] _ in
            self?.revision += 1
        }
        HandAsset.preloadThumbnails(PointerStyle.allCases.compactMap(\.assetName)) { [weak self] in
            self?.revision += 1
        }
    }

    func binding<T>(_ get: @escaping () -> T, _ set: @escaping (T) -> Void) -> Binding<T> {
        Binding(get: get, set: { value in
            set(value)
            self.revision += 1
        })
    }

    private var previewSound: TapSound?

    func preview(_ choice: TapSoundChoice) {
        if previewSound == nil {
            previewSound = TapSound(choice)
        }
        previewSound?.load(choice)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) { [weak self] in
            self?.previewSound?.play()
        }
    }

    @Published var dragging: PointerStyle?
    @Published private var draftOrder: [PointerStyle]?

    var pinnedOrder: [PointerStyle] {
        draftOrder ?? Preferences.pinnedStyles
    }

    private(set) var baseOrder: [PointerStyle] = []

    func beginDrag(_ style: PointerStyle) {
        dragging = style
        baseOrder = Preferences.pinnedStyles
        draftOrder = baseOrder
        pinMessage = nil
    }

    func setDraft(_ order: [PointerStyle]) {
        guard order != draftOrder else {
            return
        }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            draftOrder = order
        }
    }

    func cancelDrag() {
        draftOrder = nil
        dragging = nil
    }

    func resetToolbar() {
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = PointerStyle.defaultPinned
        }
    }

    func resetAll() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings?"
        alert.informativeText = "Shortcuts, toolbar pointers, size, shadow, drawing and sound go back to how they were at first. Open at login and Accessibility stay as they are."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else {
            return
        }
        Preferences.resetAll()
        _ = applyToggleShortcut?(.toggleDefault)
        _ = applyClearShortcut?(.clearDefault)
        shortcutError = nil
        pinMessage = nil
        revision += 1
    }

    func endDrag() {
        if let order = draftOrder {
            Preferences.pinnedStyles = order
        }
        draftOrder = nil
        dragging = nil
    }

    func pin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        if pinned.contains(style) {
            unpin(style)
            return
        }
        if pinned.count >= Preferences.maxPinned {
            pinMessage = "The toolbar is full. Remove one above to add \(style.title)."
            return
        }
        pinned.append(style)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

    func unpin(_ style: PointerStyle) {
        var pinned = Preferences.pinnedStyles
        guard let i = pinned.firstIndex(of: style) else {
            return
        }
        if pinned.count == 1 {
            pinMessage = "Keep at least one pointer in the toolbar."
            return
        }
        pinned.remove(at: i)
        pinMessage = nil
        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
            Preferences.pinnedStyles = pinned
        }
    }

}

struct SettingsView: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            page
        }
        .ignoresSafeArea()
        .frame(minWidth: 760, minHeight: 540)
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(SettingsSection.allCases) { section in
                SidebarRow(section: section, selected: model.section == section) {
                    model.section = section
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 22, height: 22)
                }
                Text("TinyHand").font(.system(size: 12, weight: .semibold))
                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 16)
        }
        .padding(.top, 52)
        .padding(.horizontal, 10)
        .frame(width: 210)
        .frame(maxHeight: .infinity)
        .background(VisualEffect(material: .sidebar))
    }

    private var page: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text(model.section.title)
                    .font(.system(size: 22, weight: .bold))
                    .padding(.top, 6)
                content
            }
            .padding(.horizontal, 28)
            .padding(.top, 48)
            .padding(.bottom, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder
    private var content: some View {
        switch model.section {
        case .general: GeneralPage(model: model)
        case .pointers: PointersPage(model: model)
        case .appearance: AppearancePage(model: model)
        case .drawing: DrawingPage(model: model)
        case .sound: SoundPage(model: model)
        case .about: AboutPage(model: model)
        }
    }
}

private struct GeneralPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Card(title: "Shortcuts") {
                Row("Turn the pointer on or off") {
                    ShortcutField(shortcut: Preferences.toggleShortcut, model: model) { model.applyToggleShortcut?($0) ?? false }
                }
                Row("Clear the drawing") {
                    ShortcutField(shortcut: Preferences.clearShortcut, model: model) { model.applyClearShortcut?($0) ?? false }
                }
            }
            if let error = model.shortcutError {
                Text(error).font(.system(size: 12)).foregroundColor(.red)
            }
            Card(title: "Clicking for real") {
                Row("Hold to use the app", detail: "While you hold this key, the hand steps aside and your clicks, drags and scrolls reach the app underneath.") {
                    Picker("", selection: model.binding({ Preferences.interactKey }, { Preferences.interactKey = $0 })) {
                        ForEach(InteractKey.allCases, id: \.self) { key in
                            Text(key.title).tag(key)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .focusable(false)
                }
            }
            Card(title: "Startup") {
                Row("Open TinyHand when you log in") {
                    Toggle("", isOn: model.binding({ Preferences.launchAtLogin }, { Preferences.launchAtLogin = $0 }))
                        .toggleStyle(.switch).labelsHidden().focusable(false)
                }
                if let updater = model.updater {
                    Row("Check for updates automatically") {
                        Toggle("", isOn: model.binding({ updater.automaticallyChecks }, { updater.automaticallyChecks = $0 }))
                            .toggleStyle(.switch).labelsHidden().focusable(false)
                    }
                }
            }
            Card(title: "Permission") {
                Row("Accessibility", detail: AXIsProcessTrusted()
                    ? "Clicks become taps and you can draw."
                    : "Needed so clicks become taps and you can draw.") {
                    if AXIsProcessTrusted() {
                        Label("Allowed", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundColor(.green)
                    } else {
                        PillButton(title: "Open Settings") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                                NSWorkspace.shared.open(url)
                            }
                        }
                    }
                }
            }
            HStack {
                Spacer()
                TextButton(title: "Reset all settings…") { model.resetAll() }
            }
            Text("Click the menu bar icon to turn the pointer on or off, right-click it for the menu. While it's on, click to tap, hold and drag to draw, hold \(Preferences.interactKey == .off ? "the interact key" : Preferences.interactKey.title) to click for real, and press Esc to clear and exit.")
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct PointersPage: View {
    @ObservedObject var model: SettingsModel
    private let columns = [GridItem(.adaptive(minimum: 92, maximum: 110), spacing: 8)]
    @State private var rowFrame: CGRect = .zero
    @State private var dragX: CGFloat = 0
    @State private var dragStart = 0
    @State private var floating: Floating?
    @State private var listDropOK = false

    struct Floating {
        let style: PointerStyle
        let point: CGPoint
        let badge: String?
    }

    private var step: CGFloat {
        (rowFrame.width - 20 + 6) / CGFloat(Preferences.maxPinned)
    }

    private func overRow(_ p: CGPoint) -> Bool {
        rowFrame.insetBy(dx: -16, dy: -28).contains(p)
    }

    private func slot(at x: CGFloat, count: Int) -> Int {
        min(max(Int((x - rowFrame.minX - 10) / step), 0), max(0, count - 1))
    }

    private func rowDrag(_ value: DragGesture.Value) {
        let start = CGPoint(x: rowFrame.minX + value.startLocation.x, y: rowFrame.minY + value.startLocation.y)
        let p = CGPoint(x: rowFrame.minX + value.location.x, y: rowFrame.minY + value.location.y)
        if model.dragging == nil {
            let base = Preferences.pinnedStyles
            let i = Int((start.x - rowFrame.minX - 10) / step)
            guard start.x >= rowFrame.minX + 10, base.indices.contains(i) else {
                return
            }
            dragStart = i
            model.beginDrag(base[i])
        }
        guard let style = model.dragging else {
            return
        }
        var order = model.baseOrder.filter { $0 != style }
        if overRow(p) {
            dragX = value.translation.width
            order.insert(style, at: slot(at: p.x, count: order.count + 1))
            floating = nil
        } else if model.baseOrder.count > 1 {
            floating = Floating(style: style, point: p, badge: "minus.circle.fill")
        } else {
            order = model.baseOrder
            floating = Floating(style: style, point: p, badge: nil)
        }
        model.setDraft(order)
    }

    private func listDrag(_ style: PointerStyle, _ value: DragGesture.Value) {
        if model.dragging != style {
            model.beginDrag(style)
            dragStart = -1
        }
        dragX = 0
        let p = value.location
        let base = model.baseOrder
        let others = base.filter { $0 != style }
        let full = !base.contains(style) && base.count >= Preferences.maxPinned
        floating = Floating(style: style, point: p, badge: full && overRow(p) ? "nosign" : nil)
        guard overRow(p), !full else {
            listDropOK = false
            model.setDraft(base)
            return
        }
        listDropOK = true
        var order = others
        order.insert(style, at: min(slot(at: p.x + step / 2, count: others.count + 1), others.count))
        model.setDraft(order)
    }

    private func dropDrag() {
        let removing = floating?.badge == "minus.circle.fill"
        let fromList = dragStart < 0
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            dragX = 0
            if fromList {
                if listDropOK {
                    model.endDrag()
                } else {
                    model.cancelDrag()
                }
            } else if !fromList && floating != nil && !removing {
                model.cancelDrag()
                model.pinMessage = "Keep at least one pointer in the toolbar."
            } else {
                model.endDrag()
            }
            floating = nil
            listDropOK = false
        }
    }

    private func offset(_ style: PointerStyle) -> CGFloat {
        guard model.dragging == style, dragStart >= 0, floating == nil, let i = model.pinnedOrder.firstIndex(of: style) else {
            return 0
        }
        return dragX - CGFloat(i - dragStart) * step
    }

    var body: some View {
        let pinned = model.pinnedOrder
        let pinnedSet = Set(Preferences.pinnedStyles)
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("In your toolbar")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.secondary)
                    Spacer()
                    Text("\(Preferences.pinnedStyles.count) of \(Preferences.maxPinned) · drag to reorder or out to remove")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                    TextButton(title: "Reset") { model.resetToolbar() }
                }
                .padding(.horizontal, 4)
                HStack(spacing: 6) {
                    ForEach(pinned, id: \.self) { style in
                        let lifted = model.dragging == style
                        ToolbarSlot(style: style, model: model, lifted: lifted, gap: lifted && dragStart < 0)
                            .offset(x: offset(style))
                            .zIndex(lifted ? 1 : 0)
                            .transaction { if lifted && dragStart >= 0 { $0.animation = nil } }
                    }
                    ForEach(0..<max(0, Preferences.maxPinned - pinned.count), id: \.self) { _ in
                        EmptySlot()
                    }
                }
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(Color.primary.opacity(0.045))
                )
                .background(GeometryReader { g in
                    Color.clear
                        .onAppear { rowFrame = g.frame(in: .named("pointersPage")) }
                        .onChange(of: g.frame(in: .named("pointersPage"))) { rowFrame = $0 }
                })
                .coordinateSpace(name: "toolbarRow")
                .gesture(
                    DragGesture(minimumDistance: 3, coordinateSpace: .named("toolbarRow"))
                        .onChanged { rowDrag($0) }
                        .onEnded { _ in dropDrag() }
                )
                if let message = model.pinMessage {
                    Text(message).font(.system(size: 12)).foregroundColor(.red).padding(.horizontal, 4)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("All pointers · click or drag to add")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(PointerStyle.allCases, id: \.self) { style in
                        PointerTile(style: style, added: pinnedSet.contains(style)) {
                            model.pin(style)
                        }
                        .simultaneousGesture(
                            DragGesture(minimumDistance: 4, coordinateSpace: .named("pointersPage"))
                                .onChanged { listDrag(style, $0) }
                                .onEnded { _ in dropDrag() }
                        )
                    }
                }
            }
        }
        .coordinateSpace(name: "pointersPage")
        .overlay(alignment: .topLeading) {
            if let f = floating {
                FloatingPointer(style: f.style, badge: f.badge)
                    .position(f.point)
                    .allowsHitTesting(false)
            }
        }
    }
}

private struct FloatingPointer: View {
    let style: PointerStyle
    let badge: String?

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(width: 58, height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(0.25), radius: 12, y: 5)
            )
            if let badge = badge {
                Image(systemName: badge)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white, badge == "nosign" ? Color.gray : Color.red)
                    .offset(x: 6, y: -6)
            }
        }
        .scaleEffect(1.06)
    }
}

private struct ToolbarSlot: View {
    let style: PointerStyle
    @ObservedObject var model: SettingsModel
    let lifted: Bool
    var gap = false
    @State private var hovering = false

    var body: some View {
        if gap {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.accentColor.opacity(0.12))
                .frame(maxWidth: .infinity)
                .frame(height: 58)
        } else {
            slot
        }
    }

    private var slot: some View {
        ZStack(alignment: .topTrailing) {
            Group {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 40, height: 40)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor).opacity(0.95))
                    .shadow(color: .black.opacity(lifted ? 0.22 : 0.08), radius: lifted ? 10 : 2, y: lifted ? 4 : 1)
            )
            .scaleEffect(lifted ? 1.06 : 1)
            if hovering && model.dragging == nil {
                Button {
                    model.unpin(style)
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.black.opacity(0.55)))
                }
                .buttonStyle(.plain)
                .focusable(false)
                .help("Remove from the toolbar")
                .offset(x: 5, y: -5)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(style.title)
    }
}

private struct EmptySlot: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .frame(maxWidth: .infinity)
            .frame(height: 58)
            .overlay(Image(systemName: "plus").font(.system(size: 11, weight: .medium)).foregroundColor(.secondary.opacity(0.5)))
    }
}

private struct AppearancePage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card(title: "Pointer") {
            Row("Size") {
                HStack(spacing: 10) {
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 10)).foregroundColor(.secondary)
                    Slider(value: model.binding({ Double(Preferences.pointerSize) }, { Preferences.pointerSize = CGFloat($0) }),
                           in: Double(Preferences.pointerSizeRange.lowerBound)...Double(Preferences.pointerSizeRange.upperBound))
                        .frame(width: 180)
                        .focusable(false)
                    Image(systemName: "hand.point.up.left.fill").font(.system(size: 16)).foregroundColor(.secondary)
                }
            }
            Row("Shadow under the pointer") {
                Toggle("", isOn: model.binding({ Preferences.showShadow }, { Preferences.showShadow = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
        }
    }
}

private struct DrawingPage: View {
    @ObservedObject var model: SettingsModel
    private static let choices: [(String, Double)] = [
        ("After 3 seconds", 3),
        ("After 6 seconds", 6),
        ("After 10 seconds", 10),
        ("Keep until cleared", 0),
    ]

    var body: some View {
        Card(title: "Ink") {
            Row("Colour", detail: "Each pointer draws in its own colour unless you pick one.") {
                Picker("", selection: model.binding({ Preferences.inkChoice }, { Preferences.inkChoice = $0 })) {
                    ForEach(InkChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .focusable(false)
            }
            Row("Ink button in the toolbar", detail: "Change the colour while you present.") {
                Toggle("", isOn: model.binding({ Preferences.showInkButton }, { Preferences.showInkButton = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
            Row("Lines fade", detail: "Hold and drag to draw. Clear everything any time with the shortcut.") {
                Picker("", selection: model.binding({ Preferences.fadeSeconds }, { Preferences.fadeSeconds = $0 })) {
                    ForEach(DrawingPage.choices, id: \.1) { choice in
                        Text(choice.0).tag(choice.1)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .focusable(false)
            }
        }
    }
}

private struct SoundPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        Card(title: "Tap sound") {
            Row("Sound", detail: "Plays on every tap. Pick one to hear it.") {
                Picker("", selection: model.binding({ Preferences.tapSound }, { choice in
                    Preferences.tapSound = choice
                    model.preview(choice)
                })) {
                    ForEach(TapSoundChoice.allCases, id: \.self) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .focusable(false)
                PillButton(title: "Play") { model.preview(Preferences.tapSound) }
            }
            Row("Hands", detail: "Tap sound for the hands.") {
                Toggle("", isOn: model.binding({ Preferences.handSound }, { Preferences.handSound = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
            Row("Laser dot", detail: "Off by default, for quiet pointing.") {
                Toggle("", isOn: model.binding({ Preferences.laserSound }, { Preferences.laserSound = $0 }))
                    .toggleStyle(.switch).labelsHidden().focusable(false)
            }
        }
    }
}

private struct AboutPage: View {
    @ObservedObject var model: SettingsModel

    var body: some View {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        VStack(alignment: .leading, spacing: 22) {
            HStack(spacing: 16) {
                if let icon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                    Image(nsImage: icon).resizable().frame(width: 72, height: 72)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("TinyHand").font(.system(size: 18, weight: .bold))
                    Text("Version \(version)").font(.system(size: 12)).foregroundColor(.secondary)
                    Text("A tiny hand for your Mac. Free and open source.").font(.system(size: 12)).foregroundColor(.secondary)
                }
                Spacer()
                if let updater = model.updater {
                    PillButton(title: "Check for Updates") { updater.checkForUpdates() }
                }
            }
            Card(title: nil) {
                LinkRow(title: "Website", detail: "tinyhand.app", url: "https://tinyhand.app")
                LinkRow(title: "Source code", detail: "github.com/nilbuild/tinyhand", url: "https://github.com/nilbuild/tinyhand")
                LinkRow(title: "Made by", detail: "@nilbuild on X", url: "https://x.com/nilbuild")
            }
        }
    }
}

private struct SidebarRow: View {
    let section: SettingsSection
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                IconTile(symbol: section.symbol, tint: section.tint)
                Text(section.title)
                    .font(.system(size: 13, weight: selected ? .semibold : .regular))
                    .foregroundColor(.primary)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : hovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct IconTile: View {
    let symbol: String
    let tint: Color

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(LinearGradient(colors: [tint.opacity(0.85), tint], startPoint: .top, endPoint: .bottom))
            .frame(width: 24, height: 24)
            .overlay(Image(systemName: symbol).font(.system(size: 12, weight: .semibold)).foregroundColor(.white))
    }
}

private struct Card<Content: View>: View {
    let title: String?
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let title = title {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.leading, 4)
            }
            VStack(spacing: 0) {
                _VariadicView.Tree(Separated()) {
                    content
                }
            }
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(0.045))
            )
        }
    }
}

private struct Separated: _VariadicView_MultiViewRoot {
    func body(children: _VariadicView.Children) -> some View {
        let last = children.last?.id
        ForEach(children) { child in
            child
            if child.id != last {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.leading, 14)
            }
        }
    }
}

private struct Row<Trailing: View>: View {
    let title: String
    let detail: String?
    @ViewBuilder let trailing: Trailing

    init(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let detail = detail {
                    Text(detail).font(.system(size: 11)).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(minHeight: 44)
    }
}

private struct LinkRow: View {
    let title: String
    let detail: String
    let url: String
    @State private var hovering = false

    var body: some View {
        Button {
            if let u = URL(string: url) {
                NSWorkspace.shared.open(u)
            }
        } label: {
            HStack {
                Text(title).font(.system(size: 13)).foregroundColor(.primary)
                Spacer()
                Text(detail).font(.system(size: 12)).foregroundColor(.secondary)
                Image(systemName: "arrow.up.right").font(.system(size: 10, weight: .semibold)).foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .frame(minHeight: 44)
            .background(Color.primary.opacity(hovering ? 0.04 : 0))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct TextButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(hovering ? .primary : .secondary)
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct PillButton: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(hovering ? 0.14 : 0.09)))
        }
        .buttonStyle(.plain)
        .focusable(false)
        .onHover { hovering = $0 }
    }
}

private struct PointerTile: View {
    let style: PointerStyle
    let added: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                if let icon = pointerIcon(style) {
                    Image(nsImage: icon).resizable().interpolation(.high).frame(width: 52, height: 52)
                }
                Text(style.title)
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.07 : 0.03))
            )
            .overlay(alignment: .topTrailing) {
                if added {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.accentColor)
                        .padding(7)
                } else if hovering {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                        .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .focusable(false)
        .help(added ? "\(style.title): in the toolbar, click to remove" : "Add \(style.title) to the toolbar")
        .onHover { hovering = $0 }
    }
}

private struct ShortcutField: NSViewRepresentable {
    let shortcut: Shortcut
    let model: SettingsModel
    let apply: (Shortcut) -> Bool

    func makeNSView(context: Context) -> ShortcutRecorder {
        let r = ShortcutRecorder(shortcut: shortcut)
        r.onRecording = { model.onRecording?($0) }
        r.onChange = { s in
            let ok = apply(s)
            model.shortcutError = ok ? nil : "\(s.display) is already used by another app. Pick a different shortcut."
            return ok
        }
        return r
    }

    func updateNSView(_ nsView: ShortcutRecorder, context: Context) {
        nsView.show(shortcut)
    }
}

struct VisualEffect: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

private let blankIcon = NSImage(size: NSSize(width: 64, height: 64))

private func pointerIcon(_ style: PointerStyle) -> NSImage? {
    guard let name = style.assetName else {
        return Toolbar.icon(for: style)
    }
    return HandAsset.cachedThumbnail(name) ?? blankIcon
}
