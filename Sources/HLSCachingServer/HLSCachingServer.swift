// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import OSLog

// MARK: - handler

final class HLSRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    // MARK: - properties

    private let urlSession: URLSession
    private let cache: URLCache
    private let port: UInt16
    private var currentRequestHead: HTTPRequestHead?

    // MARK: - intializer

    init(urlSession: URLSession, cache: URLCache, port: UInt16) {
        self.urlSession = urlSession
        self.cache = cache
        self.port = port
        configureCacheSize()
    }

    // MARK: - methods

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)

        switch requestPart {
        case .head(let head):
            self.currentRequestHead = head

        case .body:
            break

        case .end:
            guard let requestHead = currentRequestHead,
                  let originURLString = requestHead.uri.components(separatedBy: HLSCachingServer.originURLKey + "=").last,
                  let originURL = URL(string: originURLString) else {
                os_log("Invalid request", log: .default, type: .error)
                return
            }

            switch originURL.pathExtension {
            case "m3u8":
                os_log("m3u8 request arrived: %@", log: .default, type: .info, originURLString)
                var request = URLRequest(url: originURL)
                requestHead.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.name) }
                urlSession.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        return
                    }
                    context.eventLoop.execute {
                        self.sendHttpResponse(status: .ok, data: self.reverseProxyPlaylist(with: data) ?? data, to: context)
                    }
                }.resume()

            case "ts":
                os_log("ts request arrived: %@", log: .default, type: .info, originURLString)
                var request = URLRequest(url: originURL)
                requestHead.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.name) }
                request.cachePolicy = .returnCacheDataElseLoad

                if let cachedResponse = cache.cachedResponse(for: request) {
                    os_log("ts request served from cache: %@", log: .default, type: .info, originURLString)
                    context.eventLoop.execute {
                        self.sendHttpResponse(status: .ok, data: cachedResponse.data, to: context)
                    }
                } else {
                    os_log("ts request served from origin: %@", log: .default, type: .info, originURLString)
                    urlSession.dataTask(with: request) { data, response, error in
                        guard let data, let response else {
                            context.eventLoop.execute {
                                self.sendHttpResponse(status: .badRequest, data: Data(), to: context)
                            }
                            return
                        }

                        self.cache.storeCachedResponse(CachedURLResponse(response: response, data: data), for: request)
                        context.eventLoop.execute {
                            self.sendHttpResponse(status: .ok, data: data, to: context)
                        }
                    }.resume()
                }
            default:
                break
            }
            currentRequestHead = nil
        }
    }

    // MARK: - private methods

    private func configureCacheSize() {
        let cacheSize = 1024 * 1024 * 2048 // 2GB
        cache.memoryCapacity = cacheSize
        cache.diskCapacity = cacheSize
    }

    private func reverseProxyPlaylist(with data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let lines = string.components(separatedBy: .newlines)
        let newLines = lines.compactMap { line -> String? in
            if line.hasPrefix("#") {
                return line
            } else {
                guard let url = URL(string: line),
                      let proxyURL = HLSCachingServer.reverseProxyURL(from: url) else {
                    return nil
                }
                return proxyURL.absoluteString
            }
        }
        return newLines.joined(separator: "\n").data(using: .utf8)
    }

    private func sendHttpResponse(status: HTTPResponseStatus, data: Data, to context: ChannelHandlerContext) {
        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: status)
        let responsePart = HTTPServerResponsePart.head(responseHead)
        context.write(self.wrapOutboundOut(responsePart), promise: nil)
        let responseBody = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))
        context.write(self.wrapOutboundOut(responseBody), promise: nil)
        let responseEnd = HTTPServerResponsePart.end(nil)
        context.write(self.wrapOutboundOut(responseEnd), promise: nil)
        context.flush()
    }
}

public class HLSCachingServer {

    // MARK: - properties

    public static let originURLKey = "__hls_origin_url"
    public static private(set) var port: UInt16 = 12345

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverBootstrap: ServerBootstrap?

    private let urlSession: URLSession
    private let urlCache: URLCache

    // MARK: - initializer

    public init(urlSession: URLSession = URLSession.shared, urlCache: URLCache) {
        self.urlSession = urlSession
        self.urlCache = urlCache
    }

    // MARK: - deinitializer

    deinit {
        stop()
    }

    // MARK: - public methods

    public static func reverseProxyURL(from originURL: URL) -> URL? {
        guard let components = URLComponents(url: originURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var componentsCopy = components
        componentsCopy.scheme = "http"
        componentsCopy.host = "localhost"
        componentsCopy.port = Int(self.port)
        componentsCopy.queryItems = [
            URLQueryItem(name: originURLKey, value: originURL.absoluteString)
        ]
        return componentsCopy.url
    }

    public func start(port: UInt16) {
        HLSCachingServer.port = port
        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        serverBootstrap = ServerBootstrap(group: eventLoopGroup!)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HLSRequestHandler(urlSession: self.urlSession, cache: self.urlCache, port: HLSCachingServer.port))
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelOption(ChannelOptions.recvAllocator, value: AdaptiveRecvByteBufferAllocator())

        os_log("Starting server on port %d", type: .info, port)
        _ = self.serverBootstrap?.bind(host: "localhost", port: Int(port))
    }

    public func stop() {
        try? eventLoopGroup?.syncShutdownGracefully()
        eventLoopGroup = nil
        serverBootstrap = nil
    }
}
