import SwiftUI
import WorshipCueLocal

struct ChartThumbnail: View {
    let stand: MusicStand
    let versionID: UUID
    var page = 0
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else { Image(systemName: "doc").foregroundStyle(.secondary).accessibilityLabel(Text("미리보기 없음")) }
        }
        .padding(3).frame(width: 44, height: 58).background(.white, in: RoundedRectangle(cornerRadius: 5))
        .task(id: "\(versionID.uuidString).\(page)") { image = stand.chartThumbnail(versionID, page: page) }
        .accessibilityHidden(image != nil)
    }
}

struct VersionInspector: View {
    @ObservedObject var stand: MusicStand
    let close: () -> Void
    let select: () -> Void
    let preview: () -> Void
    let destination: () -> Void
    @State private var targetPage = 1
    private var version: LibraryVersion? { stand.library.versions.first { $0.id == stand.current?.id } }
    private var sourceVersion: LibraryVersion? { stand.library.versions.first { $0.id == stand.clipboard.selection?.source.versionID } }
    private var selectedImage: UIImage? {
        guard let selection = stand.clipboard.selection else { return nil }
        let bounds = selection.bounds.insetBy(dx: -8, dy: -8)
        let scale = min(2, 480 / max(1, bounds.width), 160 / max(1, bounds.height))
        return selection.drawing.image(from: bounds, scale: scale)
    }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("버전과 메모").font(.title2).fontWeight(.semibold)
                Spacer()
                Button(action: close) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                    .buttonStyle(.plain).accessibilityLabel(Text("닫기")).accessibilityIdentifier("closeVersionInspector")
            }.padding(.horizontal, 18).padding(.top, 12)
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    versions
                    Divider()
                    selectedNotes
                }.padding(18)
            }.accessibilityIdentifier("versionInspectorScroll")
            Divider()
            VStack(alignment: .leading, spacing: 5) {
                Label("원본 메모 유지", systemImage: "lock.fill").font(.subheadline).fontWeight(.medium)
                    .foregroundStyle(StandStyle.gold).accessibilityIdentifier("sourceNotesPreserved")
                Text("원본 버전의 메모는 그대로 유지됩니다.").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 18).padding(.vertical, 12)
            if stand.transferMode != .inactive {
                Divider()
                TransferActions(stand: stand, stacked: true).padding(18)
            }
        }
        .background(StandStyle.surface).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(StandStyle.border))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("versionInspector")
        .onAppear { targetPage = stand.pageIndex + 1 }
        .onChange(of: stand.current?.id) { _ in targetPage = stand.pageIndex + 1 }
        .onChange(of: stand.pageIndex) { targetPage = $0 + 1 }
    }

    private var versions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("버전 목록").font(.headline)
            if let version {
                ForEach(stand.library.versions(for: version.songID)) { item in versionRow(item) }
            }
            Text("열기와 개인 기본 악보 지정은 별도입니다.").font(.caption).foregroundStyle(.secondary)
        }
    }
    private func versionRow(_ item: LibraryVersion) -> some View {
        HStack(spacing: 0) {
            Button { Task { _ = await stand.openVersion(item.id) } } label: {
                HStack(spacing: 12) {
                    ChartThumbnail(stand: stand, versionID: item.id)
                    VStack(alignment: .leading, spacing: 5) {
                        Text("v\(item.number) · \(item.writtenKey ?? "?")").font(.headline)
                        Text(item.label).font(.caption).lineLimit(1).foregroundStyle(.secondary)
                        if item.id == stand.current?.id {
                            Label("현재 악보", systemImage: "checkmark.circle.fill").font(.caption2).foregroundStyle(StandStyle.blue)
                        }
                    }
                    Spacer(minLength: 4)
                }.padding(10).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("inspectorOpenVersion.\(item.number)")
            Button { stand.prefer(item) } label: {
                Image(systemName: stand.library.preferences[item.songID] == item.id ? "star.fill" : "star")
                    .frame(width: 44, height: 44)
            }.buttonStyle(.plain).disabled(stand.library.preferences[item.songID] == item.id)
                .accessibilityLabel(stand.library.preferences[item.songID] == item.id ? Text("개인 기본 악보") : Text("개인 기본 악보로 지정"))
                .accessibilityIdentifier("inspectorPreferVersion.\(item.number)")
        }
        .background(item.id == stand.current?.id ? Color.primary.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(item.id == stand.current?.id ? StandStyle.blue.opacity(0.5) : StandStyle.border))
        .disabled(stand.busy)
    }

    @ViewBuilder private var selectedNotes: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let selection = stand.clipboard.selection {
                Text("선택한 개인 메모").font(.headline)
                HStack(spacing: 12) {
                    ChartThumbnail(stand: stand, versionID: selection.source.versionID, page: selection.source.pageIndex)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(sourceVersion.map { String(localized: "메모 원본 · v\($0.number)") } ?? String(localized: "메모 원본")).font(.subheadline)
                        Text("\(selection.source.pageIndex + 1)쪽 · \(selection.drawing.strokes.count)획").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let selectedImage {
                    Image(uiImage: selectedImage)
                        .resizable().scaledToFit().padding(12).frame(maxWidth: .infinity).frame(height: 100)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(StandStyle.blue, lineWidth: 2))
                        .accessibilityLabel(Text("선택한 개인 메모 미리보기"))
                        .accessibilityIdentifier("selectedInkPreview")
                }
                if stand.transferMode == .inactive {
                    Stepper("대상 페이지 \(targetPage) / \(stand.pageCount)", value: $targetPage, in: 1...max(1, stand.pageCount))
                        .accessibilityIdentifier("inspectorDestinationPage")
                    Button { Task {
                        if targetPage - 1 == stand.pageIndex { preview() }
                        else if let id = stand.current?.id, await stand.openVersion(id, page: targetPage - 1) { preview() }
                    } } label: {
                        Label("이 악보에 붙여넣기 미리보기", systemImage: "doc.on.clipboard").frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent).accessibilityIdentifier("inspectorPastePreview")
                    Button(action: destination) { Label("다른 곡 · 악보 · 페이지 선택", systemImage: "arrow.up.doc.on.clipboard").frame(minHeight: 44) }
                        .accessibilityIdentifier("inspectorOtherDestination")
                }
            } else {
                Text("개인 메모 복사").font(.headline)
                Text("악보에서 옮길 메모만 선택한 뒤 새 버전에 직접 배치하세요.").font(.subheadline).foregroundStyle(.secondary)
            }
            if stand.transferMode == .inactive {
                Button(action: select) { Label("악보에서 메모 선택", systemImage: "rectangle.dashed").frame(minHeight: 44) }
                    .accessibilityIdentifier("inspectorSelectNotes")
            }
        }.disabled(stand.busy)
    }
}
