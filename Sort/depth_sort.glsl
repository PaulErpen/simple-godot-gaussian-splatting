#[compute]
#version 450

layout(local_size_x = 1024, local_size_y = 1, local_size_z = 1) in;

// Depth index texture (read-write)
layout (set = 0, binding = 1) buffer elements_out {
    uint depth_index_out[];
};

// Depth buffer
layout(set = 0, binding = 2) buffer DepthBuffer {
    float depths[];
};

// n splats
layout(push_constant) uniform PushConstants {
    int n_splats;
    int iteration;
};

void main() {
    int phase = iteration % 2;

    int i_l = int(gl_GlobalInvocationID.x) * 2 + phase;
    int i_r = min(i_l + 1, n_splats - 1);

    if (i_l >= n_splats || i_r >= n_splats) {
        return;
    }

    uint index_l = depth_index_out[i_l];
    uint index_r = depth_index_out[i_r];

    float depth_l = depths[index_l];
    float depth_r = depths[index_r];

    if (depth_l.r < depth_r.r) {
        depth_index_out[i_l] = index_r;
        depth_index_out[i_r] = index_l;
    }
}
