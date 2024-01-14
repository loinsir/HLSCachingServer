// The Swift Programming Language
// https://docs.swift.org/swift-book

import Foundation
import NIO

public class HLSCachingServer {
    private var urlSession: URLSession

    private var eventLoopGroup: MultiThreadedEventLoopGroup?
    private var serverBootstrap: ServerBootstrap?

    init(urlSession: URLSession = URLSession.shared) {
        self.urlSession = urlSession
    }

    deinit {
        try? eventLoopGroup?.syncShutdownGracefully()
        eventLoopGroup = nil
        serverBootstrap = nil
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
            URLQueryItem(name: "__hls_origin_url", value: originURL.absoluteString)
        ]
        return componentsCopy.url
    }

    func start(port: UInt16) {
        eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: System.coreCount)
        serverBootstrap = ServerBootstrap(group: eventLoopGroup!)
            .serverChannelOption(
                ChannelOptions.backlog,
                value: 256
            )
            .serverChannelOption(
                ChannelOptions.socketOption(.so_reuseaddr),
                value: 1
            )
            .childChannelInitializer { channel in
                channel.pipeline.addHandlers([
                    BackPressureHandler()
                ])
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
    }
}
