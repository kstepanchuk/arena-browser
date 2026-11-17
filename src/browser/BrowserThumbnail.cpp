#include <FFGLSDK.h>
#include <algorithm>
#include <vector>

namespace
{
constexpr int WIDTH = 128;
constexpr int HEIGHT = 128;

std::vector< CFFGLColor > DrawBrowserThumbnail()
{
	std::vector< CFFGLColor > pixels( WIDTH * HEIGHT );
	for( int y = 0; y < HEIGHT; ++y )
	{
		for( int x = 0; x < WIDTH; ++x )
		{
			bool frame = x >= 17 && x < 111 && y >= 18 && y < 110;
			bool bar   = frame && y >= 18 && y < 32;
			bool page  = frame && y >= 33;
			bool line1 = page && y >= 48 && y < 53 && x >= 28 && x < 99;
			bool line2 = page && y >= 61 && y < 66 && x >= 28 && x < 88;
			bool line3 = page && y >= 74 && y < 79 && x >= 28 && x < 94;
			bool play  = page && ( ( x - 64 ) * ( x - 64 ) + ( y - 90 ) * ( y - 90 ) < 110 );
			CFFGLColor color( 18, 28, 42, 255 );
			if( frame )
				color = CFFGLColor( 35, 45, 60, 255 );
			if( bar )
				color = CFFGLColor( 55, 72, 92, 255 );
			if( page )
				color = CFFGLColor( 238, 244, 250, 255 );
			if( line1 || line2 || line3 )
				color = CFFGLColor( 145, 165, 185, 255 );
			if( play )
				color = CFFGLColor( 35, 190, 170, 255 );
			pixels[ y * WIDTH + x ] = color;
		}
	}
	return pixels;
}
}// namespace

static CFFGLThumbnailInfo BrowserThumbnailInfo( WIDTH, HEIGHT, DrawBrowserThumbnail() );
