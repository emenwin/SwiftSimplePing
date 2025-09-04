/*
    Abstract:
    A Swift wrapper around SimplePing with convenience methods and latency statistics.
 */

import Foundation
@_exported import SimplePing

/// Statistics for ping operations
public struct PingStatistics: Sendable {
    public let packetsSent: Int
    public let packetsReceived: Int
    public let packetsLost: Int
    public let lossPercentage: Double
    public let minLatency: TimeInterval?
    public let maxLatency: TimeInterval?
    public let averageLatency: TimeInterval?
    public let latencies: [TimeInterval]

    public init(sent: Int, received: Int, latencies: [TimeInterval]) {
        self.packetsSent = sent
        self.packetsReceived = received
        self.packetsLost = sent - received
        self.lossPercentage = sent > 0 ? Double(packetsLost) / Double(sent) * 100.0 : 0.0
        self.latencies = latencies

        if !latencies.isEmpty {
            self.minLatency = latencies.min()
            self.maxLatency = latencies.max()
            self.averageLatency = latencies.reduce(0, +) / Double(latencies.count)
        } else {
            self.minLatency = nil
            self.maxLatency = nil
            self.averageLatency = nil
        }
    }
}

/// Result of a single ping operation
public struct PingResult: Sendable {
    public let sequenceNumber: UInt16
    public let latency: TimeInterval?
    public let error: Error?
    public let packetSize: Int

    public var isSuccess: Bool {
        return error == nil && latency != nil
    }
}

/// Delegate protocol for SwiftSimplePing
public protocol SwiftSimplePingDelegate: AnyObject {
    /// Called when ping starts successfully
    func swiftSimplePing(_ pinger: SwiftSimplePing, didStartWithAddress address: Data)

    /// Called when ping fails to start
    func swiftSimplePing(_ pinger: SwiftSimplePing, didFailWithError error: Error)

    /// Called for each ping result
    func swiftSimplePing(_ pinger: SwiftSimplePing, didReceivePingResult result: PingResult)

    /// Called when ping statistics are updated
    func swiftSimplePing(_ pinger: SwiftSimplePing, didUpdateStatistics statistics: PingStatistics)

    /// Called when ping operation stops
    func swiftSimplePingDidStop(_ pinger: SwiftSimplePing)
}

/// Swift wrapper around SimplePing with convenience methods and statistics
public class SwiftSimplePing: NSObject {

    // MARK: - Public Properties

    /// The hostname being pinged
    public let hostName: String

    /// Address style preference
    public var addressStyle: SimplePingAddressStyle {
        get { return simplePing?.addressStyle ?? .any }
        set { simplePing?.addressStyle = newValue }
    }

    /// The delegate for callbacks
    public weak var delegate: SwiftSimplePingDelegate?

    /// Current statistics
    public private(set) var statistics: PingStatistics

    /// Whether the pinger is currently running
    public var isRunning: Bool {
        return simplePing != nil && sendTimer != nil
    }

    /// The address being pinged (available after start)
    public var hostAddress: Data? {
        return simplePing?.hostAddress
    }

    // MARK: - Private Properties

    private var simplePing: SimplePing?
    private var sendTimer: Timer?
    private var pingInterval: TimeInterval = 1.0
    private var pendingPings: [UInt16: Date] = [:]
    private var packetsSent: Int = 0
    private var packetsReceived: Int = 0
    private var latencies: [TimeInterval] = []
    private var maxLatencyHistory: Int = 100

    // MARK: - Initialization

    /// Initialize with hostname
    /// - Parameter hostName: The hostname or IP address to ping
    public init(hostName: String) {
        self.hostName = hostName
        self.statistics = PingStatistics(sent: 0, received: 0, latencies: [])
        super.init()
    }

    // MARK: - Public Methods

    /// Start continuous ping with specified interval
    /// - Parameter interval: Time interval between pings (default: 1.0 second)
    public func ping(interval: TimeInterval = 1.0) {
        guard !isRunning else {
            NSLog("SwiftSimplePing: Already running")
            return
        }

        self.pingInterval = interval
        resetStatistics()
        startPing()
    }

    /// Send a single ping
    public func pingOnce() {
        guard !isRunning else {
            NSLog("SwiftSimplePing: Cannot send single ping while continuous ping is running")
            return
        }

        if simplePing == nil {
            startPing(continuous: false)
        } else {
            sendSinglePing()
        }
    }

    /// Stop all ping operations
    public func stop() {
        sendTimer?.invalidate()
        sendTimer = nil

        simplePing?.stop()
        simplePing = nil

        pendingPings.removeAll()

        delegate?.swiftSimplePingDidStop(self)
    }

    /// Configure maximum number of latency values to keep in history
    /// - Parameter maxHistory: Maximum number of latency values (default: 100)
    public func setMaxLatencyHistory(_ maxHistory: Int) {
        self.maxLatencyHistory = max(1, maxHistory)
        if latencies.count > maxLatencyHistory {
            latencies = Array(latencies.suffix(maxLatencyHistory))
        }
    }

    // MARK: - Private Methods

    private func startPing(continuous: Bool = true) {
        let pinger = SimplePing(hostName: hostName)
        self.simplePing = pinger
        pinger.delegate = self
        pinger.start()

        if continuous {
            // Timer will be started in didStartWithAddress
        }
    }

    private func sendSinglePing() {
        guard let pinger = simplePing else { return }

        let sequenceNumber = pinger.nextSequenceNumber
        pendingPings[sequenceNumber] = Date()
        packetsSent += 1

        pinger.send(with: nil)
    }

    @objc private func sendPeriodicPing() {
        sendSinglePing()
    }

    private func resetStatistics() {
        packetsSent = 0
        packetsReceived = 0
        latencies.removeAll()
        pendingPings.removeAll()
        updateStatistics()
    }

    private func updateStatistics() {
        statistics = PingStatistics(
            sent: packetsSent, received: packetsReceived, latencies: latencies)
        delegate?.swiftSimplePing(self, didUpdateStatistics: statistics)
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

    private func handlePingResponse(sequenceNumber: UInt16, packetSize: Int) {
        let now = Date()
        var latency: TimeInterval? = nil

        if let sendTime = pendingPings.removeValue(forKey: sequenceNumber) {
            latency = now.timeIntervalSince(sendTime)
            packetsReceived += 1

            // Add to latency history
            latencies.append(latency!)
            if latencies.count > maxLatencyHistory {
                latencies.removeFirst()
            }
        }

        let result = PingResult(
            sequenceNumber: sequenceNumber,
            latency: latency,
            error: nil,
            packetSize: packetSize
        )

        delegate?.swiftSimplePing(self, didReceivePingResult: result)
        updateStatistics()
    }

    private func handlePingError(sequenceNumber: UInt16, error: Error) {
        pendingPings.removeValue(forKey: sequenceNumber)

        let result = PingResult(
            sequenceNumber: sequenceNumber,
            latency: nil,
            error: error,
            packetSize: 0
        )

        delegate?.swiftSimplePing(self, didReceivePingResult: result)
        updateStatistics()
    }
}

// MARK: - SimplePingDelegate

extension SwiftSimplePing: SimplePingDelegate {

    public func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        NSLog(
            "SwiftSimplePing: Started pinging %@",
            displayAddressForAddress(address: address as NSData))

        delegate?.swiftSimplePing(self, didStartWithAddress: address)

        // Send first ping immediately
        sendSinglePing()

        // Start timer for continuous pings if needed
        if sendTimer == nil && pingInterval > 0 {
            sendTimer = Timer.scheduledTimer(
                timeInterval: pingInterval,
                target: self,
                selector: #selector(sendPeriodicPing),
                userInfo: nil,
                repeats: true
            )
        }
    }

    public func simplePing(_ pinger: SimplePing, didFailWithError error: Error) {
        NSLog(
            "SwiftSimplePing: Failed with error: %@",
            shortErrorFromError(error: error as NSError))

        stop()
        delegate?.swiftSimplePing(self, didFailWithError: error)
    }

    public func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16)
    {
        NSLog("SwiftSimplePing: #%u sent", sequenceNumber)
    }

    public func simplePing(
        _ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error
    ) {
        NSLog(
            "SwiftSimplePing: #%u send failed: %@", sequenceNumber,
            shortErrorFromError(error: error as NSError))

        handlePingError(sequenceNumber: sequenceNumber, error: error)
    }

    public func simplePing(
        _ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16
    ) {
        NSLog("SwiftSimplePing: #%u received, size=%zu", sequenceNumber, packet.count)

        handlePingResponse(sequenceNumber: sequenceNumber, packetSize: packet.count)
    }

    public func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        NSLog("SwiftSimplePing: Unexpected packet, size=%zu", packet.count)
    }
}
