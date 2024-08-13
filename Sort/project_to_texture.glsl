#[compute]
#version 450

layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in;

layout(set = 0, binding = 0, r32f) uniform image2D depth_index_texture;

layout (std430, set = 0, binding = 1) buffer elements_out {
    uint g_elements_out[];
};

layout(push_constant) uniform PushConstants {
    int n_splats;
};

void main() {
    int texture_size = int(imageSize(depth_index_texture).x);

    int i = int(gl_GlobalInvocationID.x);

    if (i >= n_splats) {
        return;
    }

    imageStore(depth_index_texture, ivec2(i % texture_size, i / texture_size), vec4(float(g_elements_out[n_splats - i])));
}
