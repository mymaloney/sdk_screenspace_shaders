// Edge-preserving smoothing pass for the example_celshade shader (Garry's Mod, GShader library)
//
// Flattens noisy/grungy textures before the cel-shading bands are picked, so band
// boundaries follow clean contours instead of texture noise. It's a separable
// cross-bilateral blur: run once horizontally and once vertically (set from Lua).
// A neighbor only contributes if it has a similar color, depth and normal, so object
// silhouettes, creases and strong texture features (painted lines etc.) stay sharp.
//
// Must be compiled as Shader Model 3.0 (build_celshade.bat) and drawn with GShader's
// pp_vs30 vertex shader and shaderlib.DrawScreenQuad, like example_celshade.
//
// Textures:
//   $basetexture : color to smooth (_rt_FullFrameFB, or the previous pass)
//   $texture1    : _rt_NormalsTangents
//   $texture2    : _rt_WPDepth
//
// Parameters:
//   $c0_xy : step between taps in UV units (direction * spacing / screen size)
//   $c0_z  : color tolerance, larger = smooths stronger texture features (e.g. 0.15)
//   $c0_w  : depth tolerance, relative to depth (e.g. 0.02)

#include "common.hlsl"

#define TapStep          Constants0.xy
#define ColorSigma       Constants0.z
#define DepthSigma       Constants0.w

#define NormalBuffer     Tex1
#define WPDepthBuffer    Tex2

// only TEXCOORD0 is written by pp_vs30, so don't use PS_INPUT from common.hlsl
struct PS_INPUT_VPOS
{
	float2 uv  : TEXCOORD0;
	float2 pos : VPOS;
};

// GShader octahedron normal decoding
float3 DecodeNormal(float2 f)
{
	f = f * 2.0 - 1.0;
	float3 n = float3(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));
	float t = saturate(-n.z);
	n.xy += n.xy >= 0.0 ? -t : t;
	return normalize(n);
}

float4 main( PS_INPUT_VPOS i ) : COLOR
{
	float2 uv = (i.pos + 0.5) * TexBaseSize;

	float3 centerColor = tex2D(TexBase, uv).rgb;
	float centerDepth = 1.0 / max(tex2D(WPDepthBuffer, uv).a, 1e-6);
	float3 centerNormal = DecodeNormal(tex2D(NormalBuffer, uv).rg);

	float colorFactor = -0.5 / max(ColorSigma * ColorSigma, 1e-5);
	float depthFactor = -0.5 / max(DepthSigma * DepthSigma, 1e-8);

	float3 sum = centerColor;
	float weightSum = 1.0;

	[unroll]
	for (int k = -4; k <= 4; k++)
	{
		if (k == 0)
			continue;

		float2 tapUV = uv + TapStep * k;
		float3 tapColor = tex2D(TexBase, tapUV).rgb;
		float tapDepth = 1.0 / max(tex2D(WPDepthBuffer, tapUV).a, 1e-6);
		float3 tapNormal = DecodeNormal(tex2D(NormalBuffer, tapUV).rg);

		float3 colorDiff = tapColor - centerColor;
		float depthDiff = (tapDepth - centerDepth) / centerDepth;

		// spatial falloff (gaussian over the 9 taps)
		float weight = exp(-0.5 * (k * k) / 9.0);
		// similar color
		weight *= exp(dot(colorDiff, colorDiff) * colorFactor);
		// same surface: similar depth and facing the same way
		weight *= exp(depthDiff * depthDiff * depthFactor);
		weight *= saturate(dot(centerNormal, tapNormal) * 4.0 - 3.0);

		sum += tapColor * weight;
		weightSum += weight;
	}

	return float4(sum / weightSum, 1.0);
}
