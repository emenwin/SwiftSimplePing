/*
 Abstract:
 A Swift wrapper around SimpleTraceroute with convenience methods and comprehensive traceroute functionality.
 */

import Foundation
@_exported import SimpleTraceroute

#if canImport(Combine)
    import Combine
#endif

/// Swift wrapper around SimpleTraceroute with convenience methods and statistics
public class SwiftSimpleTraceroute: NSObject {

    // MARK: - Public Properties

    /// The hostname being traced
    public let hostName: String

    /// Address style preference
    public var addressStyle: SimplePingAddressStyle {
        get { return simpleTraceroute?.addressStyle ?? .any }
        set { simpleTraceroute?.addressStyle = newValue }
    }

    /// The delegate for callbacks
    public weak var delegate: SwiftSimpleTracerouteDelegate?

    /// Current configuration
    public private(set) var configuration: STracerouteConfiguration

    /// Current statistics
    public private(set) var statistics: STracerouteStatistics

    /// Whether the traceroute is currently running
    public var isRunning: Bool {
        return simpleTraceroute?.isRunning ?? false
    }

    /// The address being traced (available after start)
    public var hostAddress: Data? {
        return simpleTraceroute?.hostAddress
    }

    /// Current hop number being traced
    public var currentHop: UInt8 {
        return simpleTraceroute?.currentHop ?? 0
    }

    /// Maximum number of hops to trace
    public var maxHops: UInt8 {
        get { return configuration.maxHops }
        set {
            configuration.maxHops = newValue
            simpleTraceroute?.maxHops = newValue
        }
    }

    /// Timeout for each probe packet
    public var timeout: TimeInterval {
        get { return configuration.timeout }
        set {
            configuration.timeout = newValue
            simpleTraceroute?.timeout = newValue
        }
    }

    /// Number of probes per hop
    public var probesPerHop: UInt8 {
        get { return configuration.probesPerHop }
        set {
            configuration.probesPerHop = newValue
            simpleTraceroute?.probesPerHop = newValue
        }
    }

    // MARK: - Private Properties

    private var simpleTraceroute: SimpleTraceroute?
    private var startTime: Date?
    private var completedHops: [STracerouteHop] = []
    private var probesSent: Int = 0
    private var responsesReceived: Int = 0
    private var timeouts: Int = 0
    private var latencies: [TimeInterval] = []
    private var finalResult: STracerouteResult?

    // MARK: - Initialization

    /// Initialize with hostname and default configuration
    /// - Parameter hostName: The hostname or IP address to trace
    public init(hostName: String) {
        self.hostName = hostName
        self.configuration = STracerouteConfiguration()
        self.statistics = STracerouteStatistics(
            probesSent: 0, responsesReceived: 0, timeouts: 0, latencies: [])
        super.init()
    }

    /// Initialize with hostname and custom configuration
    /// - Parameters:
    ///   - hostName: The hostname or IP address to trace
    ///   - configuration: Custom traceroute configuration
    public init(hostName: String, configuration: STracerouteConfiguration) {
        self.hostName = hostName
        self.configuration = configuration
        self.statistics = STracerouteStatistics(
            probesSent: 0, responsesReceived: 0, timeouts: 0, latencies: [])
        super.init()
    }

    // MARK: - Public Methods

    /// Start traceroute with current configuration
    /// - Throws: TracerouteError if configuration is invalid or traceroute is already running
    public func start() throws {
        guard !isRunning else {
            throw STracerouteError.alreadyRunning
        }

        try configuration.validate()

        resetStatistics()
        startTraceroute()
    }

    /// Start traceroute with custom configuration
    /// - Parameter config: Custom configuration to use
    /// - Throws: TracerouteError if configuration is invalid or traceroute is already running
    public func start(with config: STracerouteConfiguration) throws {
        self.configuration = config
        try start()
    }

    /// Stop the traceroute operation
    public func stop() {
        simpleTraceroute?.stop()
        simpleTraceroute = nil

        if startTime != nil {
            completeTraceroute(reachedTarget: false)
        }

        delegate?.swiftSimpleTraceroute(
            self, didFinishWithResult: finalResult ?? createEmptyResult())
    }

    /// Update the configuration (only when not running)
    /// - Parameter config: New configuration
    /// - Throws: TracerouteError if traceroute is currently running or configuration is invalid
    public func updateConfiguration(_ config: STracerouteConfiguration) throws {
        guard !isRunning else {
            throw STracerouteError.alreadyRunning
        }

        try config.validate()
        self.configuration = config
    }

    // MARK: - Private Methods

    private func startTraceroute() {
        let traceroute = SimpleTraceroute(hostName: hostName)
        self.simpleTraceroute = traceroute
        traceroute.delegate = self

        // Apply configuration
        traceroute.addressStyle = configuration.addressStyle
        traceroute.maxHops = configuration.maxHops
        traceroute.timeout = configuration.timeout
        traceroute.probesPerHop = configuration.probesPerHop

        // traceroute.delegate = self
        traceroute.start()

        startTime = Date()
    }

    private func resetStatistics() {
        completedHops.removeAll()
        probesSent = 0
        responsesReceived = 0
        timeouts = 0
        latencies.removeAll()
        startTime = nil
        finalResult = nil
        updateStatistics()
    }

    private func updateStatistics() {
        statistics = STracerouteStatistics(
            probesSent: probesSent,
            responsesReceived: responsesReceived,
            timeouts: timeouts,
            latencies: latencies
        )
        delegate?.swiftSimpleTraceroute(self, didUpdateStatistics: statistics)
    }

    private func completeTraceroute(reachedTarget: Bool) {
        guard let startTime = startTime else { return }

        let totalTime = Date().timeIntervalSince(startTime)
        let targetAddress =
            hostAddress.flatMap { displayAddressForAddress(address: $0 as NSData) } ?? hostName

        finalResult = STracerouteResult(
            targetHostname: hostName,
            targetAddress: targetAddress,
            maxHops: configuration.maxHops,
            actualHops: UInt8(completedHops.count),
            totalTime: totalTime,
            hops: completedHops,
            reachedTarget: reachedTarget,
            statistics: statistics
        )

        self.startTime = nil
    }

    private func createEmptyResult() -> STracerouteResult {
        return STracerouteResult(
            targetHostname: hostName,
            targetAddress: hostName,
            maxHops: configuration.maxHops,
            actualHops: 0,
            totalTime: 0,
            hops: [],
            reachedTarget: false,
            statistics: statistics
        )
    }

    // MARK: - Utility Methods

    /// Returns the string representation of the supplied address.
    ///
    /// - parameter address: Contains a `(struct sockaddr)` with the address to render.
    ///
    /// - returns: A string representation of that address.
    private func displayAddressForAddress(address: NSData) -> String {
        var hostStr = [Int8](repeating: 0, count: Int(NI_MAXHOST))

        let success =
            getnameinfo(
                address.bytes.assumingMemoryBound(to: sockaddr.self),
                socklen_t(address.length),
                &hostStr,
                socklen_t(hostStr.count),
                nil,
                0,
                NI_NUMERICHOST
            ) == 0
        let result: String
        if success {
            result = hostStr.withUnsafeBufferPointer { String(cString: $0.baseAddress!) }
        } else {
            result = "?"
        }
        return result
    }

    /// Returns a short error string for the supplied error.
    ///
    /// - parameter error: The error to render.
    ///
    /// - returns: A short string representing that error.
    private func shortErrorFromError(error: NSError) -> String {
        if error.domain == kCFErrorDomainCFNetwork as String
            && error.code == Int(CFNetworkErrors.cfHostErrorUnknown.rawValue)
        {
            if let failureObj = error.userInfo[kCFGetAddrInfoFailureKey as String] {
                if let failureNum = failureObj as? NSNumber {
                    if failureNum.intValue != 0 {
                        let f = gai_strerror(Int32(failureNum.intValue))
                        if f != nil {
                            return String(cString: f!)
                        }
                    }
                }
            }
        }
        if let result = error.localizedFailureReason {
            return result
        }
        return error.localizedDescription
    }

    private func convertTracerouteError(_ error: NSError) -> STracerouteError {
        if error.domain == kCFErrorDomainCFNetwork as String {
            switch error.code {
            case Int(CFNetworkErrors.cfHostErrorHostNotFound.rawValue),
                Int(CFNetworkErrors.cfHostErrorUnknown.rawValue):
                return .resolutionFailed(underlying: shortErrorFromError(error: error))
            default:
                return .networkError(underlying: shortErrorFromError(error: error))
            }
        }

        if error.domain == NSPOSIXErrorDomain {
            switch error.code {
            case Int(ENETUNREACH), Int(EHOSTUNREACH):
                return .networkError(underlying: "Network unreachable")
            case Int(ETIMEDOUT):
                return .timeout
            default:
                return .systemError(underlying: shortErrorFromError(error: error))
            }
        }

        return .systemError(underlying: shortErrorFromError(error: error))
    }
}

// MARK: - SimpleTracerouteDelegate

extension SwiftSimpleTraceroute: SimpleTracerouteDelegate {

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didStartWithAddress address: Data
    ) {
        NSLog(
            "SwiftSimpleTraceroute: Started tracing to %@",
            displayAddressForAddress(address: address as NSData))

        let addressString = displayAddressForAddress(address: address as NSData)
        delegate?.swiftSimpleTraceroute(self, didStartWithAddress: addressString)
    }

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didFailWithError error: Error
    ) {
        NSLog(
            "SwiftSimpleTraceroute: Failed with error: %@",
            shortErrorFromError(error: error as NSError))

        let tracerouteError = convertTracerouteError(error as NSError)
        stop()
        delegate?.swiftSimpleTraceroute(self, didFailWithError: tracerouteError)
    }

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didCompleteHop hopResult: TracerouteHopResult
    ) {
        NSLog(
            "SwiftSimpleTraceroute: Completed hop %u: %@ (%.1f ms)",
            hopResult.hopNumber,
            hopResult.routerAddress ?? "timeout",
            hopResult.roundTripTime * 1000)

        // Convert Objective-C hop result to Swift type
        let hop = STracerouteHop(
            hopNumber: hopResult.hopNumber,
            routerAddress: hopResult.routerAddress,
            hostName: nil,  // TODO: Add hostname resolution if needed
            roundTripTime: hopResult.isTimeout ? nil : hopResult.roundTripTime,
            isDestination: hopResult.isDestination,
            isTimeout: hopResult.isTimeout,
            timestamp: hopResult.timestamp ?? Date(),
            sequenceNumber: hopResult.sequenceNumber,
            probeIndex: hopResult.probeIndex
        )

        completedHops.append(hop)

        // Update statistics
        responsesReceived += 1
        if hopResult.isTimeout {
            timeouts += 1
        } else {
            latencies.append(hopResult.roundTripTime)
        }
        updateStatistics()

        delegate?.swiftSimpleTraceroute(self, didCompleteHop: hop)
    }

    public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didFinishWith result: TracerouteResult
    ) {
        NSLog(
            "SwiftSimpleTraceroute: Finished - reached target: %@, hops: %u",
            result.reachedTarget ? "YES" : "NO", result.actualHops)

        completeTraceroute(reachedTarget: result.reachedTarget)

        if let finalResult = self.finalResult {
            delegate?.swiftSimpleTraceroute(self, didFinishWithResult: finalResult)
        }

        // Clean up
        simpleTraceroute = nil
    }

    // MARK: - Optional Delegate Methods

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didSendProbeToHop hopNumber: UInt8, sequenceNumber: UInt16
    ) {
        NSLog("SwiftSimpleTraceroute: Sent probe to hop %u, seq=%u", hopNumber, sequenceNumber)

        probesSent += 1
        updateStatistics()

        delegate?.swiftSimpleTraceroute(
            self, didSendProbeToHop: hopNumber, sequenceNumber: sequenceNumber)
    }

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didReceiveResponseFromHop hopNumber: UInt8,
        latency: TimeInterval
    ) {
        NSLog("SwiftSimpleTraceroute: Response from hop %u: %.1f ms", hopNumber, latency * 1000)

        delegate?.swiftSimpleTraceroute(
            self, didReceiveResponseFromHop: hopNumber, latency: latency)
    }

    @objc public func simpleTraceroute(
        _ traceroute: SimpleTraceroute, didTimeoutForHop hopNumber: UInt8
    ) {
        NSLog("SwiftSimpleTraceroute: Timeout for hop %u", hopNumber)

        delegate?.swiftSimpleTraceroute(self, didTimeoutForHop: hopNumber)
    }

}

// MARK: - Convenience Methods

extension SwiftSimpleTraceroute {

    /// Start traceroute with quick configuration (faster, less detailed)
    public func startQuick() throws {
        try start(with: .quick)
    }

    /// Start traceroute with detailed configuration (slower, more thorough)
    public func startDetailed() throws {
        try start(with: .detailed)
    }

    /// Start IPv4-only traceroute
    public func startIPv4Only() throws {
        try start(with: .ipv4Only)
    }

    /// Start IPv6-only traceroute
    public func startIPv6Only() throws {
        try start(with: .ipv6Only)
    }
}

#if canImport(Combine)
    // MARK: - Combine Support

    @available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
    extension SwiftSimpleTraceroute {

        /// Publisher that emits traceroute results
        public var traceroutePublisher: TraceroutePublisher {
            return TraceroutePublisher(traceroute: self)
        }

        /// Combine publisher for traceroute operations
        public struct TraceroutePublisher: Publisher {
            public typealias Output = STracerouteResult
            public typealias Failure = STracerouteError

            private let traceroute: SwiftSimpleTraceroute

            init(traceroute: SwiftSimpleTraceroute) {
                self.traceroute = traceroute
            }

            public func receive<S>(subscriber: S)
            where S: Subscriber, STracerouteError == S.Failure, STracerouteResult == S.Input {
                let subscription = TracerouteSubscription(
                    subscriber: subscriber, traceroute: traceroute)
                subscriber.receive(subscription: subscription)
            }
        }

        private class TracerouteSubscription<S: Subscriber>: NSObject, Subscription,
            SwiftSimpleTracerouteDelegate
        where S.Input == STracerouteResult, S.Failure == STracerouteError {

            private var subscriber: S?
            private let traceroute: SwiftSimpleTraceroute

            init(subscriber: S, traceroute: SwiftSimpleTraceroute) {
                self.subscriber = subscriber
                self.traceroute = traceroute
                super.init()
                traceroute.delegate = self
            }

            func request(_ demand: Subscribers.Demand) {
                // Start traceroute when demand is requested
                do {
                    try traceroute.start()
                } catch let error as STracerouteError {
                    subscriber?.receive(completion: .failure(error))
                } catch {
                    subscriber?.receive(
                        completion: .failure(.systemError(underlying: error.localizedDescription)))
                }
            }

            func cancel() {
                traceroute.stop()
                subscriber = nil
            }

            // MARK: - SwiftSimpleTracerouteDelegate

            func swiftSimpleTraceroute(
                _ traceroute: SwiftSimpleTraceroute, didStartWithAddress address: String
            ) {
                // Optional: Could emit intermediate updates here
            }

            func swiftSimpleTraceroute(
                _ traceroute: SwiftSimpleTraceroute, didFailWithError error: STracerouteError
            ) {
                subscriber?.receive(completion: .failure(error))
                subscriber = nil
            }

            func swiftSimpleTraceroute(
                _ traceroute: SwiftSimpleTraceroute, didCompleteHop hop: STracerouteHop
            ) {
                // Optional: Could emit hop updates here
            }

            func swiftSimpleTraceroute(
                _ traceroute: SwiftSimpleTraceroute,
                didUpdateStatistics statistics: STracerouteStatistics
            ) {
                // Optional: Could emit statistics updates here
            }

            func swiftSimpleTraceroute(
                _ traceroute: SwiftSimpleTraceroute, didFinishWithResult result: STracerouteResult
            ) {
                _ = subscriber?.receive(result)
                subscriber?.receive(completion: .finished)
                subscriber = nil
            }
        }
    }
#endif

// MARK: - Async/Await Support

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, *)
extension SwiftSimpleTraceroute {

    /// Perform traceroute asynchronously
    /// - Returns: TracerouteResult when complete
    /// - Throws: TracerouteError if operation fails
    public func trace() async throws -> STracerouteResult {
        return try await withCheckedThrowingContinuation { continuation in
            let delegate = AsyncTracerouteDelegate(continuation: continuation)
            self.delegate = delegate

            do {
                try self.start()
            } catch {
                if let tracerouteError = error as? STracerouteError {
                    continuation.resume(throwing: tracerouteError)
                } else {
                    continuation.resume(
                        throwing: STracerouteError.systemError(
                            underlying: error.localizedDescription))
                }
            }
        }
    }

    /// Perform traceroute with custom configuration asynchronously
    /// - Parameter configuration: Custom traceroute configuration
    /// - Returns: TracerouteResult when complete
    /// - Throws: TracerouteError if operation fails
    public func trace(with configuration: STracerouteConfiguration) async throws
        -> STracerouteResult
    {
        self.configuration = configuration
        return try await trace()
    }

    private class AsyncTracerouteDelegate: SwiftSimpleTracerouteDelegate {
        private let continuation: CheckedContinuation<STracerouteResult, Error>
        private var hasResumed = false

        init(continuation: CheckedContinuation<STracerouteResult, Error>) {
            self.continuation = continuation
        }

        func swiftSimpleTraceroute(
            _ traceroute: SwiftSimpleTraceroute, didStartWithAddress address: String
        ) {
            // Do nothing, wait for completion
        }

        func swiftSimpleTraceroute(
            _ traceroute: SwiftSimpleTraceroute, didFailWithError error: STracerouteError
        ) {
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(throwing: error)
        }

        func swiftSimpleTraceroute(
            _ traceroute: SwiftSimpleTraceroute, didCompleteHop hop: STracerouteHop
        ) {
            // Do nothing, wait for completion
        }

        func swiftSimpleTraceroute(
            _ traceroute: SwiftSimpleTraceroute,
            didUpdateStatistics statistics: STracerouteStatistics
        ) {
            // Do nothing, wait for completion
        }

        func swiftSimpleTraceroute(
            _ traceroute: SwiftSimpleTraceroute, didFinishWithResult result: STracerouteResult
        ) {
            guard !hasResumed else { return }
            hasResumed = true
            continuation.resume(returning: result)
        }
    }
}
