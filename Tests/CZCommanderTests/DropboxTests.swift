import XCTest
@testable import CZCommanderCore

final class DropboxTests: XCTestCase {
    func testLocationRoundTripAndNavigation() {
        let cases: [DropboxLocation] = [
            .own("/"), .own("/Photos/2026"), .sharedWithMe,
            .namespace(id: "1234567", path: ""), .namespace(id: "1234567", path: "/Raw/Day 1"),
            .link(url: "https://www.dropbox.com/scl/fo/abc/xyz?rlkey=k&dl=0", path: "/Sub/Ünnep"),
        ]
        for loc in cases {
            XCTAssertEqual(DropboxLocation(fullPath: loc.fullPath), loc, loc.fullPath)
        }
        XCTAssertEqual(DropboxLocation.own("/").apiPath, "")
        XCTAssertEqual(DropboxLocation.own("/A/B").apiPath, "/A/B")
        XCTAssertEqual(DropboxLocation.namespace(id: "9", path: "/x").apiPath, "ns:9/x")
        XCTAssertNil(DropboxLocation.sharedWithMe.apiPath)
        XCTAssertFalse(DropboxLocation.link(url: "u", path: "").supportsWrite)

        XCTAssertEqual(DropboxLocation.own("/").appending("A"), .own("/A"))
        XCTAssertEqual(DropboxLocation.own("/A/B").parent, .own("/A"))
        XCTAssertEqual(DropboxLocation.own("/A").parent, .own("/"))
        XCTAssertEqual(DropboxLocation.namespace(id: "9", path: "").parent, .sharedWithMe)
        XCTAssertEqual(DropboxLocation.namespace(id: "9", path: "/a/b").parent, .namespace(id: "9", path: "/a"))
        XCTAssertEqual(DropboxLocation.sharedWithMe.parent, .own("/"))
        XCTAssertTrue(DropboxLocation.isDropboxPath("dbx:/x"))
        XCTAssertFalse(DropboxLocation.isDropboxPath("/Users/x"))
    }

    func testRedirectParsing() {
        let ok = "GET /czcommander-dropbox?code=ABC123&state=S1 HTTP/1.1\r\nHost: localhost:53682\r\n\r\n"
        XCTAssertEqual(DropboxRedirectReceiver.parse(request: ok, expectedState: "S1"), .code("ABC123"))
        XCTAssertEqual(DropboxRedirectReceiver.parse(request: ok, expectedState: "OTHER"), .error("state mismatch"))
        let denied = "GET /czcommander-dropbox?error=access_denied&error_description=The+user+denied&state=S1 HTTP/1.1\r\n\r\n"
        if case .error(let m) = DropboxRedirectReceiver.parse(request: denied, expectedState: "S1") {
            XCTAssertTrue(m.contains("denied"))
        } else { XCTFail() }
        XCTAssertEqual(DropboxRedirectReceiver.parse(request: "GET /favicon.ico HTTP/1.1\r\n\r\n", expectedState: "S1"), .ignore)
    }

    func testAuthorizeURLAndPKCE() {
        let pkce = DropboxClient.PKCE()
        XCTAssertGreaterThanOrEqual(pkce.verifier.count, 43)
        XCTAssertFalse(pkce.challenge.contains("="))
        let url = DropboxClient.authorizeURL(pkce: pkce).absoluteString
        XCTAssertTrue(url.hasPrefix("https://www.dropbox.com/oauth2/authorize?"))
        XCTAssertTrue(url.contains("client_id=sz3517amssvkl80"))
        XCTAssertTrue(url.contains("code_challenge_method=S256"))
        XCTAssertTrue(url.contains("token_access_type=offline"))
        XCTAssertTrue(url.contains("redirect_uri=http://localhost:53682/czcommander-dropbox"))
        XCTAssertFalse(url.contains("team_data"))
    }

    func testHeaderJSONIsASCII() {
        let json = DropboxTransfer.asciiJSON(["path": "/Fotók/Ünnep ☀︎.jpg"])
        XCTAssertTrue(json.allSatisfy { $0.isASCII }, json)
        let back = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: String]
        XCTAssertEqual(back?["path"], "/Fotók/Ünnep ☀︎.jpg")
    }

    func testEntryFromListFolderJSON() {
        let file: [String: Any] = [".tag": "file", "name": "clip.mov", "size": 123456789012,
                                   "server_modified": "2026-11-20T10:11:12Z", "content_hash": "h"]
        let e = DropboxEntry.from(json: file, in: .namespace(id: "77", path: "/Raw"))
        XCTAssertEqual(e?.location, .namespace(id: "77", path: "/Raw/clip.mov"))
        XCTAssertEqual(e?.size, 123456789012)
        XCTAssertNotNil(e?.modified)
        XCTAssertNil(DropboxEntry.from(json: [".tag": "deleted", "name": "x"], in: .own("/")))
        XCTAssertEqual(DropboxEntry.from(json: [".tag": "folder", "name": "Day 1"], in: .own("/"))?.isFolder, true)
    }
}

final class DropboxCredentialStoreTests: XCTestCase {
    func testFileIsPrivate() throws {
        // Uses the real path only when the override is set by the test scheme; here we check the helper directly.
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("czc-dbx-\(UUID().uuidString).json")
        setenv("CZ_DROPBOX_CREDENTIALS", url.path, 1)
        defer { unsetenv("CZ_DROPBOX_CREDENTIALS"); try? FileManager.default.removeItem(at: url) }
        DropboxKeychain.save("tok", account: "refresh_token")
        XCTAssertEqual(DropboxKeychain.load(account: "refresh_token"), "tok")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        DropboxKeychain.delete(account: "refresh_token")
        XCTAssertNil(DropboxKeychain.load(account: "refresh_token"))
    }
}

final class DropboxSavedLinksTests: XCTestCase {
    func testAddRemove() {
        let suite = "czc-test-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        DropboxSavedLinks.defaults = d
        defer { d.removePersistentDomain(forName: suite); DropboxSavedLinks.defaults = .standard }
        DropboxSavedLinks.add(url: "https://www.dropbox.com/scl/fo/a/h?x=1", title: "Big Footage")
        DropboxSavedLinks.add(url: "https://www.dropbox.com/scl/fo/b/h", title: "Other")
        DropboxSavedLinks.add(url: "https://www.dropbox.com/scl/fo/a/h?x=1", title: "Big Footage")
        XCTAssertEqual(DropboxSavedLinks.all.map(\.title), ["Other", "Big Footage"])
        XCTAssertEqual(DropboxLocation.link(url: "https://www.dropbox.com/scl/fo/a/h?x=1", path: "").lastName, "Big Footage")
        DropboxSavedLinks.remove(url: "https://www.dropbox.com/scl/fo/b/h")
        XCTAssertEqual(DropboxSavedLinks.all.count, 1)
    }
}
