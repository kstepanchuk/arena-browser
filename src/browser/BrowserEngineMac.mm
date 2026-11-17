#include "BrowserEngine.h"

#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <WebKit/WebKit.h>

#include <chrono>
#include <atomic>
#include <algorithm>
#include <mutex>

struct BrowserEngineState
{
	std::mutex mutex;
	std::vector< uint8_t > pixels;
	int width = 0;
	int height = 0;
	bool frameReady = false;
	bool snapshotInProgress = false;
	std::atomic< bool > controllerCreated{ false };
	std::atomic< unsigned int > snapshotIntervalMilliseconds{ 66 };
	std::chrono::steady_clock::time_point lastSnapshot{};
	__strong id controller = nil;
};

@interface BrowserWindowController : NSObject < WKNavigationDelegate, WKUIDelegate, NSWindowDelegate >
- (instancetype)initWithState:(std::weak_ptr< BrowserEngineState >)state;
- (void)navigate:(NSString*)address;
- (void)reloadPage;
- (void)goBack;
- (void)goForward;
- (void)toggleInteractionWindow;
- (void)shutdown;
- (void)takeSnapshot;
@end

@implementation BrowserWindowController
{
	std::weak_ptr< BrowserEngineState > _state;
	NSPanel* _panel;
	WKWebView* _webView;
	BOOL _interactionVisible;
}

- (instancetype)initWithState:(std::weak_ptr< BrowserEngineState >)state
{
	if( ( self = [super init] ) )
	{
		_state = state;
		NSRect rect = NSMakeRect( 120, 120, 1280, 720 );
		NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable;
		_panel = [[NSPanel alloc] initWithContentRect:rect styleMask:style backing:NSBackingStoreBuffered defer:NO];
		// Keep the host application's title-bar text untouched. Resolume embeds FFGL
		// sources in a long-lived AppKit process; changing a newly-created panel title
		// here can crash AppKit's title text measurement cache on some macOS builds.
		_panel.titleVisibility = NSWindowTitleHidden;
		_panel.delegate = self;
		_panel.releasedWhenClosed = NO;
		_panel.restorable = NO;
		WKWebViewConfiguration* configuration = [[WKWebViewConfiguration alloc] init];
		configuration.websiteDataStore = WKWebsiteDataStore.defaultDataStore;
		configuration.defaultWebpagePreferences.allowsContentJavaScript = YES;
		configuration.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;
		_webView = [[WKWebView alloc] initWithFrame:_panel.contentView.bounds configuration:configuration];
		_webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
		_webView.navigationDelegate = self;
		_webView.UIDelegate = self;
		_panel.contentView = _webView;
		[_webView loadHTMLString:@"<!doctype html><meta charset='utf-8'><body style='font:24px -apple-system;display:grid;place-items:center;height:100vh;color:#555'>Введите URL в параметре «Адрес страницы»</body>" baseURL:nil];
		[_panel orderOut:nil];
	}
	return self;
}

- (void)navigate:(NSString*)address
{
	NSString* trimmed = [address stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
	if( trimmed.length == 0 )
		return;
	if( [trimmed rangeOfString:@"://"].location == NSNotFound )
		trimmed = [@"https://" stringByAppendingString:trimmed];
	NSURL* url = [NSURL URLWithString:trimmed];
	NSString* scheme = url.scheme.lowercaseString;
	if( url == nil || !( [scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"file"] ) )
	{
		[_webView loadHTMLString:@"<!doctype html><meta charset='utf-8'><body style='font:20px -apple-system;padding:32px;color:#b00020'>Не удалось открыть адрес. Используйте http://, https:// или file://.</body>" baseURL:nil];
		return;
	}
	[_webView loadRequest:[NSURLRequest requestWithURL:url]];
	if( !_interactionVisible )
		[_panel orderBack:nil];
}

- (void)reloadPage { [_webView reload]; }
- (void)goBack { if( _webView.canGoBack ) [_webView goBack]; }
- (void)goForward { if( _webView.canGoForward ) [_webView goForward]; }

- (void)toggleInteractionWindow
{
	_interactionVisible = !_interactionVisible;
	if( _interactionVisible )
		[_panel makeKeyAndOrderFront:nil];
	else
		[_panel orderBack:nil];
}

- (void)shutdown
{
	[_panel orderOut:nil];
}

- (void)windowWillClose:(NSNotification*)notification
{
	_interactionVisible = NO;
}

- (WKWebView*)webView:(WKWebView*)webView createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration forNavigationAction:(WKNavigationAction*)navigationAction windowFeatures:(WKWindowFeatures*)windowFeatures
{
	if( navigationAction.targetFrame == nil )
		[webView loadRequest:navigationAction.request];
	return nil;
}

- (void)takeSnapshot
{
	std::shared_ptr< BrowserEngineState > state = _state.lock();
	if( !state )
		return;
	WKSnapshotConfiguration* configuration = [[WKSnapshotConfiguration alloc] init];
	configuration.afterScreenUpdates = YES;
	[_webView takeSnapshotWithConfiguration:configuration completionHandler:^( NSImage* image, NSError* error ) {
		std::shared_ptr< BrowserEngineState > current = self->_state.lock();
		if( current && image != nil )
		{
			NSRect proposed = NSMakeRect( 0, 0, image.size.width, image.size.height );
			CGImageRef cgImage = [image CGImageForProposedRect:&proposed context:nil hints:nil];
			if( cgImage != nullptr )
			{
				size_t width = CGImageGetWidth( cgImage );
				size_t height = CGImageGetHeight( cgImage );
				std::vector< uint8_t > pixels( width * height * 4 );
				CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
				CGContextRef context = CGBitmapContextCreate( pixels.data(), width, height, 8, width * 4, colorSpace,
					kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst );
				CGColorSpaceRelease( colorSpace );
				if( context != nullptr )
				{
					CGContextTranslateCTM( context, 0, height );
					CGContextScaleCTM( context, 1, -1 );
					CGContextDrawImage( context, CGRectMake( 0, 0, width, height ), cgImage );
					CGContextRelease( context );
					std::lock_guard< std::mutex > lock( current->mutex );
					current->pixels = std::move( pixels );
					current->width = static_cast< int >( width );
					current->height = static_cast< int >( height );
					current->frameReady = true;
				}
			}
		}
		std::lock_guard< std::mutex > lock( state->mutex );
		state->snapshotInProgress = false;
	}];
}
@end

static BrowserWindowController* EnsureController( const std::shared_ptr< BrowserEngineState >& state )
{
	__block BrowserWindowController* result = nil;
	void ( ^createController )( void ) = ^{
		if( state->controller == nil )
			state->controller = [[BrowserWindowController alloc] initWithState:state];
		state->controllerCreated = true;
		result = (BrowserWindowController*)state->controller;
	};
	if( NSThread.isMainThread )
		createController();
	else
		dispatch_sync( dispatch_get_main_queue(), createController );
	return result;
}

BrowserEngine::BrowserEngine() : state( std::make_shared< BrowserEngineState >() )
{
}

BrowserEngine::~BrowserEngine()
{
	std::shared_ptr< BrowserEngineState > old = std::move( state );
	if( !old || !old->controllerCreated.load() )
		return;
	void ( ^releaseController )( void ) = ^{
		if( old->controller != nil )
			[(BrowserWindowController*)old->controller shutdown];
		old->controller = nil;
	};
	if( NSThread.isMainThread )
		releaseController();
	else
		dispatch_sync( dispatch_get_main_queue(), releaseController );
}

void BrowserEngine::Navigate( const std::string& address )
{
	NSString* text = [NSString stringWithUTF8String:address.c_str()] ?: @"";
	std::shared_ptr< BrowserEngineState > current = state;
	dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) navigate:text]; });
}

void BrowserEngine::Reload()
{
	std::shared_ptr< BrowserEngineState > current = state;
	dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) reloadPage]; });
}

void BrowserEngine::GoBack()
{
	std::shared_ptr< BrowserEngineState > current = state;
	dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) goBack]; });
}

void BrowserEngine::GoForward()
{
	std::shared_ptr< BrowserEngineState > current = state;
	dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) goForward]; });
}

void BrowserEngine::ToggleInteractionWindow()
{
	std::shared_ptr< BrowserEngineState > current = state;
	dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) toggleInteractionWindow]; });
}

void BrowserEngine::SetFrameRate( unsigned int framesPerSecond )
{
	framesPerSecond = std::clamp( framesPerSecond, 1u, 60u );
	state->snapshotIntervalMilliseconds = std::max( 1u, 1000u / framesPerSecond );
}

void BrowserEngine::RequestFrame()
{
	std::shared_ptr< BrowserEngineState > current = state;
	if( !current || !current->controllerCreated.load() )
		return;
	bool request = false;
	{
		std::lock_guard< std::mutex > lock( current->mutex );
		auto now = std::chrono::steady_clock::now();
		const unsigned int interval = current->snapshotIntervalMilliseconds.load();
		if( !current->snapshotInProgress && now - current->lastSnapshot >= std::chrono::milliseconds( interval ) )
		{
			current->snapshotInProgress = true;
			current->lastSnapshot = now;
			request = true;
		}
	}
	if( request )
		dispatch_async( dispatch_get_main_queue(), ^{ [EnsureController( current ) takeSnapshot]; });
}

bool BrowserEngine::TakeFrame( std::vector< uint8_t >& bgra, int& width, int& height )
{
	std::lock_guard< std::mutex > lock( state->mutex );
	if( !state->frameReady )
		return false;
	bgra.swap( state->pixels );
	width = state->width;
	height = state->height;
	state->frameReady = false;
	return true;
}
