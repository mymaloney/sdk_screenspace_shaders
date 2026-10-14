// World relighting pass for toon_world (Garry's Mod, GShader library)
//
// Replaces the baked lighting of world brushes with toon lighting:
//   lighting = ambient * baked lightmap  +  sun * hard N.L * real-time sun shadow
// The baked lightmap is kept as soft fill (so lamps and bounce light survive), while
// the sun gets a hard terminator and crisp shadows from a real-time shadow map.
//
// The framebuffer is surface color * baked lighting, so the result is
// framebuffer * new lighting / baked lighting (in gamma space, like the framebuffer).
// Pixels without a lightmap (models, sky) are left untouched; models get their toon
// lighting from toon_lighting.lua instead.
//
// Draw with GShader's pp_vs30 vertex shader and shaderlib.DrawScreenQuad.
//
// Textures:
//   $basetexture : _rt_FullFrameFB
//   $texture1    : _rt_WPDepth (GShader: .rgb = 1 / world position, .a = 1 / depth)
//   $texture2    : _rt_Lightmaps (GShader, r_shaderlib_lightmaps 1)
//   $texture3    : sun shadow map (R32F, rendered by toon_world.lua)
//
// Parameters:
//   $c0_xyz : direction towards the sun          $c0_w : sun strength
//   $c1_xyz : sun color                          $c1_w : ambient (baked light kept)
//   $c2_xyz : eye position                       $c2_w : lightmap scale (16 HDR, 4.59479 LDR)
//   $c3_x   : shadow depth bias (0-1 depth)      $c3_y : normal offset (units)
//   $c3_z   : terminator softness                $c3_w : debug view (1 = shadow term only)
//   $VIEWPROJMAT : world -> shadow map (u, v, depth, 1)

#include "common.hlsl"

#define SunDir           Constants0.xyz
#define SunStrength      Constants0.w
#define SunColor         Constants1.xyz
#define AmbientScale     Constants1.w
#define EyePos           Constants2.xyz
#define LightmapScaleC   Constants2.w
#define ShadowBias       Constants3.x
#define NormalOffset     Constants3.y
#define Softness         Constants3.z
#define DebugView        Constants3.w

#define WPDepthBuffer    Tex1
#define LightmapBuffer   Tex2
#define ShadowMap        Tex3
#define ShadowTexel      Tex3Size

const float4x4 g_WorldToShadow : register( c11 );

// GShader's depth buffer reads exactly 1 (4000 units) on the sky
#define SKY_DEPTH        4000.0

// only TEXCOORD0 is written by pp_vs30, so don't use PS_INPUT from common.hlsl
struct PS_INPUT_VPOS
{
	float2 uv  : TEXCOORD0;
	float2 pos : VPOS;
};

static const float3 LumaWeights = float3(0.299, 0.587, 0.114);

float ShadowTap(float2 uv, float depth)
{
	return step(depth, tex2D(ShadowMap, uv).r);
}

float4 main( PS_INPUT_VPOS i ) : COLOR
{
	float2 uv = (i.pos + 0.5) * TexBaseSize;
	float4 sceneColor = tex2D(TexBase, uv);

	float4 wpDepth = tex2D(WPDepthBuffer, uv);
	float3 worldPos = 1.0 / wpDepth.rgb;
	float depth = 1.0 / max(wpDepth.a, 1e-6);

	// face normal from how the world position changes across the screen
	float3 normal = normalize(cross(ddx(worldPos), ddy(worldPos)));
	normal *= sign(dot(normal, EyePos - worldPos) + 1e-6); // face the camera

	float3 baked = tex2D(LightmapBuffer, uv).rgb * LightmapScaleC;
	float isWorld = step(1e-4, dot(baked, LumaWeights)) * step(0.5, abs(depth - SKY_DEPTH));

	// --- sun shadow ---
	// offset along the normal before looking up, to avoid self-shadowing acne
	float4 shadowPos = mul(float4(worldPos + normal * NormalOffset, 1.0), g_WorldToShadow);
	float shadowDepth = shadowPos.z - ShadowBias;
	float2 texel = ShadowTexel * 0.5;
	float shadow = 0.25 * (
		ShadowTap(shadowPos.xy + float2(-texel.x, -texel.y), shadowDepth) +
		ShadowTap(shadowPos.xy + float2( texel.x, -texel.y), shadowDepth) +
		ShadowTap(shadowPos.xy + float2(-texel.x,  texel.y), shadowDepth) +
		ShadowTap(shadowPos.xy + float2( texel.x,  texel.y), shadowDepth));
	// harden the small filter into a crisp edge
	shadow = smoothstep(0.25, 0.75, shadow);

	// outside the shadow map the scene keeps its original lighting, fading out near the edge
	float2 edge = abs(shadowPos.xy - 0.5) * 2.0;
	float coverage = saturate((1.0 - max(edge.x, edge.y)) * 10.0) * step(shadowPos.z, 1.0) * step(0.0, shadowPos.z);

	// --- toon lighting ---
	float terminator = smoothstep(-Softness, Softness, dot(normal, SunDir));
	float direct = terminator * shadow;
	float3 lighting = AmbientScale * baked + SunColor * (SunStrength * direct);

	// swap baked lighting for the new lighting, in gamma space like the framebuffer
	float3 ratio = pow(clamp(lighting / max(baked, 1e-3), 0.0, 8.0), 1.0 / 2.2);
	float3 relit = saturate(sceneColor.rgb * ratio);

	float amount = isWorld * coverage;
	float3 color = lerp(sceneColor.rgb, relit, amount);

	// debug: white = sunlit, black = shadowed or facing away, red = not relit
	float3 debug = lerp(float3(1, 0, 0), direct.xxx, amount);
	color = lerp(color, debug, DebugView);

	return float4(color, 1.0);
}
