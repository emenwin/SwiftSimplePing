/*
 Abstract:
 An object wrapper around the low-level BSD Sockets traceroute function.
 */

#import "Public/SimpleTraceroute.h"

#include <arpa/inet.h>
#include <errno.h>
#include <netinet/icmp6.h>
#include <netinet/in.h>
#include <netinet/ip.h>
#include <netinet/ip6.h>
#include <netinet/ip_icmp.h>
#include <sys/socket.h>

#pragma mark * TracerouteResult Implementation

@implementation TracerouteResult

- (instancetype)initWithTargetHostname:(NSString *)targetHostname
                         targetAddress:(NSData *)targetAddress
                               maxHops:(uint8_t)maxHops
                            actualHops:(uint8_t)actualHops
                             totalTime:(double)totalTime
                                  hops:(NSArray<NSValue *> *)hops
                         reachedTarget:(BOOL)reachedTarget {
  if ((self = [super init])) {
    _targetHostname = [targetHostname copy];
    _targetAddress = [targetAddress copy];
    _maxHops = maxHops;
    _actualHops = actualHops;
    _totalTime = totalTime;
    _hops = [hops copy];
    _reachedTarget = reachedTarget;
  }
  return self;
}

@end

#pragma mark * Private Interface

@interface SimpleTraceroute ()

// Read/write versions of public properties
@property(nonatomic, copy, readwrite, nullable) NSData *hostAddress;
@property(nonatomic, assign, readwrite) uint8_t currentHop;
@property(nonatomic, assign, readwrite) BOOL isRunning;

// Private properties for traceroute functionality
@property(nonatomic, strong, readwrite, nullable) CFHostRef host
    __attribute__((NSObject));
@property(nonatomic, strong, readwrite, nullable) CFSocketRef socket
    __attribute__((NSObject));
@property(nonatomic, strong, readwrite, nullable) NSTimer *timeoutTimer;
@property(nonatomic, strong, readwrite, nullable)
    NSMutableDictionary *pendingProbes;
@property(nonatomic, assign, readwrite) uint16_t nextSequenceNumber;
@property(nonatomic, assign, readwrite) BOOL nextSequenceNumberHasWrapped;

// Traceroute state
@property(nonatomic, assign, readwrite) NSTimeInterval startTime;
@property(nonatomic, strong, readwrite, nullable) NSMutableArray *completedHops;

@end

#pragma mark * TracerouteHopResult Implementation

@implementation TracerouteHopResult

- (instancetype)init {
  self = [super init];
  if (self != nil) {
    self.hopNumber = 0;
    self.routerAddress = nil;
    self.roundTripTime = 0.0;
    self.isDestination = NO;
    self.isTimeout = NO;
    self.timestamp = nil;
    self.sequenceNumber = 0;
    self.probeIndex = 0;
  }
  return self;
}

- (NSString *)description {
  if (self.isTimeout) {
    return [NSString stringWithFormat:@"Hop %d: * (timeout)", self.hopNumber];
  } else {
    return [NSString
        stringWithFormat:@"Hop %d: %@ %.3fms%@", self.hopNumber,
                         self.routerAddress ?: @"unknown",
                         self.roundTripTime * 1000.0,
                         self.isDestination ? @" (destination)" : @""];
  }
}

@end

@implementation SimpleTraceroute

#pragma mark * Initialization and Deallocation

- (instancetype)initWithHostName:(NSString *)hostName {
  NSParameterAssert(hostName != nil);
  self = [super init];
  if (self != nil) {
    self->_hostName = [hostName copy];
    self->_identifier = (uint16_t)arc4random();
    self->_maxHops = kTracerouteDefaultMaxHops;
    self->_timeout = kTracerouteDefaultTimeout;
    self->_probesPerHop = kTracerouteDefaultProbesPerHop;
    self->_addressStyle = SimplePingAddressStyleAny;

    // Initialize private properties
    self->_pendingProbes = [[NSMutableDictionary alloc] init];
    self->_completedHops = [[NSMutableArray alloc] init];
    self->_nextSequenceNumber = 0;
    self->_nextSequenceNumberHasWrapped = NO;
    self->_currentHop = 0;
    self->_isRunning = NO;
  }
  return self;
}

- (void)dealloc {
  [self stop];
  // Double check that -stop took care of _host and _socket
  assert(self->_host == NULL);
  assert(self->_socket == NULL);
}

#pragma mark * Property Access

- (sa_family_t)hostAddressFamily {
  sa_family_t result;

  result = AF_UNSPEC;
  if ((self.hostAddress != nil) &&
      (self.hostAddress.length >= sizeof(struct sockaddr))) {
    result = ((const struct sockaddr *)self.hostAddress.bytes)->sa_family;
  }
  return result;
}

#pragma mark * Error Handling

/*! Shuts down the traceroute object and tells the delegate about the error.
 *  \param error Describes the failure.
 */
/*! Shuts down the traceroute object and tells the delegate about the error.
 *  \param error Describes the failure.
 */
- (void)didFailWithError:(NSError *)error {
  id<SimpleTracerouteDelegate> strongDelegate;

  assert(error != nil);

  // Ensure delegate is called on main thread
  if (![NSThread isMainThread]) {
    [self ensureMainThread:^{
      [self didFailWithError:error];
    }];
    return;
  }

  // Prevent duplicate calls
  if (!self.isRunning && self.host == NULL && self.socket == NULL) {
    return;
  }

  // Log detailed error information for debugging
  NSLog(@"SimpleTraceroute failed with error: %@", error.localizedDescription);

  // Retain ourselves temporarily to prevent dealloc during delegate callback
  CFAutorelease(CFBridgingRetain(self));

  [self stop];

  strongDelegate = self.delegate;
  if ((strongDelegate != nil) &&
      [strongDelegate respondsToSelector:@selector(simpleTraceroute:
                                                   didFailWithError:)]) {
    [strongDelegate simpleTraceroute:self didFailWithError:error];
  }
}

/*! Converts CFStreamError to NSError and calls -didFailWithError:.
 *  \param streamError Describes the failure.
 */
- (void)didFailWithHostStreamError:(CFStreamError)streamError {
  NSDictionary *userInfo;
  NSError *error;

  if (streamError.domain == kCFStreamErrorDomainNetDB) {
    userInfo = @{(id)kCFGetAddrInfoFailureKey : @(streamError.error)};
  } else {
    userInfo = nil;
  }
  error = [NSError errorWithDomain:(NSString *)kCFErrorDomainCFNetwork
                              code:kCFHostErrorUnknown
                          userInfo:userInfo];

  [self didFailWithError:error];
}

#pragma mark * Host Resolution

/*! The callback for our CFHost object.
 */
static void HostResolveCallback(CFHostRef theHost, CFHostInfoType typeInfo,
                                const CFStreamError *error, void *info) {
  SimpleTraceroute *obj;

  obj = (__bridge SimpleTraceroute *)info;
  assert([obj isKindOfClass:[SimpleTraceroute class]]);

#pragma unused(theHost)
  assert(theHost == obj.host);
#pragma unused(typeInfo)
  assert(typeInfo == kCFHostAddresses);

  if ((error != NULL) && (error->domain != 0)) {
    [obj didFailWithHostStreamError:*error];
  } else {
    [obj hostResolutionDone];
  }
}

/*! Processes the results of name-to-address resolution.
 */
- (void)hostResolutionDone {
  Boolean resolved;
  NSArray *addresses;

  // Find the first appropriate address
  addresses = (__bridge NSArray *)CFHostGetAddressing(self.host, &resolved);
  if (resolved && (addresses != nil)) {
    resolved = false;
    for (NSData *address in addresses) {
      const struct sockaddr *addrPtr;

      addrPtr = (const struct sockaddr *)address.bytes;
      if (address.length >= sizeof(struct sockaddr)) {
        switch (addrPtr->sa_family) {
        case AF_INET: {
          if (self.addressStyle != SimplePingAddressStyleICMPv6) {
            self.hostAddress = address;
            resolved = true;
          }
        } break;
        case AF_INET6: {
          if (self.addressStyle != SimplePingAddressStyleICMPv4) {
            self.hostAddress = address;
            resolved = true;
          }
        } break;
        }
      }
      if (resolved) {
        break;
      }
    }
  }

  // We're done resolving, so shut that down
  [self stopHostResolution];

  // If all is OK, start the traceroute, otherwise stop
  if (resolved) {
    [self startTracerouteWithHostAddress];
  } else {
    [self
        didFailWithError:[NSError
                             errorWithDomain:(NSString *)kCFErrorDomainCFNetwork
                                        code:kCFHostErrorHostNotFound
                                    userInfo:nil]];
  }
}

/*! Stops the name-to-address resolution infrastructure.
 */
- (void)stopHostResolution {
  if (self.host != NULL) {
    CFHostSetClient(self.host, NULL, NULL);
    CFHostUnscheduleFromRunLoop(self.host, CFRunLoopGetCurrent(),
                                kCFRunLoopDefaultMode);
    self.host = NULL;
  }
}

#pragma mark * Socket Management

/*! Starts the traceroute after successful host resolution.
 */
- (void)startTracerouteWithHostAddress {
  int err;
  int fd;

  assert(self.hostAddress != nil);

  // Open the socket
  fd = -1;
  err = 0;
  switch (self.hostAddressFamily) {
  case AF_INET: {
    fd = socket(AF_INET, SOCK_DGRAM, IPPROTO_ICMP);
    if (fd < 0) {
      err = errno;
    }
  } break;
  case AF_INET6: {
    fd = socket(AF_INET6, SOCK_DGRAM, IPPROTO_ICMPV6);
    if (fd < 0) {
      err = errno;
    }
  } break;
  default: {
    err = EPROTONOSUPPORT;
  } break;
  }

  if (err != 0) {
    [self didFailWithError:[NSError errorWithDomain:NSPOSIXErrorDomain
                                               code:err
                                           userInfo:nil]];
  } else {
    CFSocketContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
    CFRunLoopSourceRef rls;
    id<SimpleTracerouteDelegate> strongDelegate;

    // Wrap it in a CFSocket and schedule it on the runloop
    self.socket = (CFSocketRef)CFAutorelease(CFSocketCreateWithNative(
        NULL, fd, kCFSocketReadCallBack, SocketReadCallback, &context));
    assert(self.socket != NULL);

    // The socket will now take care of cleaning up our file descriptor
    assert(CFSocketGetSocketFlags(self.socket) & kCFSocketCloseOnInvalidate);
    fd = -1;

    // Verify TTL functionality with initial test
    if (![self setTTLForSocket:CFSocketGetNative(self.socket)
                           ttl:1
                 addressFamily:self.hostAddressFamily]) {
      NSError *error = [NSError errorWithDomain:NSPOSIXErrorDomain
                                           code:errno
                                       userInfo:@{
                                         NSLocalizedDescriptionKey :
                                             @"Failed to initialize TTL control"
                                       }];
      [self didFailWithError:error];
      return;
    }

    rls = CFSocketCreateRunLoopSource(NULL, self.socket, 0);
    assert(rls != NULL);

    CFRunLoopAddSource(CFRunLoopGetCurrent(), rls, kCFRunLoopDefaultMode);
    CFRelease(rls);

    // Mark as running and notify delegate
    self.isRunning = YES;
    self.startTime = [NSDate timeIntervalSinceReferenceDate];

    strongDelegate = self.delegate;
    if ((strongDelegate != nil) &&
        [strongDelegate respondsToSelector:@selector(simpleTraceroute:
                                                  didStartWithAddress:)]) {
      [strongDelegate simpleTraceroute:self
                   didStartWithAddress:self.hostAddress];
    }

    // Start the first hop
    [self startNextHop];
  }
  assert(fd == -1);
}

/*! The callback for our CFSocket object.
 */
static void SocketReadCallback(CFSocketRef s, CFSocketCallBackType type,
                               CFDataRef address, const void *data,
                               void *info) {
  SimpleTraceroute *obj;

  obj = (__bridge SimpleTraceroute *)info;
  assert([obj isKindOfClass:[SimpleTraceroute class]]);

#pragma unused(s)
  assert(s == obj.socket);
#pragma unused(type)
  assert(type == kCFSocketReadCallBack);
#pragma unused(address)
  assert(address == nil);
#pragma unused(data)
  assert(data == nil);

  [obj readData];
}

/*! Stops the socket infrastructure.
 */
- (void)stopSocket {
  if (self.socket != NULL) {
    CFSocketInvalidate(self.socket);
    self.socket = NULL;
  }
}

#pragma mark * TTL Control Methods

/*! Validate the validity of TTL value
 *  \param ttl The TTL value to validate
 *  \returns Returns YES if valid, NO if invalid
 */
- (BOOL)isValidTTL:(uint8_t)ttl {
  // TTL value must be in the range 1-255
  // 0 is invalid (will cause packet to expire immediately)
  return (ttl >= 1 && ttl <= 255);
}

/*! Get the protocol level corresponding to the current address family
 *  \param addressFamily Address family
 *  \returns Protocol level constant, returns -1 on failure
 */
- (int)getProtocolLevelForAddressFamily:(sa_family_t)addressFamily {
  switch (addressFamily) {
  case AF_INET:
    return IPPROTO_IP;
  case AF_INET6:
    return IPPROTO_IPV6;
  default:
    return -1;
  }
}

/*! Get the socket option corresponding to the current address family
 *  \param addressFamily Address family
 *  \returns Socket option constant, returns -1 on failure
 */
- (int)getSocketOptionForAddressFamily:(sa_family_t)addressFamily {
  switch (addressFamily) {
  case AF_INET:
    return IP_TTL;
  case AF_INET6:
    return IPV6_UNICAST_HOPS;
  default:
    return -1;
  }
}

/*! Set TTL value for the specified socket
 *  \param socketFD The socket file descriptor to set
 *  \param ttl TTL value (1-255)
 *  \param addressFamily Address family (AF_INET or AF_INET6)
 *  \returns Returns YES if successful, NO if failed
 */
- (BOOL)setTTLForSocket:(int)socketFD
                    ttl:(uint8_t)ttl
          addressFamily:(sa_family_t)addressFamily {
  // 1. Parameter validation
  if (socketFD < 0) {
    NSLog(@"SimpleTraceroute: Invalid socket file descriptor: %d", socketFD);
    return NO;
  }

  if (![self isValidTTL:ttl]) {
    NSLog(@"SimpleTraceroute: Invalid TTL value: %d", ttl);
    return NO;
  }

  // 2. Get the corresponding socket option
  int level = [self getProtocolLevelForAddressFamily:addressFamily];
  int option = [self getSocketOptionForAddressFamily:addressFamily];

  if (level == -1 || option == -1) {
    NSLog(@"SimpleTraceroute: Unsupported address family: %d", addressFamily);
    return NO;
  }

  // 3. Set socket option
  // Use int for setsockopt value
  int hop = (int)ttl;
  socklen_t hopLen = (socklen_t)sizeof(hop);
  int result = setsockopt(socketFD, level, option, &hop, hopLen);
  if (result != 0) {
    NSLog(@"SimpleTraceroute: Failed to set TTL to %d: %s", ttl,
          strerror(errno));
    NSLog(@"SimpleTraceroute: Failed to set TTL to %d: %s (level=%d, opt=%d)",
          hop, strerror(errno), level, option);
    return NO;
  }

  NSLog(@"SimpleTraceroute: Successfully set TTL to %d for address family %d",
        ttl, addressFamily);
  return YES;
}

/*! Get the current socket's TTL value
 *  \param socketFD Socket file descriptor
 *  \param addressFamily Address family
 *  \returns Current TTL value, returns 0 on failure
 */
- (uint8_t)getTTLForSocket:(int)socketFD
             addressFamily:(sa_family_t)addressFamily {
  // 1. Parameter validation
  if (socketFD < 0) {
    NSLog(@"SimpleTraceroute: Invalid socket file descriptor: %d", socketFD);
    return 0;
  }

  // 2. Get the corresponding socket option
  int level = [self getProtocolLevelForAddressFamily:addressFamily];
  int option = [self getSocketOptionForAddressFamily:addressFamily];

  if (level == -1 || option == -1) {
    NSLog(@"SimpleTraceroute: Unsupported address family: %d", addressFamily);
    return 0;
  }

  // 3. Get socket option value
  uint8_t ttl = 0;
  socklen_t ttlSize = sizeof(ttl);
  int result = getsockopt(socketFD, level, option, &ttl, &ttlSize);

  if (result != 0) {
    NSLog(@"SimpleTraceroute: Failed to get TTL: %s", strerror(errno));
    return 0;
  }

  return ttl;
}

/*! Set TTL for the current hop and send probe packet
 *  \param hop Hop number (1-255)
 *  \returns Returns YES if successful, NO if failed
 */
- (BOOL)setTTLForCurrentHop:(uint8_t)hop {
  // Get socket file descriptor
  if (self.socket == NULL) {
    NSLog(@"SimpleTraceroute: No socket available for TTL setting");
    return NO;
  }

  int socketFD = CFSocketGetNative(self.socket);
  if (socketFD < 0) {
    NSLog(@"SimpleTraceroute: Invalid socket for TTL setting");
    return NO;
  }

  // Set TTL
  return [self setTTLForSocket:socketFD
                           ttl:hop
                 addressFamily:self.hostAddressFamily];
}

#pragma mark * Packet Sending Methods

/*! Sequence number management - get next sequence number
 *  \returns New sequence number
 */
- (uint16_t)getNextSequenceNumber {
  uint16_t current = self.nextSequenceNumber;

  // Increment sequence number
  self.nextSequenceNumber++;

  // Handle wraparound (from 65535 to 0)
  if (self.nextSequenceNumber == 0) {
    self.nextSequenceNumberHasWrapped = YES;
  }

  return current;
}

/*! Record probe packet information
 *  \param sequenceNumber Sequence number
 *  \param hop Hop number
 *  \param probeIndex Probe index
 *  \param timestamp Send timestamp
 */
- (void)recordProbe:(uint16_t)sequenceNumber
                hop:(uint8_t)hop
         probeIndex:(uint8_t)probeIndex
          timestamp:(NSTimeInterval)timestamp {
  NSDictionary *probeInfo = @{
    @"hop" : @(hop),
    @"probeIndex" : @(probeIndex),
    @"timestamp" : @(timestamp),
    @"sequenceNumber" : @(sequenceNumber)
  };

  NSString *key = [NSString stringWithFormat:@"%d", sequenceNumber];
  self.pendingProbes[key] = probeInfo;

  // Clean up expired probe records (optional optimization)
  [self cleanupExpiredProbes];
}

/*! Find probe information by sequence number
 *  \param sequenceNumber Sequence number
 *  \returns Probe information dictionary, returns nil if not found
 */
- (nullable NSDictionary *)probeInfoForSequenceNumber:(uint16_t)sequenceNumber {
  NSString *key = [NSString stringWithFormat:@"%d", sequenceNumber];
  return self.pendingProbes[key];
}

/*! Clean up expired probe records
 */
- (void)cleanupExpiredProbes {
  // Clean up probe records that exceed a certain time to prevent memory leaks
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  NSTimeInterval maxAge =
      self.timeout * 2; // Double timeout as cleanup threshold

  NSMutableArray *keysToRemove = [NSMutableArray array];

  for (NSString *key in self.pendingProbes) {
    NSDictionary *probeInfo = self.pendingProbes[key];
    NSTimeInterval timestamp = [probeInfo[@"timestamp"] doubleValue];

    if (now - timestamp > maxAge) {
      [keysToRemove addObject:key];
    }
  }

  for (NSString *key in keysToRemove) {
    [self.pendingProbes removeObjectForKey:key];
  }

  if (keysToRemove.count > 0) {
    NSLog(@"Cleaned up %lu expired probe records",
          (unsigned long)keysToRemove.count);
  }
}

/*! Calculate ICMP checksum
 *  \param data ICMP packet data
 *  \returns Calculated checksum
 */
- (uint16_t)calculateICMPChecksum:(NSData *)data {
  const uint16_t *words = (const uint16_t *)data.bytes;
  size_t wordCount = data.length / 2;
  uint32_t sum = 0;

  // Calculate the sum of all 16-bit words
  for (size_t i = 0; i < wordCount; i++) {
    sum += ntohs(words[i]);
  }

  // Handle odd bytes
  if (data.length % 2 == 1) {
    uint8_t lastByte = ((const uint8_t *)data.bytes)[data.length - 1];
    sum += lastByte << 8;
  }

  // Handle carry
  while (sum >> 16) {
    sum = (sum & 0xFFFF) + (sum >> 16);
  }

  // Invert to get checksum
  return htons(~sum);
}

/*! Create payload data for probe packet
 *  \param timestamp Timestamp
 *  \param hop Hop number
 *  \param probeIndex Probe index
 *  \returns Payload data
 */
- (NSData *)createProbePayload:(NSTimeInterval)timestamp
                           hop:(uint8_t)hop
                    probeIndex:(uint8_t)probeIndex {
  // Create payload containing timestamp and probe information
  NSMutableData *payload = [NSMutableData dataWithCapacity:32];

  // Add timestamp (8 bytes)
  [payload appendBytes:&timestamp length:sizeof(timestamp)];

  // Add hop information (1 byte)
  [payload appendBytes:&hop length:sizeof(hop)];

  // Add probe index (1 byte)
  [payload appendBytes:&probeIndex length:sizeof(probeIndex)];

  // Add padding data to reach minimum size (optional)
  const size_t minPayloadSize = 16;
  while (payload.length < minPayloadSize) {
    uint8_t padding = 0x00;
    [payload appendBytes:&padding length:1];
  }

  return payload;
}

/*! Create IPv4 ICMP Echo Request packet
 *  \param identifier Identifier
 *  \param sequenceNumber Sequence number
 *  \param payload Payload data
 *  \returns ICMP packet data
 */
- (NSData *)createIPv4ICMPPacket:(uint16_t)identifier
                  sequenceNumber:(uint16_t)sequenceNumber
                         payload:(NSData *)payload {
  // ICMP header size
  const size_t headerSize = 8;
  const size_t totalSize = headerSize + payload.length;

  // Create packet buffer
  NSMutableData *packet = [NSMutableData dataWithLength:totalSize];
  uint8_t *bytes = (uint8_t *)packet.mutableBytes;

  // Fill ICMP header
  bytes[0] = ICMP_ECHO;                             // Type: Echo Request (8)
  bytes[1] = 0;                                     // Code: 0
  *(uint16_t *)(bytes + 2) = 0;                     // Checksum: set to 0 first
  *(uint16_t *)(bytes + 4) = htons(identifier);     // Identifier
  *(uint16_t *)(bytes + 6) = htons(sequenceNumber); // Sequence Number

  // Copy payload data
  if (payload.length > 0) {
    memcpy(bytes + headerSize, payload.bytes, payload.length);
  }

  // Calculate and set checksum
  uint16_t checksum = [self calculateICMPChecksum:packet];
  *(uint16_t *)(bytes + 2) = checksum;

  return packet;
}

/*! Create IPv6 ICMPv6 Echo Request packet
 *  \param identifier Identifier
 *  \param sequenceNumber Sequence number
 *  \param payload Payload data
 *  \returns ICMPv6 packet data
 */
- (NSData *)createIPv6ICMPPacket:(uint16_t)identifier
                  sequenceNumber:(uint16_t)sequenceNumber
                         payload:(NSData *)payload {
  // ICMPv6 header size
  const size_t headerSize = 8;
  const size_t totalSize = headerSize + payload.length;

  // Create packet buffer
  NSMutableData *packet = [NSMutableData dataWithLength:totalSize];
  uint8_t *bytes = (uint8_t *)packet.mutableBytes;

  // Fill ICMPv6 header
  bytes[0] = ICMP6_ECHO_REQUEST; // Type: Echo Request (128)
  bytes[1] = 0;                  // Code: 0
  *(uint16_t *)(bytes + 2) = 0;  // Checksum: IPv6 calculated by kernel
  *(uint16_t *)(bytes + 4) = htons(identifier);     // Identifier
  *(uint16_t *)(bytes + 6) = htons(sequenceNumber); // Sequence Number

  // Copy payload data
  if (payload.length > 0) {
    memcpy(bytes + headerSize, payload.bytes, payload.length);
  }

  // IPv6 checksum is automatically calculated by the kernel, no need to set
  // manually here

  return packet;
}

/*! Create ICMP probe packet
 *  \param ttl TTL value
 *  \param sequenceNumber Sequence number
 *  \param addressFamily Address family (AF_INET or AF_INET6)
 *  \returns Constructed ICMP packet data, returns nil on failure
 */
- (nullable NSData *)createICMPPacketWithTTL:(uint8_t)ttl
                              sequenceNumber:(uint16_t)sequenceNumber
                               addressFamily:(sa_family_t)addressFamily {
  // Create payload data (containing timestamp, etc.)
  NSTimeInterval timestamp = [NSDate timeIntervalSinceReferenceDate];
  NSData *payload = [self createProbePayload:timestamp hop:ttl probeIndex:0];

  // Create corresponding ICMP packet based on address family
  switch (addressFamily) {
  case AF_INET:
    return [self createIPv4ICMPPacket:self.identifier
                       sequenceNumber:sequenceNumber
                              payload:payload];
  case AF_INET6:
    return [self createIPv6ICMPPacket:self.identifier
                       sequenceNumber:sequenceNumber
                              payload:payload];
  default:
    NSLog(@"SimpleTraceroute: Unsupported address family for ICMP packet: %d",
          addressFamily);
    return nil;
  }
}

/*! Send ICMP packet to target address
 *  \param packet ICMP packet data
 *  \param address Target address
 *  \returns Returns YES if successful, NO if failed
 */
- (BOOL)sendICMPPacket:(NSData *)packet toAddress:(NSData *)address {
  if (self.socket == NULL) {
    NSLog(@"SimpleTraceroute: No socket available for sending");
    return NO;
  }

  // Get socket file descriptor
  int socketFD = CFSocketGetNative(self.socket);
  if (socketFD < 0) {
    NSLog(@"SimpleTraceroute: Invalid socket file descriptor");
    return NO;
  }

  // Send packet
  const struct sockaddr *addr = (const struct sockaddr *)address.bytes;
  ssize_t bytesSent = sendto(socketFD, packet.bytes, packet.length, 0, addr,
                             (socklen_t)address.length);

  if (bytesSent < 0) {
    NSLog(@"SimpleTraceroute: Failed to send ICMP packet: %s", strerror(errno));
    return NO;
  }

  if (bytesSent != (ssize_t)packet.length) {
    NSLog(@"SimpleTraceroute: Partial send: %zd of %zu bytes", bytesSent,
          packet.length);
    return NO;
  }

  return YES;
}

/*! Send single probe packet
 *  \param hop Hop number
 *  \param probeIndex Current hop's probe packet index (0-based)
 *  \returns Returns YES if successful, NO if failed
 */
- (BOOL)sendProbeForHop:(uint8_t)hop probeIndex:(uint8_t)probeIndex {
  // 1. Get next sequence number
  uint16_t sequenceNumber = [self getNextSequenceNumber];

  // 2. Record send time
  NSTimeInterval timestamp = [NSDate timeIntervalSinceReferenceDate];

  // 3. Create ICMP packet
  NSData *packet = [self createICMPPacketWithTTL:hop
                                  sequenceNumber:sequenceNumber
                                   addressFamily:self.hostAddressFamily];
  if (packet == nil) {
    NSLog(
        @"SimpleTraceroute: Failed to create ICMP packet for hop %d, probe %d",
        hop, probeIndex);
    return NO;
  }

  // 4. Send packet
  if (![self sendICMPPacket:packet toAddress:self.hostAddress]) {
    NSLog(@"SimpleTraceroute: Failed to send ICMP packet for hop %d, probe %d",
          hop, probeIndex);
    return NO;
  }

  // 5. Record probe information
  [self recordProbe:sequenceNumber
                hop:hop
         probeIndex:probeIndex
          timestamp:timestamp];

  NSLog(@"SimpleTraceroute: Sent probe: hop=%d, index=%d, seq=%d", hop,
        probeIndex, sequenceNumber);
  return YES;
}

/*! Send probe packets for the specified hop
 *  \param hop Hop number (1-255)
 *  \details Send multiple probe packets according to probesPerHop setting
 */
- (void)sendProbesForHop:(uint8_t)hop {
  NSLog(@"SimpleTraceroute: Sending %d probes for hop %d", self.probesPerHop,
        hop);

  // Ensure TTL is set correctly
  if (![self setTTLForCurrentHop:hop]) {
    NSError *error = [NSError
        errorWithDomain:NSPOSIXErrorDomain
                   code:errno
               userInfo:@{
                 NSLocalizedDescriptionKey : [NSString
                     stringWithFormat:@"Failed to set TTL for hop %d", hop]
               }];
    [self didFailWithError:error];
    return;
  }

  // Send multiple probe packets
  for (uint8_t probeIndex = 0; probeIndex < self.probesPerHop; probeIndex++) {
    if (![self sendProbeForHop:hop probeIndex:probeIndex]) {
      NSLog(@"SimpleTraceroute: Failed to send probe %d for hop %d", probeIndex,
            hop);
      // Continue sending other probes without interrupting the entire process
    }

    // Small interval between probes (to avoid network congestion)
    if (probeIndex < self.probesPerHop - 1) {
      usleep(10000); // 10ms interval
    }
  }

  // Start timeout timer
  [self startTimeoutTimerForHop:hop];
  NSLog(
      @"SimpleTraceroute: All probes sent for hop %d, waiting for responses...",
      hop);
}

#pragma mark * Control Methods

/*! Reset traceroute state to initial values
 */
- (void)resetTracerouteState {
  self.hostAddress = nil;
  self.currentHop = 0;
  self.nextSequenceNumber = 0;
  self.nextSequenceNumberHasWrapped = NO;
  [self.pendingProbes removeAllObjects];
  [self.completedHops removeAllObjects];
  self.startTime = 0;
}

/*! Check if current object state allows starting
 *  \returns If can start returns YES, otherwise returns NO
 */
- (BOOL)canStart {
  return !self.isRunning && self.host == NULL && self.socket == NULL &&
         self.hostAddress == nil;
}

/*! Validate traceroute parameters
 *  \returns If parameters are valid returns nil, otherwise returns NSError
 * describing the error
 */
- (nullable NSError *)validateTracerouteParameters {
  if (self.hostName.length == 0) {
    return [NSError
        errorWithDomain:NSInvalidArgumentException
                   code:-1
               userInfo:@{
                 NSLocalizedDescriptionKey : @"Host name cannot be empty"
               }];
  }

  if (self.maxHops < 1 || self.maxHops > 255) {
    return [NSError errorWithDomain:NSInvalidArgumentException
                               code:-2
                           userInfo:@{
                             NSLocalizedDescriptionKey :
                                 @"Max hops must be between 1 and 255"
                           }];
  }

  if (self.timeout <= 0 || self.timeout > 60) {
    return [NSError errorWithDomain:NSInvalidArgumentException
                               code:-3
                           userInfo:@{
                             NSLocalizedDescriptionKey :
                                 @"Timeout must be between 0 and 60 seconds"
                           }];
  }

  if (self.probesPerHop < 1 || self.probesPerHop > 10) {
    return [NSError errorWithDomain:NSInvalidArgumentException
                               code:-4
                           userInfo:@{
                             NSLocalizedDescriptionKey :
                                 @"Probes per hop must be between 1 and 10"
                           }];
  }

  return nil;
}

/*! Ensure operations are performed on the correct thread
 */
- (void)ensureMainThread:(void (^)(void))block {
  if ([NSThread isMainThread]) {
    block();
  } else {
    dispatch_async(dispatch_get_main_queue(), block);
  }
}

- (void)start {
  Boolean success;
  CFHostClientContext context = {0, (__bridge void *)(self), NULL, NULL, NULL};
  CFStreamError streamError;
  NSError *validationError;

  // 1. Input validation and state checking
  if (self.isRunning) {
    NSLog(@"SimpleTraceroute: Cannot start - already running");
    return;
  }

  validationError = [self validateTracerouteParameters];
  if (validationError != nil) {
    [self didFailWithError:validationError];
    return;
  }

  if (![self canStart]) {
    [self
        didFailWithError:
            [NSError errorWithDomain:NSInternalInconsistencyException
                                code:-5
                            userInfo:@{
                              NSLocalizedDescriptionKey :
                                  @"Object is in an invalid state for starting"
                            }]];
    return;
  }

  // 2. Reset state
  [self resetTracerouteState];

  assert(self.host == NULL);
  assert(self.hostAddress == nil);
  assert(!self.isRunning);

  // Create CFHost for name resolution
  self.host = (CFHostRef)CFAutorelease(
      CFHostCreateWithName(NULL, (__bridge CFStringRef)self.hostName));
  assert(self.host != NULL);

  CFHostSetClient(self.host, HostResolveCallback, &context);
  CFHostScheduleWithRunLoop(self.host, CFRunLoopGetCurrent(),
                            kCFRunLoopDefaultMode);

  success =
      CFHostStartInfoResolution(self.host, kCFHostAddresses, &streamError);
  if (!success) {
    [self didFailWithHostStreamError:streamError];
  }
}

- (void)stop {
  // 1. Thread safety check
  if (!self.isRunning && self.host == NULL && self.socket == NULL) {
    return; // Already stopped, safe return
  }

  // 2. Immediately mark as non-running state to prevent race conditions
  self.isRunning = NO;

  // 3. Clean up resources in order
  [self stopTimeoutTimer];   // Stop timer first
  [self stopHostResolution]; // Stop host resolution
  [self stopSocket];         // Stop socket

  // 4. Clean up state
  [self resetTracerouteState];
}

#pragma mark * Traceroute Implementation (Placeholder)

/*! Starts tracing the next hop.
 */
- (void)startNextHop {
  // 1. Increment current hop
  self.currentHop++;

  // 2. Check if exceeds maximum hops
  if (self.currentHop > self.maxHops) {
    [self finishTraceroute];
    return;
  }

  NSLog(
      @"SimpleTraceroute: Starting hop %d with TTL control and packet sending",
      self.currentHop);

  // 3. Set TTL for current hop (already handled in sendProbesForHop)
  // 4. Send probe packets (real implementation)
  [self sendProbesForHop:self.currentHop];

  // Note: No longer automatically proceed to next hop, wait for response or
  // timeout Next hop will be triggered after receiving response or timeout
}

/*! Completes the traceroute.
 */
- (void)finishTraceroute {
  id<SimpleTracerouteDelegate> strongDelegate;

  // Create empty hops array for now - this would need to be populated with
  // actual hop data
  NSArray *hops = @[];

  // Create result object
  TracerouteResult *result = [[TracerouteResult alloc]
      initWithTargetHostname:self.hostName
               targetAddress:self.hostAddress
                     maxHops:self.maxHops
                  actualHops:self.currentHop
                   totalTime:[NSDate timeIntervalSinceReferenceDate] -
                             self.startTime
                        hops:hops
               reachedTarget:NO]; // This would need proper logic

  strongDelegate = self.delegate;
  if ((strongDelegate != nil) &&
      [strongDelegate respondsToSelector:@selector(simpleTraceroute:
                                                didFinishWithResult:)]) {
    [strongDelegate simpleTraceroute:self didFinishWithResult:result];
  }

  [self stop];
}

#pragma mark * Packet Parsing Methods

// Locate the start of the ICMP header inside a received packet.
// For IPv4, the kernel often includes the IP header; for IPv6 ping sockets,
// ICMPv6 usually starts at 0.
- (BOOL)locateICMPHeaderInPacket:(NSData *)packet
                   addressFamily:(sa_family_t)addressFamily
                      icmpOffset:(size_t *)icmpOffset {
  const uint8_t *bytes = (const uint8_t *)packet.bytes;
  size_t len = packet.length;

  if (len < 8) {
    return NO;
  }

  if (addressFamily == AF_INET) {
    // If it looks like an IPv4 header (version nibble == 4), skip it.
    if (len >= 20 && (bytes[0] >> 4) == 4) {
      const struct ip *ipHeader = (const struct ip *)bytes;
      size_t ipHeaderLen = (size_t)(ipHeader->ip_hl) * 4;
      if (ipHeaderLen < 20 || ipHeaderLen > len || len < ipHeaderLen + 8) {
        return NO;
      }
      *icmpOffset = ipHeaderLen;
      return YES;
    } else {
      // Bare ICMP (no IP header)
      *icmpOffset = 0;
      return YES;
    }
  } else if (addressFamily == AF_INET6) {
    // ICMPv6 from ping sockets is typically bare ICMPv6.
    *icmpOffset = 0;
    return YES;
  }

  return NO;
}

/*! Read response data from socket
 *  \param socketFD socket file descriptor
 *  \param responseData output response data
 *  \param sourceAddress output source address
 *  \returns Returns YES if read successful, NO if failed
 */
- (BOOL)readResponseFromSocket:(int)socketFD
                  responseData:(NSData **)responseData
                 sourceAddress:(NSData **)sourceAddress {
  uint8_t buffer[1024]; // Response buffer
  struct sockaddr_storage addr;
  socklen_t addrLen = sizeof(addr);

  // Receive data
  ssize_t bytesReceived = recvfrom(socketFD, buffer, sizeof(buffer), 0,
                                   (struct sockaddr *)&addr, &addrLen);

  if (bytesReceived < 0) {
    if (errno != EAGAIN && errno != EWOULDBLOCK) {
      NSLog(@"SimpleTraceroute: Failed to receive data: %s", strerror(errno));
    }
    return NO;
  }

  if (bytesReceived == 0) {
    NSLog(@"SimpleTraceroute: Connection closed by peer");
    return NO;
  }

  // Create data object
  *responseData = [NSData dataWithBytes:buffer length:bytesReceived];
  *sourceAddress = [NSData dataWithBytes:&addr length:addrLen];

  NSLog(@"SimpleTraceroute: Received %zd bytes from %@", bytesReceived,
        [self addressStringFromSockaddr:*sourceAddress]);

  return YES;
}

/*! Validate ICMP response packet validity
 *  \param responseData ICMP response data
 *  \param addressFamily address family
 *  \returns Returns YES if validation passes, NO if fails
 */
- (BOOL)validateICMPResponse:(NSData *)responseData
               addressFamily:(sa_family_t)addressFamily {
  // 1. Basic size check
  size_t icmpOffset = 0;
  if (![self locateICMPHeaderInPacket:responseData
                        addressFamily:addressFamily
                           icmpOffset:&icmpOffset]) {
    NSLog(@"SimpleTraceroute: Cannot locate ICMP header");
    return NO;
  }

  // 2. Get ICMP type
  const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  uint8_t icmpType = bytes[icmpOffset];

  // 3. Check if ICMP type is what we expect
  BOOL isValidType = NO;

  if (addressFamily == AF_INET) {
    isValidType = (icmpType == ICMP_TIMXCEED || icmpType == ICMP_ECHOREPLY);
  } else if (addressFamily == AF_INET6) {
    isValidType =
        (icmpType == ICMP6_TIME_EXCEEDED || icmpType == ICMP6_ECHO_REPLY);
  }

  if (!isValidType) {
    NSLog(@"SimpleTraceroute: Unexpected ICMP type: %d for address family %d",
          icmpType, addressFamily);
    return NO;
  }

  if (!isValidType) {
    NSLog(@"SimpleTraceroute: Unexpected ICMP type: %d for address family %d",
          icmpType, addressFamily);
    return NO;
  }

  NSLog(@"SimpleTraceroute: Valid ICMP response, type: %d", icmpType);
  return YES;
}

/*! Identify ICMP response type
 *  \param responseData ICMP response data
 *  \param addressFamily address family
 *  \returns ICMP type, returns -1 if unknown
 */
- (int)identifyICMPType:(NSData *)responseData
          addressFamily:(sa_family_t)addressFamily {
  //    if (responseData.length < 1) {
  //        return -1;
  //    }
  //
  //    const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  //    return bytes[0]; // ICMP type is in the first byte
  size_t icmpOffset = 0;
  if (![self locateICMPHeaderInPacket:responseData
                        addressFamily:addressFamily
                           icmpOffset:&icmpOffset]) {
    return -1;
  }
  const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  return bytes[icmpOffset];
}

/*! Check if it's a Time Exceeded response
 *  \param icmpType ICMP type
 *  \param addressFamily address family
 *  \returns Returns YES if it's Time Exceeded
 */
- (BOOL)isTimeExceededResponse:(int)icmpType
                 addressFamily:(sa_family_t)addressFamily {
  switch (addressFamily) {
  case AF_INET:
    return (icmpType == ICMP_TIMXCEED); // Type 11
  case AF_INET6:
    return (icmpType == ICMP6_TIME_EXCEEDED); // Type 3
  default:
    return NO;
  }
}

/*! Check if it's an Echo Reply response
 *  \param icmpType ICMP type
 *  \param addressFamily address family
 *  \returns Returns YES if it's Echo Reply
 */
- (BOOL)isEchoReplyResponse:(int)icmpType
              addressFamily:(sa_family_t)addressFamily {
  switch (addressFamily) {
  case AF_INET:
    return (icmpType == ICMP_ECHOREPLY); // Type 0
  case AF_INET6:
    return (icmpType == ICMP6_ECHO_REPLY); // Type 129
  default:
    return NO;
  }
}

/*! Extract original sequence number from Time Exceeded response
 *  \param responseData Time Exceeded response data
 *  \param addressFamily address family
 *  \returns Original sequence number, returns 0 on failure
 */
- (uint16_t)extractSequenceNumberFromTimeExceeded:(NSData *)responseData
                                    addressFamily:(sa_family_t)addressFamily {
  // Time Exceeded contains original IP header + ICMP header
  // Need to skip ICMP Time Exceeded header (8 bytes) and IP header to find
  // original ICMP packet

  const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  size_t len = responseData.length;

  size_t icmpOffset = 0;
  if (![self locateICMPHeaderInPacket:responseData
                        addressFamily:addressFamily
                           icmpOffset:&icmpOffset]) {
    return 0;
  }

  size_t offset = icmpOffset + 8; // skip ICMP Time Exceeded header

  if (addressFamily == AF_INET) {
    if (len < offset + 20) {
      NSLog(@"SimpleTraceroute: Time Exceeded too small for IPv4 inner IP");
      return 0;
    }
    const struct ip *innerIP = (const struct ip *)(bytes + offset);
    size_t innerIPLen = (size_t)(innerIP->ip_hl) * 4;
    if (innerIPLen < 20 || len < offset + innerIPLen + 8) {
      NSLog(@"SimpleTraceroute: Not enough data for inner ICMP header");
      return 0;
    }
    offset += innerIPLen; // now at original ICMP header
    uint16_t sequence = ntohs(*(const uint16_t *)(bytes + offset + 6));
    return sequence;

  } else if (addressFamily == AF_INET6) {
    // Included invoking packet starts with IPv6 header (40 bytes)
    if (len < offset + 40 + 8) {
      NSLog(@"SimpleTraceroute: Time Exceeded too small for IPv6 inner ICMPv6");
      return 0;
    }
    offset += 40; // skip inner IPv6 header
    uint16_t sequence = ntohs(*(const uint16_t *)(bytes + offset + 6));
    return sequence;
  }

  return 0;
}

/*! Extract sequence number from Echo Reply response
 *  \param responseData Echo Reply response data
 *  \param addressFamily address family
 *  \returns Sequence number, returns 0 on failure
 */
- (uint16_t)extractSequenceNumberFromEchoReply:(NSData *)responseData
                                 addressFamily:(sa_family_t)addressFamily {
  // Echo Reply sequence number is directly at offset 6 in ICMP header
  size_t icmpOffset = 0;
  if (![self locateICMPHeaderInPacket:responseData
                        addressFamily:addressFamily
                           icmpOffset:&icmpOffset]) {
    NSLog(@"SimpleTraceroute: Echo Reply too small");
    return 0;
  }

  const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  if (responseData.length < icmpOffset + 8) {
    NSLog(@"SimpleTraceroute: Echo Reply response too small");
    return 0;
  }

  uint16_t sequence = ntohs(*(const uint16_t *)(bytes + icmpOffset + 6));
  NSLog(@"SimpleTraceroute: Extracted sequence %d from Echo Reply", sequence);
  return sequence;
}

/*! Extract timestamp from response payload
 *  \param responseData response data
 *  \param addressFamily address family
 *  \returns Timestamp, returns 0 on failure
 */
- (NSTimeInterval)extractTimestampFromResponse:(NSData *)responseData
                                 addressFamily:(sa_family_t)addressFamily {
  // For Echo Reply, timestamp is at the beginning of payload
  // For Time Exceeded, need to extract original payload

  const uint8_t *bytes = (const uint8_t *)responseData.bytes;
  size_t len = responseData.length;

  size_t icmpOffset = 0;
  if (![self locateICMPHeaderInPacket:responseData
                        addressFamily:addressFamily
                           icmpOffset:&icmpOffset]) {
    return 0;
  }

  int icmpType = [self identifyICMPType:responseData
                          addressFamily:addressFamily];

  if ((addressFamily == AF_INET && icmpType == ICMP_ECHOREPLY) ||
      (addressFamily == AF_INET6 && icmpType == ICMP6_ECHO_REPLY)) {
    size_t payloadOffset = icmpOffset + 8;
    if (len < payloadOffset + sizeof(NSTimeInterval)) {
      NSLog(@"SimpleTraceroute: Response too small to contain timestamp");
      return 0;
    }
    NSTimeInterval ts = 0;
    memcpy(&ts, bytes + payloadOffset, sizeof(ts));
    return ts;
  }

  if ((addressFamily == AF_INET && icmpType == ICMP_TIMXCEED) ||
      (addressFamily == AF_INET6 && icmpType == ICMP6_TIME_EXCEEDED)) {
    // Locate original ICMP payload to read our timestamp (we put it first).
    size_t offset = icmpOffset + 8;

    if (addressFamily == AF_INET) {
      if (len < offset + 20)
        return 0;
      const struct ip *innerIP = (const struct ip *)(bytes + offset);
      size_t innerIPLen = (size_t)(innerIP->ip_hl) * 4;
      if (innerIPLen < 20 ||
          len < offset + innerIPLen + 8 + sizeof(NSTimeInterval))
        return 0;
      offset += innerIPLen; // inner ICMP header
      offset += 8;          // inner ICMP header size
    } else {
      // IPv6: inner IPv6 header (40) + inner ICMPv6 header (8)
      if (len < offset + 40 + 8 + sizeof(NSTimeInterval))
        return 0;
      offset += 40 + 8;
    }

    NSTimeInterval ts = 0;
    memcpy(&ts, bytes + offset, sizeof(ts));
    return ts;
  }

  return 0;
}

/*! Convert sockaddr structure to readable address string
 *  \param address sockaddr address data
 *  \returns Address string, returns nil on failure
 */
- (nullable NSString *)addressStringFromSockaddr:(NSData *)address {
  if (address.length < sizeof(struct sockaddr)) {
    return nil;
  }

  const struct sockaddr *addr = (const struct sockaddr *)address.bytes;
  char addressString[INET6_ADDRSTRLEN];

  switch (addr->sa_family) {
  case AF_INET: {
    const struct sockaddr_in *addr4 = (const struct sockaddr_in *)addr;
    if (inet_ntop(AF_INET, &addr4->sin_addr, addressString, INET_ADDRSTRLEN)) {
      return [NSString stringWithUTF8String:addressString];
    }
    break;
  }
  case AF_INET6: {
    const struct sockaddr_in6 *addr6 = (const struct sockaddr_in6 *)addr;
    if (inet_ntop(AF_INET6, &addr6->sin6_addr, addressString,
                  INET6_ADDRSTRLEN)) {
      return [NSString stringWithUTF8String:addressString];
    }
    break;
  }
  default:
    NSLog(@"SimpleTraceroute: Unsupported address family: %d", addr->sa_family);
    break;
  }

  return nil;
}

/*! Match corresponding probe packet by sequence number
 *  \param sequenceNumber sequence number
 *  \returns Matched probe information, returns nil if not found
 */
- (nullable NSDictionary *)matchProbeWithSequenceNumber:
    (uint16_t)sequenceNumber {
  NSString *key = [NSString stringWithFormat:@"%d", sequenceNumber];
  NSDictionary *probeInfo = self.pendingProbes[key];

  if (probeInfo != nil) {
    NSLog(@"SimpleTraceroute: Matched probe for sequence %d", sequenceNumber);
    // Remove matched probe from pending list
    [self.pendingProbes removeObjectForKey:key];
  }

  return probeInfo;
}

/*! Create hop result structure
 *  \param hopNumber hop number
 *  \param routerAddress router address
 *  \param roundTripTime round trip time
 *  \param isDestination whether it's the destination host
 *  \returns hop result structure
 */
- (TracerouteHopResult *)createHopResult:(uint8_t)hopNumber
                           routerAddress:(nullable NSString *)routerAddress
                           roundTripTime:(NSTimeInterval)roundTripTime
                           isDestination:(BOOL)isDestination {
  TracerouteHopResult *result = [[TracerouteHopResult alloc] init];
  result.hopNumber = hopNumber;
  result.routerAddress = routerAddress;
  result.roundTripTime = roundTripTime;
  result.isDestination = isDestination;
  result.isTimeout = NO;
  result.timestamp = [NSDate date];

  return result;
}

/*! Parse ICMP response packet
 *  \param responseData ICMP response data
 *  \param sourceAddress response source address
 *  \returns Parse result, returns nil on failure
 */
- (nullable TracerouteHopResult *)parseICMPResponse:(NSData *)responseData
                                        fromAddress:(NSData *)sourceAddress {
  // 1. Identify ICMP type
  int icmpType = [self identifyICMPType:responseData
                          addressFamily:self.hostAddressFamily];

  // 2. Extract sequence number
  uint16_t sequenceNumber = 0;
  BOOL isDestination = NO;

  if ([self isTimeExceededResponse:icmpType
                     addressFamily:self.hostAddressFamily]) {
    // Time Exceeded - from intermediate router
    sequenceNumber =
        [self extractSequenceNumberFromTimeExceeded:responseData
                                      addressFamily:self.hostAddressFamily];
    isDestination = NO;
    NSLog(@"SimpleTraceroute: Time Exceeded response from intermediate router");
  } else if ([self isEchoReplyResponse:icmpType
                         addressFamily:self.hostAddressFamily]) {
    // Echo Reply - from destination host
    sequenceNumber =
        [self extractSequenceNumberFromEchoReply:responseData
                                   addressFamily:self.hostAddressFamily];
    isDestination = YES;
    NSLog(@"SimpleTraceroute: Echo Reply response from destination");
  } else {
    NSLog(@"SimpleTraceroute: Unknown ICMP type: %d", icmpType);
    return nil;
  }

  if (sequenceNumber == 0) {
    NSLog(@"SimpleTraceroute: Failed to extract sequence number");
    return nil;
  }

  // 3. Match probe packet
  NSDictionary *probeInfo = [self matchProbeWithSequenceNumber:sequenceNumber];
  if (probeInfo == nil) {
    NSLog(@"SimpleTraceroute: No matching probe for sequence %d",
          sequenceNumber);
    return nil;
  }

  // 4. Calculate round trip time
  NSTimeInterval sendTime = [probeInfo[@"timestamp"] doubleValue];
  NSTimeInterval receiveTime = [NSDate timeIntervalSinceReferenceDate];
  NSTimeInterval roundTripTime = receiveTime - sendTime;

  // 5. Get router address
  NSString *routerAddress = [self addressStringFromSockaddr:sourceAddress];

  // 6. Create hop result
  uint8_t hopNumber = [probeInfo[@"hop"] unsignedCharValue];
  TracerouteHopResult *result = [self createHopResult:hopNumber
                                        routerAddress:routerAddress
                                        roundTripTime:roundTripTime
                                        isDestination:isDestination];

  result.sequenceNumber = sequenceNumber;
  result.probeIndex = [probeInfo[@"probeIndex"] unsignedCharValue];

  NSLog(@"SimpleTraceroute: Parsed response - hop %d, RTT %.3fms, %@",
        hopNumber, roundTripTime * 1000.0,
        isDestination ? @"destination" : @"intermediate");

  return result;
}

/*! Process received response data
 *  \param responseData received raw data
 *  \param sourceAddress response source address
 */
- (void)processReceivedData:(NSData *)responseData
                fromAddress:(NSData *)sourceAddress {
  // 1. Validate response packet
  if (![self validateICMPResponse:responseData
                    addressFamily:self.hostAddressFamily]) {
    NSLog(@"SimpleTraceroute: Invalid ICMP response, ignoring");
    return;
  }

  // 2. Parse response packet
  TracerouteHopResult *hopResult = [self parseICMPResponse:responseData
                                               fromAddress:sourceAddress];
  if (hopResult == nil) {
    NSLog(@"SimpleTraceroute: Failed to parse ICMP response");
    return;
  }

  // 3. Process hop completion
  [self handleHopCompletion:hopResult];
}

/*! Process hop completion and decide next action
 *  \param hopResult current hop result
 */
- (void)handleHopCompletion:(TracerouteHopResult *)hopResult {
  // 1. Add to completed list
  [self.completedHops addObject:hopResult];

  // 2. Notify delegate
  id<SimpleTracerouteDelegate> strongDelegate = self.delegate;
  if ((strongDelegate != nil) &&
      [strongDelegate respondsToSelector:@selector(simpleTraceroute:
                                                     didCompleteHop:)]) {
    [strongDelegate simpleTraceroute:self didCompleteHop:hopResult];
  }

  // 3. Check if destination reached
  if (hopResult.isDestination) {
    NSLog(@"SimpleTraceroute: Reached destination at hop %d",
          hopResult.hopNumber);
    [self stopTimeoutTimer]; // Stop current timer
    [self finishTraceroute];
    return;
  }

  // 4. Check if need to continue to next hop
  if ([self shouldProceedToNextHop:hopResult.hopNumber]) {
    NSLog(@"SimpleTraceroute: Proceeding to next hop after completing hop %d",
          hopResult.hopNumber);
    [self stopTimeoutTimer]; // Stop current timer
    [self startNextHop];
  } else {
    NSLog(@"SimpleTraceroute: Waiting for more responses for hop %d",
          hopResult.hopNumber);
    // Keep current timeout timer running, wait for more responses or timeout
  }
}

/*! Determine if should proceed to next hop
 *  \param currentHop current hop number
 *  \returns Returns YES if should proceed to next hop, otherwise returns NO
 *  \details Decide whether to proceed to next hop based on received responses
 * count and strategy
 */
- (BOOL)shouldProceedToNextHop:(uint8_t)currentHop {
  // Strategy 1: Proceed to next hop after receiving first valid response (fast
  // mode) This is traditional traceroute behavior - one response per hop is
  // sufficient

  // Strategy 2: Wait for all probe responses or timeout (complete mode)
  // Strategy can be configured via property, using fast mode here

  // Check if there are pending probes for current hop
  NSUInteger pendingProbesForCurrentHop = 0;
  for (NSString *key in self.pendingProbes) {
    NSDictionary *probeInfo = self.pendingProbes[key];
    uint8_t probeHop = [probeInfo[@"hop"] unsignedCharValue];
    if (probeHop == currentHop) {
      pendingProbesForCurrentHop++;
    }
  }

  NSLog(@"SimpleTraceroute: Hop %d has %lu pending probes", currentHop,
        (unsigned long)pendingProbesForCurrentHop);

  // Fast mode: Proceed to next hop upon receiving any response, don't wait for
  // other probes If all probes have responded or this is timeout handling,
  // proceed to next hop
  return YES; // Use fast mode

  // Optional complete mode implementation:
  // return (pendingProbesForCurrentHop == 0);
}

/*! Read and process ICMP response data (replacement for placeholder
 * implementation) \details Read data from socket and trigger parsing process
 */
- (void)readData {
  if (self.socket == NULL) {
    NSLog(@"SimpleTraceroute: No socket available for reading");
    return;
  }

  int socketFD = CFSocketGetNative(self.socket);
  if (socketFD < 0) {
    NSLog(@"SimpleTraceroute: Invalid socket for reading");
    return;
  }

  NSData *responseData = nil;
  NSData *sourceAddress = nil;

  // Read response data
  if ([self readResponseFromSocket:socketFD
                      responseData:&responseData
                     sourceAddress:&sourceAddress]) {
    // Process received data
    [self processReceivedData:responseData fromAddress:sourceAddress];
  }
}

#pragma mark * Timeout Management Methods

/*! Start timeout timer for specified hop
 *  \param hop hop number (1-255)
 *  \details Start timer after sending probes, automatically handle unresponsive
 * probes on timeout
 */
- (void)startTimeoutTimerForHop:(uint8_t)hop {
  // 1. Stop previous timer (prevent duplicate timing)
  [self stopTimeoutTimer];

  // 2. Validate parameters
  if (hop < 1 || hop > 255) {
    NSLog(@"SimpleTraceroute: Invalid hop number for timeout timer: %d", hop);
    return;
  }

  if (!self.isRunning) {
    NSLog(@"SimpleTraceroute: Cannot start timeout timer - traceroute not "
          @"running");
    return;
  }

  // 3. Create user info dictionary (pass hop information to timer callback)
  NSDictionary *userInfo = @{
    @"hop" : @(hop),
    @"timestamp" : @([NSDate timeIntervalSinceReferenceDate])
  };

  // 4. Create and start timer
  self.timeoutTimer =
      [NSTimer scheduledTimerWithTimeInterval:self.timeout
                                       target:self
                                     selector:@selector(timeoutForHop:)
                                     userInfo:userInfo
                                      repeats:NO];

  NSLog(@"SimpleTraceroute: Started timeout timer for hop %d (%.1fs)", hop,
        self.timeout);
}

/*! Timeout handling callback method
 *  \param timer triggered timer object
 *  \details Handle timed out hop, generate timeout result and decide next
 * action
 */
- (void)timeoutForHop:(NSTimer *)timer {
  // 1. Get timer information
  NSDictionary *userInfo = timer.userInfo;
  if (userInfo == nil) {
    NSLog(@"SimpleTraceroute: Timeout timer fired with no user info");
    return;
  }

  uint8_t hop = [userInfo[@"hop"] unsignedCharValue];
  NSTimeInterval startTimestamp = [userInfo[@"timestamp"] doubleValue];
  NSTimeInterval actualTimeout =
      [NSDate timeIntervalSinceReferenceDate] - startTimestamp;

  NSLog(@"SimpleTraceroute: Timeout fired for hop %d after %.3fs", hop,
        actualTimeout);

  // 2. Validate state
  if (!self.isRunning) {
    NSLog(@"SimpleTraceroute: Ignoring timeout - traceroute stopped");
    return;
  }

  if (hop != self.currentHop) {
    NSLog(@"SimpleTraceroute: Timeout hop mismatch - expected %d, got %d",
          self.currentHop, hop);
    return;
  }

  // 3. Clean up timer
  self.timeoutTimer = nil;

  // 4. Handle timeout situation for current hop
  [self handleTimeoutForHop:hop actualTimeout:actualTimeout];
}

/*! Handle timeout situation for specified hop
 *  \param hop timed out hop number
 *  \param actualTimeout actual timeout duration
 *  \details Generate result for timed out hop, clean up pending probes, decide
 * whether to continue to next hop
 */
- (void)handleTimeoutForHop:(uint8_t)hop
              actualTimeout:(NSTimeInterval)actualTimeout {
  NSLog(@"SimpleTraceroute: Processing timeout for hop %d", hop);

  // 1. Count pending probe packets for current hop
  NSMutableArray *timeoutProbes = [NSMutableArray array];
  NSMutableArray *keysToRemove = [NSMutableArray array];

  for (NSString *key in self.pendingProbes) {
    NSDictionary *probeInfo = self.pendingProbes[key];
    uint8_t probeHop = [probeInfo[@"hop"] unsignedCharValue];

    if (probeHop == hop) {
      [timeoutProbes addObject:probeInfo];
      [keysToRemove addObject:key];
    }
  }

  // 2. Clean up timed out pending probe packets
  for (NSString *key in keysToRemove) {
    [self.pendingProbes removeObjectForKey:key];
  }

  NSLog(@"SimpleTraceroute: Found %lu timeout probes for hop %d",
        (unsigned long)timeoutProbes.count, hop);

  // 3. Generate timeout result (if there are pending probe packets)
  if (timeoutProbes.count > 0) {
    TracerouteHopResult *timeoutResult =
        [self createTimeoutResult:hop
                    timeoutProbes:timeoutProbes
                    actualTimeout:actualTimeout];
    [self handleHopCompletion:timeoutResult];
  } else {
    // No pending probe packets, all probes may have been received
    NSLog(@"SimpleTraceroute: No pending probes for hop %d timeout - all may "
          @"have been received",
          hop);

    // Proceed directly to next hop (if still running)
    if (self.isRunning) {
      [self startNextHop];
    }
  }
}

/*! Create timeout hop result
 *  \param hop hop number
 *  \param timeoutProbes array of timed out probe information
 *  \param actualTimeout actual timeout duration
 *  \returns timeout hop result object
 */
- (TracerouteHopResult *)createTimeoutResult:(uint8_t)hop
                               timeoutProbes:(NSArray *)timeoutProbes
                               actualTimeout:(NSTimeInterval)actualTimeout {
  TracerouteHopResult *result = [[TracerouteHopResult alloc] init];
  result.hopNumber = hop;
  result.routerAddress = nil;           // No address information for timeout
  result.roundTripTime = actualTimeout; // Use actual timeout duration
  result.isDestination = NO;
  result.isTimeout = YES; // Mark as timeout
  result.timestamp = [NSDate date];

  // Use sequence number from first timeout probe (if any)
  if (timeoutProbes.count > 0) {
    NSDictionary *firstProbe = timeoutProbes[0];
    result.sequenceNumber = [firstProbe[@"sequenceNumber"] unsignedShortValue];
    result.probeIndex = [firstProbe[@"probeIndex"] unsignedCharValue];
  } else {
    result.sequenceNumber = 0;
    result.probeIndex = 0;
  }

  NSLog(@"SimpleTraceroute: Created timeout result for hop %d with %lu probes",
        hop, (unsigned long)timeoutProbes.count);

  return result;
}

/*! Stops the timeout timer.
 */
- (void)stopTimeoutTimer {
  if (self.timeoutTimer != nil) {
    [self.timeoutTimer invalidate];
    self.timeoutTimer = nil;
  }
}

@end
