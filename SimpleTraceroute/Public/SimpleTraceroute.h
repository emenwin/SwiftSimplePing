/*
    Abstract:
    An object wrapper around the low-level BSD Sockets traceroute function.
 */

@import Foundation;
#import <sys/socket.h>
#import "TracerouteTypes.h"
#import "../../SimplePing/Public/SimplePing.h"

NS_ASSUME_NONNULL_BEGIN

@protocol SimpleTracerouteDelegate;

/*! An object wrapper around the low-level BSD Sockets traceroute function.
 *  \details This class extends the functionality of SimplePing to provide
 *      traceroute capabilities. It sends ICMP packets with incrementing TTL
 *      values to discover the network path to a destination.
 *
 *      To use the class, create an instance, set the delegate and call `-start`
 *      to start the traceroute on the current run loop. You'll receive delegate
 *      callbacks as each hop is discovered.
 *
 *      The class can be used from any thread but the use of any single instance
 *      must be confined to a specific thread and that thread must run its run loop.
 */
@interface SimpleTraceroute : NSObject

- (instancetype)init NS_UNAVAILABLE;

/*! Initialize the object to traceroute to the specified host.
 *  \param hostName The DNS name of the host to traceroute; an IPv4 or IPv6 address
 *      in string form will work here.
 *  \returns The initialized object.
 */
- (instancetype)initWithHostName:(NSString *)hostName NS_DESIGNATED_INITIALIZER;

#pragma mark * Basic Properties

/*! A copy of the value passed to `-initWithHostName:`.
 */
@property(nonatomic, copy, readonly) NSString *hostName;

/*! The delegate for this object.
 *  \details Delegate callbacks are scheduled in the default run loop mode of the run loop
 *      of the thread that calls `-start`.
 */
@property(nonatomic, weak, readwrite, nullable) id<SimpleTracerouteDelegate> delegate;

/*! Controls the IP address version used by the object.
 *  \details You should set this value before starting the object.
 */
@property(nonatomic, assign, readwrite) SimplePingAddressStyle addressStyle;

/*! The address being traced.
 *  \details The contents of the NSData is a (struct sockaddr) of some form. The
 *      value is nil while the object is stopped and remains nil on start until
 *      `-simpleTraceroute:didStartWithAddress:` is called.
 */
@property(nonatomic, copy, readonly, nullable) NSData *hostAddress;

/*! The address family for `hostAddress`, or `AF_UNSPEC` if that's nil.
 */
@property(nonatomic, assign, readonly) sa_family_t hostAddressFamily;

/*! The identifier used by this traceroute object.
 *  \details When you create an instance of this object it generates a random identifier
 *      that it uses to identify its own packets.
 */
@property(nonatomic, assign, readonly) uint16_t identifier;

#pragma mark * Traceroute-Specific Properties

/*! Maximum number of hops to trace.
 *  \details Default value is 30. You should set this before calling `-start`.
 */
@property(nonatomic, assign, readwrite) uint8_t maxHops;

/*! Timeout for each probe packet in seconds.
 *  \details Default value is 5.0 seconds. You should set this before calling `-start`.
 */
@property(nonatomic, assign, readwrite) NSTimeInterval timeout;

/*! Number of probe packets to send per hop.
 *  \details Default value is 3. You should set this before calling `-start`.
 */
@property(nonatomic, assign, readwrite) uint8_t probesPerHop;

/*! Current hop number being traced.
 *  \details This value starts at 1 and increments as the traceroute progresses.
 *      It's 0 when the traceroute is not running.
 */
@property(nonatomic, assign, readonly) uint8_t currentHop;

/*! Whether the traceroute is currently running.
 */
@property(nonatomic, assign, readonly) BOOL isRunning;

#pragma mark * Control Methods

/*! Starts the traceroute.
 *  \details You should set up the delegate and any traceroute parameters before calling this.
 *
 *      If things go well you'll soon get the `-simpleTraceroute:didStartWithAddress:`
 *      delegate callback, at which point the traceroute will begin automatically.
 *
 *      If the object fails to start, typically because `hostName` doesn't resolve,
 *      you'll get the `-simpleTraceroute:didFailWithError:` delegate callback.
 *
 *      It is not correct to start an already started object.
 */
- (void)start;

/*! Stops the traceroute.
 *  \details You should call this when you're done with the traceroute.
 *
 *      It's safe to call this on an object that's stopped.
 */
- (void)stop;

@end

#pragma mark * Delegate Protocol

/*! A delegate protocol for the SimpleTraceroute class.
 */
@protocol SimpleTracerouteDelegate <NSObject>

@required

/*! A SimpleTraceroute delegate callback, called once the object has started up.
 *  \details This is called shortly after you start the object to tell you that the
 *      object has successfully started. The traceroute will begin automatically after
 *      this callback.
 *
 *      If the object didn't start, `-simpleTraceroute:didFailWithError:` is called instead.
 *  \param traceroute The object issuing the callback.
 *  \param address The address that's being traced; at the time this delegate callback
 *      is made, this will have the same value as the `hostAddress` property.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didStartWithAddress:(NSData *)address;

/*! A SimpleTraceroute delegate callback, called if the object fails to start up.
 *  \details This is called shortly after you start the object to tell you that the
 *      object has failed to start. The most likely cause of failure is a problem
 *      resolving `hostName`.
 *
 *      By the time this callback is called, the object has stopped (that is, you don't
 *      need to call `-stop` yourself).
 *  \param traceroute The object issuing the callback.
 *  \param error Describes the failure.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didFailWithError:(NSError *)error;

/*! A SimpleTraceroute delegate callback, called when a hop is completed.
 *  \details This is called when a response is received for a probe, providing
 *      detailed information about the hop.
 *  \param traceroute The object issuing the callback.
 *  \param hopResult The hop result with detailed information.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didCompleteHop:(TracerouteHopResult *)hopResult;

/*! A SimpleTraceroute delegate callback, called when the traceroute finishes.
 *  \details This is called when the traceroute reaches the target or the maximum
 *      number of hops. The result contains the complete path information.
 *  \param traceroute The object issuing the callback.
 *  \param result The complete traceroute result.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didFinishWithResult:(TracerouteResult *)result;

/*! A SimpleTraceroute delegate callback, called when a probe is sent.
 *  \param traceroute The object issuing the callback.
 *  \param hopNumber The hop number for which the probe was sent.
 *  \param sequenceNumber The ICMP sequence number of the probe.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didSendProbeToHop:(uint8_t)hopNumber sequenceNumber:(uint16_t)sequenceNumber;

/*! A SimpleTraceroute delegate callback, called when a response is received.
 *  \param traceroute The object issuing the callback.
 *  \param hopNumber The hop number that responded.
 *  \param latency The round-trip time in seconds.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didReceiveResponseFromHop:(uint8_t)hopNumber latency:(NSTimeInterval)latency;

/*! A SimpleTraceroute delegate callback, called when a probe times out.
 *  \param traceroute The object issuing the callback.
 *  \param hopNumber The hop number that timed out.
 */
- (void)simpleTraceroute:(SimpleTraceroute *)traceroute didTimeoutForHop:(uint8_t)hopNumber;

@end

NS_ASSUME_NONNULL_END
