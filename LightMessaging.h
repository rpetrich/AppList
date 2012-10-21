#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#include <mach/mach.h>
#include <mach/mach_init.h>
#include <bootstrap.h>

#ifdef __OBJC__
#import <UIKit/UIKit.h>
#endif

typedef struct {
	mach_port_t serverPort;
	name_t serverName;
} LMConnection;
typedef LMConnection *LMConnectionRef;

#define __LMMaxInlineSize 4096
typedef struct __LMMessage {
	mach_msg_header_t head;
	mach_msg_body_t body;
    mach_msg_ool_descriptor_t out_of_line;
    size_t length;
	uint8_t bytes[0];
} LMMessage;

typedef struct __LMResponseBuffer {
	LMMessage message;
	uint8_t slack[__LMMaxInlineSize - sizeof(LMMessage) + MAX_TRAILER_SIZE];
} LMResponseBuffer;

static inline size_t LMBufferSizeForLength(size_t length)
{
	if (length + sizeof(LMMessage) > __LMMaxInlineSize)
		return sizeof(LMMessage);
	else
		return ((sizeof(LMMessage) + length) + 3) & ~0x3;
}

static inline void LMMessageCopyInline(LMMessage *message, const void *data, size_t length)
{
	message->length = length;
	if (data) {
		memcpy(message->bytes, data, length);
	}
}

static inline void LMMessageAssignOutOfLine(LMMessage *message, const void *data, size_t length)
{
	message->head.msgh_bits |= MACH_MSGH_BITS_COMPLEX;
	message->body.msgh_descriptor_count = 1;
	message->out_of_line.type = MACH_MSG_OOL_DESCRIPTOR;
	message->out_of_line.copy = MACH_MSG_VIRTUAL_COPY;
	message->out_of_line.deallocate = false;
	message->out_of_line.address = (void *)data;
	message->out_of_line.size = length;
}

static inline void LMMessageAssignData(LMMessage *message, const void *data, size_t length)
{
	message->length = length;
	if (length == 0) {
		message->body.msgh_descriptor_count = 0;
	} else if (message->head.msgh_size != sizeof(LMMessage)) {
		message->body.msgh_descriptor_count = 0;
		memcpy(message->bytes, data, length);
	} else {
		LMMessageAssignOutOfLine(message, data, length);
	}
}

static inline void *LMMessageGetData(LMMessage *message)
{
	if (message->length == 0)
		return NULL;
	if (message->body.msgh_descriptor_count != 0 && message->out_of_line.type == MACH_MSG_OOL_DESCRIPTOR)
		return message->out_of_line.address;
	return &message->bytes;
}

static inline size_t LMMessageGetDataLength(LMMessage *message)
{
	size_t result = message->length;
	if (result == 0)
		return 0;
	// Use descriptor size if we have an out_of_line memory region
	if (message->body.msgh_descriptor_count != 0 && message->out_of_line.type == MACH_MSG_OOL_DESCRIPTOR)
		return message->out_of_line.size;
	// Clip to the maximum size of a message buffer, prevents clients from forcing reads outside the region
	if (result > __LMMaxInlineSize - offsetof(LMMessage, bytes))
		return __LMMaxInlineSize - offsetof(LMMessage, bytes);
	// Client specified the right size, yay!
	return result;
}

static inline mach_msg_return_t LMMachMsg(LMConnection *connection, mach_msg_header_t *msg, mach_msg_option_t option, mach_msg_size_t send_size, mach_msg_size_t rcv_size, mach_port_name_t rcv_name, mach_msg_timeout_t timeout, mach_port_name_t notify)
{
	for (;;) {
		kern_return_t err;
		if (connection->serverPort == MACH_PORT_NULL) {
			mach_port_t selfTask = mach_task_self();
			// Lookup remote port
			mach_port_t bootstrap = MACH_PORT_NULL;
			task_get_bootstrap_port(selfTask, &bootstrap);
			err = bootstrap_look_up(bootstrap, connection->serverName, &connection->serverPort);
			if (err)
				return err;
		}
		msg->msgh_remote_port = connection->serverPort;
		err = mach_msg(msg, option, send_size, rcv_size, rcv_name, timeout, notify);
		if (err != MACH_SEND_INVALID_DEST)
			return err;
		mach_port_deallocate(mach_task_self(), msg->msgh_remote_port);
		connection->serverPort = MACH_PORT_NULL;
	}
}

static inline kern_return_t LMConnectionSendOneWay(LMConnectionRef connection, SInt32 messageId, const void *data, size_t length)
{
	// Send message
	size_t size = LMBufferSizeForLength(length);
	uint8_t buffer[size];
	LMMessage *message = (LMMessage *)&buffer[0];
	memset(message, 0, sizeof(LMMessage));
	message->head.msgh_id = messageId;
	message->head.msgh_size = size;
	message->head.msgh_local_port = MACH_PORT_NULL;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
	LMMessageAssignData(message, data, length);
	return LMMachMsg(connection, &message->head, MACH_SEND_MSG, size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
}

static inline kern_return_t LMConnectionSendTwoWay(LMConnectionRef connection, SInt32 messageId, const void *data, size_t length, LMResponseBuffer *responseBuffer)
{
	// Create a reply port
	mach_port_t selfTask = mach_task_self();
	mach_port_name_t replyPort = MACH_PORT_NULL;
	int err = mach_port_allocate(selfTask, MACH_PORT_RIGHT_RECEIVE, &replyPort);
	if (err) {
		responseBuffer->message.body.msgh_descriptor_count = 0;
		return err;
	}
	// Send message
	size_t size = LMBufferSizeForLength(length);
	LMMessage *message = &responseBuffer->message;
	memset(message, 0, sizeof(LMMessage));
	message->head.msgh_id = messageId;
	message->head.msgh_size = size;
	message->head.msgh_local_port = replyPort;
	message->head.msgh_reserved = 0;
	message->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, MACH_MSG_TYPE_MAKE_SEND_ONCE);
	LMMessageAssignData(message, data, length);
	err = LMMachMsg(connection, &message->head, MACH_SEND_MSG | MACH_RCV_MSG, size, sizeof(LMResponseBuffer), replyPort, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	if (err)
		responseBuffer->message.body.msgh_descriptor_count = 0;
	// Cleanup
	mach_port_deallocate(selfTask, replyPort);
	return err;
}

static inline void LMResponseBufferFree(LMResponseBuffer *responseBuffer)
{
	if (responseBuffer->message.body.msgh_descriptor_count != 0 && responseBuffer->message.out_of_line.type == MACH_MSG_OOL_DESCRIPTOR) {
		vm_deallocate(mach_task_self(), (vm_address_t)responseBuffer->message.out_of_line.address, responseBuffer->message.out_of_line.size);
		responseBuffer->message.body.msgh_descriptor_count = 0;
	}
}

static inline kern_return_t LMSendReply(mach_port_t replyPort, const void *data, size_t length)
{
	if (replyPort == MACH_PORT_NULL)
		return 0;
	size_t size = LMBufferSizeForLength(length);
	uint8_t buffer[size];
	memset(buffer, 0, sizeof(LMMessage));
	LMMessage *response = (LMMessage *)&buffer[0];
	response->head.msgh_id = 0;
	response->head.msgh_size = size;
	response->head.msgh_remote_port = replyPort;
	response->head.msgh_local_port = MACH_PORT_NULL;
	response->head.msgh_reserved = 0;
	response->head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
	LMMessageAssignData(response, data, length);
	// Send message
	kern_return_t err = mach_msg(&response->head, MACH_SEND_MSG, size, 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	if (err) {
		// Cleanup leaked SEND_ONCE
		mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_SEND_ONCE, -1);
	}
	return err;
}

static inline kern_return_t LMSendIntegerReply(mach_port_t replyPort, int integer)
{
	return LMSendReply(replyPort, &integer, sizeof(integer));
}

static inline kern_return_t LMSendCFDataReply(mach_port_t replyPort, CFDataRef data)
{
	if (data) {
		return LMSendReply(replyPort, CFDataGetBytePtr(data), CFDataGetLength(data));
	} else {
		return LMSendReply(replyPort, NULL, 0);
	}
}

#ifdef __OBJC__

static inline kern_return_t LMSendNSDataReply(mach_port_t replyPort, NSData *data)
{
	return LMSendReply(replyPort, [data bytes], [data length]);
}

static inline kern_return_t LMSendPropertyListReply(mach_port_t replyPort, id propertyList)
{
	if (propertyList)
		return LMSendNSDataReply(replyPort, [NSPropertyListSerialization dataFromPropertyList:propertyList format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL]);
	else
		return LMSendReply(replyPort, NULL, 0);
}

#endif

// Remote functions

static inline bool LMConnectionSendOneWayData(LMConnectionRef connection, SInt32 messageId, CFDataRef data)
{
	if (data)
		return LMConnectionSendOneWay(connection, messageId, CFDataGetBytePtr(data), CFDataGetLength(data)) == 0;
	else
		return LMConnectionSendOneWay(connection, messageId, NULL, 0) == 0;
}

static inline kern_return_t LMConnectionSendTwoWayData(LMConnectionRef connection, SInt32 messageId, CFDataRef data, LMResponseBuffer *buffer)
{
	if (data)
		return LMConnectionSendTwoWay(connection, messageId, CFDataGetBytePtr(data), CFDataGetLength(data), buffer);
	else
		return LMConnectionSendTwoWay(connection, messageId, NULL, 0, buffer);
}

static inline int LMResponseConsumeInteger(LMResponseBuffer *buffer)
{
	LMResponseBufferFree(buffer);
	return LMMessageGetDataLength(&buffer->message) == sizeof(int) ? *(int *)buffer->message.bytes : 0;
}

#ifdef __OBJC__

static inline kern_return_t LMConnectionSendTwoWayPropertyList(LMConnectionRef connection, SInt32 messageId, id propertyList, LMResponseBuffer *buffer)
{
	return LMConnectionSendTwoWayData(connection, messageId, propertyList ? (CFDataRef)[NSPropertyListSerialization dataFromPropertyList:propertyList format:NSPropertyListBinaryFormat_v1_0 errorDescription:NULL] : NULL, buffer);
}

static inline id LMResponseConsumePropertyList(LMResponseBuffer *buffer)
{
	size_t length = LMMessageGetDataLength(&buffer->message);
	id result;
	if (length) {
		CFDataRef data = CFDataCreateWithBytesNoCopy(kCFAllocatorDefault, LMMessageGetData(&buffer->message), length, kCFAllocatorNull);
		result = [NSPropertyListSerialization propertyListFromData:(NSData *)data mutabilityOption:0 format:NULL errorDescription:NULL];
		CFRelease(data);
	} else {
		result = nil;
	}
	LMResponseBufferFree(buffer);
	return result;
}

typedef struct {
	size_t width;
	size_t height;
	size_t bitsPerComponent;
	size_t bitsPerPixel;
	size_t bytesPerRow;
	CGBitmapInfo bitmapInfo;
	CGFloat scale;
	UIImageOrientation orientation;
} LMImageHeader;

static void LMCGDataProviderReleaseCallback(void *info, const void *data, size_t size)
{
	vm_deallocate(mach_task_self(), (vm_address_t)data, size);
}

static inline UIImage *LMResponseConsumeImage(LMResponseBuffer *buffer)
{
	if (buffer->message.body.msgh_descriptor_count != 0 && buffer->message.out_of_line.type == MACH_MSG_OOL_DESCRIPTOR) {
		const void *bytes = buffer->message.out_of_line.address;
		const LMImageHeader *header = (const LMImageHeader *)&buffer->message.bytes;
		CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, bytes, buffer->message.out_of_line.size, LMCGDataProviderReleaseCallback);
		if (provider) {
			CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
			CGImageRef cgImage = CGImageCreate(header->width, header->height, header->bitsPerComponent, header->bitsPerPixel, header->bytesPerRow, colorSpace, header->bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
			CGColorSpaceRelease(colorSpace);
			CGDataProviderRelease(provider);
			if (cgImage) {
				UIImage *image;
				if ([UIImage respondsToSelector:@selector(imageWithCGImage:scale:orientation:)]) {
					image = [UIImage imageWithCGImage:cgImage scale:header->scale orientation:header->orientation];
				} else {
					image = [UIImage imageWithCGImage:cgImage];
				}
				CGImageRelease(cgImage);
				return image;
			}
			return nil;
		}
	}
	LMResponseBufferFree(buffer);
	return nil;
}

typedef struct CGAccessSession *CGAccessSessionRef;

CGAccessSessionRef CGAccessSessionCreate(CGDataProviderRef provider);
void *CGAccessSessionGetBytePointer(CGAccessSessionRef session);
size_t CGAccessSessionGetBytes(CGAccessSessionRef session,void *buffer,size_t bytes);
void CGAccessSessionRelease(CGAccessSessionRef session);

static inline kern_return_t LMSendImageReply(mach_port_t replyPort, UIImage *image)
{
	if (replyPort == MACH_PORT_NULL)
		return 0;
	struct {
		LMMessage response;
		LMImageHeader imageHeader;
	} buffer;
	memset(&buffer, 0, sizeof(buffer));
	buffer.response.head.msgh_id = 0;
	buffer.response.head.msgh_size = sizeof(buffer);
	buffer.response.head.msgh_remote_port = replyPort;
	buffer.response.head.msgh_local_port = MACH_PORT_NULL;
	buffer.response.head.msgh_reserved = 0;
	buffer.response.head.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_MOVE_SEND_ONCE, 0);
	CFDataRef imageData = NULL;
	CGAccessSessionRef accessSession = NULL;
	if (image) {
		CGImageRef cgImage = image.CGImage;
		if (cgImage) {
			buffer.imageHeader.width = CGImageGetWidth(cgImage);
			buffer.imageHeader.height = CGImageGetHeight(cgImage);
			buffer.imageHeader.bitsPerComponent = CGImageGetBitsPerComponent(cgImage);
			buffer.imageHeader.bitsPerPixel = CGImageGetBitsPerPixel(cgImage);
			buffer.imageHeader.bytesPerRow = CGImageGetBytesPerRow(cgImage);
			buffer.imageHeader.bitmapInfo = CGImageGetBitmapInfo(cgImage);
			buffer.imageHeader.scale = [image respondsToSelector:@selector(scale)] ? [image scale] : 1.0f;
			buffer.imageHeader.orientation = image.imageOrientation;
			CGDataProviderRef dataProvider = CGImageGetDataProvider(cgImage);
			bool hasLoadedData = false;
			if (&CGAccessSessionCreate != NULL) {
				accessSession = CGAccessSessionCreate(dataProvider);
				if (accessSession) {
					void *pointer = CGAccessSessionGetBytePointer(accessSession);
					if (pointer) {
						LMMessageAssignOutOfLine(&buffer.response, pointer, buffer.imageHeader.bytesPerRow * buffer.imageHeader.height);
						buffer.response.length = sizeof(LMImageHeader);
						hasLoadedData = true;
					}
				}
			}
			if (!hasLoadedData) {
				if (accessSession) {
					CGAccessSessionRelease(accessSession);
					accessSession = NULL;
				}
				imageData = CGDataProviderCopyData(dataProvider);
				if (imageData) {
					buffer.response.length = sizeof(LMImageHeader);
					LMMessageAssignOutOfLine(&buffer.response, CFDataGetBytePtr(imageData), CFDataGetLength(imageData));
				}
			}
		}
	}
	// Send message
	kern_return_t err = mach_msg(&buffer.response.head, MACH_SEND_MSG, sizeof(buffer), 0, MACH_PORT_NULL, MACH_MSG_TIMEOUT_NONE, MACH_PORT_NULL);
	if (err) {
		// Cleanup leaked SEND_ONCE
		mach_port_mod_refs(mach_task_self(), replyPort, MACH_PORT_RIGHT_SEND_ONCE, -1);
	}
	if (imageData) {
		CFRelease(imageData);
	}
	if (accessSession) {
		CGAccessSessionRelease(accessSession);
	}
	return err;
}

#endif
