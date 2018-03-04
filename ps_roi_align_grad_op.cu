// MIT License

// Copyright (c) 2018 Changan Wang

// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:

// The above copyright notice and this permission notice shall be included in all
// copies or substantial portions of the Software.

// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
// SOFTWARE.
#if GOOGLE_CUDA == 1
#define EIGEN_USE_GPU
#include "ps_roi_align_op.h"
#include "tensorflow/core/util/cuda_kernel_helper.h"
#include "tensorflow/core/framework/register_types.h"
#include "tensorflow/core/framework/tensor_shape.h"

using namespace tensorflow;

#include <cstdint>
#include <cmath>
#include <cfloat>

// Define the CUDA kernel.
template <typename T>
__global__ void PSROIAlignGradCudaKernel(CudaLaunchConfig config, const T * inputs, const T * rois, const T * pooled_features_grad, const int32_t * pooled_index, T * grad_output, const int32_t grid_dim_width, const int32_t grid_dim_height, const int batch_size, const int num_channals, const int map_height, const int map_width, const int num_rois) {

  const int32_t grid_size = grid_dim_width * grid_dim_height;
  const int32_t bank_size = num_channals / grid_size;

  CUDA_1D_KERNEL_LOOP(worker_index, config.virtual_thread_count) {
    // image_index * roi_index * channal_pos_remainder * row_index * col_index
    const int32_t position_index = (worker_index % num_channals) / bank_size;
    const int32_t row_index = position_index / grid_dim_width;
    const int32_t col_index = position_index % grid_dim_width;
    // position of the channal of pooled feature
    // position of the channal in the bank of feature map
    const int32_t channal_pos_remainder = worker_index % bank_size;
    const int32_t pool_index = worker_index / num_channals;
    const int32_t image_index = pool_index / num_rois;
    const int32_t roi_index = pool_index % num_rois;

    const T * roi_to_pool = rois + (image_index * num_rois + roi_index) * 4;

    if(ldg(roi_to_pool + 2) < std::numeric_limits<T>::min() || ldg(roi_to_pool + 3) < std::numeric_limits<T>::min()) continue;
    // T roi_ymin = static_cast<T>(0);
    // T roi_xmin = static_cast<T>(0);
    // T roi_ymax = static_cast<T>(0);
    // T roi_xmax = static_cast<T>(0);
    // fix ROI
    // std::tie(roi_ymin, roi_xmin, roi_ymax, roi_xmax) = [roi_to_pool, map_height, map_width](){
    T _roi_y_center = static_cast<T>(ldg(roi_to_pool) * map_height);
    T _roi_x_center = static_cast<T>(ldg(roi_to_pool + 1) * map_width);
    T _roi_h = tf_max(ldg(roi_to_pool + 2) * map_height, static_cast<T>(1));
    T _roi_w = tf_max(ldg(roi_to_pool + 3) * map_width, static_cast<T>(1));

    T roi_ymin = tf_max(_roi_y_center - static_cast<T>(_roi_h / 2.), static_cast<T>(0));
    T roi_xmin = tf_max(_roi_x_center - static_cast<T>(_roi_w / 2.), static_cast<T>(0));
    T roi_ymax = tf_min(_roi_y_center + static_cast<T>(_roi_h / 2.), static_cast<T>(map_height) - std::numeric_limits<T>::min());
    T roi_xmax = tf_min(_roi_x_center + static_cast<T>(_roi_w / 2.), static_cast<T>(map_width) - std::numeric_limits<T>::min());
    //   return std::make_tuple(roi_ymin, roi_xmin, roi_ymax, roi_xmax);
    // }();

    T roi_h = roi_ymax - roi_ymin;
    T roi_w = roi_xmax - roi_xmin;
    float pool_bin_width = static_cast<float>(roi_w) / grid_dim_width;
    float pool_bin_height = static_cast<float>(roi_h) / grid_dim_height;
    int32_t num_elem_width = static_cast<int32_t>(pool_bin_width) + 1;
    int32_t num_elem_height = static_cast<int32_t>(pool_bin_height) + 1;

    // std::cout << "pool_bin_width: " << pool_bin_width << " pool_bin_height: " << pool_bin_height << " num_elem_width: " << num_elem_width << " num_elem_height: " << num_elem_height << std::endl;

    // std::cout << "worker_index: " << worker_index << " roi_index: " << roi_index
    // << " roi_ymin: " << roi_ymin << " roi_xmin: " << roi_xmin << " roi_ymax: " << roi_ymax << " roi_xmax: " << roi_xmax << " image_index: " << image_index << " position_index: " << (position_index % grid_size) << " channal_pos_remainder: " << channal_pos_remainder << std::endl;

    float step_width_each_bin = pool_bin_width / num_elem_width;
    float step_height_each_bin = pool_bin_height / num_elem_height;

    T * grad_output_start = reinterpret_cast<T*>(grad_output + (image_index * num_channals + position_index * bank_size + channal_pos_remainder) * map_height * map_width);

    const T * pooled_features_start = pooled_features_grad + worker_index;
    const int32_t * pooled_index_start = pooled_index + worker_index;
    // T * pooled_features_start = pooled_features_grad + image_index * (num_rois * num_channals) + roi_index * num_channals + (position_index % grid_size) * bank_size + channal_pos_remainder;
    // int32_t * pooled_index_start = pooled_index + image_index * (num_rois * num_channals) + roi_index * num_channals + (position_index % grid_size) * bank_size + channal_pos_remainder;

    float pool_width_start = roi_xmin + pool_bin_width * col_index;
    float pool_height_start = roi_ymin + pool_bin_height * row_index;

    const int32_t h_ind = ldg(pooled_index_start) / num_elem_width;
    const int32_t w_ind = ldg(pooled_index_start) % num_elem_width;

    float col_to_pool = pool_width_start + step_width_each_bin * w_ind + step_width_each_bin / 2.;
    float row_to_pool = pool_height_start + step_height_each_bin * h_ind + step_height_each_bin / 2.;
    //std::cout << "col_to_pool: " << col_to_pool << " row_to_pool: " << row_to_pool << std::endl;
    int32_t int_col_to_pool = static_cast<int32_t>(col_to_pool);
    int32_t int_row_to_pool = static_cast<int32_t>(row_to_pool);
    float float_col_to_pool = col_to_pool - int_col_to_pool;
    float float_row_to_pool = row_to_pool - int_row_to_pool;

    const T grad_in = ldg(pooled_features_start);

    atomicAdd(grad_output_start + int_row_to_pool * map_width + int_col_to_pool, static_cast<T>((1. - float_col_to_pool) * (1. - float_row_to_pool) * grad_in));
    atomicAdd(grad_output_start + tf_min(int_row_to_pool + 1, map_height - 1) * map_width + int_col_to_pool, static_cast<T>((1. - float_col_to_pool) * float_row_to_pool * grad_in));
    atomicAdd(grad_output_start + int_row_to_pool * map_width + tf_min(int_col_to_pool + 1, map_width - 1), static_cast<T>(float_col_to_pool * (1. - float_row_to_pool) * grad_in));
    atomicAdd(grad_output_start + tf_min(int_row_to_pool + 1, map_height - 1) * map_width + tf_min(int_col_to_pool + 1, map_width - 1), static_cast<T>(float_col_to_pool * float_row_to_pool * grad_in));
  }
}

template <typename T>
void PSROIAlignGradFunctor<GPUDevice, T>::operator()(OpKernelContext* context, const GPUDevice& d, typename TTypes<T>::ConstFlat inputs, typename TTypes<T>::ConstFlat rois, const int32_t grid_dim_width, const int32_t grid_dim_height, typename TTypes<T>::ConstFlat pooled_features_grad, typename TTypes<int32_t>::ConstFlat pooled_index, typename TTypes<T>::Flat grad_output, KDimSize dim_info) {

    int batch_size = 0;
    int num_channals = 0;
    int map_height = 0;
    int map_width = 0;
    int num_rois = 0;

    std::tie(batch_size, num_channals, map_height, map_width, num_rois) = dim_info;

    CudaLaunchConfig config = GetCudaLaunchConfig(batch_size * num_rois * num_channals, d);
    //grad_output = grad_output.setZero();
    SetZero <<<config.block_count, config.thread_per_block, 0, d.stream()>>> (batch_size * map_height * map_width * num_channals, grad_output.data());

    PSROIAlignGradCudaKernel <<<config.block_count,
                        config.thread_per_block, 0, d.stream()>>> (config, inputs.data(), rois.data(), pooled_features_grad.data(), pooled_index.data(), grad_output.data(), grid_dim_width, grid_dim_height, batch_size, num_channals, map_height, map_width, num_rois);

    cudaError_t err = cudaGetLastError();
    if(cudaSuccess != err)
    {
      fprintf( stderr, "cudaCheckError() failed : %s\n", cudaGetErrorString( err ) );
      exit( -1 );
    }
}

template struct PSROIAlignGradFunctor<GPUDevice, float>;
// #define DEFINE_GPU_SPECS(T)   \
//   template struct PSROIAlignFunctorGPU<T>;

// TF_CALL_GPU_NUMBER_TYPES(DEFINE_GPU_SPECS);

#endif  // GOOGLE_CUDA
