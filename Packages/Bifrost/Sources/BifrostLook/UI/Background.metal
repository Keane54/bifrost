// The shader of the animated background (MetalBackground.swift). The app build compiles this
// file into the default library of the BifrostLook bundle. A command-line build (swift build,
// swift test) copies the file into the bundle, and BackgroundRenderer compiles it at run time.
#include <metal_stdlib>
using namespace metal;
struct VOut { float4 pos [[position]]; };
vertex VOut vtx(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    VOut o; o.pos = float4(p * 2.0 - 1.0, 0, 1); return o;
}
// The fade of a field from its centre (0) to its edge (1), as Motion.fade.
static float fade(float d) {
    const float at[6] = {0, 0.2, 0.4, 0.6, 0.8, 1};
    const float pt[6] = {1, 0.7, 0.38, 0.14, 0.03, 0};
    if (d >= 1.0) return 0.0;
    for (int i = 1; i < 6; i++) {
        if (d <= at[i]) return mix(pt[i-1], pt[i], (d - at[i-1]) / (at[i] - at[i-1]));
    }
    return 0.0;
}
static float hash(float2 p) { return fract(sin(dot(p, float2(12.9898, 78.233))) * 43758.5453); }
// d: 5 values for each of the 7 layers: the centre and the half size, the inverse transform,
// the colour and the alpha, the gradient line of the base, the kind (0 field, 1 base).
// stops: the 5 stops of the base. info: the points of one pixel, and the offset of the grain.
// look: the background colour and the strength of the grain.
fragment float4 frg(VOut in [[stage_in]], constant float4 *d [[buffer(0)]],
                    constant float4 *stops [[buffer(1)]], constant float4 &info [[buffer(2)]],
                    constant float4 &look [[buffer(3)]]) {
    float2 q = in.pos.xy * info.xy;
    float3 col = look.rgb;
    for (int i = 0; i < 7; i++) {
        float4 a = d[i*5], m = d[i*5+1], c = d[i*5+2], g = d[i*5+3], k = d[i*5+4];
        float2 o = q - a.xy;
        float2 l = float2(m.x * o.x + m.z * o.y, m.y * o.x + m.w * o.y);
        float alpha; float3 rgb;
        if (k.x < 0.5) {
            alpha = c.w * fade(length(l / a.zw)); rgb = c.rgb;
        } else {
            float2 p = l + a.zw;
            float t = clamp((p.x - g.x) * g.z + (p.y - g.y) * g.w, 0.0, 1.0) * 4.0;
            int j = min(3, int(t));
            rgb = mix(stops[j].rgb, stops[j+1].rgb, t - float(j)); alpha = c.w;
        }
        col = rgb * alpha + col * (1.0 - alpha);
    }
    // The fine grain: a mid grey on average at its opacity.
    col = mix(col, float3(128.0 / 255.0), look.w);
    // The dither: a triangular noise of up to one 8-bit step, so the gradients show no bands.
    float2 px = in.pos.xy + info.zw;
    col += (hash(px) - hash(px + 17.0)) / 255.0;
    return float4(col, 1);
}
