// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import OSLog

let originURLKey = "__hls_origin_url"

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
                  let originURLString = requestHead.uri.components(separatedBy: originURLKey).last,
                  let originURL = URL(string: originURLString) else { return }

            switch originURL.pathExtension {
            case "m3u8":
                var request = URLRequest(url: originURL)
                requestHead.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.name) }
                urlSession.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        return
                    }
                    let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
                    let responsePart = HTTPServerResponsePart.head(responseHead)
                    context.write(self.wrapOutboundOut(responsePart), promise: nil)
                    let responseBody = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))
                    context.write(self.wrapOutboundOut(responseBody), promise: nil)
                    let responseEnd = HTTPServerResponsePart.end(nil)
                    context.write(self.wrapOutboundOut(responseEnd), promise: nil)
                    context.flush()
                }.resume()
            case "ts":
                var request = URLRequest(url: originURL)
                requestHead.headers.forEach { request.setValue($0.value, forHTTPHeaderField: $0.name) }
                request.cachePolicy = .returnCacheDataElseLoad

                urlSession.dataTask(with: request) { data, response, error in
                    guard let data = data else {
                        return
                    }
                    let responseHead = HTTPResponseHead(version: .init(major: 1, minor: 1), status: .ok)
                    let responsePart = HTTPServerResponsePart.head(responseHead)
                    context.write(self.wrapOutboundOut(responsePart), promise: nil)
                    let responseBody = HTTPServerResponsePart.body(.byteBuffer(ByteBuffer(bytes: data)))
                    context.write(self.wrapOutboundOut(responseBody), promise: nil)
                    let responseEnd = HTTPServerResponsePart.end(nil)
                    context.write(self.wrapOutboundOut(responseEnd), promise: nil)
                    context.flush()
                }.resume()
            default:
                break
            }
            currentRequestHead = nil
        }
    }
}

public class HLSCachingServer {

    private var port: UInt16?
    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverBootstrap: ServerBootstrap?
    private var runTask: Task<Void, Error>?

    private var urlSession: URLSession

    init(urlSession: URLSession = URLSession.shared) {
        self.urlSession = urlSession
    }

    deinit {
        stop()
    }

    func reverseProxyURL(from originURL: URL) -> URL? {
        guard let components = URLComponents(url: originURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        var componentsCopy = components
        componentsCopy.scheme = "https"
        componentsCopy.host = "localhost"
        componentsCopy.port = 1234
        componentsCopy.queryItems = [
            URLQueryItem(name: originURLKey, value: originURL.absoluteString)
        ]
        return componentsCopy.url
    }

    func start(port: UInt16) {
        self.port = port

        eventLoopGroup = MultiThreadedEventLoopGroup.singleton
        serverBootstrap = ServerBootstrap(group: eventLoopGroup!)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HLSRequestHandler(urlSession: self.urlSession))
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

        runTask = Task(priority: .background) {
            os_log("Starting server on port %d", type: .info, port)
            _ = try await self.serverBootstrap?.bind(host: "localhost", port: Int(port)).get().closeFuture.get()
        }
    }

    func stop() {
        runTask?.cancel()
        eventLoopGroup = nil
        serverBootstrap = nil
    }
}
