#pragma once

#include "BrowserEngine.h"
#include "BrowserAudioOutput.h"
#include <FFGLSDK.h>
#include <string>
#include <vector>

class BrowserSource : public CFFGLPlugin
{
public:
	BrowserSource();
	~BrowserSource() override;
	FFResult InitGL( const FFGLViewportStruct* vp ) override;
	FFResult ProcessOpenGL( ProcessOpenGLStruct* pGL ) override;
	FFResult DeInitGL() override;
	FFResult SetFloatParameter( unsigned int index, float value ) override;
	FFResult SetTextParameter( unsigned int index, const char* value ) override;
	float GetFloatParameter( unsigned int index ) override;
	char* GetTextParameter( unsigned int index ) override;

private:
	void UploadFrame( const unsigned char* bgra, int width, int height );
	void UpdateAudioMarker( bool active );

	BrowserEngine browser;
	std::string address;
	std::string audioMarkerPath;
	BrowserAudioOutput audioOutput;
	std::vector< BrowserAudioDevice > audioDevices;
	unsigned int selectedAudioDevice = 0;
	unsigned int selectedAudioChannel = 0;
	bool audioEnabled = false;
	GLuint texture = 0;
	int textureWidth = 0;
	int textureHeight = 0;
	bool hasFrame = false;
	ffglex::FFGLShader shader;
	ffglex::FFGLScreenQuad quad;
};
