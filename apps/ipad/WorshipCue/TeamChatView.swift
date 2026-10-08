import SwiftUI

struct TeamChatView: View {
    @ObservedObject var team: TeamWorkspace
    @Environment(\.dismiss) private var dismiss
    @State private var room: UUID?
    @State private var replying: TeamRow?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("대화방", selection: $room) {
                    Text("팀 대화").tag(nil as UUID?)
                    ForEach(team.setlists) { Text($0.value["title"].text ?? "").tag(Optional($0.id)) }
                }.pickerStyle(.menu).padding().accessibilityLabel("팀 또는 예배 대화방 선택")
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if let error = team.chatError { Label(error, systemImage: "wifi.exclamationmark").font(.subheadline).foregroundStyle(.orange) }
                        if team.chatMessages.isEmpty { Text("함께 준비할 내용을 나눠 주세요.").foregroundStyle(.secondary).padding(.vertical) }
                        ForEach(team.chatMessages) { message in
                            VStack(alignment: .leading, spacing: 6) {
                                HStack {
                                    Text(team.chatAuthorName(message.value["author_id"].uuid)).font(.caption.bold())
                                    Spacer()
                                    if let date = message.value["created_at"].text.flatMap(TeamWorkspace.parseDate) { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                                }
                                if message.value["reply_to_id"].uuid != nil { Label("이전 메시지에 답장", systemImage: "arrowshape.turn.up.left").font(.caption).foregroundStyle(.secondary) }
                                Text(message.value["deleted"].flag ? String(localized: "삭제된 메시지") : message.value["body"].text ?? "")
                                    .textSelection(.enabled)
                                if !message.value["deleted"].flag {
                                    Button("답장") { replying = message }.font(.caption).frame(minHeight: 44).accessibilityLabel("이 메시지에 답장")
                                }
                            }.padding().background(message.value["author_id"].uuid == team.session?.userID ? Color.blue.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14))
                        }
                        ForEach(team.chatDrafts) { draft in
                            VStack(alignment: .leading, spacing: 8) {
                                Label("전송 확인 대기 · 기기에 저장됨", systemImage: "clock")
                                Text(draft.body)
                                HStack {
                                    Button("다시 전송") { Task { _ = await team.retryChat(draft) } }.frame(minHeight: 44)
                                    Spacer()
                                    Button("초안 삭제", role: .destructive) { team.discardChatDraft(draft) }.frame(minHeight: 44)
                                }.disabled(team.chatSending)
                            }.padding().background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                        }
                    }.padding()
                }
                Divider()
                VStack(spacing: 8) {
                    if let replying {
                        HStack {
                            Label(String(localized: "답장: ") + String((replying.value["body"].text ?? "").prefix(80)), systemImage: "arrowshape.turn.up.left").font(.caption).lineLimit(2)
                            Spacer(); Button("취소") { self.replying = nil }.frame(minHeight: 44)
                        }
                    }
                    HStack(alignment: .bottom) {
                        TextField("메시지 · 기기에 초안 저장", text: Binding(get: { team.chatComposer }, set: team.updateChatComposer), axis: .vertical)
                            .lineLimit(1...5).textFieldStyle(.roundedBorder).accessibilityIdentifier("teamChatComposer")
                        Button { Task { if await team.sendChat(replyToID: replying?.id) { replying = nil } } } label: {
                            Image(systemName: "arrow.up.circle.fill").font(.system(size: 32)).frame(width: 48, height: 48)
                        }.disabled(team.chatSending || team.chatComposer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("메시지 전송").accessibilityIdentifier("sendTeamChat")
                    }
                    Text("연결이 끊겨도 초안은 저장됩니다. 다시 연결되어도 자동 전송하지 않습니다.").font(.caption).foregroundStyle(.secondary)
                }.padding()
            }.navigationTitle("팀 대화")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() }.frame(minHeight: 44) }
                    ToolbarItem(placement: .primaryAction) { Button { Task { await team.refreshChat() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("대화 새로 확인") }
                }
                .task { await team.openChat() }
                .onChange(of: room) { value in replying = nil; Task { await team.openChat(setlistID: value) } }
                .onChange(of: team.scopeID) { _ in dismiss() }
                .onDisappear { team.closeChat() }
        }.preferredColorScheme(.light)
    }
}
