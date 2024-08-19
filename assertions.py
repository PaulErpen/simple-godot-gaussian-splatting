#%%

# read in file as array of integers
def read_input(file):
    with open(file) as f:
        return eval(f.readline())
# %%
sort_out = read_input("sort_out.txt")
# %%
def arr_is_sorted(arr):
    for i in range(1, len(arr)):
        if arr[i-1] > arr[i]:
            print(f"Array is not sorted at index {i}")
            return False
    return True

# %%
assert arr_is_sorted(sort_out)
# %%
debug_depths = read_input("debug_depths.txt")
assert arr_is_sorted(debug_depths)

# %%
assert len(sort_out) == 12828
# %%
