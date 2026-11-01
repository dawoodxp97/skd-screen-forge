#include <metal_stdlib>
using namespace metal;

// MARK: - Shared vertex stage

struct QuadOut {
    float4 position [[position]];
    float2 uv;
};

struct QuadUniforms {
    float4 color;         // 0
    float cornerRadius;   // 16
    float opacity;        // 20
    float4 rect;          // 32  (x, y, width, height in canvas pixels)
    int maskShape;        // 48  0 = rounded rect, 2 = circle, 3 = none
    int pad0;             // 52
    float zoom;           // 56
    float focusX;         // 60
    float focusY;         // 64
    float mirror;         // 68  1 = flip U
    float pad1;           // 72
    float pad2;           // 76
    float motionBlur;     // 80
    float blurDirX;       // 84
    float blurDirY;       // 88
    float sharpen;        // 92
    float grain;          // 96
    float gradeIndex;     // 100
    float gradeIntensity; // 104
    float superRes;       // 108
    float hasLUT;         // 112
    float pad3;           // 116
    float pad4;           // 120
    float pad5;           // 124
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
    float4 uvRect;      // 16  (x, y, width, height in source UV)
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

static inline float4 catmullRom(sampler s, texture2d<float> tex, float2 uv) {
    float2 texSize = float2(tex.get_width(), tex.get_height());
    float2 coord = uv * texSize - 0.5;
    float2 base = floor(coord);
    float2 f = coord - base;

    auto w0 = float4(-0.5, 1.5, -1.5, 0.5);
    auto w1 = float4(1.0, -2.5, 2.0, -0.5);
    auto w2 = float4(-0.5, 0.0, 0.5, 0.0);
    auto w3 = float4(0.0, 1.0, 0.0, 0.0);
    float4 wx = float4(dot(w0, float4(1.0, f.x, f.x * f.x, f.x * f.x * f.x)),
                       dot(w1, float4(1.0, f.x, f.x * f.x, f.x * f.x * f.x)),
                       dot(w2, float4(1.0, f.x, f.x * f.x, f.x * f.x * f.x)),
                       dot(w3, float4(1.0, f.x, f.x * f.x, f.x * f.x * f.x)));
    float4 wy = float4(dot(w0, float4(1.0, f.y, f.y * f.y, f.y * f.y * f.y)),
                       dot(w1, float4(1.0, f.y, f.y * f.y, f.y * f.y * f.y)),
                       dot(w2, float4(1.0, f.y, f.y * f.y, f.y * f.y * f.y)),
                       dot(w3, float4(1.0, f.y, f.y * f.y, f.y * f.y * f.y)));

    float3 sum = float3(0.0);
    float total = 0.0;
    for (int j = -1; j <= 2; ++j) {
        for (int i = -1; i <= 2; ++i) {
            float2 samplePos = (base + float2(i, j) + 0.5) / texSize;
            float weight = wx[i + 1] * wy[j + 1];
            sum += tex.sample(s, clamp(samplePos, 0.0, 1.0)).rgb * weight;
            total += weight;
        }
    }
    return float4(sum / max(total, 0.0001), tex.sample(s, clamp(uv, 0.0, 1.0)).a);
}

static inline float3 applyAnalyticGrade(float3 c, int index) {
    float luma = dot(c, float3(0.2126, 0.7152, 0.0722));
    if (index == 1) { // Golden
        float3 warm = c * float3(1.10, 1.02, 0.88);
        warm = mix(float3(luma), warm, 0.35);
        warm = pow(clamp(warm, 0.0, 1.0), float3(0.95));
        return clamp(warm * 1.04, 0.0, 1.0);
    }
    if (index == 2) { // Mono
        float m = pow(clamp(luma, 0.0, 1.0), 1.15);
        return float3(m);
    }
    if (index == 3) { // Terra
        float3 shadows = float3(0.06, 0.05, 0.04);
        float3 highs = float3(1.02, 0.96, 0.85);
        float3 outColor = mix(shadows, highs, pow(clamp(luma, 0.0, 1.0), 0.9));
        outColor = mix(outColor, c * float3(1.02, 1.0, 0.92), 0.55);
        return clamp(outColor, 0.0, 1.0);
    }
    if (index == 4) { // Teal & Orange
        float3 shadowTeal = float3(0.0, 0.08, 0.11);
        float3 highOrange = float3(0.12, 0.03, 0.0);
        float3 tint = mix(shadowTeal, highOrange, smoothstep(0.15, 0.85, luma));
        float3 saturated = mix(float3(luma), c, 1.12);
        return clamp(saturated + tint, 0.0, 1.0);
    }
    if (index == 5) { // Cool
        float3 cool = c * float3(0.92, 1.0, 1.08);
        return clamp(mix(float3(luma), cool, 0.7), 0.0, 1.0);
    }
    if (index == 6) { // Warm
        return clamp(c * float3(1.08, 1.0, 0.9) + float3(0.02, 0.005, 0.0), 0.0, 1.0);
    }
    if (index == 7) { // Noir
        float m = pow(clamp(luma, 0.0, 1.0), 1.5);
        float3 toned = mix(float3(0.02), float3(0.95), m);
        return clamp(toned, 0.0, 1.0);
    }
    return c;
}

static inline float hashNoise(float2 p) {
    float n = sin(dot(p, float2(12.9898, 78.233))) * 43758.5453;
    return n - floor(n);
}

// MARK: - Textured quad (screen, webcam, cursor, image background)

fragment float4 textured_fragment(QuadOut in [[stage_in]],
                                  constant QuadUniforms &u [[buffer(0)]],
                                  texture2d<float> tex [[texture(0)]],
                                  texture3d<float> lut [[texture(1)]]) {
    constexpr sampler samp(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler lutSamp(coord::normalized, address::clamp_to_edge, filter::linear);

    float2 uv = in.uv;
    if (u.mirror > 0.5) {
        uv.x = 1.0 - uv.x;
    }
    if (u.zoom > 1.0001) {
        uv = float2(u.focusX, u.focusY) + (uv - 0.5) / u.zoom;
        uv = clamp(uv, 0.0, 1.0);
    }

    float4 color;
    if (u.motionBlur > 0.001) {
        float2 direction = float2(u.blurDirX, u.blurDirY) * u.motionBlur;
        float3 sum = float3(0.0);
        float total = 0.0;
        for (int i = -4; i <= 4; ++i) {
            float t = float(i) / 4.0;
            float weight = 1.0 - abs(t) * 0.6;
            float2 offset = direction * t * 0.035;
            sum += tex.sample(samp, clamp(uv + offset, 0.0, 1.0)).rgb * weight;
            total += weight;
        }
        color = float4(sum / max(total, 0.0001), tex.sample(samp, uv).a);
    } else if (u.superRes > 0.5) {
        color = catmullRom(samp, tex, uv);
    } else {
        color = tex.sample(samp, uv);
    }

    if (u.sharpen > 0.001) {
        float2 texel = float2(1.0 / max(float(tex.get_width()), 1.0), 1.0 / max(float(tex.get_height()), 1.0));
        float3 blur = (tex.sample(samp, clamp(uv + float2(texel.x, 0.0), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv - float2(texel.x, 0.0), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv + float2(0.0, texel.y), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv - float2(0.0, texel.y), 0.0, 1.0)).rgb) * 0.25;
        color.rgb = clamp(color.rgb + (color.rgb - blur) * u.sharpen * 2.5, 0.0, 1.0);
    }

    if (u.hasLUT > 0.5) {
        float size = float(lut.get_width());
        float scale = (size - 1.0) / size;
        float3 coord = clamp(color.rgb, 0.0, 1.0) * scale + 0.5 / size;
        float3 graded = lut.sample(lutSamp, coord).rgb;
        color.rgb = mix(color.rgb, graded, u.gradeIntensity);
    } else if (u.gradeIndex > 0.5) {
        float3 graded = applyAnalyticGrade(clamp(color.rgb, 0.0, 1.0), int(u.gradeIndex));
        color.rgb = mix(color.rgb, graded, u.gradeIntensity);
    }

    if (u.grain > 0.001) {
        float noise = hashNoise(uv * float2(tex.get_width(), tex.get_height())) - 0.5;
        color.rgb = clamp(color.rgb + noise * u.grain * 0.08, 0.0, 1.0);
    }

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

// MARK: - Person-matte cutout

fragment float4 cutout_fragment(QuadOut in [[stage_in]],
                                constant QuadUniforms &u [[buffer(0)]],
                                texture2d<float> tex [[texture(0)]],
                                texture2d<float> mask [[texture(1)]],
                                texture3d<float> lut [[texture(2)]]) {
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
    float person = mask.sample(samp, uv).r;
    // Feather the matte edge slightly so hair is not a hard cutout.
    float2 texel = float2(1.0 / max(float(mask.get_width()), 1.0), 1.0 / max(float(mask.get_height()), 1.0));
    float soft = (mask.sample(samp, clamp(uv + float2(texel.x, 0.0), 0.0, 1.0)).r +
                  mask.sample(samp, clamp(uv - float2(texel.x, 0.0), 0.0, 1.0)).r +
                  mask.sample(samp, clamp(uv + float2(0.0, texel.y), 0.0, 1.0)).r +
                  mask.sample(samp, clamp(uv - float2(0.0, texel.y), 0.0, 1.0)).r) * 0.25;
    person = clamp(person * 0.7 + soft * 0.3, 0.0, 1.0);

    if (u.sharpen > 0.001) {
        float3 blur = (tex.sample(samp, clamp(uv + float2(texel.x, 0.0), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv - float2(texel.x, 0.0), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv + float2(0.0, texel.y), 0.0, 1.0)).rgb +
                       tex.sample(samp, clamp(uv - float2(0.0, texel.y), 0.0, 1.0)).rgb) * 0.25;
        color.rgb = clamp(color.rgb + (color.rgb - blur) * u.sharpen * 2.5, 0.0, 1.0);
    }

    if (u.hasLUT > 0.5) {
        float size = float(lut.get_width());
        float scale = (size - 1.0) / size;
        float3 coord = clamp(color.rgb, 0.0, 1.0) * scale + 0.5 / size;
        color.rgb = mix(color.rgb, lut.sample(samp, coord).rgb, u.gradeIntensity);
    } else if (u.gradeIndex > 0.5) {
        color.rgb = mix(color.rgb, applyAnalyticGrade(clamp(color.rgb, 0.0, 1.0), int(u.gradeIndex)), u.gradeIntensity);
    }

    color.a *= person * u.opacity;
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
    float2 uv = u.uvRect.xy + in.uv * u.uvRect.zw;
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
