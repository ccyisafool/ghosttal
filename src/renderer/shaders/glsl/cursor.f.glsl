#include "common.glsl"

layout(binding = 0) uniform sampler2DRect atlas_grayscale;

in CursorVertexOut {
    flat vec4 color;
    vec2 tex_coord;
} in_data;

// Must declare this output for some versions of OpenGL.
layout(location = 0) out vec4 out_FragColor;

void main() {
    bool use_linear_blending = (bools & USE_LINEAR_BLENDING) != 0;

    // Our input color is always linear.
    vec4 color = in_data.color;

    // If we're not doing linear blending, then we need to re-apply the
    // gamma encoding to our color manually.
    //
    // Since the alpha is premultiplied, we need to divide it out before
    // unlinearizing and re-multiply it after. The trail quad can fade all
    // the way to zero alpha, so unlike cell_text we have to guard the
    // division.
    if (!use_linear_blending && color.a > 0.0) {
        color.rgb /= vec3(color.a);
        color = unlinearize(color);
        color.rgb *= vec3(color.a);
    }

    // Fetch our alpha mask for this pixel. Cursor sprites are always in
    // the grayscale atlas, so there's no atlas selector here.
    //
    // Note we deliberately don't do the linear blending weight correction
    // that cell_text does: it needs the cell background color, which a
    // free-floating quad doesn't have.
    float a = texture(atlas_grayscale, in_data.tex_coord).r;

    // Multiply our whole color by the alpha mask. Since we use
    // premultiplied alpha, this is the correct way to apply the mask.
    color *= a;

    out_FragColor = color;
}
