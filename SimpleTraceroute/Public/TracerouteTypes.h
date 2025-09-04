/*
    Abstract:
    Core types and structures for SimpleTraceroute functionality.
 */

@import Foundation;
#import <sys/socket.h>
#include <AssertMacros.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark * Traceroute Data Structures

/*! Represents a single hop in the traceroute path.
 */
typedef struct TracerouteHop
{
    uint8_t hopNumber;                  ///< Hop number (1-based)
    uint8_t probeCount;                 ///< Number of probes sent for this hop
    NSData *_Nullable routerAddress;    ///< Router address (sockaddr structure)
    NSString *_Nullable routerHostname; ///< Router hostname (if resolved)
    double latencies[3];                ///< Latency times in milliseconds
    BOOL timeout[3];                    ///< Timeout flags for each probe
    NSError *_Nullable error;           ///< Error information (if any)
} TracerouteHop;

/*! Complete traceroute result.
 */
@interface TracerouteResult : NSObject
@property(nonatomic, copy, readonly) NSString *targetHostname; ///< Target hostname
@property(nonatomic, copy, readonly) NSData *targetAddress;    ///< Target address
@property(nonatomic, assign, readonly) uint8_t maxHops;        ///< Maximum number of hops
@property(nonatomic, assign, readonly) uint8_t actualHops;     ///< Actual number of hops reached
@property(nonatomic, assign, readonly) double totalTime;       ///< Total time in seconds
@property(nonatomic, copy, readonly) NSArray *hops;            ///< Array of TracerouteHop wrapped in NSValue (max 30)
@property(nonatomic, assign, readonly) BOOL reachedTarget;     ///< Whether target was reached

- (instancetype)initWithTargetHostname:(NSString *)targetHostname
                         targetAddress:(NSData *)targetAddress
                               maxHops:(uint8_t)maxHops
                            actualHops:(uint8_t)actualHops
                             totalTime:(double)totalTime
                                  hops:(NSArray *)hops
                         reachedTarget:(BOOL)reachedTarget;

@end

#pragma mark * ICMP Type Extensions

/*! Extended ICMP types for traceroute.
 */
enum
{
    ICMPv4TypeTimeExceeded = 11, ///< IPv4 TTL exceeded
    ICMPv4TypeDestUnreach = 3,   ///< IPv4 destination unreachable
    ICMPv6TypeTimeExceeded = 3,  ///< IPv6 hop limit exceeded
    ICMPv6TypeDestUnreach = 1    ///< IPv6 destination unreachable
};

/*! ICMP Time Exceeded codes.
 */
enum
{
    ICMPv4CodeTTLExceeded = 0,           ///< TTL exceeded in transit
    ICMPv4CodeFragReassemblyExceeded = 1 ///< Fragment reassembly time exceeded
};

/*! ICMP Destination Unreachable codes.
 */
enum
{
    ICMPv4CodeNetUnreach = 0,      ///< Network unreachable
    ICMPv4CodeHostUnreach = 1,     ///< Host unreachable
    ICMPv4CodeProtocolUnreach = 2, ///< Protocol unreachable
    ICMPv4CodePortUnreach = 3      ///< Port unreachable
};

#pragma mark * Response Parsing Structures

/*! Result of parsing a single traceroute response.
 */
@interface TracerouteHopResult : NSObject
@property(nonatomic, assign) uint8_t hopNumber;
@property(nonatomic, copy, nullable) NSString *routerAddress;
@property(nonatomic, assign) NSTimeInterval roundTripTime;
@property(nonatomic, assign) BOOL isDestination;
@property(nonatomic, assign) BOOL isTimeout;
@property(nonatomic, strong, nullable) NSDate *timestamp;
@property(nonatomic, assign) uint16_t sequenceNumber;
@property(nonatomic, assign) uint8_t probeIndex;
@end

/*! ICMP response analysis result.
 */
typedef struct ICMPResponseInfo
{
    int icmpType;            ///< ICMP type field
    int icmpCode;            ///< ICMP code field
    uint16_t sequenceNumber; ///< Extracted sequence number
    uint16_t identifier;     ///< ICMP identifier
    BOOL isTimeExceeded;     ///< Is Time Exceeded response
    BOOL isEchoReply;        ///< Is Echo Reply response
    BOOL isValid;            ///< Is valid ICMP response
} ICMPResponseInfo;

#pragma mark * Traceroute Configuration

/*! Default configuration values for traceroute.
 */
enum
{
    kTracerouteDefaultMaxHops = 30,     ///< Default maximum hops
    kTracerouteDefaultProbesPerHop = 3, ///< Default probes per hop
    kTracerouteDefaultTimeout = 5       ///< Default timeout in seconds
};

NS_ASSUME_NONNULL_END
