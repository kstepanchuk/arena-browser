#include "BrowserSource.h"

#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <mutex>
#include <filesystem>
#include <unistd.h>
using namespace ffglex;

namespace
{
enum Param : unsigned int
{
	PT_ADDRESS,
	PT_NAVIGATE,
	PT_INTERACT,
	PT_RELOAD,
	PT_BACK,
	PT_FORWARD,
	PT_FRAME_RATE,
	PT_AUDIO_ENABLE,
	PT_AUDIO_DEVICE,
	PT_AUDIO_CHANNEL,
};

static const char vertexShader[] = R"(#version 410 core
layout( location = 0 ) in vec4 vPosition;
layout( location = 1 ) in vec2 vUV;
out vec2 uv;
void main() { gl_Position = vPosition; uv = vUV; }
)";

static const char fragmentShader[] = R"(#version 410 core
uniform sampler2D Page;
uniform int HasFrame;
in vec2 uv;
out vec4 fragColor;
void main() {
	if (HasFrame == 0) { fragColor = vec4(0.0); return; }
	fragColor = texture(Page, uv);
}
)";

static CFFGLPluginInfo PluginInfo(
	PluginFactory< BrowserSource >,
	"WBRS",
	"Браузер",
	2,
	1,
	PLUGIN_VERSION_MAJOR,
	PLUGIN_VERSION_MINOR,
	FF_SOURCE,
	"Веб-страница как источник Arena с режимом взаимодействия",
	"Встроенный браузер на WebKit для Resolume Arena"
);
}// namespace

BrowserSource::BrowserSource()
{
	SetMinInputs( 0 );
	SetMaxInputs( 0 );
	SetParamInfo( PT_ADDRESS, "Адрес", FF_TYPE_TEXT, "" );
	SetParamInfof( PT_NAVIGATE, "Открыть", FF_TYPE_EVENT );
	SetParamInfof( PT_INTERACT, "Веб-окно", FF_TYPE_EVENT );
	SetParamInfof( PT_RELOAD, "Обнов.", FF_TYPE_EVENT );
	SetParamInfof( PT_BACK, "Назад", FF_TYPE_EVENT );
	SetParamInfof( PT_FORWARD, "Вперёд", FF_TYPE_EVENT );
	SetOptionParamInfo( PT_FRAME_RATE, "Кадры", 3, 0.0f );
	SetParamElementInfo( PT_FRAME_RATE, 0, "15", 0.0f );
	SetParamElementInfo( PT_FRAME_RATE, 1, "24", 1.0f );
	SetParamElementInfo( PT_FRAME_RATE, 2, "30", 2.0f );
	SetParamGroup( PT_FRAME_RATE, "Производительность" );
	SetParamInfo( PT_AUDIO_ENABLE, "Звук браузера", FF_TYPE_BOOLEAN, false );
	audioDevices = BrowserAudioOutput::ListOutputDevices();
	const unsigned int deviceChoices = std::max< unsigned int >( 1, static_cast< unsigned int >( audioDevices.size() ) );
	SetOptionParamInfo( PT_AUDIO_DEVICE, "Выход звука", deviceChoices, 0.0f );
	if( audioDevices.empty() )
		SetParamElementInfo( PT_AUDIO_DEVICE, 0, "Выходы не найдены", 0.0f );
	for( unsigned int i = 0; i < audioDevices.size(); ++i )
	{
		const std::string label = audioDevices[ i ].name + " (" + std::to_string( audioDevices[ i ].outputChannels ) + " каналов)";
		SetParamElementInfo( PT_AUDIO_DEVICE, i, label.c_str(), static_cast< float >( i ) );
	}
	unsigned int maxPairs = 1;
	for( const auto& device : audioDevices )
		maxPairs = std::max( maxPairs, device.outputChannels / 2 );
	SetOptionParamInfo( PT_AUDIO_CHANNEL, "Стереопара", maxPairs, 0.0f );
	for( unsigned int i = 0; i < maxPairs; ++i )
	{
		const std::string label = std::to_string( i * 2 + 1 ) + "/" + std::to_string( i * 2 + 2 );
		SetParamElementInfo( PT_AUDIO_CHANNEL, i, label.c_str(), static_cast< float >( i ) );
	}
	SetParamGroup( PT_AUDIO_ENABLE, "Аудиовыход" );
	SetParamGroup( PT_AUDIO_DEVICE, "Аудиовыход" );
	SetParamGroup( PT_AUDIO_CHANNEL, "Аудиовыход" );
	if( !audioDevices.empty() )
		audioOutput.SetOutput( audioDevices.front().id, 0 );
	browser.SetFrameRate( 15 );
	const char* home = std::getenv( "HOME" );
	if( home != nullptr )
	{
		const std::string directory = std::string( home ) + "/Library/Application Support/Resolume Browser Source";
		std::error_code error;
		std::filesystem::create_directories( directory, error );
		audioMarkerPath = directory + "/browser-" + std::to_string( getpid() ) + "-" +
			std::to_string( reinterpret_cast< uintptr_t >( this ) ) + ".active";
	}
}

BrowserSource::~BrowserSource()
{
	audioOutput.SetEnabled( false );
	UpdateAudioMarker( false );
}

void BrowserSource::UpdateAudioMarker( bool active )
{
	if( audioMarkerPath.empty() )
		return;
	if( active )
	{
		std::ofstream marker( audioMarkerPath, std::ios::out | std::ios::trunc );
		marker << "active";
	}
	else
	{
		std::error_code error;
		std::filesystem::remove( audioMarkerPath, error );
	}
}

FFResult BrowserSource::InitGL( const FFGLViewportStruct* vp )
{
	UpdateAudioMarker( !address.empty() );
	if( !shader.Compile( vertexShader, fragmentShader ) || !quad.Initialise() )
	{
		DeInitGL();
		return FF_FAIL;
	}
	glGenTextures( 1, &texture );
	{
		Scoped2DTextureBinding binding( texture );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE );
		glTexParameteri( GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE );
	}
	return CFFGLPlugin::InitGL( vp );
}

FFResult BrowserSource::DeInitGL()
{
	audioEnabled = false;
	audioOutput.SetEnabled( false );
	UpdateAudioMarker( false );
	shader.FreeGLResources();
	quad.Release();
	if( texture != 0 )
		glDeleteTextures( 1, &texture );
	texture = 0;
	hasFrame = false;
	return FF_SUCCESS;
}

FFResult BrowserSource::ProcessOpenGL( ProcessOpenGLStruct* )
{
	browser.RequestFrame();
	std::vector< uint8_t > pixels;
	int width = 0, height = 0;
	if( browser.TakeFrame( pixels, width, height ) )
		UploadFrame( pixels.data(), width, height );

	ScopedShaderBinding shaderBinding( shader.GetGLID() );
	ScopedSamplerActivation activateSampler( 0 );
	Scoped2DTextureBinding textureBinding( texture );
	shader.Set( "Page", 0 );
	shader.Set( "HasFrame", hasFrame ? 1 : 0 );
	quad.Draw();
	return FF_SUCCESS;
}

void BrowserSource::UploadFrame( const unsigned char* bgra, int width, int height )
{
	Scoped2DTextureBinding binding( texture );
	if( width != textureWidth || height != textureHeight )
	{
		glTexImage2D( GL_TEXTURE_2D, 0, GL_RGBA8, width, height, 0, GL_BGRA, GL_UNSIGNED_BYTE, nullptr );
		textureWidth = width;
		textureHeight = height;
	}
	glTexSubImage2D( GL_TEXTURE_2D, 0, 0, 0, width, height, GL_BGRA, GL_UNSIGNED_BYTE, bgra );
	hasFrame = true;
}

FFResult BrowserSource::SetTextParameter( unsigned int index, const char* value )
{
	if( index != PT_ADDRESS )
		return FF_FAIL;
	address = value ? value : "";
	if( address.empty() )
	{
		audioEnabled = false;
		audioOutput.SetEnabled( false );
	}
	UpdateAudioMarker( !address.empty() );
	return FF_SUCCESS;
}

FFResult BrowserSource::SetFloatParameter( unsigned int index, float value )
{
	switch( index )
	{
	case PT_NAVIGATE: if( value >= 0.5f ) browser.Navigate( address ); break;
	case PT_INTERACT: if( value >= 0.5f ) browser.ToggleInteractionWindow(); break;
	case PT_RELOAD: if( value >= 0.5f ) browser.Reload(); break;
	case PT_BACK: if( value >= 0.5f ) browser.GoBack(); break;
	case PT_FORWARD: if( value >= 0.5f ) browser.GoForward(); break;
	case PT_FRAME_RATE:
		browser.SetFrameRate( value < 0.5f ? 15u : ( value < 1.5f ? 24u : 30u ) );
		break;
	case PT_AUDIO_ENABLE:
		audioEnabled = value >= 0.5f;
		audioOutput.SetEnabled( audioEnabled );
		break;
	case PT_AUDIO_DEVICE:
		if( !audioDevices.empty() )
		{
			selectedAudioDevice = std::min< unsigned int >( static_cast< unsigned int >( value + 0.5f ), static_cast< unsigned int >( audioDevices.size() - 1 ) );
		if( selectedAudioChannel * 2 + 2 > audioDevices[ selectedAudioDevice ].outputChannels )
			selectedAudioChannel = 0;
			audioOutput.SetOutput( audioDevices[ selectedAudioDevice ].id, selectedAudioChannel * 2 );
		}
		break;
	case PT_AUDIO_CHANNEL:
		if( !audioDevices.empty() )
		{
			const unsigned int availablePairs = std::max< unsigned int >( 1, audioDevices[ selectedAudioDevice ].outputChannels / 2 );
			selectedAudioChannel = std::min< unsigned int >( std::max( 0, static_cast< int >( value + 0.5f ) ), availablePairs - 1 );
			audioOutput.SetOutput( audioDevices[ selectedAudioDevice ].id, selectedAudioChannel * 2 );
		}
		break;
	default: return FF_FAIL;
	}
	return FF_SUCCESS;
}

float BrowserSource::GetFloatParameter( unsigned int index )
{
	if( index == PT_AUDIO_ENABLE ) return audioEnabled ? 1.0f : 0.0f;
	if( index == PT_AUDIO_DEVICE ) return static_cast< float >( selectedAudioDevice );
	if( index == PT_AUDIO_CHANNEL ) return static_cast< float >( selectedAudioChannel );
	return 0.0f;
}

char* BrowserSource::GetTextParameter( unsigned int index )
{
	static char empty[] = "";
	if( index == PT_ADDRESS )
		return const_cast< char* >( address.c_str() );
	return empty;
}
