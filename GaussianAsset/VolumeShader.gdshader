shader_type spatial;
render_mode unshaded;

uniform bool show_aabb;
uniform sampler2D rendered_image_texture;

vec3 srgb_to_linear(vec3 srgb_color) {
    vec3 linear_color;
    for (int i = 0; i < 3; i++) {
        if (srgb_color[i] <= 0.04045) {
            linear_color[i] = srgb_color[i] / 12.92;
        } else {
            linear_color[i] = pow((srgb_color[i] + 0.055) / 1.055, 2.4);
        }
    }
    return linear_color;
}

void vertex() {
	// Called for every vertex the material is visible on.
}

void fragment() {
	vec4 tex_val = texture(rendered_image_texture, vec2(1.0, 1.0) - SCREEN_UV);
	ALBEDO = srgb_to_linear(tex_val.rgb);
	if(!show_aabb) {
		ALPHA = tex_val.a;
	}
}

//void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.
//}
