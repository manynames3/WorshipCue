import SwiftUI
import PDFKit

struct TeamChatView: View {
    @ObservedObject var team: TeamWorkspace
    var opened: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var room: UUID?
    @State private var editor: ChatEditorRequest?
    @State private var preview: ChatChartRequest?
    @State private var management = false
    @State private var reports = false
    @State private var chartPicker = false
    @State private var messageFrames: [UUID: CGRect] = [:]
    @State private var viewportSize = CGSize.zero
    @State private var automaticReadAttempt: String?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                roomHeader
                Divider()
                ScrollViewReader { scroll in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 16) {
                            if let error = team.chatError { Label(error, systemImage: "exclamationmark.bubble").font(.subheadline).foregroundStyle(.orange) }
                            if team.chatMessages.isEmpty {
                                Text("함께 준비할 내용을 나눠 주세요.").foregroundStyle(.secondary).padding(.vertical)

                            }
                            let pins = team.chatMessages.filter { $0.value["pinned"].flag && team.canUseChatMessage($0) }
                            if !pins.isEmpty {
                                VStack(alignment: .leading) {
                                    Label("고정된 메시지", systemImage: "pin.fill").font(.caption.bold())
                                    ForEach(pins) { message in
                                        Button { withAnimation { scroll.scrollTo(message.id, anchor: .center) } } label: {
                                            Text(team.chatMessageText(message)).lineLimit(2).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                        }
                                    }
                                }.padding().background(Color.blue.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                            }
                            ForEach(team.chatMessages) { message in
                                messageCard(message, scroll: scroll).id(message.id)
                                    .background(GeometryReader { geometry in
                                        Color.clear.preference(key: ChatMessageFrames.self, value: [message.id: geometry.frame(in: .named("chatViewport"))])
                                    })
                            }
                            if team.chatHasMore { Button("대화 더 불러오기") { Task { await team.refreshChat() } }.frame(minHeight: 44) }
                            ForEach(team.chatDrafts) { draft in draftCard(draft) }
                            ForEach(team.chatActions) { action in actionCard(action) }
                        }.padding()
                    }.coordinateSpace(name: "chatViewport")
                        .background(GeometryReader { geometry in Color.clear.preference(key: ChatViewportSize.self, value: geometry.size) })
                        .onPreferenceChange(ChatMessageFrames.self) { messageFrames = $0; markVisibleMessages() }
                        .onPreferenceChange(ChatViewportSize.self) { viewportSize = $0; markVisibleMessages() }
                        .onChange(of: team.chatSnapshotRevision) { _ in markVisibleMessages() }
                        .onChange(of: team.chatReadRevision) { _ in markVisibleMessages() }
                }
                Divider()
                composer
            }.navigationTitle("팀 대화")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("대화 새로 확인", systemImage: "arrow.clockwise") { Task { await team.refreshChat() } }
                            Button(team.chatMuted ? "대화방 알림 켜기" : "대화방 알림 끄기", systemImage: team.chatMuted ? "bell" : "bell.slash") { Task { _ = await team.muteChat() } }
                            Button("차단한 팀원 관리", systemImage: "person.crop.circle.badge.xmark") { management = true }
                            if team.canLead { Button("신고 검토", systemImage: "flag") { reports = true } }
                        } label: { Image(systemName: "ellipsis.circle").frame(width: 44, height: 44) }
                            .accessibilityLabel("대화방 옵션").disabled(team.chatSending)
                    }
                }
                .task { await team.openChat() }
                .onChange(of: room) { value in messageFrames = [:]; Task { await team.openChat(setlistID: value) } }
                .onChange(of: team.scopeID) { _ in dismiss() }
                .onDisappear { team.closeChat() }
                .sheet(item: $editor) { request in ChatEditorSheet(team: team, request: request) }
                .sheet(item: $preview) { request in ChatChartPreviewSheet(team: team, request: request) { opened(); dismiss() } }
                .sheet(isPresented: $management) { ChatBlockedMembersSheet(team: team) }
                .sheet(isPresented: $reports) { ChatReportsSheet(team: team) { room = $0 } }
                .sheet(isPresented: $chartPicker) { ChatChartPicker(team: team) }
        }.preferredColorScheme(.light)
    }
    private var latestMessageIsVisible: Bool {
        guard let last = team.chatMessages.last?.id, let frame = messageFrames[last], viewportSize.height > 0 else { return false }
        // Lazy stacks can prepare rows below the screen. Reading requires the end of the last card in the viewport.
        return frame.maxY > 0 && frame.maxY <= viewportSize.height + 1 && frame.minY < viewportSize.height
    }
    private func markVisibleMessages(force: Bool = false) {
        guard latestMessageIsVisible, team.chatSnapshotRevision > team.chatReadRevision else { return }
        let last = team.chatMessages.last?.id, revision = team.chatSnapshotRevision
        let attempt = team.chatRoomScopeID.uuidString + "/" + (last?.uuidString ?? "empty") + "/" + String(revision)
        guard force || automaticReadAttempt != attempt else { return }
        automaticReadAttempt = attempt
        Task {
            let started = await team.markChatDisplayed(lastMessageID: last, revision: revision)
            if !started, automaticReadAttempt == attempt { automaticReadAttempt = nil }
        }
    }
    private var roomHeader: some View {
        HStack {
            Picker("대화방", selection: $room) {
                Text(roomTitle(nil, title: String(localized: "팀 대화"))).tag(nil as UUID?)
                ForEach(team.setlists) { Text(roomTitle($0.id, title: $0.value["title"].text ?? "")).tag(Optional($0.id)) }
            }.pickerStyle(.menu).accessibilityLabel("팀 또는 예배 대화방 선택")
            Spacer()
            if latestMessageIsVisible, team.chatSnapshotRevision > team.chatReadRevision, !team.chatHasMore {
                Button("읽음 표시") { markVisibleMessages(force: true) }.font(.caption).frame(minHeight: 44).accessibilityLabel("화면에 보이는 대화까지 읽음 표시")
            }
            if team.chatMuted { Image(systemName: "bell.slash").foregroundStyle(.secondary).accessibilityLabel("이 대화방 알림 꺼짐") }
            if team.chatRoomsHaveMore { Button("대화방 더 확인") { Task { await team.refreshChatRooms(more: true) } }.font(.caption).frame(minHeight: 44) }
        }.padding(.horizontal)
    }
    private func roomTitle(_ id: UUID?, title: String) -> String {
        title + (team.chatUnreadLabel(id).map { " · " + $0 } ?? "")
    }
    private func messageCard(_ message: TeamRow, scroll: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(team.chatAuthorName(message.value["author_id"].uuid)).font(.caption.bold())
                if message.value["pinned"].flag { Image(systemName: "pin.fill").font(.caption).accessibilityLabel("고정된 메시지") }
                Spacer()
                if let date = message.value["created_at"].text.flatMap(TeamWorkspace.parseDate) { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                if message.value["edited_at"].text != nil { Text("수정됨").font(.caption).foregroundStyle(.secondary) }
            }
            if let replyID = message.value["reply_to_id"].uuid {
                Button {
                    if team.chatMessages.contains(where: { $0.id == replyID }) { withAnimation { scroll.scrollTo(replyID, anchor: .center) } }
                    else { Task { await team.refreshChat() } }
                } label: {
                    Label(replyQuote(replyID), systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(3).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityLabel("답장 원문 확인")
            }
            Text(team.chatMessageText(message)).textSelection(.enabled)
            if team.canUseChatMessage(message), let chart = message.value["chart_version_id"].uuid {
                Button { preview = ChatChartRequest(id: chart) } label: {
                    Label(team.chatChartTitle(chart), systemImage: "doc.richtext").frame(minHeight: 44)
                }.accessibilityLabel("공유한 악보 미리보기")
            }
        }.padding().frame(maxWidth: .infinity, alignment: .leading)
            .background(message.value["author_id"].uuid == team.session?.userID ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
            .contextMenu { messageActions(message) }
            .accessibilityActions { messageActions(message) }
    }
    @ViewBuilder private func messageActions(_ message: TeamRow) -> some View {
        if team.canUseChatMessage(message) {
            Button("답장", systemImage: "arrowshape.turn.up.left") { team.setChatReply(message.id) }
            if team.canEditChat(message) {
                Button("수정", systemImage: "pencil") { editor = ChatEditorRequest(message: message, reporting: false) }
            }
            if team.canDeleteChat(message) { Button("삭제", systemImage: "trash", role: .destructive) { Task { _ = await team.deleteChat(message) } } }
            if team.canLead { Button(message.value["pinned"].flag ? "고정 해제" : "고정", systemImage: "pin") { Task { _ = await team.pinChat(message) } } }
            if message.value["author_id"].uuid != team.session?.userID {
                Button("신고", systemImage: "flag") { editor = ChatEditorRequest(message: message, reporting: true) }
                if let author = message.value["author_id"].uuid { Button("팀원 차단", systemImage: "person.crop.circle.badge.xmark", role: .destructive) { Task { _ = await team.blockChatMember(author, blocked: true) } } }
            }
        } else if let author = message.value["author_id"].uuid, team.chatBlockedAuthors.contains(author) {
            Button("팀원 차단 해제", systemImage: "person.crop.circle.badge.checkmark") { Task { _ = await team.blockChatMember(author, blocked: false) } }
        }
    }
    private func replyQuote(_ id: UUID) -> String {
        guard let original = team.chatMessages.first(where: { $0.id == id }) else { return String(localized: "이전 메시지 불러오기") }
        return team.chatAuthorName(original.value["author_id"].uuid) + ": " + String(team.chatMessageText(original).prefix(100))
    }
    private func draftCard(_ draft: TeamChatDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("전송 확인 대기 · 기기에 저장됨", systemImage: "clock")
            if let reply = draft.replyToID { Text(replyQuote(reply)).font(.caption).foregroundStyle(.secondary) }
            if let chart = draft.chartVersionID { Label(team.chatChartTitle(chart), systemImage: "doc.richtext").font(.caption) }
            Text(draft.body)
            HStack {
                Button("다시 전송") { Task { _ = await team.retryChat(draft) } }.frame(minHeight: 44)
                Spacer()
                Button("초안 삭제", role: .destructive) { team.discardChatDraft(draft) }.frame(minHeight: 44)
            }.disabled(team.chatSending)
        }.padding().background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private func actionCard(_ action: TeamChatAction) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(action.label + " · " + String(localized: "확인 대기"), systemImage: "clock")
            if let text = action.payload["body"]?.text ?? action.payload["reason"]?.text { Text(text).font(.subheadline) }
            HStack {
                Button("요청 다시 시도") { Task { _ = await team.retryChatAction(action) } }.frame(minHeight: 44)
                Spacer()
                Button("저장된 요청 삭제", role: .destructive) { team.discardChatAction(action) }.frame(minHeight: 44)
            }.disabled(team.chatSending)
        }.padding().background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
    }
    private var composer: some View {
        VStack(spacing: 8) {
            if let reply = team.chatComposerReplyID {
                HStack {
                    Label(replyQuote(reply), systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(2)
                    Spacer(); Button("답장 취소") { team.setChatReply(nil) }.frame(minHeight: 44)
                }
            }
            if let chart = team.chatComposerChartID {
                HStack {
                    Label(team.chatChartTitle(chart), systemImage: "doc.richtext").font(.caption).lineLimit(2)
                    Spacer(); Button("링크 제거") { team.setChatChart(nil) }.frame(minHeight: 44)
                }
            }
            HStack(alignment: .bottom) {
                Button { chartPicker = true } label: { Image(systemName: "paperclip").frame(width: 44, height: 44) }.accessibilityLabel("팀 악보 링크 첨부")
                TextField("메시지 · 기기에 초안 저장", text: Binding(get: { team.chatComposer }, set: team.updateChatComposer), axis: .vertical)
                    .lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("teamChatComposer")
                Button { Task { _ = await team.sendChat() } } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).frame(width: 48, height: 48)
                }.disabled(team.chatSending || team.chatComposer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityLabel("메시지 전송").accessibilityIdentifier("sendTeamChat")
            }
            Text("연결이 끊겨도 초안은 저장됩니다. 다시 연결되어도 자동 전송하지 않습니다.").font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

private struct ChatEditorRequest: Identifiable {
    let id = UUID()
    let message: TeamRow
    let reporting: Bool
}
private struct ChatEditorSheet: View {
    @ObservedObject var team: TeamWorkspace
    let request: ChatEditorRequest
    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    init(team: TeamWorkspace, request: ChatEditorRequest) {
        self.team = team; self.request = request; _text = State(initialValue: request.reporting ? "" : request.message.value["body"].text ?? "")
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(request.reporting ? "신고 이유" : "메시지 수정") {
                    TextField(request.reporting ? "확인할 내용을 적어 주세요" : "메시지", text: $text, axis: .vertical).lineLimit(4...12)
                        .onChange(of: text) { text = String($0.prefix(request.reporting ? 1000 : 2000)) }
                    if let error = team.chatError { Text(error).foregroundStyle(.orange) }
                    Text("확인되지 않은 요청은 기기에 저장되며 직접 다시 시도할 수 있습니다.").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle(request.reporting ? "메시지 신고" : "메시지 수정")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(request.reporting ? "신고 보내기" : "저장") {
                            Task {
                                let result = request.reporting ? await team.reportChat(request.message, reason: text) : await team.editChat(request.message, body: text)
                                if result { dismiss() }
                            }
                        }.disabled(team.chatSending || text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).frame(minHeight: 44)
                    }
                }.onChange(of: team.chatRoomScopeID) { _ in dismiss() }.onChange(of: team.scopeID) { _ in dismiss() }
        }
    }
}
private struct ChatBlockedMembersSheet: View {
    @ObservedObject var team: TeamWorkspace
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("차단한 팀원의 메시지는 이 계정에서만 숨깁니다. 팀의 원본 메시지는 보관됩니다.").font(.subheadline).foregroundStyle(.secondary)
                if team.chatBlockedAuthors.isEmpty { Text("차단한 팀원이 없어요.") }
                ForEach(Array(team.chatBlockedAuthors).sorted { $0.uuidString < $1.uuidString }, id: \.self) { user in
                    HStack {
                        Text(team.chatAuthorName(user)); Spacer()
                        Button("차단 해제") { Task { _ = await team.blockChatMember(user, blocked: false) } }.frame(minHeight: 44).disabled(team.chatSending)
                    }
                }
                if let error = team.chatError { Text(error).foregroundStyle(.orange) }
            }.navigationTitle("차단한 팀원")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) } }
                .onChange(of: team.chatRoomScopeID) { _ in dismiss() }.onChange(of: team.scopeID) { _ in dismiss() }
        }
    }
}
private struct ChatReportsSheet: View {
    @ObservedObject var team: TeamWorkspace
    let selectRoom: (UUID?) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                if let error = team.chatError { Text(error).foregroundStyle(.orange) }
                if team.chatReports.isEmpty { Text("검토할 신고가 없어요.") }
                ForEach(team.chatReports) { report in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(report.value["reason"].text ?? "").font(.headline)
                        Text(team.chatAuthorName(report.value["reporter_id"].uuid)).font(.caption).foregroundStyle(.secondary)
                        if let text = team.chatReportMessageText(report) { Text(text).font(.subheadline).lineLimit(4) }
                        else if let original = team.chatMessages.first(where: { $0.id == report.value["message_id"].uuid }) { Text(team.chatMessageText(original)).font(.subheadline).lineLimit(4) }
                        else { Text("해당 대화방에서 원문을 확인해 주세요.").font(.caption).foregroundStyle(.secondary) }
                        Button("해당 대화방 열기") { selectRoom(report.value["setlist_id"].uuid); dismiss() }.frame(minHeight: 44)
                        Text("메시지 삭제는 해당 대화방에서 직접 선택합니다.").font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("처리 완료") { Task { _ = await team.resolveChatReport(report, dismissed: false) } }.frame(minHeight: 44)
                            Spacer()
                            Button("신고 기각") { Task { _ = await team.resolveChatReport(report, dismissed: true) } }.frame(minHeight: 44)
                        }.disabled(team.chatSending || !team.canLead)
                    }.padding(.vertical, 4)
                }
                if team.chatReportsHaveMore { Button("신고 더 불러오기") { Task { await team.refreshChatReports(more: true) } }.frame(minHeight: 44) }
            }.navigationTitle("신고 검토")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .primaryAction) { Button("새로 확인") { Task { await team.refreshChatReports() } }.frame(minHeight: 44) }
                }.task { await team.refreshChatReports() }
                .onChange(of: team.canLead) { if !$0 { dismiss() } }.onChange(of: team.chatRoomScopeID) { _ in dismiss() }.onChange(of: team.scopeID) { _ in dismiss() }
        }
    }
}
private struct ChatChartPicker: View {
    @ObservedObject var team: TeamWorkspace
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Text("팀에서 게시한 악보의 링크를 공유합니다. 받는 사람이 직접 미리보거나 열 수 있습니다.").font(.subheadline).foregroundStyle(.secondary)
                ForEach(team.chatLinkVersions) { chart in
                    Button(team.chatChartTitle(chart.id)) { team.setChatChart(chart.id); dismiss() }.frame(minHeight: 44)
                }
            }.navigationTitle("악보 링크 첨부")
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) } }
                .onChange(of: team.chatRoomScopeID) { _ in dismiss() }.onChange(of: team.scopeID) { _ in dismiss() }
        }
    }
}
private struct ChatChartRequest: Identifiable { let id: UUID }
private struct ChatChartPreviewSheet: View {
    @ObservedObject var team: TeamWorkspace
    let request: ChatChartRequest
    let opened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var document: PDFDocument?
    @State private var failure: String?
    @State private var opening = false
    var body: some View {
        NavigationStack {
            VStack {
                if let document { ChatPDFPreview(document: document) }
                else if let failure { Text(failure).padding(); Button("미리보기 다시 시도") { Task { await load() } }.frame(minHeight: 44) }
                else { ProgressView("악보 확인 중") }
            }.navigationTitle(team.chatChartTitle(request.id))
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("악보대에서 열기") {
                            opening = true
                            Task { if await team.openChatChart(request.id) { dismiss(); opened() }; opening = false }
                        }.disabled(document == nil || opening || team.busy).frame(minHeight: 44)
                    }
                }.task { await load() }
                .onChange(of: team.chatRoomScopeID) { _ in dismiss() }.onChange(of: team.scopeID) { _ in dismiss() }
        }
    }
    private func load() async {
        failure = nil
        do { document = try await team.previewChatChart(request.id) }
        catch { failure = String(localized: "이 악보를 확인하지 못했어요. 팀 권한과 연결을 다시 확인해 주세요.") }
    }
}
private struct ChatPDFPreview: UIViewRepresentable {
    let document: PDFDocument
    func makeUIView(context: Context) -> PDFView {
        let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous
        view.displayDirection = .vertical; view.backgroundColor = .secondarySystemBackground; view.document = document
        return view
    }
    func updateUIView(_ view: PDFView, context: Context) { if view.document !== document { view.document = document } }
}

private struct ChatMessageFrames: PreferenceKey {
    static var defaultValue: [UUID: CGRect] = [:]
    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) { value.merge(nextValue()) { _, new in new } }
}
private struct ChatViewportSize: PreferenceKey {
    static var defaultValue = CGSize.zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { let next = nextValue(); if next.width > 0, next.height > 0 { value = next } }
}
