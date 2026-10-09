import XCTest
import SwiftUI
import WorshipCueRemote
import CryptoKit
import PencilKit
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
    private func zipFiles(_ url: URL) throws -> [String: Data] {
        let data = try Data(contentsOf: url)
        func number(_ index: Int, _ count: Int) throws -> Int {
            guard index >= 0, index + count <= data.count else { throw RemoteError.invalidResponse }
            return (0..<count).reduce(0) { $0 | Int(data[index + $1]) << (8 * $1) }
        }
        var position = 0, files: [String: Data] = [:]
        while try number(position, 4) == 0x0403_4b50 {
            guard try number(position + 6, 2) == 0, try number(position + 8, 2) == 0 else { throw RemoteError.invalidResponse }
            let size = try number(position + 18, 4), nameLength = try number(position + 26, 2), extra = try number(position + 28, 2)
            let start = position + 30 + nameLength + extra
            guard start + size <= data.count, let name = String(data: data.subdata(in: position + 30..<position + 30 + nameLength), encoding: .utf8), files[name] == nil else { throw RemoteError.invalidResponse }
            let bytes = data.subdata(in: start..<start + size)
            XCTAssertEqual(Int(AccountExportArchiveWriter.crc32(bytes)), try number(position + 14, 4))
            files[name] = bytes; position = start + size
        }
        XCTAssertEqual(try number(position, 4), 0x0201_4b50)
        XCTAssertEqual(try number(data.count - 22, 4), 0x0605_4b50)
        XCTAssertEqual(try number(data.count - 12, 2), files.count)
        XCTAssertEqual(try number(data.count - 6, 4), position)
        return files
    }
    private func bundleFixture() -> (records: [String: [TeamJSON]], version: TeamJSON, bytes: [UUID: Data]) {
        let layer = UUID(), native = UUID(), preview = UUID(), pdf = UUID(), chart = UUID()
        let geometry = TeamJSON.object(["schema_version": .int(1), "crop_x": .int(0), "crop_y": .int(0), "crop_width": .int(612), "crop_height": .int(792), "rotation": .int(0)])
        let pdfBytes = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { context in
            context.beginPage(); ("Synthetic owned-note paper" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [:])
        }
        let previewBytes = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { _ in UIColor.blue.setFill(); UIBezierPath(rect: CGRect(x: 2, y: 2, width: 4, height: 4)).fill() }.pngData()!
        let bytes = [native: PKDrawing().dataRepresentation(), preview: previewBytes, pdf: pdfBytes]
        func asset(_ id: UUID, _ type: String, _ uploader: UUID? = nil) -> TeamJSON {
            let data = bytes[id]!
            return .object(["id": .id(id), "type": .string(type), "owner_user_id": .id(uploader ?? owner), "team_id": .id(team),
                "verified": .bool(true), "sha256": .string(SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()),
                "bytes": .int(Int64(data.count)), "storage_key": .string("synthetic/" + id.uuidString.lowercased())])
        }
        let nativeAsset = asset(native, "native"), previewAsset = asset(preview, "preview"), pdfAsset = asset(pdf, "pdf", UUID())
        let ownLayer = TeamJSON.object(["id": .id(layer), "owner_user_id": .id(owner), "team_id": .id(team), "scope": .string("personal"), "chart_version_id": .id(chart), "page_index": .int(0)])
        let head = TeamJSON.object(["id": .id(UUID()), "layer_id": .id(layer), "owner_user_id": .id(owner), "team_id": .id(team), "scope": .string("personal"),
            "geometry": geometry, "native_asset_id": .id(native), "preview_asset_id": .id(preview),
            "native_sha256": nativeAsset["sha256"], "preview_sha256": previewAsset["sha256"], "native_bytes": nativeAsset["bytes"], "preview_bytes": previewAsset["bytes"],
            "native_storage_key": nativeAsset["storage_key"], "preview_storage_key": previewAsset["storage_key"]])
        let version = TeamJSON.object(["id": .id(chart), "team_id": .id(team), "pdf_asset_id": .id(pdf), "pdf_sha256": pdfAsset["sha256"],
            "pdf_bytes": pdfAsset["bytes"], "page_count": .int(1), "page_manifest": .array([geometry]), "pdf_asset": pdfAsset])
        return (["assets": [nativeAsset, previewAsset], "annotation_layers": [ownLayer], "annotation_heads": [head], "annotation_revisions": [head]], version, bytes)
    }
    private func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AccountExportTests-" + UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
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
            page(["memberships": [.object(["team_id": .id(team), "user_id": .id(owner), "metadata": .object(["refresh_token": .string("synthetic")])])]]),
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
        let url = try XCTUnwrap(model.exportedURL), files = try zipFiles(url)
        let saved = try JSONDecoder().decode(TeamJSON.self, from: XCTUnwrap(files["manifest.json"]))
        XCTAssertEqual(url.pathExtension, "zip"); XCTAssertEqual(saved["owner_user_id"].uuid, AdministrationFixture.user)
        XCTAssertEqual(saved["team_id"].uuid, AdministrationFixture.teamA); XCTAssertEqual(saved["includes_file_bytes"], .bool(true))
        XCTAssertEqual(saved["includes_local_unsynced_notes"], .bool(false)); XCTAssertEqual(saved["export_scope"].text, "current_authorized_team_cloud_personal_bundle")
        XCTAssertNotNil(files["README.txt"])
        XCTAssertEqual(saved["memberships"].list.count, 1); XCTAssertEqual(saved["chat_messages"].list.count, 1)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        let requests = fixture.recorded("get_account_export_page"); XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests[0]["cursor"], .null); XCTAssertEqual(requests[1]["cursor"]["after_key"].uuid, AdministrationFixture.invite)
        XCTAssertEqual(fixture.mutationCount, 0); XCTAssertNil(workspace.reader)
        model.reset(); XCTAssertNil(model.exportedURL); XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().path))
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
    func testFileInclusiveBundleContainsExactOwnNativePreviewAndAuthorizedOriginalPDF() async throws {
        let fixture = bundleFixture(), directory = try scratch()
        var fetched: [UUID] = [], resolved: [UUID] = []
        let url = try await AccountDataExport.writeBundle(records: fixture.records, owner: owner, team: team,
            unavailableTeams: .int(1), directory: directory, chart: { id in resolved.append(id); return fixture.version },
            asset: { value in let id = try value.requiredID("id"); fetched.append(id); return try XCTUnwrap(fixture.bytes[id]) }, checkContext: {})
        let files = try zipFiles(url), manifest = try JSONDecoder().decode(TeamJSON.self, from: XCTUnwrap(files["manifest.json"]))
        XCTAssertEqual(fetched.count, 3); XCTAssertEqual(resolved.count, 1); XCTAssertEqual(manifest["source_charts"].list.count, 1)
        XCTAssertEqual(manifest["files"].list.count, 3); XCTAssertEqual(manifest["unavailable_team_count"].integer, 1)
        for receipt in manifest["files"].list {
            let id = try receipt.requiredID("asset_id"), path = try receipt.requiredText("path")
            XCTAssertEqual(files[path], fixture.bytes[id]); XCTAssertEqual(files[path]?.count, receipt["bytes"].integer.map(Int.init))
        }
        XCTAssertEqual(manifest["source_charts"].list.first?["pdf_path"].text, manifest["files"].list.first { $0["type"].text == "pdf" }?["path"].text)
        XCTAssertTrue(manifest["exclusions"].list.contains(.string("local_unsynced_notes")))
        XCTAssertTrue(manifest["exclusions"].list.contains(.string("team_ink")))
        XCTAssertEqual(files.count, 5); XCTAssertFalse(FileManager.default.fileExists(atPath: url.deletingLastPathComponent().appendingPathComponent(".archive.partial").path))
    }
    func testCorruptInkOrPDFBytesNeverProducePartialShareableBundle() async throws {
        let fixture = bundleFixture()
        for corruptType in ["native", "preview", "pdf"] {
            let directory = try scratch()
            do {
                _ = try await AccountDataExport.writeBundle(records: fixture.records, owner: owner, team: team,
                    unavailableTeams: .int(0), directory: directory, chart: { _ in fixture.version },
                    asset: { value in
                        var bytes = try XCTUnwrap(fixture.bytes[value.requiredID("id")])
                        if value["type"].text == corruptType { bytes[0] ^= 1 }
                        return bytes
                    }, checkContext: {})
                XCTFail("Corrupt file must fail the entire archive")
            } catch { XCTAssertTrue(error is VaultError) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testBundleRejectsForeignPersonalRecordsAndSharedInkBeforeDownloadingAnyFile() async throws {
        let fixture = bundleFixture()
        for shared in [false, true] {
            var records = fixture.records
            let row = records["annotation_layers"]![0]
            records["annotation_layers"] = [replacing(row, shared ? "scope" : "owner_user_id", shared ? .string("team") : .id(UUID()))]
            let directory = try scratch(); var downloaded = false
            do {
                _ = try await AccountDataExport.writeBundle(records: records, owner: owner, team: team,
                    unavailableTeams: .int(0), directory: directory, chart: { _ in fixture.version },
                    asset: { _ in downloaded = true; return Data() }, checkContext: {})
                XCTFail("Foreign personal records or shared ink must never enter a personal bundle")
            } catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
            XCTAssertFalse(downloaded); XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testSourcePaperDenialAndWrongVersionGeometryRemoveAlreadyWrittenInk() async throws {
        let fixture = bundleFixture()
        for denied in [true, false] {
            let directory = try scratch()
            do {
                _ = try await AccountDataExport.writeBundle(records: fixture.records, owner: owner, team: team,
                    unavailableTeams: .int(0), directory: directory,
                    chart: { _ in if denied { throw RemoteError.forbidden }; return self.replacing(fixture.version, "page_manifest", .array([.null])) },
                    asset: { try XCTUnwrap(fixture.bytes[$0.requiredID("id")]) }, checkContext: {})
                XCTFail("Denied or mismatched original PDF cannot be omitted silently")
            } catch { XCTAssertEqual(error as? RemoteError, denied ? .forbidden : .invalidResponse) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testFileDownloadScopeChangeAndCancellationDiscardPrivatePartialArchive() async throws {
        let fixture = bundleFixture()
        for cancellation in [false, true] {
            let directory = try scratch()
            var current = true, waitingForPDF = false
            let exporting = Task {
                try await AccountDataExport.writeBundle(records: fixture.records, owner: owner, team: team,
                    unavailableTeams: .int(0), directory: directory, chart: { _ in fixture.version },
                    asset: { value in
                        if value["type"].text == "pdf" {
                            waitingForPDF = true
                            if cancellation { try await Task.sleep(for: .seconds(30)) } else { current = false }
                        }
                        return try XCTUnwrap(fixture.bytes[value.requiredID("id")])
                    }, checkContext: { if !current { throw RemoteError.authentication } })
            }
            if cancellation {
                let deadline = ContinuousClock().now.advanced(by: .seconds(5))
                while !waitingForPDF, ContinuousClock().now < deadline { try await Task.sleep(for: .milliseconds(10)) }
                XCTAssertTrue(waitingForPDF); exporting.cancel()
            }
            do { _ = try await exporting.value; XCTFail("Cancelled or stale export cannot complete") }
            catch { if cancellation { XCTAssertTrue(error is CancellationError) } else { XCTAssertEqual(error as? RemoteError, .authentication) } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        }
    }
    func testZIPCRCStandardAndTraversalDuplicateAndSizeGuards() async throws {
        XCTAssertEqual(AccountExportArchiveWriter.crc32(Data("123456789".utf8)), 0xcbf4_3926)
        let directory = try scratch(); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("archive.partial"), writer = try AccountExportArchiveWriter(url: file, maximumBytes: 160)
        for name in ["../ink", "/private", "a/../b", "a//b", "a\\b"] {
            do { try await writer.append(name: name, data: Data()); XCTFail("Archive name must remain relative and safe") }
            catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
        }
        try await writer.append(name: "test.txt", data: Data("123456789".utf8))
        do { try await writer.append(name: "test.txt", data: Data()); XCTFail("Duplicate ZIP entries are ambiguous") }
        catch { XCTAssertEqual(error as? RemoteError, .invalidResponse) }
        try await writer.finish(); XCTAssertEqual(try zipFiles(file)["test.txt"], Data("123456789".utf8))
        let small = try AccountExportArchiveWriter(url: directory.appendingPathComponent("small.partial"), maximumBytes: 20)
        do { try await small.append(name: "test.txt", data: Data()); XCTFail("Capacity failure must be explicit") }
        catch { XCTAssertEqual(error as? RemoteError, .tooLarge) }
        await small.abort()
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
        attachment.name = "Build8 personal cloud ZIP preflight rendered on iPad"; attachment.lifetime = .keepAlways; add(attachment)
    }

}
