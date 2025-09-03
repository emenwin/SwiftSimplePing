# SwiftSimplePing

A lightweight Swift wrapper around [Apple’s SimplePing Code Example](https://developer.apple.com/library/archive/samplecode/SimplePing/Introduction/Intro.html)  with modern Swift support and a convenient API.

## Overview

- Based on Apple’s SimplePing Code Example (Objective‑C).
- Extended to support Swift 5 and Swift 6.
- Provides a Swift wrapper `SwiftSimplePing` for easy, idiomatic use with delegate callbacks and basic latency statistics.
- Ships as a Swift Package with two products: `SimplePing` (ObjC) and `SwiftSimplePing` (Swift wrapper).

For original Apple license and notes, see `LICENSE-Apple.txt` and `README-Apple.md`.

## Requirements

- Swift 5 or Swift 6
- iOS 12+, tvOS 12+, macOS 10.13+

## Installation (Swift Package Manager)

- Add this repository as a package dependency.
- Select the product you need:
  - `SwiftSimplePing` (recommended) for the Swift wrapper.
  - `SimplePing` if you only want the original Objective‑C API.

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
}
```

## Credits & License

This package includes and builds upon Apple’s SimplePing sample. See:

- `LICENSE-Apple.txt`
- `README-Apple.md`

The Swift wrapper code is provided under this repository’s license; Apple’s sample remains under its original terms.