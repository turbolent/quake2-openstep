#ifndef Q2_INTERCEPTOR_PRIVATE_H
#define Q2_INTERCEPTOR_PRIVATE_H

#import <AppKit/AppKit.h>

/* Signatures checked against OPENSTEP 4.2 Interceptor Objective-C metadata. */
@interface NSSimpleBitmap : NSObject
- (char *)data;
- (int)bytesPerRow;
- pixelEncoding;
@end

@interface NSDirectBitmap : NSSimpleBitmap
- (id)initForRect:(NSRect)rect inWindow:(id)window;
- (char)isDirectMapped;
- (char)isBuffered;
- (void)setDirectMapped:(char)flag;
- (void)setBuffered:(char)flag;
- (void)updateState;
- (void)updateForRect:(NSRect)rect inWindow:(id)window;
- (void)flushIn:(NSRect)rect;
- (void)unlockBitmap;
- (char)tryLockBitmap;
@end

#endif
