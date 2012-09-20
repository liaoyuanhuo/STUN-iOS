//
//  STUNClient.m
//  STUN
//
//  Created by IgorKh on 9/19/12.
//  Copyright (c) 2012 quickblox. All rights reserved.
//

#import "STUNClient.h"
#include <stdlib.h>

@implementation STUNClient

- (void)dealloc{
    [msgType release];
    [bodyLength release];
    [magicCookie release];
    [transactionId release];
    
    [super dealloc];
}

- (void)requestPublicIPandPortWithDelegate:(id<STUNClientDelegate>)_delegate{
    // create socket and bind it
    udpSocket = [[GCDAsyncUdpSocket alloc] initWithDelegate:self delegateQueue:dispatch_get_main_queue()];
    NSError *error = nil;
    if (![udpSocket bindToPort:0 error:&error]) {
        STUNLog(@"bindToPort error=%@", error);
        return;
    }
    if (![udpSocket beginReceiving:&error]){
        STUNLog(@"beginReceiving error=%@", error);
        return;
    }
    
    delegate = _delegate;
    
    msgType = [[NSData dataWithBytes:"\x00\x01" length:2] retain]; // STUN binding request. A Binding request has class=0b00 (request) and
                                                          // method=0b000000000001 (Binding)
    bodyLength = [[NSData dataWithBytes:"\x00\x00" length:2] retain]; // we have/need no attributes, so message body length is zero
    magicCookie = [[NSData dataWithBytes:"\x21\x12\xA4\x42" length:4] retain]; // The magic cookie field MUST contain the fixed value 0x2112A442 in
                                                                      // network byte order.
    transactionId = [[self createNRundomBytes:12] retain]; //  The transaction ID used to uniquely identify STUN transactions.

    // create final request
    NSMutableData *stunRequest = [NSMutableData data];
    [stunRequest appendData:msgType];
    [stunRequest appendData:bodyLength];
    [stunRequest appendData:magicCookie];
    [stunRequest appendData:transactionId];
    
    STUNLog(@"STUN request=%@", stunRequest);
    
    // Start request
    //
    [udpSocket sendData:stunRequest toHost:SNUTServer port:SNUTPort withTimeout:-1 tag:1002];
}


#pragma mark -
#pragma mark Utils

/**
 * Generate random n bytes
 **/
-(NSData *)createNRundomBytes:(int)n{
    NSMutableData* theData = [NSMutableData dataWithCapacity:n];
    for( unsigned int i = 0 ; i < n ; ++i ){
        u_int32_t randomBits = arc4random();
        [theData appendBytes:(void*)&randomBits length:1];
    }
    return theData;
}

- (NSString *)extractIP:(NSData *)rawIP{
    unsigned char *n = (unsigned char *)[rawIP bytes];
    int value1 = n[0];
    int value2 = n[1];
    int value3 = n[2];
    int value4 = n[3];
    
    return [NSString stringWithFormat:@"%d:%d:%d:%d", value1, value2, value3, value4];
}

- (NSString *)extractPort:(NSData *)rawPort{
    unsigned port = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[[rawPort description] substringWithRange:NSMakeRange(1, 4)]];
    [scanner scanHexInt:&port];
    
    return [NSString stringWithFormat:@"%d", port];
}


#pragma mark -
#pragma mark GCDAsyncUdpSocketDelegate

/**
 * Called when the socket has received the requested datagram.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didReceiveData:(NSData *)data
      fromAddress:(NSData *)address
withFilterContext:(id)filterContext{
    
    STUNLog(@"STUN didReceiveData = %@", data);
    
    // Checks
    //
    if([data length] < 20){
        STUNLog(@"STUN didReceiveData. Length too short (not a STUN response). Please repeat request");
        return;
    }
    //
    //
    NSMutableData *magicCookieAndTransactionID = [NSMutableData data];
    [magicCookieAndTransactionID appendData:magicCookie];
    [magicCookieAndTransactionID appendData:transactionId];
    if(![[data subdataWithRange:NSMakeRange(4, 16)] isEqualToData:magicCookieAndTransactionID]){
        STUNLog(@"STUN magic cookie and/or transaction id check failed. Please repeat request");
        return;
    }
    //
    //
    if(![[data subdataWithRange:NSMakeRange(0, 2)] isEqualToData:[NSData dataWithBytes:"\x01\x01" length:2]]){
        STUNLog(@"STUN a non-success STUN response received. Please repeat request");
        return;
    }


    // get responss body length
    unsigned responseBodyLength = 0;
    NSScanner *scanner = [NSScanner scannerWithString:[[[data subdataWithRange:NSMakeRange(2, 4)] description] substringWithRange:NSMakeRange(1, 4)]];
    [scanner scanHexInt:&responseBodyLength];
    STUNLog(@"STUN response Body Length = %d", responseBodyLength);
    
    
    NSData *maddr = nil;   // mapped ip
    NSData *mport = nil;   // mapped port
    //
    NSData *xmaddr = nil;  // xor mapped ip
    NSData *xmport = nil;  // xor mapped port
    
    int i = 20; // current reading position in the response binary data
    while(i < responseBodyLength+20){ // proccessing the response
    
        NSData *mappedAddressData = [data subdataWithRange:NSMakeRange(i, 2)];
        
        if([mappedAddressData isEqualToData:[NSData dataWithBytes:"\x00\x01" length:2]]){ // MAPPED-ADDRESS
            int maddrStartPos = i + 2 + 2 + 1 + 1;
            mport = [data subdataWithRange:NSMakeRange(maddrStartPos, 2)];
            maddr = [data subdataWithRange:NSMakeRange(maddrStartPos+2, 4)];
        }
        if([mappedAddressData isEqualToData:[NSData dataWithBytes:"\x80\x20" length:2]] ||
           [mappedAddressData isEqualToData:[NSData dataWithBytes:"\x00\x20" length:2]]){
            
            // apparently, all public stun servers tested use 0x8020 (in the Comprehension-optional range) -
            // as the XOR-MAPPED-ADDRESS Attribute type number instead of 0x0020 specified in RFC5389
            int xmaddrStartPos = i + 2 + 2 + 1 + 1;
            xmport=[data subdataWithRange:NSMakeRange(xmaddrStartPos, 2)];
            xmaddr=[data subdataWithRange:NSMakeRange(xmaddrStartPos+2, 4)];
        }
        
        i += 2;

        unsigned attribValueLength = 0;
        NSScanner *scanner = [NSScanner scannerWithString:[[[data subdataWithRange:NSMakeRange(i, 2)] description]
                                                           substringWithRange:NSMakeRange(1, 4)]];
        [scanner scanHexInt:&attribValueLength];

        if(attribValueLength % 4 > 0){
            attribValueLength += 4 - (attribValueLength % 4); // adds stun attribute value padding
        }
        
        i += 2;
        i += attribValueLength;
    }
    
    
    if(maddr != nil){
        STUNLog(@"MAPPED-ADDRESS: %@", maddr);
        STUNLog(@"mport: %@", mport);
    }else{
        STUNLog(@"STUN No MAPPED-ADDRESS found.");
    }
    
    
    NSString *ip = nil;
    NSString *port = nil;
    
    if(maddr != nil){
        ip = [self extractIP:maddr];
        port = [self extractPort:mport];
    }else{
        STUNLog(@"STUN query failed.");
        return;
    }
    
    STUNLog(@"\n");
    STUNLog(@"=======STUN========");
    STUNLog(@"STUN IP: %@", ip);
    STUNLog(@"STUN Port: %@", port);
    STUNLog(@"===================");
    STUNLog(@"\n");
    
    // notify delegate
    if([delegate respondsToSelector:@selector(didReceivePublicIPandPort:)]){
        NSDictionary *result = [NSDictionary dictionaryWithObjectsAndKeys:ip, publicIPKey, port, publicPortKey, nil];
        [delegate didReceivePublicIPandPort:result];
    }
}

/**
 * Called when the datagram with the given tag has been sent.
 **/
- (void)udpSocket:(GCDAsyncUdpSocket *)sock didSendDataWithTag:(long)tag{
    STUNLog(@"STUN didSendDataWithTag=%ld", tag);
}

@end