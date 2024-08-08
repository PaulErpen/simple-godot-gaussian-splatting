#[compute]
#version 450

layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in;

// Depth index texture (read-write)
layout(set = 0, binding = 0, r32f) uniform image2D depth_index_texture;

// Depth buffer
layout(set = 0, binding = 1) buffer DepthBuffer {
    float depths[];
};

// n splats
layout(push_constant) uniform PushConstants {
    int n_splats;
    int iteration;
};

void main() {
    int texture_size = int(imageSize(depth_index_texture).x);
    int phase = iteration % 2;

    int i_l = int(gl_GlobalInvocationID.x) * 2 + phase;
    int i_r = min(i_l + 1, n_splats - 1);

    if (i_l >= n_splats || i_r >= n_splats) {
        return;
    }

    int index_l = int(imageLoad(depth_index_texture, ivec2(i_l % texture_size, i_l / texture_size)).r);
    int index_r = int(imageLoad(depth_index_texture, ivec2(i_r % texture_size, i_r / texture_size)).r);

    float depth_l = depths[index_l];
    float depth_r = depths[index_r];

    if (depth_l.r < depth_r.r) {
        imageStore(depth_index_texture, ivec2(i_l % texture_size, i_l / texture_size), vec4(float(index_r)));
        imageStore(depth_index_texture, ivec2(i_r % texture_size, i_r / texture_size), vec4(float(index_l)));
    }
}
