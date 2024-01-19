import XCTest
@testable import HLSCachingServer

final class HLSCachingServerTests: XCTestCase {
    var sut: HLSCachingServer!
    var urlSession = URLSession.shared
    var urlCache = URLCache.shared

    override func setUp() {
        super.setUp()
        urlSession = URLSession.shared
        urlCache = URLCache.shared
        sut = HLSCachingServer(urlSession: urlSession, urlCache: urlCache)
        sut.start(port: 1234)
    }

    override func tearDown() {
        super.tearDown()
        sut = nil
    }

    func testReverseProxyURL_returnsLocalhostURLWithOriginURL() {
        let origin = URL(string: "https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8")!
        let reverseProxyURL = HLSCachingServer.reverseProxyURL(from: origin)!

        XCTAssertEqual(reverseProxyURL.absoluteString, "http://localhost:1234/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8?__hls_origin_url=https://demo.unified-streaming.com/k8s/features/stable/video/tears-of-steel/tears-of-steel.ism/.m3u8")
    }
}
