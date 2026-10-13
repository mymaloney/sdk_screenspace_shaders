// Cartoony cel-shading post process for Garry's Mod, using the GShader library
// https://github.com/Akabenko/GShader-library
//
// NOTE: this must be compiled as Shader Model 3.0 (build_celshade.bat) and paired with
// GShader's "pp_vs30" vertex shader, like GShader's own shaders. UVs are computed from
// VPOS because the default screenspace texcoords are wrong when drawn this way in GMod.
//
// Requires GShader's reconstruction to be enabled (r_shaderlib 1), which provides:
//   _rt_NormalsTangents : .rg = world normal (octahedron encoded)
//   _rt_WPDepth         : .rgb = 1 / world position, .a = 1 / linear depth (units)
// Optionally uses GShader's lightmap buffer (r_shaderlib_lightmaps 1):
//   _rt_Lightmaps       : .rgb = baked lightmap of world brushes, black elsewhere
//
// Effect:
//   - on world brushes with a lightmap, the lighting is separated from the surface
//     color and stepped into hard-edged bands (clean cartoon shadows, texture kept)
//   - everything else (models, props, viewmodel) has its luminance quantized into
//     flat "toon" bands (hue is preserved)
//   - optional saturation boost
//   - ink outlines are drawn on depth and normal discontinuities
//
// Textures:
//   $basetexture : _rt_FullFrameFB
//   $texture1    : _rt_NormalsTangents
//   $texture2    : _rt_WPDepth
//   $texture3    : _rt_Lightmaps (set from Lua)
//
// Parameters:
//   $c0_x : number of shading bands for models (e.g. 4)
//   $c0_y : band edge softness, 0 = hard steps, 0.5 = smooth (e.g. 0.05)
//   $c0_z : saturation multiplier (1 = unchanged)
//   $c0_w : pixels darker than this keep their original brightness (keeps shadow detail)
//   $c1_x : outline thickness in pixels (e.g. 1)
//   $c1_y : depth edge threshold, relative to depth (e.g. 0.02)
//   $c1_z : normal edge threshold, 0-2 (e.g. 0.4)
//   $c1_w : outline opacity, 0-1
//   $c2_xyz : outline color
//   $c2_w : distance (units) at which outlines have fully faded out
//   $c3_x : number of lighting bands for lightmapped world (0 = off, use model banding)
//   $c3_y : brightness of the darkest lighting band (shadow brightness), 0-1
//   $c3_z : lightmap scale (set from Lua: 16 in HDR, 4.59479 in LDR)
//   $c3_w : lighting threshold, where the first lit band starts, 0-1 (e.g. 0.6)

#include "common.hlsl"

#define BandCount        Constants0.x
#define BandSoftness     Constants0.y
#define Saturation       Constants0.z
#define MinBrightness    Constants0.w
#define OutlineThickness Constants1.x
#define DepthThreshold   Constants1.y
#define NormalThreshold  Constants1.z
#define OutlineOpacity   Constants1.w
#define OutlineColor     Constants2.xyz
#define OutlineFadeDist  Constants2.w
#define LightBands       Constants3.x
#define ShadowLevel      Constants3.y
#define LightmapScaleC   Constants3.z
#define LightThreshold   Constants3.w

#define NormalBuffer     Tex1
#define WPDepthBuffer    Tex2
#define LightmapBuffer   Tex3

// only TEXCOORD0 is written by pp_vs30, so don't use PS_INPUT from common.hlsl
struct PS_INPUT_VPOS
{
	float2 uv  : TEXCOORD0;
	float2 pos : VPOS;
};

static const float3 LumaWeights = float3(0.299, 0.587, 0.114);

// GShader octahedron normal decoding
float3 DecodeNormal(float2 f)
{
	f = f * 2.0 - 1.0;
	float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
	float t = saturate(-n.z);
	n.xy += n.xy >= 0.0 ? -t : t;
	return normalize(n);
}

float3 SampleNormal(float2 uv)
{
	return DecodeNormal(tex2D(NormalBuffer, uv).rg);
}

float SampleDepth(float2 uv)
{
	return 1.0 / max(tex2D(WPDepthBuffer, uv).a, 1e-6);
}

// quantize x (0-1) into bands with an adjustable soft edge between them
float Posterize(float x, float bands, float softness)
{
	float f = x * bands;
	float i = floor(f);
	float t = smoothstep(0.5 - softness, 0.5 + softness, f - i);
	return (i + t) / bands;
}

float4 main( PS_INPUT_VPOS i ) : COLOR
{
	float2 uv = (i.pos + 0.5) * TexBaseSize;
	float3 color = tex2D(TexBase, uv).rgb;

	float depth = SampleDepth(uv);
	float3 normal = SampleNormal(uv);

	// fade outlines out in the distance (and on the skybox)
	float distanceFade = saturate(1.0 - depth / OutlineFadeDist);

	float2 px = TexBaseSize * OutlineThickness;
	float2 uvL = uv - float2(px.x, 0.0);
	float2 uvR = uv + float2(px.x, 0.0);
	float2 uvU = uv - float2(0.0, px.y);
	float2 uvD = uv + float2(0.0, px.y);

	// --- toon bands (models, props, anything without a lightmap) ---
	// pick the band from a slightly blurred luminance, so texture noise doesn't
	// flicker between bands and turn into speckles
	float luma = dot(color, LumaWeights);
	float blurLuma = luma * 0.5 + 0.125 * (
		dot(tex2D(TexBase, uvL).rgb, LumaWeights) +
		dot(tex2D(TexBase, uvR).rgb, LumaWeights) +
		dot(tex2D(TexBase, uvU).rgb, LumaWeights) +
		dot(tex2D(TexBase, uvD).rgb, LumaWeights));
	float banded = Posterize(saturate(blurLuma), BandCount, BandSoftness);
	// pixels darker than MinBrightness keep their own brightness instead of
	// being crushed to black (or boosted, which amplifies color noise)
	banded = max(banded, min(blurLuma, MinBrightness));
	// limit how far a pixel can be brightened/darkened to avoid blowing out colors
	float3 bandedColor = color * clamp(banded / max(blurLuma, 1e-3), 0.5, 1.5);

	// --- hard lighting (lightmapped world brushes) ---
	// the framebuffer is roughly surface color * lighting, so dividing out the smooth
	// lightmap and multiplying by a stepped version swaps soft shadows for hard ones
	// while keeping texture detail. Brightness is compared in gamma space, like the framebuffer.
	float3 lightmap = tex2D(LightmapBuffer, uv).rgb;
	float hasLightmap = step(1.0 / 255.0, max(lightmap.r, max(lightmap.g, lightmap.b)));
	hasLightmap *= step(0.5, LightBands);

	float lightLevel = pow(saturate(dot(lightmap, LumaWeights) * LightmapScaleC), 1.0 / 2.2);
	// shift so the first band boundary sits at LightThreshold
	float steppedLight = Posterize(saturate(lightLevel - LightThreshold + 0.5 / max(LightBands, 1.0)), max(LightBands, 1.0), BandSoftness);
	steppedLight = lerp(ShadowLevel, 1.0, steppedLight);
	float3 litColor = color * clamp(steppedLight / max(lightLevel, 1e-3), 0.2, 3.0);

	color = lerp(bandedColor, litColor, hasLightmap);

	// --- saturation ---
	float newLuma = dot(color, LumaWeights);
	color = saturate(lerp(newLuma.xxx, color, Saturation));

	// --- outlines ---
	// second derivative of depth, so flat surfaces at grazing angles don't get outlined
	float dL = SampleDepth(uvL);
	float dR = SampleDepth(uvR);
	float dU = SampleDepth(uvU);
	float dD = SampleDepth(uvD);
	float depthEdge = max(abs(dL + dR - 2.0 * depth), abs(dU + dD - 2.0 * depth)) / depth;
	depthEdge = smoothstep(DepthThreshold, DepthThreshold * 2.0, depthEdge);

	float normalDiff = 0.0;
	normalDiff = max(normalDiff, 1.0 - dot(normal, SampleNormal(uvL)));
	normalDiff = max(normalDiff, 1.0 - dot(normal, SampleNormal(uvR)));
	normalDiff = max(normalDiff, 1.0 - dot(normal, SampleNormal(uvU)));
	normalDiff = max(normalDiff, 1.0 - dot(normal, SampleNormal(uvD)));
	float normalEdge = smoothstep(NormalThreshold, NormalThreshold * 1.5, normalDiff);

	float edge = max(depthEdge, normalEdge);
	edge *= distanceFade;

	color = lerp(color, OutlineColor, edge * OutlineOpacity);

	return float4(color, 1.0);
}
