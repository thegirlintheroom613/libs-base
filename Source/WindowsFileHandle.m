/** Implementation for WindowsFileHandle for GNUStep
   Copyright (C) 1997-1999 Free Software Foundation, Inc.

   Rewritten: Adam Fedor <fedor@gnu.org>
   Written: Richard Frith-Macdonald <richard@brainstorm.co.uk>
   Date: Sep 2000

   This file is part of the GNUstep Base Library.

   This library is free software; you can redistribute it and/or
   modify it under the terms of the GNU Library General Public
   License as published by the Free Software Foundation; either
   version 2 of the License, or (at your option) any later version.

   This library is distributed in the hope that it will be useful,
   but WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   Library General Public License for more details.

   You should have received a copy of the GNU Library General Public
   License along with this library; if not, write to the Free
   Software Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111 USA.
   */

#include <config.h>
#include <base/preface.h>
#include <Foundation/NSObject.h>
#include <Foundation/NSData.h>
#include <Foundation/NSArray.h>
#include <Foundation/NSString.h>
#include <Foundation/NSFileHandle.h>
#include <Foundation/WindowsFileHandle.h>
#include <Foundation/NSException.h>
#include <Foundation/NSRunLoop.h>
#include <Foundation/NSNotification.h>
#include <Foundation/NSNotificationQueue.h>
#include <Foundation/NSHost.h>
#include <Foundation/NSByteOrder.h>

#include <winsock.h>
#include <fcntl.h>

#include <sys/file.h>
#include <sys/stat.h>
#include <string.h>
#include <unistd.h>
#include <errno.h>

// Maximum data in single I/O operation
#define	NETBUF_SIZE	4096

static WindowsFileHandle*	fh_stdin = nil;
static WindowsFileHandle*	fh_stdout = nil;
static WindowsFileHandle*	fh_stderr = nil;

// Key to info dictionary for operation mode.
static NSString*	NotificationKey = @"NSFileHandleNotificationKey";

@interface	WindowsFileHandle (Private)
- (void) setAddr: (struct sockaddr_in *)sin;
@end

@implementation WindowsFileHandle

static BOOL
getAddr(NSString* name, NSString* svc, NSString* pcl, struct sockaddr_in *sin)
{
  const char		*proto = "tcp";
  struct servent	*sp;

  if (pcl)
    proto = [pcl cString];

  memset(sin, '\0', sizeof(*sin));
  sin->sin_family = AF_INET;

  /*
   *	If we were given a hostname, we use any address for that host.
   *	Otherwise we expect the given name to be an address unless it is
   *	a nul (any address).
   */
  if (name)
    {
      NSHost*		host = [NSHost hostWithName: name];

      if (host)
	name = [host address];

#ifndef	HAVE_INET_ATON
      sin->sin_addr.s_addr = inet_addr([name cString]);
      if (sin->sin_addr.s_addr == INADDR_NONE)
	return NO;
#else
      if (inet_aton([name cString], &sin->sin_addr) == 0)
	return NO;
#endif
    }
  else
    sin->sin_addr.s_addr = GSSwapHostI32ToBig(INADDR_ANY);

  if (svc == nil)
    {
      sin->sin_port = 0;
      return YES;
    }
  else if ((sp = getservbyname([svc cString], proto)) == 0)
    {
      const char*     ptr = [svc cString];
      int             val = atoi(ptr);

      while (isdigit(*ptr))
	ptr++;

      if (*ptr == '\0' && val <= 0xffff)
	{
	  gsu16       v = val;

	  sin->sin_port = GSSwapHostI16ToBig(v);
	  return YES;
        }
      else
	return NO;
    }
  else
    {
      sin->sin_port = sp->s_port;
      return YES;
    }
}

+ (void) initialize
{
}

- (void) dealloc
{
  [address release];
  [service release];
  [protocol release];

  if (self == fh_stdin)
    fh_stdin = nil;
  if (self == fh_stdout)
    fh_stdout = nil;
  if (self == fh_stderr)
    fh_stderr = nil;

  [self ignoreReadDescriptor];
  [self ignoreWriteDescriptor];

  if (descriptor != -1)
    {
      [self setNonBlocking: wasNonBlocking];
      if (closeOnDealloc == YES)
	{
	  close(descriptor);
	  descriptor = -1;
	}
    }
  [readInfo release];
  [writeInfo release];
  [super dealloc];
}

// Initializing a WindowsFileHandle Object

- (id) init
{
  return [self initWithNullDevice];
}

- (id) initAsClientAtAddress: (NSString*)a
		     service: (NSString*)s
		    protocol: (NSString*)p
{
  int	net;
  struct sockaddr_in	sin;

  if (s == nil)
    {
      NSLog(@"bad argument - service is nil");
      [self release];
      return nil;
    }
  if (getAddr(a, s, p, &sin) == NO)
    {
      NSLog(@"bad address-service-protocol combination");
      [self release];
      return nil;
    }
  [self setAddr: &sin];

  if ((net = socket(AF_INET, SOCK_STREAM, PF_UNSPEC)) < 0)
    {
      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
      [self release];
      return nil;
    }

  self = [self initWithFileDescriptor: net closeOnDealloc: YES];
  if (self)
    {
      if (connect(net, (struct sockaddr*)&sin, sizeof(sin)) < 0)
	{
	  NSLog(@"unable to make connection to %s:%d - %s",
		inet_ntoa(sin.sin_addr),
		GSSwapBigI16ToHost(sin.sin_port), GSLastErrorStr(errno));
	  [self release];
	  return nil;
	}
	
      connectOK = NO;
      readOK = YES;
      writeOK = YES;
    }
  return self;
}

- (id) initAsClientInBackgroundAtAddress: (NSString*)a
				 service: (NSString*)s
			        protocol: (NSString*)p
			        forModes: (NSArray*)modes
{
  int	net;
  struct sockaddr_in	sin;

  if (a == nil || [a isEqualToString: @""])
    a = @"localhost";
  if (s == nil)
    {
      NSLog(@"bad argument - service is nil");
      [self release];
      return nil;
    }
  if (getAddr(a, s, p, &sin) == NO)
    {
      NSLog(@"bad address-service-protocol combination");
      [self release];
      return nil;
    }
  [self setAddr: &sin];

  if ((net = socket(AF_INET, SOCK_STREAM, PF_UNSPEC)) < 0)
    {
      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
      [self release];
      return nil;
    }

  self = [self initWithFileDescriptor: net closeOnDealloc: YES];
  if (self)
    {
      NSMutableDictionary*	info;

      [self setNonBlocking: YES];
      if (connect(net, (struct sockaddr*)&sin, sizeof(sin)) < 0)
	if (WSAGetLastError() == WSAEINPROGRESS)
	  {
	    NSLog(@"unable to make connection to %s:%d - %s",
		inet_ntoa(sin.sin_addr),
		GSSwapBigI16ToHost(sin.sin_port), GSLastErrorStr(errno));
	    [self release];
	    return nil;
	  }
	
      info = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
      [info setObject: address forKey: NSFileHandleNotificationDataItem];
      [info setObject: GSFileHandleConnectCompletionNotification
	       forKey: NotificationKey];
      if (modes)
        [info setObject: modes forKey: NSFileHandleNotificationMonitorModes];
      [writeInfo addObject: info];
      [info release];
      [self watchWriteDescriptor];
      connectOK = YES;
      readOK = NO;
      writeOK = NO;
    }
  return self;
}

- (id) initAsServerAtAddress: (NSString*)a
		     service: (NSString*)s
		    protocol: (NSString*)p
{
  int	status = 1;
  int	net;
  struct sockaddr_in	sin;
  int	size = sizeof(sin);

  if (getAddr(a, s, p, &sin) == NO)
    {
      [self release];
      NSLog(@"bad address-service-protocol combination");
      return  nil;
    }

  if ((net = socket(AF_INET, SOCK_STREAM, PF_UNSPEC)) < 0)
    {
      NSLog(@"unable to create socket - %s", GSLastErrorStr(errno));
      [self release];
      return nil;
    }

  setsockopt(net, SOL_SOCKET, SO_REUSEADDR, (char *)&status, sizeof(status));

  if (bind(net, (struct sockaddr *)&sin, sizeof(sin)) < 0)
    {
      NSLog(@"unable to bind to port %s:%d - %s",
		inet_ntoa(sin.sin_addr),
		GSSwapBigI16ToHost(sin.sin_port), GSLastErrorStr(errno));
      (void) close(net);
      [self release];
      return nil;
    }

  if (listen(net, 5) < 0)
    {
      NSLog(@"unable to listen on port - %s", GSLastErrorStr(errno));
      (void) close(net);
      [self release];
      return nil;
    }

  if (getsockname(net, (struct sockaddr*)&sin, &size) < 0)
    {
      NSLog(@"unable to get socket name - %s", GSLastErrorStr(errno));
      (void) close(net);
      [self release];
      return nil;
    }

  self = [self initWithFileDescriptor: net closeOnDealloc: YES];
  if (self)
    {
      acceptOK = YES;
      readOK = NO;
      writeOK = NO;
      [self setAddr: &sin];
    }
  return self;
}

- (id) initForReadingAtPath: (NSString*)path
{
  int	d = open([path fileSystemRepresentation], O_RDONLY|O_BINARY);

  if (d < 0)
    {
      [self release];
      return nil;
    }
  else
    {
      self = [self initWithFileDescriptor: d closeOnDealloc: YES];
      if (self)
	writeOK = NO;
      return self;
    }
}

- (id) initForWritingAtPath: (NSString*)path
{
  int	d = open([path fileSystemRepresentation], O_WRONLY|O_BINARY);

  if (d < 0)
    {
      [self release];
      return nil;
    }
  else
    {
      self = [self initWithFileDescriptor: d closeOnDealloc: YES];
      if (self)
        readOK = NO;
      return self;
    }
}

- (id) initForUpdatingAtPath: (NSString*)path
{
  int	d = open([path fileSystemRepresentation], O_RDWR|O_BINARY);

  if (d < 0)
    {
      [self release];
      return nil;
    }
  else
    {
      return [self initWithFileDescriptor: d closeOnDealloc: YES];
    }
}

- (id) initWithStandardError
{
  if (fh_stderr)
    {
      [fh_stderr retain];
      [self release];
    }
  else
    {
      self = [self initWithFileDescriptor: 2 closeOnDealloc: NO];
      fh_stderr = self;
    }
  self = fh_stderr;
  if (self)
    readOK = NO;
  return self;
}

- (id) initWithStandardInput
{
  if (fh_stdin)
    {
      [fh_stdin retain];
      [self release];
    }
  else
    {
      self = [self initWithFileDescriptor: 0 closeOnDealloc: NO];
      fh_stdin = self;
    }
  self = fh_stdin;
  if (self)
    writeOK = NO;
  return self;
}

- (id) initWithStandardOutput
{
  if (fh_stdout)
    {
      [fh_stdout retain];
      [self release];
    }
  else
    {
      self = [self initWithFileDescriptor: 1 closeOnDealloc: NO];
      fh_stdout = self;
    }
  self = fh_stdout;
  if (self)
    readOK = NO;
  return self;
}

- (id) initWithNullDevice
{
  self = [self initWithFileDescriptor: open("/dev/null", O_RDWR|O_BINARY)
		       closeOnDealloc: YES];
  if (self)
    {
      isNullDevice = YES;
    }
  return self;
}

- (id) initWithFileDescriptor: (int)desc closeOnDealloc: (BOOL)flag
{
  unsigned long dummy;
  self = [super init];
  if (self)
    {
      struct stat sbuf;

      if (fstat(desc, &sbuf) < 0)
	{
          NSLog(@"unable to get status of descriptor - %s", GSLastErrorStr(errno));
	  [self release];
	  return nil;
	}
      if (S_ISREG(sbuf.st_mode))
        isStandardFile = YES;
      else
        isStandardFile = NO;

      dummy = 1;
#if 0
      if (ioctlsocket(desc, FIONBIO, &dummy) >= 0)
	{
	  if (e & NBLK_OPT)
	    wasNonBlocking = YES;
	  else
	    wasNonBlocking = NO;
	}
#endif

      isNonBlocking = wasNonBlocking;
      descriptor = desc;
      closeOnDealloc = flag;
      readInfo = nil;
      writeInfo = [[NSMutableArray array] retain];
      readPos = 0;
      writePos = 0;
      readOK = YES;
      writeOK = YES;
    }
  return self;
}

- (id) initWithNativeHandle: (void*)hdl
{
  return [self initWithFileDescriptor: (gsaddr)hdl closeOnDealloc: NO];
}

- (id) initWithNativeHandle: (void*)hdl closeOnDealloc: (BOOL)flag
{
  return [self initWithFileDescriptor: (gsaddr)hdl closeOnDealloc: flag];
}

- (void) checkAccept
{
  if (acceptOK == NO)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"accept not permitted in this file handle"];
    }
  if (readInfo)
    {
      id	operation = [readInfo objectForKey: NotificationKey];

      if (operation == NSFileHandleConnectionAcceptedNotification)
        {
          [NSException raise: NSFileHandleOperationException
                      format: @"accept already in progress"];
	}
      else
	{
          [NSException raise: NSFileHandleOperationException
                      format: @"read already in progress"];
	}
    }
}

- (void) checkConnect
{
  if (connectOK == NO)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"connect not permitted in this file handle"];
    }
  if ([writeInfo count] > 0)
    {
      id	info = [writeInfo objectAtIndex: 0];
      id	operation = [info objectForKey: NotificationKey];

      if (operation == GSFileHandleConnectCompletionNotification)
	{
          [NSException raise: NSFileHandleOperationException
                      format: @"connect already in progress"];
	}
      else
	{
          [NSException raise: NSFileHandleOperationException
                      format: @"write already in progress"];
	}
    }
}

- (void) checkRead
{
  if (readOK == NO)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"read not permitted on this file handle"];
    }
  if (readInfo)
    {
      id	operation = [readInfo objectForKey: NotificationKey];

      if (operation == NSFileHandleConnectionAcceptedNotification)
        {
          [NSException raise: NSFileHandleOperationException
                      format: @"accept already in progress"];
	}
      else
	{
          [NSException raise: NSFileHandleOperationException
                      format: @"read already in progress"];
	}
    }
}

- (void) checkWrite
{
  if (writeOK == NO)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"write not permitted in this file handle"];
    }
  if ([writeInfo count] > 0)
    {
      id	info = [writeInfo objectAtIndex: 0];
      id	operation = [info objectForKey: NotificationKey];

      if (operation == GSFileHandleConnectCompletionNotification)
	{
          [NSException raise: NSFileHandleOperationException
                      format: @"connect already in progress"];
	}
    }
}

// Returning file handles

- (int) fileDescriptor
{
  return descriptor;
}

- (void*) nativeHandle
{
  return (void*)0;
}

// Synchronous I/O operations

- (NSData*) availableData
{
  char			buf[NETBUF_SIZE];
  NSMutableData*	d;
  int			len;

  [self checkRead];
  if (isNonBlocking == YES)
    [self setNonBlocking: NO];
  d = [NSMutableData dataWithCapacity: 0];
  if (isStandardFile)
    {
      while ((len = read(descriptor, buf, sizeof(buf))) > 0)
        {
	  [d appendBytes: buf length: len];
        }
    }
  else
    {
      if ((len = read(descriptor, buf, sizeof(buf))) > 0)
	{
	  [d appendBytes: buf length: len];
	}
    }
  if (len < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"unable to read from descriptor - %s",
                  GSLastErrorStr(errno)];
    }
  return d;
}

- (NSData*) readDataToEndOfFile
{
  char			buf[NETBUF_SIZE];
  NSMutableData*	d;
  int			len;

  [self checkRead];
  if (isNonBlocking == YES)
    [self setNonBlocking: NO];
  d = [NSMutableData dataWithCapacity: 0];
  while ((len = read(descriptor, buf, sizeof(buf))) > 0)
    {
      [d appendBytes: buf length: len];
    }
  if (len < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"unable to read from descriptor - %s",
                  GSLastErrorStr(errno)];
    }
  return d;
}

- (NSData*) readDataOfLength: (unsigned)len
{
  NSMutableData*	d;
  int			got;

  [self checkRead];
  if (isNonBlocking == YES)
    [self setNonBlocking: NO];
  if (len <= 65536)
    {
      char	*buf;

      buf = NSZoneMalloc(NSDefaultMallocZone(), len);
      d = [NSMutableData dataWithBytesNoCopy: buf length: len];
      if ((got = read(descriptor, [d mutableBytes], len)) < 0)
	{
	  [NSException raise: NSFileHandleOperationException
		      format: @"unable to read from descriptor - %s",
		      GSLastErrorStr(errno)];
	}
      [d setLength: got];
    }
  else
    {
      char	buf[NETBUF_SIZE];

      d = [NSMutableData dataWithCapacity: 0];
      do
	{
	  int	chunk = len > sizeof(buf) ? sizeof(buf) : len;

	  got = read(descriptor, buf, chunk);
	  if (got > 0)
	    {
	      [d appendBytes: buf length: got];
	      len -= got;
	    }
	  else if (got < 0)
	    {
	      [NSException raise: NSFileHandleOperationException
			  format: @"unable to read from descriptor - %s",
			  GSLastErrorStr(errno)];
	    }
	}
      while (len > 0 && got > 0);
    }
  return d;
}

- (void) writeData: (NSData*)item
{
  int		rval = 0;
  const void*	ptr = [item bytes];
  unsigned int	len = [item length];
  unsigned int	pos = 0;

  [self checkWrite];
  if (isNonBlocking == YES)
    {
      [self setNonBlocking: NO];
    }
  while (pos < len)
    {
      int	toWrite = len - pos;

      if (toWrite > NETBUF_SIZE)
	{
	  toWrite = NETBUF_SIZE;
	}
      rval = write(descriptor, (char*)ptr+pos, toWrite);
      if (rval < 0)
	{
	  if (errno == EAGAIN || errno == EINTR)
	    {
	      rval = 0;
	    }
	  else
	    {
	      break;
	    }
	}
      pos += rval;
    }
  if (rval < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"unable to write to descriptor - %s",
                  GSLastErrorStr(errno)];
    }
}


// Asynchronous I/O operations

- (void) acceptConnectionInBackgroundAndNotifyForModes: (NSArray*)modes
{
  [self checkAccept];
  readPos = 0;
  [readInfo release];
  readInfo = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
  [readInfo setObject: NSFileHandleConnectionAcceptedNotification
	       forKey: NotificationKey];
  [self watchReadDescriptorForModes: modes];
}

- (void) acceptConnectionInBackgroundAndNotify
{
  [self acceptConnectionInBackgroundAndNotifyForModes: nil];
}

- (void) readInBackgroundAndNotifyForModes: (NSArray*)modes
{
  [self checkRead];
  readPos = 0;
  [readInfo release];
  readInfo = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
  [readInfo setObject: NSFileHandleReadCompletionNotification
	       forKey: NotificationKey];
  [readInfo setObject: [NSMutableData dataWithCapacity: 0]
	       forKey: NSFileHandleNotificationDataItem];
  [self watchReadDescriptorForModes: modes];
}

- (void) readInBackgroundAndNotify
{
  return [self readInBackgroundAndNotifyForModes: nil];
}

- (void) readToEndOfFileInBackgroundAndNotifyForModes: (NSArray*)modes
{
  [self checkRead];
  readPos = 0;
  [readInfo release];
  readInfo = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
  [readInfo setObject: NSFileHandleReadToEndOfFileCompletionNotification
	       forKey: NotificationKey];
  [readInfo setObject: [NSMutableData dataWithCapacity: 0]
	       forKey: NSFileHandleNotificationDataItem];
  [self watchReadDescriptorForModes: modes];
}

- (void) readToEndOfFileInBackgroundAndNotify
{
  return [self readToEndOfFileInBackgroundAndNotifyForModes: nil];
}

- (void) waitForDataInBackgroundAndNotifyForModes: (NSArray*)modes
{
  [self checkRead];
  readPos = 0;
  [readInfo release];
  readInfo = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
  [readInfo setObject: NSFileHandleDataAvailableNotification
	       forKey: NotificationKey];
  [readInfo setObject: [NSMutableData dataWithCapacity: 0]
	       forKey: NSFileHandleNotificationDataItem];
  [self watchReadDescriptorForModes: modes];
}

- (void) waitForDataInBackgroundAndNotify
{
  return [self waitForDataInBackgroundAndNotifyForModes: nil];
}

// Seeking within a file

- (unsigned long long) offsetInFile
{
  off_t	result = -1;

  if (isStandardFile && descriptor >= 0)
    result = lseek(descriptor, 0, SEEK_CUR);
  if (result < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"failed to move to offset in file - %s",
                  GSLastErrorStr(errno)];
    }
  return (unsigned long long)result;
}

- (unsigned long long) seekToEndOfFile
{
  off_t	result = -1;

  if (isStandardFile && descriptor >= 0)
    result = lseek(descriptor, 0, SEEK_END);
  if (result < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"failed to move to offset in file - %s",
                  GSLastErrorStr(errno)];
    }
  return (unsigned long long)result;
}

- (void) seekToFileOffset: (unsigned long long)pos
{
  off_t	result = -1;

  if (isStandardFile && descriptor >= 0)
    result = lseek(descriptor, (off_t)pos, SEEK_SET);
  if (result < 0)
    {
      [NSException raise: NSFileHandleOperationException
                  format: @"failed to move to offset in file - %s",
                  GSLastErrorStr(errno)];
    }
}


// Operations on file

- (void) closeFile
{
  if (descriptor < 0)
    [NSException raise: NSFileHandleOperationException
		format: @"attempt to close closed file"];

  [self ignoreReadDescriptor];
  [self ignoreWriteDescriptor];

  [self setNonBlocking: wasNonBlocking];
  (void)close(descriptor);
  descriptor = -1;
  acceptOK = NO;
  connectOK = NO;
  readOK = NO;
  writeOK = NO;

  /*
   *    Clear any pending operations on the file handle, sending
   *    notifications if necessary.
   */
  if (readInfo)
    {
      [readInfo setObject: @"File handle closed locally"
                   forKey: GSFileHandleNotificationError];
      [self postReadNotification];
    }

  if ([writeInfo count])
    {
      NSMutableDictionary       *info = [writeInfo objectAtIndex: 0];

      [info setObject: @"File handle closed locally"
               forKey: GSFileHandleNotificationError];
      [self postWriteNotification];
      [writeInfo removeAllObjects];
    }
}

- (void) synchronizeFile
{
}

- (void) truncateFileAtOffset: (unsigned long long)pos
{
  [self seekToFileOffset: pos];
}

- (void) writeInBackgroundAndNotify: (NSData*)item forModes: (NSArray*)modes
{
  NSMutableDictionary*	info;

  [self checkWrite];

  info = [[NSMutableDictionary dictionaryWithCapacity: 4] retain];
  [info setObject: item forKey: NSFileHandleNotificationDataItem];
  [info setObject: GSFileHandleWriteCompletionNotification
		forKey: NotificationKey];
  if (modes)
    [info setObject: modes forKey: NSFileHandleNotificationMonitorModes];

  [writeInfo addObject: info];
  [info release];
  [self watchWriteDescriptor];
}

- (void) writeInBackgroundAndNotify: (NSData*)item;
{
  [self writeInBackgroundAndNotify: item forModes: nil];
}

- (void) postReadNotification
{
  NSMutableDictionary	*info = readInfo;
  NSNotification	*n;
  NSArray		*modes;
  NSString		*name;

  [self ignoreReadDescriptor];
  readInfo = nil;
  modes = (NSArray*)[info objectForKey: NSFileHandleNotificationMonitorModes];
  name = (NSString*)[info objectForKey: NotificationKey];

  n = [NSNotification notificationWithName: name object: self userInfo: info];

  [info release];	/* Retained by the notification.	*/

  [[NSNotificationQueue defaultQueue] enqueueNotification: n
		postingStyle: NSPostASAP
		coalesceMask: NSNotificationNoCoalescing
		forModes: modes];
}

- (void) postWriteNotification
{
  NSMutableDictionary	*info = [writeInfo objectAtIndex: 0];
  NSNotification	*n;
  NSArray		*modes;
  NSString		*name;

  [self ignoreWriteDescriptor];
  modes = (NSArray*)[info objectForKey: NSFileHandleNotificationMonitorModes];
  name = (NSString*)[info objectForKey: NotificationKey];

  n = [NSNotification notificationWithName: name object: self userInfo: info];

  writePos = 0;
  [writeInfo removeObjectAtIndex: 0];	/* Retained by notification.	*/

  [[NSNotificationQueue defaultQueue] enqueueNotification: n
		postingStyle: NSPostASAP
		coalesceMask: NSNotificationNoCoalescing
		forModes: modes];
  if ((writeOK || connectOK) && [writeInfo count] > 0)
    [self watchWriteDescriptor];	/* In case of queued writes.	*/
}

- (BOOL) readInProgress
{
  if (readInfo)
    return YES;
  return NO;
}

- (BOOL) writeInProgress
{
  if ([writeInfo count] > 0)
    return YES;
  return NO;
}

- (void) ignoreReadDescriptor
{
  NSRunLoop	*l;
  NSArray	*modes;

  if (descriptor < 0)
    return;

  l = [NSRunLoop currentRunLoop];
  modes = nil;

  if (readInfo)
    modes = (NSArray*)[readInfo objectForKey: NSFileHandleNotificationMonitorModes];

  if (modes && [modes count])
    {
      int		i;

      for (i = 0; i < [modes count]; i++)
	{
	  [l removeEvent: (void*)(gsaddr)descriptor
		    type: ET_RDESC
		 forMode: [modes objectAtIndex: i]
		     all: YES];
        }
    }
  else
    [l removeEvent: (void*)(gsaddr)descriptor
	      type: ET_RDESC
	   forMode: NSDefaultRunLoopMode
	       all: YES];
}

- (void) ignoreWriteDescriptor
{
  NSRunLoop	*l;
  NSArray	*modes;

  if (descriptor < 0)
    return;

  l = [NSRunLoop currentRunLoop];
  modes = nil;

  if ([writeInfo count] > 0)
    {
      NSMutableDictionary*	info = [writeInfo objectAtIndex: 0];

      modes=(NSArray*)[info objectForKey: NSFileHandleNotificationMonitorModes];
    }

  if (modes && [modes count])
    {
      int		i;

      for (i = 0; i < [modes count]; i++)
	{
	  [l removeEvent: (void*)(gsaddr)descriptor
		    type: ET_WDESC
		 forMode: [modes objectAtIndex: i]
		     all: YES];
        }
    }
  else
    [l removeEvent: (void*)(gsaddr)descriptor
	      type: ET_WDESC
	   forMode: NSDefaultRunLoopMode
	       all: YES];
}

- (void) watchReadDescriptorForModes: (NSArray*)modes;
{
  NSRunLoop	*l;

  if (descriptor < 0)
    return;

  l = [NSRunLoop currentRunLoop];
  [self setNonBlocking: YES];
  if (modes && [modes count])
    {
      int		i;

      for (i = 0; i < [modes count]; i++)
	{
	  [l addEvent: (void*)(gsaddr)descriptor
		 type: ET_RDESC
	      watcher: self
	      forMode: [modes objectAtIndex: i]];
        }
      [readInfo setObject: modes forKey: NSFileHandleNotificationMonitorModes];
    }
  else
    {
      [l addEvent: (void*)(gsaddr)descriptor
	     type: ET_RDESC
	  watcher: self
	  forMode: NSDefaultRunLoopMode];
    }
}

- (void) watchWriteDescriptor
{
  if (descriptor < 0)
    return;

  if ([writeInfo count] > 0)
    {
      NSMutableDictionary*	info = [writeInfo objectAtIndex: 0];
      NSRunLoop*		l = [NSRunLoop currentRunLoop];
      NSArray*			modes = nil;


      modes = [info objectForKey: NSFileHandleNotificationMonitorModes];

      [self setNonBlocking: YES];
      if (modes && [modes count])
	{
	  int		i;

	  for (i = 0; i < [modes count]; i++)
	    {
	      [l addEvent: (void*)(gsaddr)descriptor
		     type: ET_WDESC
		  watcher: self
		  forMode: [modes objectAtIndex: i]];
	    }
	}
      else
	{
	  [l addEvent: (void*)(gsaddr)descriptor
		 type: ET_WDESC
	      watcher: self
	      forMode: NSDefaultRunLoopMode];
	}
    }
}

- (void) receivedEvent: (void*)data
                  type: (RunLoopEventType)type
		 extra: (void*)extra
	       forMode: (NSString*)mode
{
  NSString	*operation;

  if (isNonBlocking == NO)
    [self setNonBlocking: YES];
  if (type == ET_RDESC)
    {
      operation = [readInfo objectForKey: NotificationKey];
      if (operation == NSFileHandleConnectionAcceptedNotification)
	{
	  struct sockaddr_in	buf;
	  int			desc;
	  int			blen = sizeof(buf);

	  desc = accept(descriptor, (struct sockaddr*)&buf, &blen);
	  if (desc < 0)
	    {
	      NSString	*s;

	      s = [NSString stringWithFormat: @"Accept attempt failed - %s",
                      GSLastErrorStr(errno)];
	      [readInfo setObject: s forKey: GSFileHandleNotificationError];
	    }
	  else
	    { // Accept attempt completed.
	      WindowsFileHandle		*h;
	      struct sockaddr_in	sin;
	      int			size = sizeof(sin);

	      h = [[WindowsFileHandle alloc] initWithFileDescriptor: desc
						  closeOnDealloc: YES];
	      getpeername(desc, (struct sockaddr*)&sin, &size);
	      [h setAddr: &sin];
	      [readInfo setObject: h
			   forKey: NSFileHandleNotificationFileHandleItem];
	      [h release];
	    }
	  [self postReadNotification];
	}
      else if (operation == NSFileHandleDataAvailableNotification)
	{
	  [self postReadNotification];
	}
      else
	{
	  NSMutableData	*item;
	  int		length;
	  int		received = 0;
	  char		buf[NETBUF_SIZE];

	  item = [readInfo objectForKey: NSFileHandleNotificationDataItem];
	  length = [item length];

	  received = read(descriptor, buf, sizeof(buf));
	  if (received == 0)
	    { // Read up to end of file.
	      [self postReadNotification];
	    }
	  else if (received < 0)
	    {
	      if (errno != EAGAIN && errno != EINTR)
		{
		  NSString	*s;

		  s = [NSString stringWithFormat: @"Read attempt failed - %s",
                          GSLastErrorStr(errno)];
		  [readInfo setObject: s forKey: GSFileHandleNotificationError];
		  [self postReadNotification];
		}
	    }
	  else
	    {
	      [item appendBytes: buf length: received];
	      if (operation == NSFileHandleReadCompletionNotification)
		{
		  // Read a single chunk of data
		  [self postReadNotification];
		}
	    }
	}
    }
  else if (type == ET_WDESC)
    {
      NSMutableDictionary	*info;

      info = [writeInfo objectAtIndex: 0];
      operation = [info objectForKey: NotificationKey];
      if (operation == GSFileHandleWriteCompletionNotification)
	{
	  NSData	*item;
	  int		length;
	  const void	*ptr;

	  item = [info objectForKey: NSFileHandleNotificationDataItem];
	  length = [item length];
	  ptr = [item bytes];
	  if (writePos < length)
	    {
	      int	written;

	      written = write(descriptor, (char*)ptr+writePos, length-writePos);
	      if (written <= 0)
		{
		  if (written < 0 && errno != EAGAIN && errno != EINTR)
		    {
		      NSString	*s;

		      s = [NSString stringWithFormat:
			@"Write attempt failed - %s", GSLastErrorStr(errno)];
		      [info setObject: s forKey: GSFileHandleNotificationError];
		      [self postWriteNotification];
		    }
		}
	      else
		{
		  writePos += written;
		}
	    }
	  if (writePos >= length)
	    { // Write operation completed.
	      [self postWriteNotification];
	    }
	}
      else
	{ // Connection attempt completed.
	  int	result;
	  int	len = sizeof(result);

	  if (getsockopt(descriptor, SOL_SOCKET, SO_ERROR,
	    (char*)&result, &len) == 0 && result != 0)
	    {
	      NSString	*s;

	      s = [NSString stringWithFormat: @"Connect attempt failed - %s",
		GSLastErrorStr(result)];
	      [info setObject: s forKey: GSFileHandleNotificationError];
	    }
	  else
	    {
	      readOK = YES;
	      writeOK = YES;
	    }
	  connectOK = NO;
	  [self postWriteNotification];
	}
    }
}

- (NSDate*) timedOutEvent: (void*)data
		     type: (RunLoopEventType)type
		  forMode: (NSString*)mode
{
  return nil;		/* Don't restart timed out events	*/
}

- (void) setAddr: (struct sockaddr_in *)sin
{
  address = [NSString stringWithCString: (char*)inet_ntoa(sin->sin_addr)];
  [address retain];
  service = [NSString stringWithFormat: @"%d",
	(int)GSSwapBigI16ToHost(sin->sin_port)];
  [service retain];
  protocol = @"tcp";
}

- (void) setNonBlocking: (BOOL)flag
{
  unsigned long dummy;

  if (descriptor < 0)
    return;

  if (isStandardFile)
    return;

  if (isNonBlocking == flag)
    return;

  dummy = 1;
  if (flag)
    {
      if (ioctlsocket(descriptor, FIONBIO, &dummy) < 0)
        {
          NSLog(@"unable to set non-blocking mode - %s", GSLastErrorStr(errno));
        }
    }
}

- (NSString*) socketAddress
{
  return address;
}

- (NSString*) socketProtocol
{
  return protocol;
}

- (NSString*) socketService
{
  return service;
}

@end


