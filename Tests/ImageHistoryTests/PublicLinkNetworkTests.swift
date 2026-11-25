import Foundation
import Network
import Security
#if !STANDALONE_TESTS
import XCTest
@testable import Shelf
#endif

@MainActor final class PublicLinkPolicyTests: HistoryTestCase {
    func testAddressClassificationRejectsPrivateTransitionAndNoncanonicalForms() throws {
        for value in ["0.1.2.3", "10.1.2.3", "100.64.0.1", "100.127.255.254", "127.0.0.1", "169.254.169.254", "172.16.0.1", "172.31.255.254", "192.0.0.1", "192.0.2.1", "192.168.0.1", "198.18.1.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "::", "::1", "::ffff:8.8.8.8", "fc00::1", "fe80::1", "ff02::1", "64:ff9b::7f00:1", "2001::1", "2001:20::1", "2001:db8::1", "2002:7f00:1::", "3fff::1"] {
            XCTAssertFalse(try XCTUnwrap(PublicLinkAddress(value)).isPublic, value)
        }
        for value in ["8.8.8.8", "93.184.216.34", "100.63.255.254", "100.128.0.1", "172.32.0.1", "2606:4700:4700::1111", "2001:4860:4860::8888"] {
            XCTAssertTrue(try XCTUnwrap(PublicLinkAddress(value)).isPublic, value)
        }
        for value in ["127.1", "2130706433", "0x7f000001", "0177.0.0.1", "127.000.0.1", "fe80::1%en0", "public.example.org"] { XCTAssertNil(PublicLinkAddress(value), value) }
    }

    func testDestinationRequiresNamedHTTPSAndStripsFragmentWithoutLeakingSecrets() throws {
        let syntheticUserInfo = "synthetic-user" + ":" + "synthetic-password" + "@"
        for value in ["http://example.com/a", "https://127.1/a", "https://8.8.8.8/a", "https://[2606:4700::1111]/a", "https://" + syntheticUserInfo + "example.com/a", "https://example.com:8443/a", "https://localhost/a", "https://host.local/a", "https://host.internal/a", "https://host.home.arpa/a", "https://host.onion/a", "https://host.invalid/a", "https://example.com./a", "https://-bad.example.com/a", "https://example.com/?%74oken=secret", "https://example.com/?X-Amz-Signature=secret", "https://example.com/?api_key=secret", "https://example.com/?accessToken=secret", "https://example.com/?sessionId=secret", "https://example.com/?pwd=secret", "https://example.com/?PassWd=secret", "https://example.com/?pass_code=secret", "https://example.com/?passphrase=secret", "https://example.com/?otp=000000", "https://example.com/?totp=000000", "https://example.com/?api-secret=secret", "https://example.com/?secret_key=secret", "https://example.com/?private_key=secret", "https://example.com/?accessKey=secret"] {
            XCTAssertNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
        let destination = try XCTUnwrap(PublicLinkDestination(URL(string: "https://Example.com:443/articles?q=hello%20world#private-fragment")!))
        XCTAssertEqual(destination.hostname, "example.com")
        XCTAssertEqual(destination.url.absoluteString, "https://example.com/articles?q=hello%20world")
        XCTAssertEqual(destination.requestTarget, "/articles?q=hello%20world")
        for value in ["https://example.com/?keyword=otp", "https://example.com/?topic=pwd", "https://example.com/?passage=2"] {
            XCTAssertNotNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
    }

    /// Opening these signs in, confirms, resets or unsubscribes, so a preview
    /// must never request them. Ordinary pages with similar words still load.
    func testDestinationRefusesSingleUseAndSignedLinksByNamePathAndValue() throws {
        let signed = "eyJhbGciOiJIUzI1NiJ9" + ".e30." + "c2lnbmF0dXJl"
        let random = "Q7vX2mLp9" + "Rk4Tz8Wn3" + "Yb6Hc1Jd5"
        for value in ["https://example.com/reset_token?reset_token=AAAA", "https://example.com/?reset_token=AAAA", "https://example.com/?magic_link=AAAA",
                      "https://example.com/?ticket=AAAA", "https://example.com/?nonce=AAAA", "https://example.com/?invite=AAAA",
                      "https://example.com/?login_token=AAAA", "https://example.com/?confirmation_token=AAAA", "https://example.com/?unsubscribe=AAAA",
                      "https://example.com/?access_token=AAAA", "https://example.com/?code=AAAA", "https://example.com/?password_reset=1",
                      "https://example.com/?userAuthToken=AAAA", "https://example.com/?inviteCode=AAAA", "https://example.com/?state=AAAA",
                      "https://example.com/verify/" + signed, "https://example.com/?id=" + signed, "https://example.com/?id=" + random,
                      "https://example.com/account/reset-password", "https://example.com/email/verify", "https://example.com/unsubscribe",
                      "https://example.com/magic-link", "https://example.com/users/confirmation", "https://example.com/invitations/accept"] {
            XCTAssertNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
        for value in ["https://example.com/blog/how-to-reset-your-router", "https://example.com/?q=reset+password", "https://example.com/?author=synthetic",
                      "https://example.com/?designer=synthetic", "https://example.com/?keywords=search", "https://example.com/watch?v=jNQXAC9IVRw&t=10",
                      "https://example.com/commit/0123456789abcdef0123456789abcdef01234567", "https://example.com/?page=2&sort=new",
                      "https://example.com/docs/d/" + random + "/edit"] {
            XCTAssertNotNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
    }

    /// Page names that act on a visit are recognised by any of their words,
    /// with or without a file extension or a following number.
    func testDestinationRefusesSingleUsePageNamesAnywhereInASegment() throws {
        for value in ["https://example.com/resetpassword.php?id=42", "https://example.com/verify.php?id=42&h=1a2b", "https://example.com/verify-email-address/42",
                      "https://example.com/confirm-subscription?id=42", "https://www.facebook.com/recover/code/?u=100001234567&n=123456",
                      "https://example.com/emailVerification", "https://example.com/passwordreset", "https://example.com/activate-account.html",
                      "https://example.com/magic/sign-in", "https://example.com/invite/team", "https://example.com/unsubscribe.php?u=1",
                      "https://example.com/?code=AAAA", "https://example.com/?session=keynote"] {
            XCTAssertNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
        for value in ["https://example.com/blog/how-to-reset-your-router", "https://example.com/products/preset-packs", "https://example.com/docs/confirmation-bias-explained-for-new-readers",
                      "https://shop.example.org/cart?promo_code=SAVE10", "https://support.example.org/view?ticket_id=123", "https://www.apple.com/macos/",
                      "https://en.wikipedia.org/wiki/Password"] {
            XCTAssertNotNil(PublicLinkDestination(try XCTUnwrap(URL(string: value))), value)
        }
    }

    func testPinnedEndpointUsesNumericCaseButTLSAndHostHeaderUseOriginalHostname() throws {
        let destination = try XCTUnwrap(PublicLinkDestination(URL(string: "https://public.example.org/path")!))
        let address = try XCTUnwrap(PublicLinkAddress("93.184.216.34"))
        let plan = try PublicLinkConnectionPlan(destination: destination, address: address)
        if case .ipv4 = plan.address.endpointHost {} else { XCTAssertTrue(false, "Must never create a hostname endpoint") }
        XCTAssertEqual(plan.tlsServerName, "public.example.org"); XCTAssertEqual(plan.certificateHostname, "public.example.org")
        let properties = try XCTUnwrap(SecPolicyCopyProperties(PublicLinkTLS.policy(hostname: plan.certificateHostname)) as? [String: Any])
        XCTAssertEqual(properties["SecPolicyName"] as? String, "public.example.org")
        let request = String(decoding: plan.request, as: UTF8.self)
        XCTAssertTrue(request.contains("Host: public.example.org\r\n")); XCTAssertTrue(request.contains("Accept-Encoding: identity\r\n"))
        XCTAssertFalse(request.contains("Authorization:")); XCTAssertFalse(request.contains("Cookie:")); XCTAssertFalse(request.contains("93.184.216.34"))
        XCTAssertThrowsError(try PublicLinkConnectionPlan(destination: destination, address: PublicLinkAddress("127.0.0.1")!))
    }

    func testTLSRejectsAnUntrustedSelfSignedCertificateWithoutChangingSystemTrust() throws {
        // Public DER fixture only. Its generated private key was discarded.
        let untrustedPublicCertificateDER = "MIICtjCCAZ4CCQDcBX9bSTbs6TANBgkqhkiG9w0BAQsFADAdMRswGQYDVQQDDBJwdWJsaWMuZXhhbXBsZS5vcmcwHhcNMjYxMDE5MTIyMDIyWhcNMzYxMDE2MTIyMDIyWjAdMRswGQYDVQQDDBJwdWJsaWMuZXhhbXBsZS5vcmcwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQDH0zEGIWAoYwZuw7uP3FTUJneEguHHcstRYUCRSTnjRU4aPm8KpcRiWsiezLMOs15GGDyzL0s1Th7LDiHRH2oMxbaWClK6VUZK6uWtNfo12zva1OcralZNaRA7aubN40f/b631CM/1Fk47F+l8ZdjRvYpyJvIYdHaSlHtbUKxkLWFmmjjkGrdaf5j4ARhdqnpkqZxjqzHJm4hrjHrE81EIpXZ8HpZjSDStRcmF6jsRFLtBLw+PlMTVPS3v0lt/g0L5WaO9ZWtQ+E3nGgjbGoD/EgQrIpffGh6VnA0xZpzPeJQ8X1l8KpqTM+S/tp1Vze6MNb+rOUOOdwsUfnDJbYBZAgMBAAEwDQYJKoZIhvcNAQELBQADggEBADycxGDwyJHLcJvrchC6VExa7TCXO8PkgiwOhFxUVXFUsKLbmhxJ6QoNIC/gj3LWQ/AsvDr3kGFW6SNsYhAeB7XLR7izAglGgvlcOGtH2QCK6uEW97PrbNDao+mUqBP/JKsDxPh2SxWVE3foj0Dsa/Wm9jHBBCLZvCkygYqaKfhyWmXsp6mSTHCVvHpMiIS+UKOKevo3ur8xfonPKVstubZiweA0dn/e28pA0ztvfQss3vI/EwavfRh1U7Gy2pHYDB9b6NkxLRn/cMYKdINPjTOuj7iRMxLg7znJldnzKMf6PGf/ek7rn2AFIPHg4IpKX2hbKgSDalazKQUbW90HG7I="
        let certificate = try XCTUnwrap(SecCertificateCreateWithData(nil, try XCTUnwrap(Data(base64Encoded: untrustedPublicCertificateDER)) as CFData))
        var trust: SecTrust?
        XCTAssertEqual(SecTrustCreateWithCertificates(certificate, PublicLinkTLS.policy(hostname: "public.example.org"), &trust), errSecSuccess)
        XCTAssertFalse(PublicLinkTLS.evaluate(try XCTUnwrap(trust), hostname: "public.example.org"))
    }

    func testHTTPParserStreamsFixedChunkedAndConnectionCloseBodies() throws {
        for fixture in ["HTTP/1.1 200 OK\r\nContent-Length: 5\r\nContent-Type: text/html\r\n\r\nhello",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n2;foo=bar\r\nhe\r\n3\r\nllo\r\n0\r\nX-Ignored: test\r\n\r\n",
                        "HTTP/1.0 200 OK\r\nContent-Type: text/html\r\n\r\nhello"] {
            var parser = PublicLinkHTTPParser(limit: 5), response: PublicLinkHTTPResponse?
            let bytes = Array(fixture.utf8)
            for (index, byte) in bytes.enumerated() { response = try parser.append(Data([byte]), end: index == bytes.count - 1) ?? response }
            XCTAssertEqual(response?.status, 200); XCTAssertEqual(response?.body, Data("hello".utf8))
        }
    }

    func testHTTPParserRejectsAmbiguousTruncatedCompressedAndOversizedResponses() throws {
        for fixture in ["HTTP/1.1 200 OK\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Length: 1\r\nTransfer-Encoding: chunked\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\nx",
                        "HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nhello!",
                        "HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\nhell",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n6\r\nhello!\r\n0\r\n\r\n",
                        "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n1\r\nxZZ0\r\n\r\n",
                        "HTTP/1.1 200 OK\r\n bad: folded\r\n\r\nx"] {
            var parser = PublicLinkHTTPParser(limit: 5)
            XCTAssertThrowsError(try parser.append(Data(fixture.utf8), end: true))
        }
        var parser = PublicLinkHTTPParser(limit: 5)
        XCTAssertThrowsError(try parser.append(Data(repeating: 65, count: 32_769)))
    }

    func testHTMLExtractsBoundedTextAndOneSafeThumbnailWithoutExecutingOrFollowingOtherResources() throws {
        let url = URL(string: "https://public.example.org/page")!
        let html = #"<html><!--<meta property='og:title' content='comment'>--><script><meta property='og:title' content='script'>fetch('http://localhost')</script><title>fallback</title><meta content='A &amp; B &#x1F30D;' property='og:title'><meta name=author content='Writer'><meta property='og:image' content='/cover.png'><img src='http://localhost/tracking'><iframe src='http://localhost'></iframe></html>"#
        let parsed = try PublicLinkHTMLMetadata(data: Data(html.utf8), url: url)
        XCTAssertEqual(parsed.title, "A & B 🌍"); XCTAssertEqual(parsed.author, "Writer"); XCTAssertEqual(parsed.thumbnailURL?.absoluteString, "https://public.example.org/cover.png")
        let blocked = try PublicLinkHTMLMetadata(data: Data(#"<title>Plain &lt;img&gt; &#0;</title><meta property='og:image' content='http://127.0.0.1/private'>"#.utf8), url: url)
        XCTAssertTrue(blocked.title?.contains("Plain <img>") == true); XCTAssertNil(blocked.thumbnailURL)
        let long = try PublicLinkHTMLMetadata(data: Data(("<meta property='og:title' content='" + String(repeating: "a", count: 3000) + "'>").utf8), url: url)
        XCTAssertEqual(long.title?.count, 500)
        XCTAssertThrowsError(try PublicLinkHTMLMetadata(data: Data(repeating: 65, count: 512 * 1024 + 1), url: url))
    }

    func testHTMLOfUnclosedTagsIsReadInOnePassWithoutStalling() throws {
        let url = URL(string: "https://public.example.org/page")!, limit = 512 * 1024
        let longTag = "<meta " + String(repeating: "a", count: 8100) + ">"
        // Each of these once cost a scan of the rest of the page per tag: minutes of uninterruptible work.
        for unit in ["<!--", "<script>", "<script", "<style>", "<style ", "<meta ", "<meta a='", "<title>", "<title", "<title></title ", "</script ", longTag, "<meta a=\"b\" c", "<<"] {
            let page = String(repeating: unit, count: (limit - 200) / unit.utf8.count) + "<title>Tail</title><meta name=author content='Writer'>"
            let started = Date(), parsed = try PublicLinkHTMLMetadata(data: Data(page.utf8), url: url)
            XCTAssertTrue(Date().timeIntervalSince(started) < 5, "\(unit.prefix(12)) took \(Date().timeIntervalSince(started)) s")
            _ = parsed.title
        }
        let unclosed = "<script><!--<style>" + String(repeating: "<script <!-- <style ", count: 2000)
        let parsed = try PublicLinkHTMLMetadata(data: Data(("<title>Kept</title><meta name=author content='Writer'>" + unclosed).utf8), url: url)
        XCTAssertEqual(parsed.title, "Kept"); XCTAssertEqual(parsed.author, "Writer")
    }

    func testHTMLScannerMatchesTheOriginalPatternsOnSyntheticMarkup() throws {
        func scalars(_ value: String) -> [UInt32] { value.unicodeScalars.map(\.value) }
        func full(_ value: String) -> NSRange { NSRange(value.startIndex..., in: value) }
        let hidden = try NSRegularExpression(pattern: #"(?is)<!--.*?-->|<script\b[^>]*>.*?</script\s*>|<style\b[^>]*>.*?</style\s*>"#)
        let meta = try NSRegularExpression(pattern: #"(?is)<meta\b([^>]{0,8192})>"#)
        let attributes = try NSRegularExpression(pattern: #"([A-Za-z_:][A-Za-z0-9_:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#)
        let title = try NSRegularExpression(pattern: #"(?is)<title\b[^>]*>(.{0,8192}?)</title\s*>"#)
        let tag = try NSRegularExpression(pattern: #"<[^>]*>"#)
        func check(_ page: String, attributePattern: Bool = true) {
            let label = page.count > 200 ? "\(page.prefix(40))… (\(page.count))" : page.debugDescription
            XCTAssertEqual(scalars(PublicLinkHTMLScanner.withoutHiddenMarkup(page)), scalars(hidden.stringByReplacingMatches(in: page, range: full(page), withTemplate: "")), "hidden \(label)")
            XCTAssertEqual(scalars(PublicLinkHTMLScanner.withoutTags(page)), scalars(tag.stringByReplacingMatches(in: page, range: full(page), withTemplate: "")), "tags \(label)")
            let metas = meta.matches(in: page, range: full(page)).prefix(256).compactMap { Range($0.range(at: 1), in: page).map { String(page[$0]) } }
            XCTAssertEqual(PublicLinkHTMLScanner.metaTags(in: page).map(scalars), metas.map(scalars), "meta \(label)")
            let expected = title.firstMatch(in: page, range: full(page)).flatMap { Range($0.range(at: 1), in: page) }.map { scalars(String(page[$0])) }
            XCTAssertEqual(PublicLinkHTMLScanner.titleMarkup(in: page).map(scalars), expected, "title \(label)")
            // The original attribute pattern needs seconds for one long unassigned name.
            guard attributePattern else { return }
            let pairs = attributes.matches(in: page, range: full(page)).map { match -> [[UInt32]] in
                let value = (2...4).compactMap { Range(match.range(at: $0), in: page) }.first
                return [Range(match.range(at: 1), in: page).map { scalars(String(page[$0])) } ?? [], value.map { scalars(String(page[$0])) } ?? []]
            }
            XCTAssertEqual(PublicLinkHTMLScanner.attributes(in: page).map { [scalars($0.name), scalars($0.value)] }, pairs, "attributes \(label)")
        }
        let pieces = ["<", ">", "<!--", "-->", "--", "!", "<script", "</script", "<SCRIPT", "</Script", "<style", "</style", "</STYLE", "<meta", "<META", "<title", "</title", "</TITLE", "<\u{17F}cript", "</\u{17F}tyle", "<\u{FB06}yle", "<t\u{130}tle", "<\u{212A}",
                      " ", "\n", "\t", "\u{B}", "\u{85}", "\u{A0}", "\u{2028}", "\u{3000}", "\u{1C}", "\u{200B}", "\u{200D}", "\u{301}", "=", "\"", "'", "`", "/", "-", "_", ":", ".", "1", "a", "B", "content", "property", "og:title", "é", "😀", "&amp;", "中"]
        var state: UInt64 = 0x5EED
        func next(_ bound: Int) -> Int { state = state &* 6364136223846793005 &+ 1442695040888963407; return Int((state >> 33) % UInt64(bound)) }
        for _ in 0..<4000 { check((0..<next(28)).map { _ in pieces[next(pieces.count)] }.joined()) }
        for filler in ["a", "😀", " "] {
            for count in [8191, 8192, 8193] {
                let body = String(repeating: filler, count: count)
                for page in ["<meta \(body)><meta name=author content=x>", "<meta\(body)>", "<title>\(body)</title><title>short</title >"] { check(page, attributePattern: filler != "a") }
            }
        }
        check(String(repeating: "<meta a=b>", count: 300))
        check(#"<html><!--<meta property='og:title' content='comment'>--><script type="module"><meta property='og:title' content='script'></script ><style>a{}</style><title lang=en>A <b>bold</b> title</title><meta content='A &amp; B' property='og:title'><meta name=author content=Writer></html>"#)
    }
}

#if !STANDALONE_TESTS
private actor PublicLinkProbe {
    var hosts: [String] = [], plans: [PublicLinkConnectionPlan] = []
    let answers: [[PublicLinkAddress]], responses: [PublicLinkHTTPResponse]
    init(answers: [[PublicLinkAddress]], responses: [PublicLinkHTTPResponse]) { self.answers = answers; self.responses = responses }
    func resolve(_ host: String) throws -> [PublicLinkAddress] {
        hosts.append(host); guard hosts.count <= answers.count else { throw PublicLinkError.resolution }; return answers[hosts.count - 1]
    }
    func exchange(_ plan: PublicLinkConnectionPlan) throws -> PublicLinkHTTPResponse {
        plans.append(plan); guard plans.count <= responses.count else { throw PublicLinkError.invalidResponse }; return responses[plans.count - 1]
    }
}

final class PublicLinkNetworkAsyncTests: XCTestCase {
    private func client(_ probe: PublicLinkProbe) -> PublicLinkNetwork {
        PublicLinkNetwork(resolve: { try await probe.resolve($0) }, exchange: { plan, _ in try await probe.exchange(plan) })
    }
    func testAnyPrivateDNSAnswerPreventsEveryConnection() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!, PublicLinkAddress("100.64.0.1")!]], responses: [])
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Private DNS answer accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .blockedAddress) }
        let count = await probe.plans.count; XCTAssertEqual(count, 0)
    }
    func testRedirectRebindingRevalidatesDNSBeforeSendingAnotherHTTPRequest() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!], [PublicLinkAddress("127.0.0.1")!]],
            responses: [PublicLinkHTTPResponse(status: 302, headers: ["location": "/next"], body: Data())])
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Rebinding accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .blockedAddress) }
        let plans = await probe.plans, hosts = await probe.hosts
        XCTAssertEqual(plans.count, 1); XCTAssertEqual(hosts.count, 2)
    }
    func testPublicRedirectPinsEachAddressAndKeepsItsOwnTLSHostname() async throws {
        let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!], [PublicLinkAddress("8.8.8.8")!]], responses: [
            PublicLinkHTTPResponse(status: 302, headers: ["location": "https://cdn.example.org/next"], body: Data()),
            PublicLinkHTTPResponse(status: 200, headers: ["content-type": "text/html"], body: Data("done".utf8))])
        let result = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100)
        let plans = await probe.plans
        XCTAssertEqual(result.url.absoluteString, "https://cdn.example.org/next"); XCTAssertEqual(result.body, Data("done".utf8))
        XCTAssertEqual(plans.map(\.tlsServerName), ["public.example.org", "cdn.example.org"])
        XCTAssertEqual(plans.map { $0.address.text }, ["93.184.216.34", "8.8.8.8"])
    }
    func testUnsafeRedirectCannotResolveOrConnectAndHopBudgetIsEnforced() async throws {
        let syntheticUserInfo = "synthetic-user" + ":" + "synthetic-password" + "@"
        for location in ["http://public.example.org/plain", "https://127.0.0.1/secret", "https://" + syntheticUserInfo + "cdn.example.org/a"] {
            let probe = PublicLinkProbe(answers: [[PublicLinkAddress("93.184.216.34")!]], responses: [PublicLinkHTTPResponse(status: 302, headers: ["location": location], body: Data())])
            do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Unsafe redirect accepted") }
            catch { XCTAssertEqual(error as? PublicLinkError, .blockedURL) }
            let hosts = await probe.hosts, plans = await probe.plans; XCTAssertEqual(hosts.count, 1); XCTAssertEqual(plans.count, 1)
        }
        let probe = PublicLinkProbe(answers: Array(repeating: [PublicLinkAddress("93.184.216.34")!], count: 4), responses: Array(repeating: PublicLinkHTTPResponse(status: 302, headers: ["location": "/again"], body: Data()), count: 4))
        do { _ = try await client(probe).fetch(URL(string: "https://public.example.org/a")!, limit: 100); XCTFail("Unbounded redirect accepted") }
        catch { XCTAssertEqual(error as? PublicLinkError, .redirects) }
        let plans = await probe.plans; XCTAssertEqual(plans.count, 4)
    }
}
#endif
