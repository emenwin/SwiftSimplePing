# SwiftSimplePing & Traceroute

A lightweight Swift wrapper around [Apple’s SimplePing Code Example](https://developer.apple.com/library/archive/samplecode/SimplePing/Introduction/Intro.html) , providing both ping and traceroute functionality with modern Swift support and convenient APIs.

## Overview

- Based on Apple's SimplePing Code Example (Objective‑C), with SimpleTraceroute referencing SimplePing's implementation.
- Extended to support Swift 5 and Swift 6.
- Provides Swift wrappers `SwiftSimplePing` and `SwiftSimpleTraceroute` for easy, idiomatic use with delegate callbacks and statistics.
- Ships as a Swift Package with four products: `SimplePing` (ObjC), `SwiftSimplePing` (Swift wrapper), `SimpleTraceroute` (ObjC), and `SwiftSimpleTraceroute` (Swift wrapper).

For original Apple license and notes, see `LICENSE-Apple.txt` and `README-Apple.md`.

## Requirements

- Swift 5 or Swift 6
- iOS 12+, tvOS 12+, macOS 10.13+

## Installation (Swift Package Manager)

- Add this repository as a package dependency.
- Select the product you need:
  - `SwiftSimplePing` (recommended) for the Swift ping wrapper.
  - `SimplePing` if you only want the original Objective‑C ping API.
  - `SwiftSimpleTraceroute` (recommended) for the Swift traceroute wrapper.
  - `SimpleTraceroute` if you only want the original Objective‑C traceroute API.

## Quick start

```swift
import SwiftSimplePing

final class MyPinger: NSObject, SwiftSimplePingDelegate {
	private var pinger: SwiftSimplePing?

	func start() {
		let p = SwiftSimplePing(hostName: "8.8.8.8")
		p.delegate = self
		p.ping(interval: 1.0) // continuous ping every second
		self.pinger = p
	}

	func stop() {
		pinger?.stop()
	}

	// MARK: - SwiftSimplePingDelegate

	func swiftSimplePing(_ pinger: SwiftSimplePing, didStartWithAddress address: Data) { }

	func swiftSimplePing(_ pinger: SwiftSimplePing, didFailWithError error: Error) {
		print("Ping failed: \(error)")
	}

	func swiftSimplePing(_ pinger: SwiftSimplePing, didReceivePingResult result: PingResult) {
		if result.isSuccess, let ms = result.latency.map({ $0 * 1000 }) {
			print("#\(result.sequenceNumber) \(Int(ms)) ms")
		} else {
			print("#\(result.sequenceNumber) error: \(result.error?.localizedDescription ?? "unknown")")
		}
	}

	func swiftSimplePing(_ pinger: SwiftSimplePing, didUpdateStatistics statistics: PingStatistics) {
		print("sent: \(statistics.packetsSent), received: \(statistics.packetsReceived), loss: \(statistics.lossPercentage)%")
	}

	func swiftSimplePingDidStop(_ pinger: SwiftSimplePing) { }
```

## SimpleTraceroute

SimpleTraceroute is the Objective-C implementation that references SimplePing's implementation code. It provides low-level traceroute functionality with delegate callbacks for tracing network paths to a target host.

### Features
- Traces the network path to a specified hostname or IP address
- Configurable maximum hops, timeout, and probes per hop
- Delegate-based callbacks for hop completion and errors
- Supports IPv4 and IPv6

## SwiftSimpleTraceroute

SwiftSimpleTraceroute is a modern Swift wrapper around SimpleTraceroute, offering a convenient API for performing traceroute operations with comprehensive statistics and error handling.

### Features
- Easy-to-use Swift API with delegate callbacks
- Automatic statistics tracking (packets sent, received, timeouts, latencies)
- Configurable traceroute parameters
- Comprehensive error handling with custom error types
- Support for Combine (if available)

## Quick start for SwiftSimpleTraceroute

```swift
import SwiftSimplePing

final class MyTracer: NSObject, SwiftSimpleTracerouteDelegate {
    private var tracer: SwiftSimpleTraceroute?

    func start() {
        let t = SwiftSimpleTraceroute(hostName: "google.com")
        t.delegate = self
        do {
            try t.start()
            self.tracer = t
        } catch {
            print("Failed to start traceroute: \(error)")
        }
    }

    func stop() {
        tracer?.stop()
    }

    // MARK: - SwiftSimpleTracerouteDelegate

    func swiftSimpleTraceroute(_ traceroute: SwiftSimpleTraceroute, didStartWithAddress address: String) {
        print("Started tracing to \(address)")
    }

    func swiftSimpleTraceroute(_ traceroute: SwiftSimpleTraceroute, didFailWithError error: STracerouteError) {
        print("Traceroute failed: \(error)")
    }

    func swiftSimpleTraceroute(_ traceroute: SwiftSimpleTraceroute, didCompleteHop hop: STracerouteHop) {
        if hop.isTimeout {
            print("Hop \(hop.hopNumber): timeout")
        } else {
            let ms = hop.roundTripTime.map { Int($0 * 1000) } ?? 0
            print("Hop \(hop.hopNumber): \(hop.routerAddress ?? "unknown") (\(ms) ms)")
        }
    }

    func swiftSimpleTraceroute(_ traceroute: SwiftSimpleTraceroute, didUpdateStatistics statistics: STracerouteStatistics) {
        print("Statistics: sent \(statistics.probesSent), received \(statistics.responsesReceived)")
    }

    func swiftSimpleTraceroute(_ traceroute: SwiftSimpleTraceroute, didFinishWithResult result: STracerouteResult) {
        print("Traceroute completed: \(result.actualHops) hops, reached target: \(result.reachedTarget)")
    }
}
```

This package includes and builds upon Apple’s SimplePing sample. See:

- `LICENSE-Apple.txt`
- `README-Apple.md`

The Swift wrapper code is provided under this repository’s license; Apple’s sample remains under its original terms.