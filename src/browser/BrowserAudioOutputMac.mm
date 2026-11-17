#import "BrowserAudioOutput.h"

#import <AudioToolbox/AudioToolbox.h>
#import <CoreAudio/AudioHardware.h>
#import <CoreAudio/AudioHardwareTapping.h>
#import <CoreAudio/CATapDescription.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstring>
#include <chrono>
#include <filesystem>
#include <mutex>
#include <cstdlib>
#include <thread>
#include <unistd.h>
#include <vector>

namespace
{
constexpr uint64_t kRingFrames = 1u << 15;
constexpr uint64_t kRingMask = kRingFrames - 1;

struct AudioRoute
{
	std::atomic< uint64_t > writeIndex{ 0 };
	std::atomic< uint64_t > readIndex{ 0 };
	std::atomic< bool > enabled{ false };
	std::atomic< bool > stopping{ false };
	std::vector< float > samples = std::vector< float >( kRingFrames * 2, 0.0f );
	AudioObjectID tap = kAudioObjectUnknown;
	AudioObjectID aggregate = kAudioObjectUnknown;
	AudioDeviceIOProcID tapProc = nullptr;
	AudioUnit outputUnit = nullptr;
	AudioStreamBasicDescription tapFormat{};
	AudioDeviceID outputDevice = kAudioObjectUnknown;
	UInt32 firstChannel = 0;
	UInt32 outputChannels = 0;
	double readPosition = 0.0;
	std::mutex configMutex;
	uint32_t requestedDevice = 0;
	uint32_t requestedChannel = 0;
	bool requestedEnabled = false;
	uint64_t configVersion = 0;
};

UInt32 DeviceChannelCount( AudioDeviceID device )
{
	AudioObjectPropertyAddress address{ kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	if( AudioObjectGetPropertyDataSize( device, &address, 0, nullptr, &size ) != noErr || size == 0 )
		return 0;
	std::vector< uint8_t > storage( size );
	AudioBufferList* buffers = reinterpret_cast< AudioBufferList* >( storage.data() );
	if( AudioObjectGetPropertyData( device, &address, 0, nullptr, &size, buffers ) != noErr )
		return 0;
	UInt32 channels = 0;
	for( UInt32 i = 0; i < buffers->mNumberBuffers; ++i )
		channels += buffers->mBuffers[ i ].mNumberChannels;
	return channels;
}

std::string DeviceName( AudioDeviceID device )
{
	CFStringRef value = nullptr;
	AudioObjectPropertyAddress address{ kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	UInt32 size = sizeof( value );
	if( AudioObjectGetPropertyData( device, &address, 0, nullptr, &size, &value ) != noErr || value == nullptr )
		return "Audio device";
	char name[ 512 ]{};
	CFStringGetCString( value, name, sizeof( name ), kCFStringEncodingUTF8 );
	CFRelease( value );
	return name;
}

std::vector< AudioDeviceID > AllAudioDevices()
{
	AudioObjectPropertyAddress address{ kAudioHardwarePropertyDevices, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	UInt32 size = 0;
	if( AudioObjectGetPropertyDataSize( kAudioObjectSystemObject, &address, 0, nullptr, &size ) != noErr || size == 0 )
		return {};
	std::vector< AudioDeviceID > devices( size / sizeof( AudioDeviceID ) );
	if( AudioObjectGetPropertyData( kAudioObjectSystemObject, &address, 0, nullptr, &size, devices.data() ) != noErr )
		return {};
	return devices;
}

float DecodeSample( const uint8_t* data, UInt32 bits, bool isFloat )
{
	if( isFloat && bits == 32 ) return *reinterpret_cast< const float* >( data );
	if( isFloat && bits == 64 ) return static_cast< float >( *reinterpret_cast< const double* >( data ) );
	if( bits == 16 ) return static_cast< float >( *reinterpret_cast< const int16_t* >( data ) ) / 32768.0f;
	if( bits == 32 ) return static_cast< float >( *reinterpret_cast< const int32_t* >( data ) ) / 2147483648.0f;
	if( bits == 24 )
	{
		int32_t value = data[ 0 ] | ( data[ 1 ] << 8 ) | ( data[ 2 ] << 16 );
		if( value & 0x800000 ) value |= static_cast< int32_t >( 0xFF000000 );
		return static_cast< float >( value ) / 8388608.0f;
	}
	return 0.0f;
}

OSStatus TapCallback( AudioObjectID, const AudioTimeStamp*, const AudioBufferList* input,
	const AudioTimeStamp*, AudioBufferList*, const AudioTimeStamp*, void* refcon )
{
	auto* route = static_cast< AudioRoute* >( refcon );
	if( !route || !input || input->mNumberBuffers == 0 || route->tapFormat.mBytesPerFrame == 0 ) return noErr;
	const auto& format = route->tapFormat;
	const bool planar = ( format.mFormatFlags & kAudioFormatFlagIsNonInterleaved ) != 0;
	const bool isFloat = ( format.mFormatFlags & kAudioFormatFlagIsFloat ) != 0;
	const UInt32 bytes = std::max< UInt32 >( 1, format.mBitsPerChannel / 8 );
	const UInt32 channels = std::max< UInt32 >( 1, format.mChannelsPerFrame );
	const UInt32 stride = bytes * ( planar ? 1 : channels );
	UInt32 frames = input->mBuffers[ 0 ].mDataByteSize / stride;
	if( planar && input->mNumberBuffers < 2 ) return noErr;
	if( planar ) frames = std::min( frames, input->mBuffers[ 1 ].mDataByteSize / stride );
	const auto* leftData = static_cast< const uint8_t* >( input->mBuffers[ 0 ].mData );
	const auto* rightData = planar ? static_cast< const uint8_t* >( input->mBuffers[ 1 ].mData ) : leftData;
	if( !leftData || !rightData ) return noErr;
	const UInt32 rightChannel = planar ? 0 : std::min< UInt32 >( 1, channels - 1 );
	for( UInt32 frame = 0; frame < frames; ++frame )
	{
		const float left = DecodeSample( leftData + frame * stride, format.mBitsPerChannel, isFloat );
		const float right = channels == 1 ? left : DecodeSample( rightData + frame * stride + rightChannel * bytes, format.mBitsPerChannel, isFloat );
		uint64_t write = route->writeIndex.load( std::memory_order_relaxed );
		const uint64_t read = route->readIndex.load( std::memory_order_acquire );
		if( write - read >= kRingFrames ) continue;
		const size_t offset = static_cast< size_t >( write & kRingMask ) * 2;
		route->samples[ offset ] = left;
		route->samples[ offset + 1 ] = right;
		route->writeIndex.store( write + 1, std::memory_order_release );
	}
	return noErr;
}

OSStatus RenderCallback( void* refcon, AudioUnitRenderActionFlags*, const AudioTimeStamp*,
	UInt32, UInt32 frames, AudioBufferList* output )
{
	auto* route = static_cast< AudioRoute* >( refcon );
	if( !route || !output ) return noErr;
	for( UInt32 b = 0; b < output->mNumberBuffers; ++b )
		if( output->mBuffers[ b ].mData )
			std::memset( output->mBuffers[ b ].mData, 0, output->mBuffers[ b ].mDataByteSize );
	if( output->mNumberBuffers == 0 || !output->mBuffers[ 0 ].mData ) return noErr;
	const double ratio = route->tapFormat.mSampleRate > 0.0 ? route->tapFormat.mSampleRate / 48000.0 : 1.0;
	for( UInt32 frame = 0; frame < frames; ++frame )
	{
		const uint64_t read = static_cast< uint64_t >( route->readPosition );
		const uint64_t write = route->writeIndex.load( std::memory_order_acquire );
		if( read + 1 >= write ) break;
		const size_t source = static_cast< size_t >( read & kRingMask ) * 2;
		const size_t next = static_cast< size_t >( ( read + 1 ) & kRingMask ) * 2;
		const float fraction = static_cast< float >( route->readPosition - read );
		const float left = route->samples[ source ] + ( route->samples[ next ] - route->samples[ source ] ) * fraction;
		const float right = route->samples[ source + 1 ] + ( route->samples[ next + 1 ] - route->samples[ source + 1 ] ) * fraction;
		const UInt32 targets[ 2 ] = { route->firstChannel, route->firstChannel + 1 };
		for( UInt32 buffer = 0, base = 0; buffer < output->mNumberBuffers; ++buffer )
		{
			auto& out = output->mBuffers[ buffer ];
			if( !out.mData ) { base += out.mNumberChannels; continue; }
			const UInt32 count = out.mNumberChannels;
			for( UInt32 channel = 0; channel < count; ++channel )
			{
				const UInt32 absolute = base + channel;
				if( absolute == targets[ 0 ] ) static_cast< float* >( out.mData )[ frame * count + channel ] = left;
				if( absolute == targets[ 1 ] ) static_cast< float* >( out.mData )[ frame * count + channel ] = right;
			}
			base += count;
		}
		route->readPosition += ratio;
		route->readIndex.store( static_cast< uint64_t >( route->readPosition ), std::memory_order_release );
	}
	return noErr;
}

void StopRoute( AudioRoute* route )
{
	if( route->outputUnit )
	{
		AudioOutputUnitStop( route->outputUnit );
		AudioUnitUninitialize( route->outputUnit );
		AudioComponentInstanceDispose( route->outputUnit );
		route->outputUnit = nullptr;
	}
	if( route->aggregate != kAudioObjectUnknown && route->tapProc )
	{
		AudioDeviceStop( route->aggregate, route->tapProc );
		AudioDeviceDestroyIOProcID( route->aggregate, route->tapProc );
		route->tapProc = nullptr;
	}
	if( route->aggregate != kAudioObjectUnknown )
	{
		AudioHardwareDestroyAggregateDevice( route->aggregate );
		route->aggregate = kAudioObjectUnknown;
	}
	if( route->tap != kAudioObjectUnknown )
	{
		if( @available( macOS 14.2, * ) )
			AudioHardwareDestroyProcessTap( route->tap );
		route->tap = kAudioObjectUnknown;
	}
	route->readIndex = 0;
	route->writeIndex = 0;
	route->readPosition = 0.0;
}

bool StartRoute( AudioRoute* route )
{
	if( !route->enabled || route->outputDevice == kAudioObjectUnknown || route->outputChannels < route->firstChannel + 2 ) return false;
	if( @available( macOS 14.2, * ) )
	{
	const char* home = std::getenv( "HOME" );
	if( !home ) return false;
	const std::filesystem::path markers = std::filesystem::path( home ) / "Library/Application Support/Resolume Browser Source";
	const std::string prefix = "browser-" + std::to_string( getpid() ) + "-";
	std::error_code fileError;
	bool sourceLoaded = false;
	for( const auto& entry : std::filesystem::directory_iterator( markers, fileError ) )
		if( entry.path().filename().string().rfind( prefix, 0 ) == 0 && entry.path().extension() == ".active" ) { sourceLoaded = true; break; }
	if( !sourceLoaded ) return false;
	AudioObjectPropertyAddress listAddress{ kAudioHardwarePropertyProcessObjectList, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
	UInt32 listSize = 0;
	if( AudioObjectGetPropertyDataSize( kAudioObjectSystemObject, &listAddress, 0, nullptr, &listSize ) != noErr || !listSize ) return false;
	std::vector< AudioObjectID > processes( listSize / sizeof( AudioObjectID ) );
	if( AudioObjectGetPropertyData( kAudioObjectSystemObject, &listAddress, 0, nullptr, &listSize, processes.data() ) != noErr ) return false;
	AudioObjectID selected = kAudioObjectUnknown;
	for( AudioObjectID process : processes )
	{
		CFStringRef bundle = nullptr;
		AudioObjectPropertyAddress prop{ kAudioProcessPropertyBundleID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		UInt32 size = sizeof( bundle );
		if( AudioObjectGetPropertyData( process, &prop, 0, nullptr, &size, &bundle ) != noErr || !bundle ) continue;
		char value[ 256 ]{};
		CFStringGetCString( bundle, value, sizeof( value ), kCFStringEncodingUTF8 );
		CFRelease( bundle );
		if( std::strncmp( value, "com.apple.WebKit.GPU", 19 ) != 0 && std::strncmp( value, "com.apple.WebKit.WebContent", 27 ) != 0 ) continue;
		UInt32 running = 0;
		AudioObjectPropertyAddress isRunning{ kAudioProcessPropertyIsRunningOutput, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		size = sizeof( running );
		if( AudioObjectGetPropertyData( process, &isRunning, 0, nullptr, &size, &running ) == noErr && running )
		{
			if( selected != kAudioObjectUnknown ) return false;
			selected = process;
		}
	}
	if( selected == kAudioObjectUnknown ) return false;

	@autoreleasepool
	{
		CATapDescription* description = [[CATapDescription alloc] init];
		description.name = @"Arena Browser Source";
		description.processes = @[ @( selected ) ];
		description.privateTap = YES;
		description.mixdown = YES;
		description.mono = NO;
		description.exclusive = NO;
		description.muteBehavior = CATapMuted;
		OSStatus status = AudioHardwareCreateProcessTap( description, &route->tap );
		if( status != noErr ) return false;
		CFStringRef tapUid = nullptr;
		AudioObjectPropertyAddress tapUidAddress{ kAudioTapPropertyUID, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain };
		UInt32 tapUidSize = sizeof( tapUid );
		if( AudioObjectGetPropertyData( route->tap, &tapUidAddress, 0, nullptr, &tapUidSize, &tapUid ) != noErr || !tapUid ) { StopRoute( route ); return false; }
		NSString* aggregateUid = NSUUID.UUID.UUIDString;
		NSDictionary* tapEntry = @{ @kAudioSubTapUIDKey : (__bridge NSString*)tapUid, @kAudioSubTapDriftCompensationKey : @YES };
		NSDictionary* aggregate = @{ @kAudioAggregateDeviceNameKey : @"Arena Browser Source",
			@kAudioAggregateDeviceUIDKey : aggregateUid, @kAudioAggregateDeviceIsPrivateKey : @YES,
			@kAudioAggregateDeviceIsStackedKey : @NO, @kAudioAggregateDeviceTapListKey : @[ tapEntry ],
			@kAudioAggregateDeviceTapAutoStartKey : @NO };
		status = AudioHardwareCreateAggregateDevice( (__bridge CFDictionaryRef)aggregate, &route->aggregate );
		CFRelease( tapUid );
		if( status != noErr ) { StopRoute( route ); return false; }
		AudioObjectPropertyAddress formatAddress{ kAudioDevicePropertyStreamFormat, kAudioDevicePropertyScopeInput, kAudioObjectPropertyElementMain };
		UInt32 formatSize = sizeof( route->tapFormat );
		if( AudioObjectGetPropertyData( route->aggregate, &formatAddress, 0, nullptr, &formatSize, &route->tapFormat ) != noErr ) { StopRoute( route ); return false; }
		status = AudioDeviceCreateIOProcID( route->aggregate, TapCallback, route, &route->tapProc );
		if( status == noErr ) status = AudioDeviceStart( route->aggregate, route->tapProc );
		if( status != noErr ) { StopRoute( route ); return false; }
		route->readIndex = route->writeIndex.load( std::memory_order_acquire );
		route->readPosition = static_cast< double >( route->readIndex.load( std::memory_order_relaxed ) );

		AudioComponentDescription componentDescription{ kAudioUnitType_Output, kAudioUnitSubType_HALOutput, kAudioUnitManufacturer_Apple, 0, 0 };
		AudioComponent component = AudioComponentFindNext( nullptr, &componentDescription );
		if( !component || AudioComponentInstanceNew( component, &route->outputUnit ) != noErr ) { StopRoute( route ); return false; }
		UInt32 enable = 1, disable = 0;
		AudioUnitSetProperty( route->outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Output, 0, &enable, sizeof( enable ) );
		AudioUnitSetProperty( route->outputUnit, kAudioOutputUnitProperty_EnableIO, kAudioUnitScope_Input, 1, &disable, sizeof( disable ) );
		status = AudioUnitSetProperty( route->outputUnit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &route->outputDevice, sizeof( route->outputDevice ) );
		if( status != noErr ) { StopRoute( route ); return false; }
		AURenderCallbackStruct callback{ RenderCallback, route };
		status = AudioUnitSetProperty( route->outputUnit, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &callback, sizeof( callback ) );
		if( status != noErr ) { StopRoute( route ); return false; }
		AudioStreamBasicDescription clientFormat{};
		clientFormat.mSampleRate = 48000.0;
		clientFormat.mFormatID = kAudioFormatLinearPCM;
		clientFormat.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
		clientFormat.mBytesPerPacket = sizeof( float );
		clientFormat.mFramesPerPacket = 1;
		clientFormat.mBytesPerFrame = sizeof( float );
		clientFormat.mChannelsPerFrame = route->outputChannels;
		clientFormat.mBitsPerChannel = 32;
		status = AudioUnitSetProperty( route->outputUnit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &clientFormat, sizeof( clientFormat ) );
		if( status == noErr ) status = AudioUnitInitialize( route->outputUnit );
		if( status == noErr ) status = AudioOutputUnitStart( route->outputUnit );
		if( status != noErr ) { StopRoute( route ); return false; }
	}
	return true;
	}
	return false;
}
}

struct BrowserAudioOutput::Impl
{
	AudioRoute route;
	std::thread worker;
	Impl() : worker( [this] {
		uint64_t seenVersion = 0;
		while( !route.stopping.load() )
		{
			uint32_t device = 0, channel = 0;
			bool enabled = false;
			uint64_t version = 0;
			{
				std::lock_guard< std::mutex > lock( route.configMutex );
				device = route.requestedDevice;
				channel = route.requestedChannel;
				enabled = route.requestedEnabled;
				version = route.configVersion;
			}
			if( version != seenVersion )
			{
				StopRoute( &route );
				route.outputDevice = device;
				route.firstChannel = channel;
				route.outputChannels = DeviceChannelCount( device );
				route.enabled = enabled;
				seenVersion = version;
			}
			else if( route.enabled.load() )
			{
				if( route.outputUnit == nullptr ) StartRoute( &route );
			}
			else if( route.outputUnit != nullptr ) StopRoute( &route );
			std::this_thread::sleep_for( std::chrono::milliseconds( 500 ) );
		}
		StopRoute( &route );
	} ) {}
	~Impl()
	{
		route.stopping = true;
		if( worker.joinable() ) worker.join();
	}
};

BrowserAudioOutput::BrowserAudioOutput() : impl( new Impl ) {}
BrowserAudioOutput::~BrowserAudioOutput() { delete impl; }

std::vector< BrowserAudioDevice > BrowserAudioOutput::ListOutputDevices()
{
	std::vector< BrowserAudioDevice > result;
	for( AudioDeviceID id : AllAudioDevices() )
	{
		const UInt32 channels = DeviceChannelCount( id );
		if( channels >= 2 ) result.push_back( { id, DeviceName( id ), channels } );
	}
	return result;
}

void BrowserAudioOutput::SetOutput( uint32_t deviceId, uint32_t firstChannel )
{
	std::lock_guard< std::mutex > lock( impl->route.configMutex );
	impl->route.requestedDevice = deviceId;
	impl->route.requestedChannel = firstChannel;
	++impl->route.configVersion;
}

void BrowserAudioOutput::SetEnabled( bool enabled )
{
	std::lock_guard< std::mutex > lock( impl->route.configMutex );
	impl->route.requestedEnabled = enabled;
	++impl->route.configVersion;
}
