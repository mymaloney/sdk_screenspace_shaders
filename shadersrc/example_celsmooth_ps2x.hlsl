// Edge-preserving smoothing pass for the example_celshade shader (Garry's Mod, GShader library)
//
// Separable cross-bilateral blur: run once horizontally and once vertically (set from Lua).
// It produces two things:
//   .rgb : the scene with texture noise flattened. A neighbor only contributes if it has
//          a similar color, depth and normal, so object silhouettes, creases and strong
//          texture features (painted lines etc.) stay sharp.
//   .a   : "shading" brightness, averaged over a much wider area while ignoring color,
//          stopping only at depth/normal edges. This approximates the lighting without
//          the texture, so the cel bands follow lighting instead of turning texture
//          patches into splotches.
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
//   $c0_xy : step between color taps in UV units (direction * spacing / screen size)
//   $c0_z  : color tolerance, larger = smooths stronger texture features (e.g. 0.2)
//   $c0_w  : depth tolerance, relative to depth (e.g. 0.03)
//   $c1_xy : step between shading taps in UV units (wider than the color taps)
//   $c1_z  : 1 if the source alpha already holds shading brightness (later passes),
//            0 to compute it from the source color (first pass)

#include "common.hlsl"

#define TapStep          Constants0.xy
#define ColorSigma       Constants0.z
#define DepthSigma       Constants0.w
#define ShadeStep        Constants1.xy
#define AlphaIsShade     Constants1.z

#define NormalBuffer     Tex1
#define WPDepthBuffer    Tex2

// only TEXCOORD0 is written by pp_vs30, so don't use PS_INPUT from common.hlsl
struct PS_INPUT_VPOS
{
	float2 uv  : TEXCOORD0;
	float2 pos : VPOS;
};

static const float3 LumaWeights = float3(0.299, 0.587, 0.114);

// 1 if the tap is on the same surface as the center (similar depth, same facing), else 0.
// Normals are compared in their octahedron-encoded form, which is much cheaper than
// decoding them and close enough for telling surfaces apart (keeps us under the
// shader model 3 instruction limit)
float SurfaceWeight(float2 tapUV, float centerDepth, float2 centerNormal, float depthFactor)
{
	float tapDepth = 1.0 / max(tex2D(WPDepthBuffer, tapUV).a, 1e-6);
	float2 normalDiff = tex2D(NormalBuffer, tapUV).rg - centerNormal;
	float depthDiff = (tapDepth - centerDepth) / centerDepth;
	return exp(depthDiff * depthDiff * depthFactor) * saturate(1.0 - dot(normalDiff, normalDiff) * 50.0);
}

float4 main( PS_INPUT_VPOS i ) : COLOR
{
	float2 uv = (i.pos + 0.5) * TexBaseSize;

	float4 center = tex2D(TexBase, uv);
	float centerShade = lerp(dot(center.rgb, LumaWeights), center.a, AlphaIsShade);
	float centerDepth = 1.0 / max(tex2D(WPDepthBuffer, uv).a, 1e-6);
	float2 centerNormal = tex2D(NormalBuffer, uv).rg;

	float colorFactor = -0.5 / max(ColorSigma * ColorSigma, 1e-5);
	float depthFactor = -0.5 / max(DepthSigma * DepthSigma, 1e-8);

	// --- color: short range, stops at color, depth and normal edges ---
	float3 colorSum = center.rgb;
	float colorWeightSum = 1.0;

	[unroll]
	for (int k = -4; k <= 4; k++)
	{
		if (k == 0)
			continue;

		float2 tapUV = uv + TapStep * k;
		float3 tapColor = tex2D(TexBase, tapUV).rgb;
		float3 colorDiff = tapColor - center.rgb;

		float weight = exp(-0.5 * (k * k) / 9.0);
		weight *= exp(dot(colorDiff, colorDiff) * colorFactor);
		weight *= SurfaceWeight(tapUV, centerDepth, centerNormal, depthFactor);

		colorSum += tapColor * weight;
		colorWeightSum += weight;
	}

	// --- shading: long range, ignores color, stops at depth and normal edges ---
	// (depth tolerance is looser, since the wide taps cross more depth on sloped ground)
	float shadeDepthFactor = depthFactor * (1.0 / 9.0);
	float shadeSum = centerShade;
	float shadeWeightSum = 1.0;

	[unroll]
	for (int s = -3; s <= 3; s++)
	{
		if (s == 0)
			continue;

		float2 tapUV = uv + ShadeStep * s;
		float4 tap = tex2D(TexBase, tapUV);
		float tapShade = lerp(dot(tap.rgb, LumaWeights), tap.a, AlphaIsShade);

		float weight = exp(-0.5 * (s * s) / 4.0);
		weight *= SurfaceWeight(tapUV, centerDepth, centerNormal, shadeDepthFactor);

		shadeSum += tapShade * weight;
		shadeWeightSum += weight;
	}

	return float4(colorSum / colorWeightSum, shadeSum / shadeWeightSum);
}
