// Sun shadow map depth pass for toon_world (Garry's Mod), see toon_sundepth_vs30.hlsl

struct PS_INPUT
{
	float depth : TEXCOORD0;
};

float4 main( PS_INPUT i ) : COLOR
{
	return float4( i.depth, i.depth, i.depth, 1.0 );
}
