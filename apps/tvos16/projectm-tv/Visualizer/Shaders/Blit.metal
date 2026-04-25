#include <metal_stdlib>
using namespace metal;

struct VertexOut {
    float4 position [[position]];
    float2 texCoord;
};

// Fullscreen triangle from vertex_id alone (no vertex buffer).
// Vertices: 0 -> (-1,-1), 1 -> (3,-1), 2 -> (-1,3)
// The oversized triangle covers the entire clip-space quad after clipping.
vertex VertexOut blit_vertex(uint vertex_id [[vertex_id]]) {
    VertexOut out;

    // NDC positions for the oversized triangle
    float2 positions[3] = {
        float2(-1.0, -1.0),
        float2( 3.0, -1.0),
        float2(-1.0,  3.0)
    };

    out.position = float4(positions[vertex_id], 0.0, 1.0);

    // Derive UVs from NDC: u = (x + 1) / 2, v = (y + 1) / 2
    // Then flip v (1 - v) to compensate for GL's bottom-left origin
    // vs Metal's top-left origin, so the texture appears right-side-up.
    float2 uv;
    uv.x = (positions[vertex_id].x + 1.0) * 0.5;
    uv.y = 1.0 - (positions[vertex_id].y + 1.0) * 0.5;

    out.texCoord = uv;
    return out;
}

fragment float4 blit_fragment(VertexOut in [[stage_in]],
                              texture2d<float> tex [[texture(0)]],
                              sampler smp [[sampler(0)]]) {
    return tex.sample(smp, in.texCoord);
}
