#pragma once

#include <cstdint>
#include <string>
#include <vector>

struct BrowserAudioDevice
{
	uint32_t id = 0;
	std::string name;
	uint32_t outputChannels = 0;
};

class BrowserAudioOutput
{
public:
	BrowserAudioOutput();
	~BrowserAudioOutput();
	BrowserAudioOutput( const BrowserAudioOutput& ) = delete;
	BrowserAudioOutput& operator=( const BrowserAudioOutput& ) = delete;

	static std::vector< BrowserAudioDevice > ListOutputDevices();
	void SetOutput( uint32_t deviceId, uint32_t firstChannel );
	void SetEnabled( bool enabled );

private:
	struct Impl;
	Impl* impl;
};
