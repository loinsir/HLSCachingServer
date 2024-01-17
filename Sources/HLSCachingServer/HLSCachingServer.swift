// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import OSLog

let originURLKey = "__hls_origin_url"
var bindPort = 1234

// MARK: - handler

class HLSRequestHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let urlSession: URLSession

    private var currentRequestHead: HTTPRequestHead?

    init(urlSession: URLSession) {
        self.urlSession = urlSession
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let requestPart = self.unwrapInboundIn(data)

        switch requestPart {
        case .head(let head):
            self.currentRequestHead = head
        case .body:
            break
        case .end:
            guard let requestHead = currentRequestHead,
                  let originURLString = requestHead.uri.components(separatedBy: originURLKey + "=").last,
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
                        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
                        let responsePart = HTTPServerResponsePart.head(responseHead)
                        context.write(self.wrapOutboundOut(responsePart), promise: nil)
                        let responseBody = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: self.reverseProxyPlaylist(with: data) ?? data)))
                        context.write(self.wrapOutboundOut(responseBody), promise: nil)
                        let responseEnd = HTTPServerResponsePart.end(nil)
                        context.write(self.wrapOutboundOut(responseEnd), promise: nil)
                        context.flush()
                    }
                }.resume()
            case "ts":
                os_log("ts request arrived: %@", log: .default, type: .info, originURLString)
                var request = URLRequest(url: originURL)
                requestHead.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.name) }
                request.cachePolicy = .returnCacheDataElseLoad

                if self.urlSession.configuration.urlCache?.cachedResponse(for: request) != nil {
                    os_log("ts request served from cache: %@", log: .default, type: .info, originURLString)
                } else {
                    os_log("ts request served from origin: %@", log: .default, type: .info, originURLString)
                }

                urlSession.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        return
                    }
                    context.eventLoop.execute {
                        let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
                        let responsePart = HTTPServerResponsePart.head(responseHead)
                        context.write(self.wrapOutboundOut(responsePart), promise: nil)
                        let responseBody = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))
                        context.write(self.wrapOutboundOut(responseBody), promise: nil)
                        let responseEnd = HTTPServerResponsePart.end(nil)
                        context.write(self.wrapOutboundOut(responseEnd), promise: nil)
                        context.flush()
                    }
                }.resume()
            default:
                break
            }
            currentRequestHead = nil
        }
    }

    // MARK: - private methods

    private func reverseProxyURL(from: URL) -> URL? {
        guard let components = URLComponents(url: from, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var componentsCopy = components
        componentsCopy.scheme = "http"
        componentsCopy.host = "localhost"
        componentsCopy.port = bindPort
        componentsCopy.queryItems = [
            URLQueryItem(name: originURLKey, value: from.absoluteString)
        ]
        return componentsCopy.url
    }

    private func reverseProxyPlaylist(with data: Data) -> Data? {
        guard let string = String(data: data, encoding: .utf8) else { return nil }
        let lines = string.components(separatedBy: .newlines)
        let newLines = lines.compactMap { line -> String? in
            if line.hasPrefix("#") {
                return line
            } else {
                guard let url = URL(string: line),
                      let proxyURL = reverseProxyURL(from: url) else {
                    return nil
                }
                return proxyURL.absoluteString
            }
        }
        return newLines.joined(separator: "\n").data(using: .utf8)
    }
}

public class HLSCachingServer {

    // MARK: - properties

    private let originURLKey = "__hls_origin_url"

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverBootstrap: ServerBootstrap?
    private var runTask: Task<Void, Error>?

    private var urlSession: URLSession

    // MARK: - initializer

    public init(urlSession: URLSession = URLSession.shared) {
        self.urlSession = urlSession
    }

    // MARK: - deinitializer

    deinit {
        stop()
    }

    // MARK: - public methods

    public func reverseProxyURL(from originURL: URL) -> URL? {
        guard let components = URLComponents(url: originURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var componentsCopy = components
        componentsCopy.scheme = "http"
        componentsCopy.host = "localhost"
        componentsCopy.port = bindPort
        componentsCopy.queryItems = [
            URLQueryItem(name: originURLKey, value: originURL.absoluteString)
        ]
        return componentsCopy.url
    }

    public func start(port: UInt16) {
        bindPort = Int(port)

        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        serverBootstrap = ServerBootstrap(group: eventLoopGroup!)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.configureHTTPServerPipeline().flatMap {
                    channel.pipeline.addHandler(HLSRequestHandler(urlSession: self.urlSession))
                }
            }
            .childChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelOption(
                ChannelOptions.maxMessagesPerRead,
                value: 16
            )
            .childChannelOption(
                ChannelOptions.recvAllocator,
                value: AdaptiveRecvByteBufferAllocator()
            )

        runTask = Task(priority: .high) {
            os_log("Starting server on port %d", type: .info, port)
            _ = try await self.serverBootstrap?.bind(host: "localhost", port: Int(port)).get().closeFuture.get()
        }
    }

    public func stop() {
        runTask?.cancel()
        eventLoopGroup = nil
        serverBootstrap = nil
    }
}
