import XCTest
import SwiftUI
import WorshipCueRemote
@testable import WorshipCue

@MainActor final class AccountDataExportTests: XCTestCase {
    private let owner = UUID(), team = UUID()
    private func page(_ rows: [String: [TeamJSON]] = [:]) -> TeamJSON {
        var fields = Dictionary(uniqueKeysWithValues: AccountDataExport.tables.map { ($0, TeamJSON.array(rows[$0] ?? [])) })
        fields["schema_version"] = .int(1); fields["owner_user_id"] = .id(owner)
        fields["team_id"] = .id(team); fields["export_scope"] = .string("current_authorized_team"); fields["next_cursor"] = .null
        return .object(fields)
    }
    private func replacing(_ value: TeamJSON, _ key: String, _ replacement: TeamJSON) -> TeamJSON {
        guard case .object(var fields) = value else { return .null }; fields[key] = replacement; return .object(fields)
    }
    func testExportAcceptsOnlyOwnCurrentTeamPersonalRecordsAndVerifiedFileReferences() throws {
        let value = page([
            "memberships": [.object(["team_id": .id(team), "user_id": .id(owner)])],
            "annotation_layers": [.object(["team_id": .id(team), "owner_user_id": .id(owner), "scope": .string("personal")])],
            "annotation_heads": [.object(["team_id": .id(team), "owner_user_id": .id(owner), "scope": .string("personal")])],
            "assets": [.object(["team_id": .id(team), "owner_user_id": .id(owner), "type": .string("native"), "verified": .bool(true)])],
            "chat_messages": [.object(["team_id": .id(team), "author_id": .id(owner), "body": .string("Synthetic personal message")])]])
        XCTAssertEqual(try AccountDataExport.validatePage(value, owner: owner, team: team), 5)
    }
    func testExportRejectsForeignOwnerScopeSharedInkAndUnverifiedOrPdfFiles() {
        let own = TeamJSON.object(["team_id": .id(team), "owner_user_id": .id(owner), "type": .string("native"), "verified": .bool(true)])
        let bad = [page(["assets": [replacing(own, "owner_user_id", .id(UUID()))]]),
                   page(["assets": [replacing(own, "team_id", .id(UUID()))]]),
                   page(["assets": [replacing(own, "verified", .bool(false))]]),
                   page(["assets": [replacing(own, "type", .string("pdf"))]]),
                   page(["annotation_revisions": [.object(["team_id": .id(team), "owner_user_id": .id(owner), "scope": .string("team")])]]),
                   replacing(page(), "owner_user_id", .id(UUID())), replacing(page(), "team_id", .id(UUID())),
                   replacing(page(), "export_scope", .string("entire_church"))]
        for value in bad { XCTAssertThrowsError(try AccountDataExport.validatePage(value, owner: owner, team: team)) }
    }
    func testExportRejectsPartialShapesSecretsAndUnboundedPage() {
        let bad = [replacing(page(), "assets", .null), replacing(page(), "access_token", .string("synthetic-secret")),
            page(["memberships": [.object(["team_id": .id(team), "user_id": .id(owner), "token": .string("synthetic")])]]),
            page(["chat_preferences": Array(repeating: .object(["team_id": .id(team), "user_id": .id(owner)]), count: 101)])]
        for value in bad { XCTAssertThrowsError(try AccountDataExport.validatePage(value, owner: owner, team: team)) }
    }
    func testExportOpaqueCursorIsExactTeamTypedAndDoesNotExposeRawResourceKeys() throws {
        let key = UUID(), scope = String(repeating: "a", count: 64)
        let value = TeamJSON.object(["schema_version": .int(1), "team_id": .id(team), "table": .string("assets"), "after_key": .id(key), "scope_token": .string(scope)])
        let valid = try AccountDataExport.validateCursor(value, team: team)
        XCTAssertEqual(valid.0, key); XCTAssertEqual(valid.1, scope)
        for bad in [replacing(value, "team_id", .id(UUID())), replacing(value, "table", .string("invitations")),
                    replacing(value, "after_key", .string("private-user/path")), replacing(value, "scope_token", .string("bad")),
                    replacing(value, "raw_key", .string("private-key"))] {
            XCTAssertThrowsError(try AccountDataExport.validateCursor(bad, team: team))
        }
    }
    func testPreflightRequiresExactAccountBoundedTeamsAndHonestDeletionCapability() throws {
        let row = TeamJSON.object(["team_id": .id(team), "church_id": .id(UUID()), "display_name": .string("Synthetic team"),
            "role": .string("admin"), "revision": .int(1), "sole_admin": .bool(true), "handoff_required": .bool(true)])
        let valid = TeamJSON.object(["schema_version": .int(1), "owner_user_id": .id(owner), "generated_at": .string("2026-10-08T12:00:00Z"),
            "delete_supported": .bool(false), "teams": .array([row]), "unavailable_team_count": .int(1)])
        XCTAssertNoThrow(try AccountDataExport.validatePreflight(valid, owner: owner))
        for bad in [replacing(valid, "owner_user_id", .id(UUID())), replacing(valid, "delete_supported", .bool(true)),
                    replacing(valid, "teams", .array([row, row])), replacing(valid, "teams", .array(Array(repeating: row, count: 201))),
                    replacing(valid, "unavailable_team_count", .number(-1))] {
            XCTAssertThrowsError(try AccountDataExport.validatePreflight(bad, owner: owner))
        }
    }
    func testCompletePagedExportWritesProtectedOwnMetadataAndProducesShareableURL() async throws {
        let (workspace, fixture, _, _, _) = try await makeAdministrationWorkspace(for: self)
        let model = AccountDataExport(team: workspace)
        await model.exportSelectedTeam()
        XCTAssertNil(model.error)
        let url = try XCTUnwrap(model.exportedURL), data = try Data(contentsOf: url), saved = try JSONDecoder().decode(TeamJSON.self, from: data)
        XCTAssertEqual(url.pathExtension, "json"); XCTAssertEqual(saved["owner_user_id"].uuid, AdministrationFixture.user)
        XCTAssertEqual(saved["team_id"].uuid, AdministrationFixture.teamA); XCTAssertEqual(saved["includes_file_bytes"], .bool(false))
        XCTAssertEqual(saved["memberships"].list.count, 1); XCTAssertEqual(saved["chat_messages"].list.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        let requests = fixture.recorded("get_account_export_page"); XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["cursor"], .null); XCTAssertEqual(requests[1]["cursor"]["after_key"].uuid, AdministrationFixture.invite)
        XCTAssertEqual(fixture.mutationCount, 0); XCTAssertNil(workspace.reader)
    }
    func testLaterExportPageDenialNeverPublishesPartialFileOrStaleShareURL() async throws {
        let (workspace, fixture, _, _, _) = try await makeAdministrationWorkspace(for: self)
        fixture.denyLaterExportPage(true)
        let model = AccountDataExport(team: workspace); await model.exportSelectedTeam()
        XCTAssertNotNil(model.error); XCTAssertNil(model.exportedURL); XCTAssertNil(model.preflight)
        let folder = try workspace.operationDirectory().appendingPathComponent("personal-data-exports")
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path), "Incomplete export must never create a partial file")
        XCTAssertEqual(fixture.recorded("get_account_export_page").count, 2); XCTAssertEqual(fixture.mutationCount, 0)
    }
    func testAccountOrTeamChangeWhileExportIsPausedCannotExposePriorAccountURL() async throws {
        for logout in [false, true] {
            let (workspace, fixture, _, _, _) = try await makeAdministrationWorkspace(for: self)
            let model = AccountDataExport(team: workspace)
            fixture.pauseNext("get_account_export_page")
            let exporting = Task { await model.exportSelectedTeam() }
            let deadline = ContinuousClock().now.advanced(by: .seconds(5))
            while !fixture.isPaused, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(fixture.isPaused)
            if logout { let loggedOut = await workspace.logout(); XCTAssertTrue(loggedOut) }
            else {
                let other = try XCTUnwrap(workspace.memberships.first { $0["team_id"].uuid == AdministrationFixture.teamB })
                await workspace.chooseWorkspace(other); XCTAssertEqual(workspace.selectedTeam, AdministrationFixture.teamB)
            }
            fixture.release(); await exporting.value
            XCTAssertNil(model.exportedURL); XCTAssertNil(model.preflight); XCTAssertEqual(fixture.mutationCount, 0)
        }
    }
    func testExportFinalReferencesRequireMatchingPersonalLayersAndNativePreviewHashes() throws {
        let layer = UUID(), native = UUID(), preview = UUID(), hash = String(repeating: "a", count: 64)
        let nativeAsset = TeamJSON.object(["id": .id(native), "type": .string("native"), "sha256": .string(hash), "bytes": .int(20), "storage_key": .string("synthetic/native")])
        let previewAsset = TeamJSON.object(["id": .id(preview), "type": .string("preview"), "sha256": .string(hash), "bytes": .int(20), "storage_key": .string("synthetic/preview")])
        let head = TeamJSON.object(["layer_id": .id(layer), "native_asset_id": .id(native), "preview_asset_id": .id(preview),
            "native_sha256": .string(hash), "preview_sha256": .string(hash), "native_bytes": .int(20), "preview_bytes": .int(20),
            "native_storage_key": .string("synthetic/native"), "preview_storage_key": .string("synthetic/preview")])
        let records: [String: [TeamJSON]] = ["annotation_layers": [.object(["id": .id(layer)])], "assets": [nativeAsset, previewAsset], "annotation_heads": [head]]
        XCTAssertNoThrow(try AccountDataExport.validateReferences(records))
        for bad in [replacing(head, "layer_id", .id(UUID())), replacing(head, "native_sha256", .string(String(repeating: "b", count: 64))),
                    replacing(head, "preview_asset_id", .id(native)), replacing(head, "native_bytes", .int(21))] {
            var corrupt = records; corrupt["annotation_heads"] = [bad]
            XCTAssertThrowsError(try AccountDataExport.validateReferences(corrupt))
        }
    }
    func testRenderedAccountExportPreflightShowsCapabilityWithoutWritingOrNavigating() async throws {
        let (workspace, fixture, _, _, _) = try await makeAdministrationWorkspace(for: self)
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene), host = UIHostingController(rootView: AccountDataExportView(team: workspace))
        window.frame = scene.coordinateSpace.bounds; window.rootViewController = host; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKeyAndVisible() }
        let deadline = ContinuousClock().now.advanced(by: .seconds(8))
        while fixture.recorded("get_account_preflight").isEmpty, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200)); host.view.layoutIfNeeded()
        XCTAssertFalse(fixture.recorded("get_account_preflight").isEmpty); XCTAssertTrue(fixture.recorded("get_account_export_page").isEmpty)
        XCTAssertEqual(fixture.mutationCount, 0); XCTAssertNil(workspace.reader)
        var rendered = false
        let picture = UIGraphicsImageRenderer(size: host.view.bounds.size).image { _ in rendered = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
        XCTAssertTrue(rendered); let attachment = XCTAttachment(image: picture)
        attachment.name = "Build7 personal export preflight rendered on iPad"; attachment.lifetime = .keepAlways; add(attachment)
    }

}
