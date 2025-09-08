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

    // Single ping support
    private var singlePingCompletion: ((PingResult) -> Void)?
    private var singlePingTimeoutTimer: Timer?
    private var lastSinglePingSequenceNumber: UInt16?

    // Errors
    public enum SwiftSimplePingError: Error {
        case continuousPingRunning
        case singlePingAlreadyInProgress
        case timeout
    }

    // Internal error wrapper for unexpected packets
    private struct UnexpectedICMPPacketError: Error, CustomStringConvertible {
        let description: String
    }

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
        // Backwards-compatible API: no completion or timeout (default 5s), completion only via delegate
        pingOnce(timeout: 5.0, completion: { _ in })
    }

    /// Send a single ping with timeout and completion handler
    /// - Parameters:
    ///   - timeout: Timeout in seconds (default 5 seconds)
    ///   - completion: Called with the `PingResult` (success or error/timeout)
    public func pingOnce(timeout: TimeInterval = 5.0, completion: @escaping (PingResult) -> Void) {
        // Cannot start a single ping while continuous mode running
        if sendTimer != nil {  // indicates continuous mode
            completion(
                PingResult(
                    sequenceNumber: 0, latency: nil,
                    error: SwiftSimplePingError.continuousPingRunning, packetSize: 0))
            NSLog("SwiftSimplePing: Cannot perform single ping while continuous ping is running")
            return
        }
        // Avoid overlapping single pings
        if singlePingCompletion != nil {
            completion(
                PingResult(
                    sequenceNumber: 0, latency: nil,
                    error: SwiftSimplePingError.singlePingAlreadyInProgress, packetSize: 0))
            NSLog("SwiftSimplePing: Single ping already in progress")
            return
        }

        singlePingCompletion = completion
        pingInterval = 0  // prevent timer creation in didStart

        if simplePing == nil {
            startPing(continuous: false)
        } else {
            sendSinglePing()
        }

        // Setup timeout
        if timeout > 0 {
            singlePingTimeoutTimer = Timer.scheduledTimer(
                timeInterval: timeout, target: self, selector: #selector(handleSinglePingTimeout),
                userInfo: nil, repeats: false)
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
        lastSinglePingSequenceNumber = sequenceNumber
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

    // Attempt to parse an unexpected ICMP packet and return human-readable description
    private func parseUnexpectedPacket(_ data: Data) -> String {
        if data.count < 20 { return "Packet too short (\(data.count) bytes)" }
        let first = data[data.startIndex]
        let version = (first & 0xF0) >> 4
        if version != 4 {
            return "Non-IPv4 unexpected packet (version=\(version)) size=\(data.count)"
        }
        let ihl = Int(first & 0x0F) * 4
        guard data.count >= ihl + 8 else { return "Truncated IPv4/ICMP header" }
        let proto = data[data.startIndex + 9]
        guard proto == 1 else { return "Not ICMP protocol (proto=\(proto))" }
        let icmpType = data[data.startIndex + ihl]
        let icmpCode = data[data.startIndex + ihl + 1]
        func typeDesc(_ t: UInt8, _ c: UInt8) -> String {
            switch t {
            case 0: return "Echo Reply"
            case 3:
                switch c {
                case 0: return "Destination Network Unreachable"
                case 1: return "Destination Host Unreachable"
                case 3: return "Destination Port Unreachable"
                case 4: return "Fragmentation Needed"
                default: return "Destination Unreachable (code=\(c))"
                }
            case 4: return "Source Quench (Deprecated)"
            case 5: return "Redirect (code=\(c))"
            case 8: return "Echo Request"
            case 9: return "Router Advertisement"
            case 10: return "Router Solicitation"
            case 11: return c == 0 ? "Time Exceeded (TTL Exceeded)" : "Time Exceeded (code=\(c))"
            case 12: return "Parameter Problem (code=\(c))"
            case 13: return "Timestamp Request"
            case 14: return "Timestamp Reply"
            default: return "ICMP type=\(t) code=\(c)"
            }
        }
        var extra = ""
        // Try to extract referenced sequence number for error packets (they embed original IP+8 bytes)
        if [3, 4, 5, 11, 12].contains(icmpType) {
            // Offset to original IP header inside payload
            let originalIPOffset = ihl + 8
            if data.count >= originalIPOffset + 20 + 8 {  // original IP header + 8 bytes (original ICMP header for echo)
                let innerFirst = data[originalIPOffset]
                let innerVersion = (innerFirst & 0xF0) >> 4
                let innerIHL = Int(innerFirst & 0x0F) * 4
                if innerVersion == 4, data.count >= originalIPOffset + innerIHL + 8 {
                    let innerProto = data[originalIPOffset + 9]
                    if innerProto == 1 {  // ICMP
                        let innerICMPTypeIndex = originalIPOffset + innerIHL
                        if data.count >= innerICMPTypeIndex + 8 {
                            let innerType = data[innerICMPTypeIndex]
                            if innerType == 8 || innerType == 0 {  // Echo req/rep
                                let seqHigh = UInt16(data[innerICMPTypeIndex + 6])
                                let seqLow = UInt16(data[innerICMPTypeIndex + 7])
                                let seq = (seqHigh << 8) | seqLow
                                extra = " (ref seq=\(seq))"
                            }
                        }
                    }
                }
            }
        }
        return "ICMP " + typeDesc(icmpType, icmpCode) + extra
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

        // Finish single ping mode
        if let completion = singlePingCompletion {
            completion(result)
            cleanupSinglePing()
        }
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

        if let completion = singlePingCompletion {
            completion(result)
            cleanupSinglePing()
        }
    }

    private func cleanupSinglePing() {
        singlePingTimeoutTimer?.invalidate()
        singlePingTimeoutTimer = nil
        singlePingCompletion = nil
        lastSinglePingSequenceNumber = nil
        // Stop underlying SimplePing to release resources (will trigger delegate didStop)
        if sendTimer == nil {  // only if not in continuous mode
            stop()
        }
    }

    @objc private func handleSinglePingTimeout() {
        guard let completion = singlePingCompletion else { return }
        let seq = lastSinglePingSequenceNumber ?? 0
        let result = PingResult(
            sequenceNumber: seq, latency: nil, error: SwiftSimplePingError.timeout, packetSize: 0)
        completion(result)
        delegate?.swiftSimplePing(self, didReceivePingResult: result)
        cleanupSinglePing()
    }
}

// MARK: - SimplePingDelegate

extension SwiftSimplePing: SimplePingDelegate {

    public func simplePing(_ pinger: SimplePing, didStartWithAddress address: Data) {
        NSLog(
            "SwiftSimplePing: Started pinging host:%@ %@",
            self.hostName,
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
            "SwiftSimplePing: host:%@ Failed with error: %@",
            self.hostName,
            shortErrorFromError(error: error as NSError))

        stop()
        delegate?.swiftSimplePing(self, didFailWithError: error)
    }

    public func simplePing(_ pinger: SimplePing, didSendPacket packet: Data, sequenceNumber: UInt16)
    {
        NSLog("SwiftSimplePing: host:%@ #%u sent", self.hostName, sequenceNumber)
    }

    public func simplePing(
        _ pinger: SimplePing, didFailToSendPacket packet: Data, sequenceNumber: UInt16, error: Error
    ) {
        NSLog(
            "SwiftSimplePing: host:%@ #%u send failed: %@", self.hostName, sequenceNumber,
            shortErrorFromError(error: error as NSError))

        handlePingError(sequenceNumber: sequenceNumber, error: error)
    }

    public func simplePing(
        _ pinger: SimplePing, didReceivePingResponsePacket packet: Data, sequenceNumber: UInt16
    ) {
        NSLog(
            "SwiftSimplePing:host:%@ #%u received, size=%zu", self.hostName, sequenceNumber,
            packet.count)

        handlePingResponse(sequenceNumber: sequenceNumber, packetSize: packet.count)
    }

    public func simplePing(_ pinger: SimplePing, didReceiveUnexpectedPacket packet: Data) {
        let desc = parseUnexpectedPacket(packet)
        NSLog(
            "SwiftSimplePing: host:%@ Unexpected packet: %@, size=%zu", self.hostName, desc,
            packet.count)
        let error = UnexpectedICMPPacketError(description: desc)
        let result = PingResult(
            sequenceNumber: 0, latency: nil, error: error, packetSize: packet.count)
        delegate?.swiftSimplePing(self, didReceivePingResult: result)
        // stats unchanged, but notify to maintain visibility if needed
        updateStatistics()
    }
}
