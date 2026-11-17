#pragma once

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

struct BrowserEngineState;

class BrowserEngine
{
public:
	BrowserEngine();
	~BrowserEngine();
	BrowserEngine( const BrowserEngine& )            = delete;
	BrowserEngine& operator=( const BrowserEngine& ) = delete;

	void Navigate( const std::string& address );
	void Reload();
	void GoBack();
	void GoForward();
	void ToggleInteractionWindow();
	void SetFrameRate( unsigned int framesPerSecond );
	void RequestFrame();
	bool TakeFrame( std::vector< uint8_t >& bgra, int& width, int& height );

private:
	std::shared_ptr< BrowserEngineState > state;
};
