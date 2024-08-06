// Adapted from: https://github.com/haztro/godot-gaussian-splatting/blob/main/shaders/splat.glsl
shader_type spatial;
render_mode unshaded, cull_back;

// property indices
uniform int idx_x;
uniform int idx_y;
uniform int idx_z;
uniform int idx_nx;
uniform int idx_ny;
uniform int idx_nz;
uniform int idx_f_dc_0;
uniform int idx_f_dc_1;
uniform int idx_f_dc_2;
uniform int idx_f_rest_0;
uniform int idx_f_rest_1;
uniform int idx_f_rest_2;
uniform int idx_f_rest_3;
uniform int idx_f_rest_4;
uniform int idx_f_rest_5;
uniform int idx_f_rest_6;
uniform int idx_f_rest_7;
uniform int idx_f_rest_8;
uniform int idx_f_rest_9;
uniform int idx_f_rest_10;
uniform int idx_f_rest_11;
uniform int idx_f_rest_12;
uniform int idx_f_rest_13;
uniform int idx_f_rest_14;
uniform int idx_f_rest_15;
uniform int idx_f_rest_16;
uniform int idx_f_rest_17;
uniform int idx_f_rest_18;
uniform int idx_f_rest_19;
uniform int idx_f_rest_20;
uniform int idx_f_rest_21;
uniform int idx_f_rest_22;
uniform int idx_f_rest_23;
uniform int idx_f_rest_24;
uniform int idx_f_rest_25;
uniform int idx_f_rest_26;
uniform int idx_f_rest_27;
uniform int idx_f_rest_28;
uniform int idx_f_rest_29;
uniform int idx_f_rest_30;
uniform int idx_f_rest_31;
uniform int idx_f_rest_32;
uniform int idx_f_rest_33;
uniform int idx_f_rest_34;
uniform int idx_f_rest_35;
uniform int idx_f_rest_36;
uniform int idx_f_rest_37;
uniform int idx_f_rest_38;
uniform int idx_f_rest_39;
uniform int idx_f_rest_40;
uniform int idx_f_rest_41;
uniform int idx_f_rest_42;
uniform int idx_f_rest_43;
uniform int idx_f_rest_44;
uniform int idx_opacity;
uniform int idx_scale_0;
uniform int idx_scale_1;
uniform int idx_scale_2;
uniform int idx_rot_0;
uniform int idx_rot_1;
uniform int idx_rot_2;
uniform int idx_rot_3;

// splat data
uniform sampler2D depth_index_sampler;
uniform int n_splats;
uniform int sh_degree;
uniform int texture_size;

uniform sampler2D means_sampler;
uniform sampler2D dc_sampler;
uniform sampler2D sh1_1_sampler;
uniform sampler2D sh1_2_sampler;
uniform sampler2D sh1_3_sampler;
uniform sampler2D sh2_1_sampler;
uniform sampler2D sh2_2_sampler;
uniform sampler2D sh2_3_sampler;
uniform sampler2D sh2_4_sampler;
uniform sampler2D sh2_5_sampler;
uniform sampler2D sh3_1_sampler;
uniform sampler2D sh3_2_sampler;
uniform sampler2D sh3_3_sampler;
uniform sampler2D sh3_4_sampler;
uniform sampler2D sh3_5_sampler;
uniform sampler2D sh3_6_sampler;
uniform sampler2D sh3_7_sampler;
uniform sampler2D opa_scale_sampler;
uniform sampler2D rot_sampler;

// parameters
uniform float modifier;
uniform float tan_fovx;
uniform float tan_fovy;
uniform float focal_x;
uniform float focal_y;
uniform vec2 viewport_size;
uniform bool shade_depth_texture;

//varyings
varying vec3 color;
varying float opacity;
varying vec3 vConic;
varying vec2 vUv;

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
		vec3(modifier * exp(scale.x), 0.0, 0.0),
		vec3(0.0, modifier * exp(scale.y), 0.0),
		vec3(0.0, 0.0, modifier * exp(scale.z))
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

    float limx = 1.3 * tan_fovx;
    float limy = 1.3 * tan_fovy;
    float txtz = t.x / t.z;
    float tytz = t.y / t.z;
    t.x = min(limx, max(-limx, txtz)) * t.z;
    t.y = min(limy, max(-limy, tytz)) * t.z;

    mat4 J = mat4(
        vec4(focal_x / t.z, 0.0, -(focal_x * t.x) / (t.z * t.z), 0.0),
        vec4(0.0, focal_y / t.z, -(focal_y * t.y) / (t.z * t.z), 0.0),
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

int retrieve_depth_index(int instance_id) {
	vec4 float_index = texelFetch(depth_index_sampler, ivec2(instance_id % texture_size, int(instance_id / texture_size)), 0);
    int r = int(float_index.r * 255.0);
    int g = int(float_index.g * 255.0);
    int b = int(float_index.b * 255.0);
    int a = int(float_index.a * 255.0);
    
    return (r << 24) | (g << 16) | (b << 8) | a;
}

vec3[16] retrieve_spherical_harmonics_coef(ivec2 index) {
	vec3[16] sh_coefs = vec3[16];
	
	sh_coefs[0] = texelFetch(dc_sampler, index, 0).rgb;
	
	if (sh_degree > 0) {
		sh_coefs[1] = texelFetch(sh1_1_sampler, index, 0).rgb;
		sh_coefs[2] = texelFetch(sh1_2_sampler, index, 0).rgb;
		sh_coefs[3] = texelFetch(sh1_3_sampler, index, 0).rgb;
		
		if (sh_degree > 1) {
			sh_coefs[4] = texelFetch(sh2_1_sampler, index, 0).rgb;
			sh_coefs[5] = texelFetch(sh2_2_sampler, index, 0).rgb;
			sh_coefs[6] = texelFetch(sh2_3_sampler, index, 0).rgb;
			sh_coefs[7] = texelFetch(sh2_4_sampler, index, 0).rgb;
			sh_coefs[8] = texelFetch(sh2_5_sampler, index, 0).rgb;
		}
		
		if (sh_degree > 2) {
			sh_coefs[9] = texelFetch(sh3_1_sampler, index, 0).rgb;
			sh_coefs[10] = texelFetch(sh3_2_sampler, index, 0).rgb;
			sh_coefs[11] = texelFetch(sh3_3_sampler, index, 0).rgb;
			sh_coefs[12] = texelFetch(sh3_4_sampler, index, 0).rgb;
			sh_coefs[13] = texelFetch(sh3_5_sampler, index, 0).rgb;
			sh_coefs[14] = texelFetch(sh3_6_sampler, index, 0).rgb;
			sh_coefs[15] = texelFetch(sh3_7_sampler, index, 0).rgb;
		}
	}
	
	return sh_coefs;
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

void vertex() {
	//int index = retrieve_depth_index(INSTANCE_ID);
	int depth_index = retrieve_depth_index(INSTANCE_ID);
	ivec2 index = ivec2(depth_index % texture_size, int(depth_index / texture_size));
	// retrieve data from texture
	vec3 mu = texelFetch(means_sampler, index, 0).xyz;
	//vec3 mu = texelFetch(means_opa_sampler, ivec2(index, 0), 0).rgb;
	opacity = sigmoid(texelFetch(opa_scale_sampler, index, 0).r);
	vec3 scale = texelFetch(opa_scale_sampler, index, 0).gba;
	vec4 rot = texelFetch(rot_sampler, index, 0).xyzw;
	
	//calculate clip space position and culling
	vec4 clipSpace = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(mu, 1.0);
    float clip = 1.2 * clipSpace.w;
    if (clipSpace.z < -clip || clipSpace.z > clip || clipSpace.x < -clip || clipSpace.x > clip || clipSpace.y < -clip || clipSpace.y > clip) {
        POSITION = vec4(0, 0, 2, 1);
    } else 
	{
		//noramlized device coordinates
		vec4 ndc = clipSpace / clipSpace.w;
		
		//conic of covariance calculation
		vec3 cov2d = computeCov2D(mu, scale, rot, MODELVIEW_MATRIX);
		float det = cov2d.x * cov2d.z - cov2d.y * cov2d.y;
	    if (det == 0.) {
	        POSITION = vec4(0, 0, 2, 1);
	    } else {
			float det_inv = 1.0 / det;
			vec3 conic = vec3(cov2d.z * det_inv, -cov2d.y * det_inv, cov2d.x * det_inv);
			float mid = 0.5 * (cov2d.x + cov2d.z);
			
			// compute eigenvalues
			float lambda_1 = mid + sqrt(max(0.1, mid * mid - det));
    		float lambda_2 = mid - sqrt(max(0.1, mid * mid - det));
			float radius_px = ceil(3. * sqrt(max(lambda_1, lambda_2)));
			// compute pixel in image space
    		vec2 point_image = vec2(ndc2Pix(ndc.x, viewport_size.x), ndc2Pix(ndc.y, viewport_size.y));
			
			if (shade_depth_texture) {
				float idx_color = float(INSTANCE_ID) / float(n_splats);
				color = vec3(idx_color, 1.0 - idx_color, 0.0);
			} else {
				vec3[16] sh = retrieve_spherical_harmonics_coef(index);
				color = computeColorFromSH(sh_degree, mu, vec3(VIEW_MATRIX[3].xyz), sh);  
			}
			
			vConic = conic;
			
			vec2 corner = vec2(float((VERTEX_ID << 1) & 2), float(VERTEX_ID & 2)) - 1.;
			vec2 screen_pos = point_image + radius_px * corner;
			vUv = point_image - screen_pos;
			POSITION = vec4(screen_pos / viewport_size * 2.0 - 1.0, 0, 1);
			//POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(VERTEX, 1.0);
		}
	}
}

void fragment() {
	vec2 d = vUv;
	vec3 conic = vConic;
	float power = -0.5 * (conic.x * d.x * d.x + conic.z * d.y * d.y) + conic.y * d.x * d.y;
	
	//if (power > 0.0) {
	//	discard;
	//}

	float alpha = min(0.99, opacity * exp(power));

	ALBEDO = color.rgb;
	ALPHA = alpha;
}

//void light() {
	// Called for every pixel for every light affecting the material.
	// Uncomment to replace the default light processing function with this one.
//}
