import SwiftUI

enum StandSection: Int, CaseIterable, Identifiable {
    case today, library, reader
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .today: return String(localized: "오늘")
        case .library: return String(localized: "라이브러리")
        case .reader: return String(localized: "악보대")
        }
    }
    var symbol: String {
        switch self {
        case .today: return "house"
        case .library: return "book"
        case .reader: return "music.note.list"
        }
    }
}

enum StandStyle {
    static let blue = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.32, green: 0.58, blue: 1, alpha: 1)
            : UIColor(red: 0.12, green: 0.35, blue: 0.78, alpha: 1)
    })
    static let gold = Color(red: 0.86, green: 0.74, blue: 0.56)
    static let surface = Color(uiColor: .secondarySystemBackground)
    static let border = Color(uiColor: .separator).opacity(0.3)
}

struct StandNavigation: View {
    @Binding var section: StandSection
    var horizontal = false
    var body: some View {
        Group {
            if horizontal { HStack(spacing: 8) { entries }.padding(.horizontal, 12) }
            else { VStack(spacing: 16) { entries; Spacer(minLength: 0) }.padding(.vertical, 20).padding(.horizontal, 6) }
        }
        .background(StandStyle.surface)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("standNavigation")
    }
    @ViewBuilder private var entries: some View {
        ForEach(StandSection.allCases) { item in
            Button { section = item } label: {
                VStack(spacing: 6) {
                    Image(systemName: item.symbol).font(.system(size: 24, weight: .regular))
                    Text(item.title).font(.caption).lineLimit(2)
                }
                .frame(maxWidth: horizontal ? .infinity : nil)
                .frame(width: horizontal ? nil : 72, height: horizontal ? 56 : 76)
                .foregroundStyle(section == item ? StandStyle.blue : Color.primary)
                .background(section == item ? StandStyle.blue.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(section == item ? .isSelected : [])
            .accessibilityIdentifier("nav.\(item.rawValue)")
        }
    }
}

struct StandToolButton: View {
    let title: String
    let symbol: String
    var selected = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 23, weight: .regular))
                    .frame(width: 48, height: 44)
                    .background(selected ? StandStyle.blue.opacity(0.12) : StandStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                Text(title).font(.caption2).lineLimit(2)
            }
            .frame(width: 64).frame(minHeight: 64)
            .foregroundStyle(selected ? StandStyle.blue : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(selected ? Text("선택됨") : Text(""))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

struct StandTools: View {
    @ObservedObject var stand: MusicStand
    let select: () -> Void
    let paste: () -> Void
    let destination: () -> Void
    @State private var colorsPresented = false
    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 8) {
                StandToolButton(title: String(localized: "펜"), symbol: "pencil.tip", selected: stand.selectedToolKind == 0 && stand.transferMode == .inactive) { stand.setTool(0) }
                    .accessibilityIdentifier("tool.pen")
                StandToolButton(title: String(localized: "형광펜"), symbol: "highlighter", selected: stand.selectedToolKind == 1 && stand.transferMode == .inactive) { stand.setTool(1) }
                    .accessibilityIdentifier("tool.marker")
                colorControl
                StandToolButton(title: String(localized: "지우개"), symbol: "eraser", selected: stand.selectedToolKind == 2 && stand.transferMode == .inactive) { stand.setTool(2) }
                    .accessibilityIdentifier("tool.eraser")
                Divider().padding(.horizontal, 12)
                StandToolButton(title: String(localized: "실행 취소"), symbol: "arrow.uturn.backward") { stand.undo() }.accessibilityIdentifier("tool.undo")
                StandToolButton(title: String(localized: "다시 실행"), symbol: "arrow.uturn.forward") { stand.redo() }.accessibilityIdentifier("tool.redo")
                StandToolButton(title: String(localized: "선택 복사"), symbol: "rectangle.dashed", selected: stand.transferMode == .select, action: select)
                    .accessibilityIdentifier("tool.select")
                StandToolButton(title: String(localized: "붙여넣기"), symbol: "doc.on.clipboard", selected: stand.transferMode == .paste, action: paste)
                    .disabled(stand.clipboard.selection == nil).accessibilityIdentifier("tool.paste")
                StandToolButton(title: String(localized: "다른 악보"), symbol: "arrow.up.doc.on.clipboard", action: destination)
                    .disabled(stand.clipboard.selection == nil).accessibilityIdentifier("tool.transferDestination")
            }.padding(.vertical, 12)
        }
        .frame(width: 72).background(Color(uiColor: .systemBackground))
        .accessibilityIdentifier("toolStrip").disabled(stand.busy)
        .onChange(of: stand.selectedToolKind) { _ in colorsPresented = false }
    }

    private var colorControl: some View {
        Button { colorsPresented.toggle() } label: {
            HStack(spacing: 4) {
                Circle().fill(Color(uiColor: stand.selectedInkColor.uiColor)).frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(.secondary, lineWidth: 1))
                Image(systemName: "chevron.down").font(.caption2)
            }.frame(width: 56, height: 44)
        }
        .buttonStyle(.plain).disabled(stand.selectedToolKind == 2)
        .accessibilityLabel(stand.selectedToolKind == 1 ? Text("형광펜 색상") : Text("펜 색상"))
        .accessibilityValue(Text(stand.selectedInkColor.name)).accessibilityHint(Text("색상 선택 열기"))
        .accessibilityIdentifier("inkColorPicker")
        .popover(isPresented: $colorsPresented, arrowEdge: .trailing) {
            InkColorPalette(selected: stand.selectedInkColor,
                title: stand.selectedToolKind == 1 ? String(localized: "형광펜 색상") : String(localized: "펜 색상"),
                choose: { stand.setInkColor($0); colorsPresented = false }, close: { colorsPresented = false })
        }
    }
}

struct TransferActions: View {
    @ObservedObject var stand: MusicStand
    var stacked = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if stand.transferMode == .select {
                Text("사각형으로 개인 메모를 선택해 주세요.").font(.subheadline)
                HStack {
                    Button("취소") { stand.cancelTransfer() }.frame(minWidth: 56, minHeight: 44).accessibilityIdentifier("cancelTransfer")
                    Spacer()
                    Button("선택 복사 (\(stand.selectionCount))") { stand.copySelection() }
                        .buttonStyle(.borderedProminent).disabled(stand.selectionCount == 0)
                        .frame(minHeight: 44).accessibilityIdentifier("copySelection")
                }
            } else if stand.transferMode == .paste {
                Text("미리보기를 드래그해 위치를 정해 주세요.").font(.subheadline)
                HStack(spacing: 12) {
                    Button { stand.scalePaste(0.8) } label: { Image(systemName: "minus").frame(width: 48, height: 44) }
                        .buttonStyle(.bordered).accessibilityLabel(Text("축소")).accessibilityIdentifier("scaleDown")
                    Button { stand.scalePaste(1.25) } label: { Image(systemName: "plus").frame(width: 48, height: 44) }
                        .buttonStyle(.bordered).accessibilityLabel(Text("확대")).accessibilityIdentifier("scaleUp")
                    Spacer(minLength: 0)
                    if !stacked { confirm }
                }
                HStack {
                    Button("취소") { stand.cancelTransfer() }.frame(minWidth: 56, minHeight: 44).accessibilityIdentifier("cancelTransfer")
                    Spacer()
                    if stacked { confirm }
                }
            }
        }.tint(StandStyle.blue).disabled(stand.busy)
    }
    private var confirm: some View {
        Button { stand.commitPaste() } label: { Text("붙여넣기 확정").fontWeight(.semibold).frame(minHeight: 44).padding(.horizontal, 12) }
            .buttonStyle(.borderedProminent).tint(stacked ? StandStyle.gold : StandStyle.blue)
            .foregroundStyle(stacked ? Color.black : Color.white).accessibilityIdentifier("commitPaste")
    }
}

struct InkColorPalette: View {
    let selected: InkColor
    let title: String
    let choose: (InkColor) -> Void
    let close: () -> Void
    var body: some View {
            VStack(spacing: 12) {
                HStack {
                    Text(title).font(.headline)
                    Spacer()
                    Button { close() } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel(Text("닫기")).accessibilityIdentifier("closeInkColors")
                }
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 12) {
                    ForEach(InkColor.allCases) { color in
                        Button { choose(color) } label: {
                            VStack(spacing: 4) {
                                Circle().fill(Color(uiColor: color.uiColor)).frame(width: 36, height: 36)
                                    .overlay(Circle().strokeBorder(.secondary.opacity(0.5), lineWidth: 1))
                                    .overlay {
                                        if selected == color {
                                            Image(systemName: "checkmark").font(.headline)
                                                .foregroundStyle(color == .yellow || color == .orange ? .black : .white)
                                        }
                                    }
                                Text(color.name).font(.caption).foregroundStyle(.primary)
                            }.frame(maxWidth: .infinity, minHeight: 60)
                        }.buttonStyle(.plain).accessibilityLabel(Text(color.name))
                            .accessibilityAddTraits(selected == color ? .isSelected : [])
                            .accessibilityIdentifier("inkColor.\(color.rawValue)")
                    }
                }
                Text("색상을 선택하면 닫힙니다.").font(.caption).foregroundStyle(.secondary)
            }.padding(16).frame(width: 288).preferredColorScheme(.light)
    }
}
