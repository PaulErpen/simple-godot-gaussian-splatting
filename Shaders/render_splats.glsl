// Adapted from: https://github.com/haztro/godot-gaussian-splatting/blob/main/shaders/splat.glsl
#[vertex]
#version 450 core

#define N_PROPERTIES 62

layout(location = 0) in vec3 vertex_position;

layout (set = 0, binding = 0) buffer depth_index_buffer {
    uint depth_index[];
};

// Input vertex positions
layout(set = 0, binding = 1) buffer Vertices {
    float vertices[];
};

layout(set = 0, binding = 2) restrict buffer Params {
	vec2 viewport_size;
    float tan_fovx;
    float tan_fovy;
    float focal_x;
    float focal_y;
    float sh_degree;
    float modifier;
}
params;

layout(set = 0, binding = 3) buffer ProjectionMatrix {
    mat4 projection_matrix;
};

// Model-view matrix
layout(set = 0, binding = 4) buffer ModelView {
    mat4 model_view_matrix;
};

layout (push_constant, std430) uniform PushConstants {
    uint n_splats;
    uint shade_depth_texture;
    uint point_cloud_mode;
};

//varyings
layout (location = 1) out vec3 color;
layout (location = 2) out vec2 vUV;
layout (location = 3) out vec3 vConic;
layout (location = 4) out float opacity;
layout (location = 5) flat out uint vpoint_cloud_mode;
layout (location = 6) flat out float v_modifier;

const float SH_C0 = 0.28209479177387814;
const float SH_C1 = 0.4886025119029199;
const float SH_C2[5] = float[5](
	1.0925484305920792,
	-1.0925484305920792, 
	0.31539156525252005, 
	-1.0925484305920792, 
	0.5462742152960396);
const float SH_C3[7] = float[7](
	-0.5900435899266435f, 
	2.890611442640554f, 
	-0.4570457994644658f, 
	0.3731763325901154f, 
	-0.4570457994644658f, 
	1.445305721320277f, 
	-0.5900435899266435f);

mat3 computeCov3D(vec3 scale, vec4 rot) {
	mat3 S = mat3(
		vec3(params.modifier * exp(scale.x), 0.0, 0.0),
		vec3(0.0, params.modifier * exp(scale.y), 0.0),
		vec3(0.0, 0.0, params.modifier * exp(scale.z))
	);

    rot = normalize(rot);
	float r = rot.x;
	float x = rot.y;
	float y = rot.z;
	float z = rot.w;

	mat3 R = mat3(
		vec3(1.0 - 2.0 * (y * y + z * z), 2.0 * (x * y - r * z), 2.0 * (x * z + r * y)),
		vec3(2.0 * (x * y + r * z), 1.0 - 2.0 * (x * x + z * z), 2.0 * (y * z - r * x)),
		vec3(2.0 * (x * z - r * y), 2.0 * (y * z + r * x), 1.0 - 2.0 * (x * x + y * y))
	);

	mat3 M = S * R;

	mat3 Sigma = transpose(M) * M;
	
	return Sigma;
}

vec3 computeCov2D(vec3 position, vec3 log_scale, vec4 rot, mat4 viewMatrix) {
    mat3 cov3D = computeCov3D(log_scale, rot);

    vec4 t = viewMatrix * vec4(position, 1.0);

    float limx = 1.3 * params.tan_fovx;
    float limy = 1.3 * params.tan_fovy;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;

    mat4 J = mat4(
        vec4(params.focal_x / t.z, 0.0, -(params.focal_x * t.x) / (t.z * t.z), 0.0),
        vec4(0.0, params.focal_y / t.z, -(params.focal_y * t.y) / (t.z * t.z), 0.0),
        vec4(0.0, 0.0, 0.0, 0.0),
		vec4(0.0, 0.0, 0.0, 0.0)
    );

    mat4 W = transpose(viewMatrix);

    mat4 T = W * J;

    mat4 Vrk = mat4(
        vec4(cov3D[0][0], cov3D[0][1], cov3D[0][2], 0.0),
        vec4(cov3D[0][1], cov3D[1][1], cov3D[1][2], 0.0),
        vec4(cov3D[0][2], cov3D[1][2], cov3D[2][2], 0.0),
        vec4(0.0, 0.0, 0.0, 0.0)
    );
	
    mat4 cov = transpose(T) * transpose(Vrk) * T;

    cov[0][0] += 0.3;
    cov[1][1] += 0.3;
    return vec3(cov[0][0], cov[0][1], cov[1][1]);
}

float ndc2Pix(float v, float S) {
    return ((v + 1.) * S - 1.) * .5;
}


float sigmoid(float x) {
    if (x >= 0.0) {
        return 1.0 / (1.0 + exp(-x));
    } else {
        float z = exp(x);
        return z / (1.0 + z);
    }
}

vec3 computeColorFromSH(int deg, vec3 pos, vec3 cam_pos, vec3 sh[16]) {
	vec3 dir = normalize(pos - cam_pos);
	vec3 result = SH_C0 * sh[0];
	
	if (deg > 0) {
		float x = dir.x;
		float y = dir.y;
		float z = dir.z;
		result = result - SH_C1 * y * sh[1] + SH_C1 * z * sh[2] - SH_C1 * x * sh[3];

		if (deg > 1) {
			float xx = x * x, yy = y * y, zz = z * z;
			float xy = x * y, yz = y * z, xz = x * z;
			result = result +
				SH_C2[0] * xy * sh[4] +
				SH_C2[1] * yz * sh[5] +
				SH_C2[2] * (2.0f * zz - xx - yy) * sh[6] +
				SH_C2[3] * xz * sh[7] +
				SH_C2[4] * (xx - yy) * sh[8];

			if (deg > 2) {
				result = result +
						SH_C3[0] * y * (3.0f * xx - yy) * sh[9] +
						SH_C3[1] * xy * z * sh[10] +
						SH_C3[2] * y * (4.0f * zz - xx - yy) * sh[11] +
						SH_C3[3] * z * (2.0f * zz - 3.0f * xx - 3.0f * yy) * sh[12] +
						SH_C3[4] * x * (4.0f * zz - xx - yy) * sh[13] +
						SH_C3[5] * z * (xx - yy) * sh[14] +
						SH_C3[6] * x * (xx - 3.0f * yy) * sh[15];
			}
		}
	}
	result += 0.5f;
	return max(result, 0.0f);
}

void main() {
	uint depth_index = depth_index[n_splats - gl_InstanceIndex - 1];
    uint idx = depth_index * N_PROPERTIES;
    vec3 mu = vec3(vertices[idx], vertices[idx + 1], vertices[idx + 2]);

    //calculate clip space position and culling
	vec4 clipSpace = projection_matrix * model_view_matrix * vec4(mu, 1.0);
    float clip = 1.2 * clipSpace.w;
    if (clipSpace.z < -clip || clipSpace.z > clip || clipSpace.x < -clip || clipSpace.x > clip || clipSpace.y < -clip || clipSpace.y > clip) {
        gl_Position = vec4(0, 0, 2, 1);
        return;
    }

    vec3 scale = vec3(vertices[idx + 55], vertices[idx + 55 + 1], vertices[idx + 55 + 2]);
    vec4 rot = vec4(vertices[idx + 58], vertices[idx + 58 + 1], vertices[idx + 58 + 2], vertices[idx + 58 + 3]);
    opacity = sigmoid(vertices[idx + 54]);

    //noramlized device coordinates
    vec4 ndc = clipSpace / clipSpace.w;
    ndc.x *= -1;    // Not sure why i need this tbh
		
    //conic of covariance calculation
    vec3 cov2d = computeCov2D(mu, scale, rot, model_view_matrix);
    float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
    if (det == 0.) {
        gl_Position = vec4(0, 0, 2, 1);
        return;
    }

	float det_inv = 1.0 / det;
	vConic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
	float mid = 0.5 * (cov2d.x + cov2d.z);

    float lambda_1 = mid + sqrt(max(0.1, mid * mid - det));
    float lambda_2 = mid - sqrt(max(0.1, mid * mid - det));
    float radius_px = ceil(3. * sqrt(max(lambda_1, lambda_2)));
    vec2 point_image = vec2(ndc2Pix(ndc.x, params.viewport_size.x), ndc2Pix(ndc.y, params.viewport_size.y));

    if (shade_depth_texture == 1) {
        float idx_color = float(gl_InstanceIndex) / float(n_splats);
        color = vec3(idx_color, 1.0 - idx_color, 0.0);
    } else {
        vec3 sh[16];
        uint cidx = 0;
        for (int i = 0; i < 48; i += 3) {
            sh[cidx] = vec3(vertices[idx + 6 + i], vertices[idx + 6 + i + 1], vertices[idx + 6 + i + 2]);
            cidx++;
        }
        color = computeColorFromSH(int(params.sh_degree), mu, vec3(model_view_matrix[3].xyz), sh);
    }
    
    vec2 screen_pos = point_image + radius_px * vertex_position.xy;
    vUV = point_image - screen_pos;
    gl_Position = vec4(screen_pos / params.viewport_size * 2 - 1, 0, 1);

    vpoint_cloud_mode = point_cloud_mode;
    v_modifier = params.modifier;
}

#[fragment]
#version 450 core

layout (location = 1) in vec3 color;
layout (location = 2) in vec2 vUV;
layout (location = 3) in vec3 vConic;
layout (location = 4) in float opacity;
layout (location = 5) flat in uint point_cloud_mode;
layout (location = 6) flat in float v_modifier;
layout (location = 0) out vec4 frag_color;

void main() {
	vec2 d = vUV;
	vec3 conic = vConic;
	float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;

    if (point_cloud_mode == 1) {
        if (length(d) > v_modifier) {
		    discard;
        }

        frag_color = vec4(color.rgb, 1.0);
    } else {
        if (power > 0.0) {
		    discard;
        }

        float alpha = min(0.99, opacity * exp(power));
        
        if (alpha < 1.0/255.0) {
            discard;
        }

        frag_color = vec4(color.rgb * alpha, alpha);
    }
}

