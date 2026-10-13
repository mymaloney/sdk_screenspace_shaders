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
//     color and its shadow edges are sharpened (clean cartoon shadows, texture kept).
//     Only places where the light changes a lot over a short distance are sharpened,
//     so the slow gradients of baked lighting don't turn into blobs
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
//   $c3_x : hard lighting strength for lightmapped world, 0 = off, 1 = full
//   $c3_y : light contrast needed to count as a shadow edge, 0-1 (e.g. 0.1)
//   $c3_z : lightmap scale (set from Lua: 16 in HDR, 4.59479 in LDR)
//   $c3_w : shadow edge search radius in pixels at a distance of 1 unit
//           (set from Lua from a radius in world units and the field of view)

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
#define HardLighting     Constants3.x
#define LightContrast    Constants3.y
#define LightmapScaleC   Constants3.z
#define LightRadius      Constants3.w

// GShader's depth buffer reads exactly 1 (4000 units) on the sky
#define SKY_DEPTH        4000.0

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

// linear brightness of the lightmap at uv
float LinearLight(float2 uv)
{
	return saturate(dot(tex2D(LightmapBuffer, uv).rgb, LumaWeights) * LightmapScaleC);
}

// perceptual (gamma space) brightness, as the light would look on a white surface
float GammaLight(float x)
{
	return pow(x, 1.0 / 2.2);
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
	// lightmap and multiplying by a sharpened version swaps soft shadows for hard ones
	// while keeping texture detail. Brightness is compared in gamma space, like the framebuffer.
	float linearLight = LinearLight(uv);
	float hasLightmap = step(1e-4, linearLight);
	// GShader draws lightmapped geometry wherever nothing is in front of it, so on
	// the sky it picks up faraway brushes (e.g. the 3D skybox room). Ignore the sky.
	hasLightmap *= step(0.5, abs(depth - SKY_DEPTH));
	hasLightmap *= step(0.001, HardLighting);

	// find the darkest and brightest light nearby. The search radius is fixed in
	// world units, so it shrinks with distance
	float radius = clamp(LightRadius / depth, 1.5, 32.0);
	// (searched in linear space, the gamma curve doesn't change which is darkest)
	float lightMin = linearLight;
	float lightMax = linearLight;
	[unroll]
	for (int k = 0; k < 8; k++)
	{
		float angle = k * 0.785398;
		float2 dir = float2(cos(angle), sin(angle)) * TexBaseSize * radius;
		[unroll]
		for (int r = 1; r <= 2; r++)
		{
			float sampleLight = LinearLight(uv + dir * (r * 0.5));
			// pixels without a lightmap (props, models) shouldn't count as shadow
			sampleLight = lerp(linearLight, sampleLight, step(1e-4, sampleLight));
			lightMin = min(lightMin, sampleLight);
			lightMax = max(lightMax, sampleLight);
		}
	}

	// across a shadow edge, snap to the dark or bright side at the midpoint.
	// Gentle gradients (low contrast) are left as they are
	float lightLevel = GammaLight(linearLight);
	lightMin = GammaLight(lightMin);
	lightMax = GammaLight(lightMax);
	float contrast = lightMax - lightMin;
	float lightMid = (lightMin + lightMax) * 0.5;
	float snapped = lerp(lightMin, lightMax,
		smoothstep(lightMid - BandSoftness * contrast, lightMid + BandSoftness * contrast + 1e-4, lightLevel));
	float edgeAmount = smoothstep(LightContrast, LightContrast * 1.5, contrast) * saturate(HardLighting);
	float hardLight = lerp(lightLevel, snapped, edgeAmount);
	float3 litColor = color * clamp(hardLight / max(lightLevel, 1e-3), 0.2, 3.0);

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
