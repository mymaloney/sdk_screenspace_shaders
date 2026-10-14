// Sun shadow map depth pass for toon_world (Garry's Mod)
//
// Used as a material override while the scene is rendered from the sun with an
// orthographic camera (render.RenderView). Outputs the projected depth, which for an
// orthographic projection is linear: 0 at the near plane, 1 at the far plane.
// Skinned models are drawn with $softwareskin 1, so positions are already posed.

// standard Source vertex shader constant: model * view * projection
const float4x4 cModelViewProj : register( c4 );

struct VS_INPUT
{
	float4 vPos : POSITION;
};

struct VS_OUTPUT
{
	float4 projPos : POSITION;
	float depth    : TEXCOORD0;
};

VS_OUTPUT main( const VS_INPUT v )
{
	VS_OUTPUT o = ( VS_OUTPUT )0;
	o.projPos = mul( float4( v.vPos.xyz, 1.0 ), cModelViewProj );
	o.depth = o.projPos.z / o.projPos.w;
	return o;
}
