#include <metal_stdlib>
using namespace metal;

// MARK: - Shared vertex stage

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadUniforms {
    float4 color;        // 0
    float cornerRadius;  // 16
    float opacity;       // 20
    float4 rect;         // 32  (x, y, width, height in canvas pixels)
    int maskShape;       // 48  0 = rounded rect, 2 = circle, 3 = none
    int pad0;            // 52
    float zoom;          // 56
    float focusX;        // 60
    float focusY;        // 64
    float mirror;        // 68  1 = flip U
    float pad1;          // 72
    float pad2;          // 76
};

struct ShadowUniforms {
    float4 color;       // 0
    float4 rect;        // 16  (expanded quad rect)
    float cornerRadius; // 32
    float blur;         // 36
    float2 shapeSize;   // 40  (original rounded-rect size)
    float2 pad;         // 48
};

struct GradientUniforms {
    float4 topColor;    // 0
    float4 bottomColor; // 16
};

struct RingUniforms {
    float4 color;       // 0
    float2 center;      // 16  normalized canvas coordinates
    float radius;       // 24  normalized to canvas min dimension
    float thickness;    // 28  normalized to canvas min dimension
    float aspect;       // 32
    float pad0;         // 36
    float pad1;         // 40
    float pad2;         // 44
};

struct BackdropUniforms {
    float2 texelSize;   // 0
    float radius;       // 8
    float dim;          // 12
};

vertex QuadOut quad_vertex(uint vid [[vertex_id]],
                           constant float4x4 &transform [[buffer(0)]]) {
    const float2 positions[6] = {
        float2(0.0, 0.0),
        float2(1.0, 0.0),
        float2(0.0, 1.0),
        float2(1.0, 0.0),
        float2(1.0, 1.0),
        float2(0.0, 1.0)
    };
    QuadOut out;
    out.position = transform * float4(positions[vid], 0.0, 1.0);
    out.uv = positions[vid];
    return out;
}

// MARK: - Helpers

static inline float roundedRectAlpha(float2 p, float2 size, float radius) {
    float2 halfSize = size * 0.5;
    float2 q = abs(p - halfSize) - (halfSize - radius);
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
    return 1.0 - smoothstep(-1.0, 1.0, dist);
}

static inline float circleAlpha(float2 p, float2 size) {
    float2 halfSize = size * 0.5;
    float radius = min(halfSize.x, halfSize.y);
    float dist = length(p - halfSize);
    return 1.0 - smoothstep(radius - 1.5, radius, dist);
}

// MARK: - Textured quad (screen, webcam, cursor, image background)

fragment float4 textured_fragment(QuadOut in [[stage_in]],
                                  constant QuadUniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]]) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;
    if (u.mirror > 0.5) {
        uv.x = 1.0 - uv.x;
    }
    if (u.zoom > 1.0001) {
        uv = float2(u.focusX, u.focusY) + (uv - 0.5) / u.zoom;
        uv = clamp(uv, 0.0, 1.0);
    }

    float4 color = tex.sample(samp, uv);

    float alpha = 1.0;
    float2 p = in.uv * u.rect.zw;
    if (u.maskShape == 0) {
        alpha = roundedRectAlpha(p, u.rect.zw, u.cornerRadius);
    } else if (u.maskShape == 2) {
        alpha = circleAlpha(p, u.rect.zw);
    }

    color.a *= alpha * u.opacity;
    return color;
}

fragment float4 cursor_fragment(QuadOut in [[stage_in]],
                                constant QuadUniforms &u [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]]) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    float4 color = tex.sample(samp, in.uv);
    color.a *= u.opacity;
    return color;
}

// MARK: - Solid quad

fragment float4 solid_fragment(QuadOut in [[stage_in]],
                               constant QuadUniforms &u [[buffer(0)]]) {
    float alpha = 1.0;
    float2 p = in.uv * u.rect.zw;
    if (u.maskShape == 0) {
        alpha = roundedRectAlpha(p, u.rect.zw, u.cornerRadius);
    } else if (u.maskShape == 2) {
        alpha = circleAlpha(p, u.rect.zw);
    }
    return float4(u.color.rgb, u.color.a * alpha * u.opacity);
}

// MARK: - Background gradient

fragment float4 gradient_fragment(QuadOut in [[stage_in]],
                                  constant GradientUniforms &u [[buffer(0)]]) {
    float t = clamp(in.uv.y, 0.0, 1.0);
    float3 color = mix(u.topColor.rgb, u.bottomColor.rgb, t);
    return float4(color, 1.0);
}

// MARK: - Blurred, dimmed copy of the screen (background)

fragment float4 backdrop_fragment(QuadOut in [[stage_in]],
                                  constant BackdropUniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]]) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = in.uv;
    float3 sum = float3(0.0);
    float total = 0.0;
    for (int i = -2; i <= 2; ++i) {
        for (int j = -2; j <= 2; ++j) {
            float2 offset = float2(i, j) * u.texelSize * u.radius;
            float weight = exp(-float(i * i + j * j) / 4.0);
            sum += tex.sample(samp, clamp(uv + offset, 0.0, 1.0)).rgb * weight;
            total += weight;
        }
    }
    return float4(sum / max(total, 0.0001) * u.dim, 1.0);
}

// MARK: - Soft shadow

fragment float4 shadow_fragment(QuadOut in [[stage_in]],
                                constant ShadowUniforms &u [[buffer(0)]]) {
    float2 quadSize = u.rect.zw;
    float2 p = in.uv * quadSize;
    float2 center = quadSize * 0.5;
    float2 halfSize = u.shapeSize * 0.5;
    float2 q = abs(p - center) - (halfSize - u.cornerRadius);
    float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - u.cornerRadius;
    float alpha = 1.0 - smoothstep(-u.blur, u.blur, dist);
    return float4(u.color.rgb, u.color.a * alpha);
}

// MARK: - Click ripple

fragment float4 ring_fragment(QuadOut in [[stage_in]],
                              constant RingUniforms &u [[buffer(0)]]) {
    float2 delta = in.uv - u.center;
    delta.x *= u.aspect;
    float dist = length(delta);
    float inner = smoothstep(u.radius - u.thickness, u.radius, dist);
    float outer = 1.0 - smoothstep(u.radius, u.radius + u.thickness, dist);
    float alpha = inner * outer;
    return float4(u.color.rgb, u.color.a * alpha);
}
