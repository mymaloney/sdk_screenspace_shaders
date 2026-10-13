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
//
// Effect:
//   - scene luminance is quantized into flat "toon" bands (hue is preserved)
//   - optional saturation boost and rim light for a more cartoony look
//   - ink outlines are drawn on depth and normal discontinuities
//
// Textures:
//   $basetexture : _rt_FullFrameFB
//   $texture1    : _rt_NormalsTangents
//   $texture2    : _rt_WPDepth
//
// Parameters:
//   $c0_x : number of shading bands (e.g. 4)
//   $c0_y : band edge softness, 0 = hard steps, 0.5 = smooth (e.g. 0.05)
//   $c0_z : saturation multiplier (1 = unchanged)
//   $c0_w : minimum brightness of the darkest band (keeps shadows from crushing to black)
//   $c1_x : outline thickness in pixels (e.g. 1)
//   $c1_y : depth edge threshold, relative to depth (e.g. 0.02)
//   $c1_z : normal edge threshold, 0-2 (e.g. 0.4)
//   $c1_w : outline opacity, 0-1
//   $c2_xyz : outline color
//   $c2_w : distance (units) at which outlines have fully faded out
//   $c3_xyz : eye position (set from Lua, the register value is unreliable on overlays)
//   $c3_w : rim light strength

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
#define EyePos           Constants3.xyz
#define RimStrength      Constants3.w

#define NormalBuffer     Tex1
#define WPDepthBuffer    Tex2

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

	float4 wpDepth = tex2D(WPDepthBuffer, uv);
	float depth = 1.0 / max(wpDepth.a, 1e-6);
	float3 worldPos = 1.0 / wpDepth.rgb;
	float3 normal = SampleNormal(uv);

	// fade outlines and rim light out in the distance (and on the skybox)
	float distanceFade = saturate(1.0 - depth / OutlineFadeDist);

	// --- toon bands ---
	float luma = dot(color, LumaWeights);
	float banded = max(Posterize(saturate(luma), BandCount, BandSoftness), MinBrightness);
	color *= banded / max(luma, 1e-4);

	// --- saturation ---
	float newLuma = dot(color, LumaWeights);
	color = lerp(newLuma.xxx, color, Saturation);

	// --- rim light (hard edged, cartoon style) ---
	float3 viewDir = normalize(EyePos - worldPos);
	float rim = 1.0 - saturate(dot(normal, viewDir));
	rim = smoothstep(0.6, 0.65, rim) * banded * distanceFade;
	color += rim * RimStrength;

	// --- outlines ---
	float2 px = TexBaseSize * OutlineThickness;
	float2 uvL = uv - float2(px.x, 0.0);
	float2 uvR = uv + float2(px.x, 0.0);
	float2 uvU = uv - float2(0.0, px.y);
	float2 uvD = uv + float2(0.0, px.y);

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
