// Input glyphs use the text fragment path. The local vertex multiplies its
// color alpha, and color-atlas glyphs need that alpha applied explicitly.
#include "common.glsl"
layout(binding = 0) uniform sampler2DRect atlas_grayscale;
layout(binding = 1) uniform sampler2DRect atlas_color;
in CellTextVertexOut { flat uint atlas; flat vec4 color; flat vec4 bg_color; vec2 tex_coord; } in_data;
layout(location = 0) out vec4 out_FragColor;
const uint ATLAS_GRAYSCALE = 0u;
const uint ATLAS_COLOR = 1u;
void main() {
    bool linear = (bools & USE_LINEAR_BLENDING) != 0;
    if (in_data.atlas == ATLAS_COLOR) {
        vec4 color = texture(atlas_color, in_data.tex_coord) * in_data.color.a;
        if (!linear && color.a > 0.0) { color.rgb /= color.a; color = unlinearize(color); color.rgb *= color.a; }
        out_FragColor = color; return;
    }
    vec4 color = in_data.color;
    if (!linear && color.a > 0.0) { color.rgb /= color.a; color = unlinearize(color); color.rgb *= color.a; }
    float a = texture(atlas_grayscale, in_data.tex_coord).r;
    if ((bools & USE_LINEAR_CORRECTION) != 0) {
        float fg_l = luminance(color.rgb);
        float bg_l = luminance(in_data.bg_color.rgb);
        if (abs(fg_l - bg_l) > 0.001) {
            float blend_l = linearize(unlinearize(fg_l) * a + unlinearize(bg_l) * (1.0 - a));
            a = clamp((blend_l - bg_l) / (fg_l - bg_l), 0.0, 1.0);
        }
    }
    out_FragColor = color * a;
}
