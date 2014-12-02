/******************************************************************************
 *cr
 *cr         (C) Copyright 2010-2013 The Board of Trustees of the
 *cr                        University of Illinois
 *cr                         All Rights Reserved
 *cr
 ******************************************************************************/

// Define your kernels in this file you may use more than one kernel if you
// need to

// INSERT KERNEL(S) HERE


#include "defs.h"
#include "support.h"
#include<iostream>
#include<stdio.h>
using namespace std;
/*__constant__ unsigned short dc_flist_key_16_index[max_unique_items];
__global__ void histogram_kernel_naive(unsigned int* input, unsigned int* bins,
        unsigned int num_elements, unsigned int num_bins) {
    unsigned int i = blockDim.x * blockIdx.x + threadIdx.x;
    unsigned int stride = blockDim.x * gridDim.x;
    while (i < num_elements) {
        int bin_num = input[i];
        if (bin_num < num_bins) {
            atomicAdd(&bins[bin_num], 1);
        }
        i+=stride;
    }
}*/
__global__ void histogram_kernel(unsigned int* input, unsigned int* bins,
        unsigned int num_elements) {
    unsigned int i = blockDim.x * blockIdx.x + threadIdx.x;
    unsigned int index_x = 0;
    extern __shared__ unsigned int hist_priv[];
    for (int i = 0; i < ceil(MAX_UNIQUE_ITEMS / (1.0 * blockDim.x)); i++){
        index_x = threadIdx.x + i * blockDim.x;
        if (index_x < MAX_UNIQUE_ITEMS)
            hist_priv[index_x] = 0;
    }

    __syncthreads();
    unsigned int stride = blockDim.x * gridDim.x;
    while (i < num_elements) {
        int bin_num = input[i];
        if (bin_num < MAX_UNIQUE_ITEMS) {
            atomicAdd(&hist_priv[bin_num], 1);
        }
        i+=stride;
    }
    __syncthreads();
    for (int i = 0; i < ceil(MAX_UNIQUE_ITEMS / (1.0 * blockDim.x)); i++){
        index_x = threadIdx.x + i * blockDim.x;
        if (index_x < MAX_UNIQUE_ITEMS) {
            atomicAdd(&bins[index_x], hist_priv[index_x]);
        }
    }
}

__global__ void pruneGPU_kernel(unsigned int* input, int num_elements, int min_sup) {
    int tx = threadIdx.x;
    int index = tx + blockDim.x * blockIdx.x;
    if (index < num_elements) {
        if (input[index] < min_sup) {
            input[index] = 0;    
        } 
    }
}
__global__ void  initializeMaskArray(int *mask_d, int maskLength) {
    int index = threadIdx.x + blockDim.x * blockIdx.x;
    if (index < maskLength) {
        mask_d[index] = -1;
    }
}
__global__ void selfJoinKernel(unsigned int *input_d, int *output_d, int num_elements, int power) {
    int tx = threadIdx.x;
    int start = blockIdx.x * MAX_ITEM_PER_SM; 
    __shared__ int sm1[MAX_ITEM_PER_SM];   
    __shared__ int sm2[MAX_ITEM_PER_SM];

    int actual_items_per_sm = num_elements - start;
    if (actual_items_per_sm >= MAX_ITEM_PER_SM) {
        actual_items_per_sm = MAX_ITEM_PER_SM;
    }
    

    int location_x = 0;   
    for (int i = 0; i < ceil(MAX_ITEM_PER_SM/ (1.0 * BLOCK_SIZE));i++) {
        location_x = tx + i * BLOCK_SIZE;
        if (location_x < actual_items_per_sm && (start + location_x) < num_elements) {
            sm1[location_x] = input_d[start + location_x];    
        } else {
            sm1[location_x] = 0; 
        }
    }
    __syncthreads();

    // self join of 1st block
    int loop_tx = 0;
    for (int i = 0; i < ceil(MAX_ITEM_PER_SM/ (1.0 * BLOCK_SIZE));i++) {
        loop_tx = tx + i * BLOCK_SIZE;
        if (loop_tx < actual_items_per_sm) {
            for (int j = loop_tx + 1;j < actual_items_per_sm;j++) {
                if (sm1[loop_tx] / (int)(pow(10.0, (double)power)) == sm1[j] / (int)(pow(10.0, (double)power))) {
                //if (sm1[loop_tx] / 10 == sm1[j] / 10) {
                    output_d[(start + loop_tx) * num_elements + (start + j)] = 0;
               } 
            }   
        }
    }

    __syncthreads();
    if ((blockIdx.x + 1) < ceil(num_elements / (1.0 * MAX_ITEM_PER_SM))) {
        int current_smid = 0;
        for (int smid = blockIdx.x + 1; smid < ceil(num_elements / (1.0 * MAX_ITEM_PER_SM));smid++) {
            int actual_items_per_secondary_sm = num_elements - current_smid * MAX_ITEM_PER_SM - start - MAX_ITEM_PER_SM;
            if (actual_items_per_secondary_sm > MAX_ITEM_PER_SM)
                actual_items_per_secondary_sm = MAX_ITEM_PER_SM;

            for (int i = 0; i < ceil(MAX_ITEM_PER_SM/ (1.0 * BLOCK_SIZE));i++) {
                int location_x = tx + i * BLOCK_SIZE;
                if (location_x < actual_items_per_secondary_sm and (current_smid * MAX_ITEM_PER_SM + start + location_x) < num_elements) {
                    sm2[location_x] = input_d[(current_smid + 1) * MAX_ITEM_PER_SM + start + location_x];
                } else {
                    sm2[location_x] = 0;
                }
            }
            __syncthreads();
                            
            for (int i = 0; i < ceil(MAX_ITEM_PER_SM/ (1.0 * BLOCK_SIZE));i++) {
                if (loop_tx < actual_items_per_sm) {
                    for (int j = 0;j < actual_items_per_secondary_sm;j++) {
                        if (sm1[loop_tx] / (int)(pow(10.0, (double)power)) == sm2[j] / (int)(pow(10.0, (double)power))) {
                        //if (sm1[loop_tx] / 10 == sm2[j] / 10) {
                            output_d[(start + loop_tx) * num_elements + (current_smid + 1) * MAX_ITEM_PER_SM + start + j] = 0;
                       } 
                    }   
                    
                }
            }
        }
        current_smid++;    
    }
}
__global__ void findFrequencyGPU_kernel(unsigned int *d_transactions, 
                                 unsigned int *d_offsets,
                                 int num_transactions,
                                 int num_elements,
                                 unsigned int* d_keyIndex,
                                 int* d_mask,
                                 int num_patterns,
                                 int maskLength) {
    __shared__ unsigned int Ts[MAX_TRANSACTION_PER_SM][MAX_ITEM_PER_TRANSACTION];
    int tx = threadIdx.x;
    
    int index = tx + blockDim.x * blockIdx.x;
    int trans_index = blockIdx.x * MAX_TRANSACTION_PER_SM; 
    //init the SM
    for (int i = 0;i < MAX_TRANSACTION_PER_SM; i++) {
        if (tx < MAX_ITEM_PER_TRANSACTION) {
            Ts[i][tx] = -1; 
        }
    }
    __syncthreads();
    // bring the trnsactions to the SM 
    for (int i = 0;i < MAX_TRANSACTION_PER_SM; i++) {
        int item_ends = num_elements;
        if ((trans_index + i + 1) == num_transactions) {
            item_ends = num_elements;
        } else if ((trans_index + i + 1) < num_transactions) {
            item_ends = d_offsets[trans_index + i + 1];
        } else
            continue;
       if ((tx + d_offsets[trans_index + i]) < item_ends and tx < MAX_ITEM_PER_TRANSACTION) {
           Ts[i][tx] = d_transactions[d_offsets[trans_index + i] + tx];
       }
    }

    __syncthreads();

   for (int maskid = 0; maskid < int(ceil(num_patterns/(1.0 * blockDim.x)));maskid++) {
       int loop_tx = tx + maskid * blockDim.x;
       if (loop_tx >= num_patterns) continue;
       
       for (int last_seen = 0; last_seen < num_patterns; last_seen++) {
           if (loop_tx * num_patterns + last_seen >= maskLength) {
               break;
           }
          if (d_mask[loop_tx * num_patterns + last_seen] < 0) continue;
           
           int item1 = d_keyIndex[loop_tx];
           int item2 = d_keyIndex[last_seen];
           //if (blockIdx.x == 0 && tx == 0)
           //printf("(tx=%d,bx=%d,item1=%d,item2=%d)\n", tx, blockIdx.x, item1, item2);
           for (int tid = 0; tid < MAX_TRANSACTION_PER_SM;tid++) {
               bool flag1 = false;
               bool flag2 = false;
               for (int titem = 0;titem < MAX_ITEM_PER_TRANSACTION;titem++) {
                   //if (blockIdx.x == 0 && tx==0)
                   //printf("(tx=%d,titem=%d)\n", tx, Ts[tid][titem]);
                   if (Ts[tid][titem] == item1) {
                       flag1 = true;
                   } else if (Ts[tid][titem] == item2) {
                       flag2 = true;
                   }
               }
               bool present_flag = flag1 & flag2;
               if (present_flag)
                   atomicAdd(&d_mask[loop_tx * num_patterns + last_seen], 1);
           }
       }    
   }
   
}
__global__ void pruneMultipleGPU(int *mask_d, int num_patterns, int min_sup) { 
    int index_x = threadIdx.x + blockDim.x * blockIdx.x;
    int index_y = threadIdx.y + blockDim.y * blockIdx.y;

    if (index_x < num_patterns && index_y < num_patterns) {
        int data_index = index_y * num_patterns + index_x;    
        if (mask_d[data_index] < min_sup) {
            mask_d[data_index] = 0;    
        }
    }
}
#if 0
    //make_flist(d_trans_offsets, d_transactions, d_flist, num_transactions, num_items_in_transactions);
void make_flist(unsigned int *d_trans_offset, unsigned int *d_transactions, unsigned int *d_flist,
        unsigned int num_transactions, unsigned int num_items_in_transactions, int SM_PER_BLOCK) {
    
    cudaError_t cuda_ret;
    dim3 grid_dim, block_dim;
    block_dim.x = BLOCK_SIZE; 
    block_dim.y = 1; block_dim.z = 1;
    grid_dim.x = ceil(num_items_in_transactions / (16.0 * BLOCK_SIZE)); 
    grid_dim.y = 1; grid_dim.z = 1;
    if (max_unique_items * sizeof(unsigned int) < SM_PER_BLOCK) {
        // private histogram should fit in shared memory
        histogram_kernel<<<grid_dim, block_dim, max_unique_items * sizeof(unsigned int)>>>(d_transactions, d_flist, num_items_in_transactions);
    } else {
        // private histogram will not fit in shared memory. launch global kernel
        histogram_kernel_naive<<<grid_dim, block_dim>>>(d_transactions, d_flist, num_items_in_transactions, max_unique_items);
    }
    
    cuda_ret = cudaDeviceSynchronize();
    if(cuda_ret != cudaSuccess) FATAL("Unable to launch kernel");
}
    
   
   
   
__global__ void sort_transaction_kernel(unsigned short *d_flist_key_16_index, unsigned int *d_flist, unsigned int *d_transactions,
        unsigned int *offset_array, unsigned int num_transactions, unsigned int num_elements, unsigned int bins, bool indexFileInConstantMem) {
   
    //unsigned int transaction_index = threadIdx.x + blockDim.x * blockIdx.x;
    //unsigned int stride = blockDim.x * gridDim.x;
    unsigned int i = 0;
    unsigned int j = 0;
    unsigned int swap = 0;
    unsigned int start_offset = 0;
    unsigned int end_offset = 0;
    unsigned int index1 = 0;
    unsigned int transaction_start_index = blockDim.x * blockIdx.x;
    //TBD: need to pass dynamically
    __shared__ unsigned int Ts[TRANSACTION_PER_SM][max_items_in_transaction];
    
    while (transaction_start_index < num_transactions) {
    unsigned int index = threadIdx.x;
    unsigned int transaction_end_index = transaction_start_index +  blockDim.x;
    
    __syncthreads();
    // clear SM 
    for (i = 0; i < TRANSACTION_PER_SM; i++) {
        while (index < max_items_in_transaction) {
            Ts[i][index] = 0;//INVALID;
            index += blockDim.x;
        }
        __syncthreads();
    }
    // get all the transaction assigned to this block into SM
    for (i = transaction_start_index; i < transaction_end_index && i < num_transactions; i++) {
        // get the ith transaction data into SM
        start_offset = offset_array[i];
        end_offset = offset_array[i+1];
        index1 = start_offset + threadIdx.x;
        __syncthreads();
        // threads collaborate to get the ith transaction
        while (index1 < end_offset) {
            Ts[i-transaction_start_index][index1 - start_offset] = d_transactions[index1];        
            index1 += blockDim.x;
        }
        __syncthreads();
    }

    // now that all transactions are in SM, each thread takes ownership of a row of SM
    // (i.e. one transaction per thread)
    if (threadIdx.x < TRANSACTION_PER_SM) {
        //to test basic functionality
        /*for (int i =0; i < max_items_in_transaction;i++) {
            if (Ts[threadIdx.x][i] < INVALID) {
                Ts[threadIdx.x][i]++;
            }
        }*/
    }
//endloop:
    __syncthreads();
    // now that work is done write back results 
    for (i = transaction_start_index; i < transaction_end_index && i < num_transactions; i++) {
        // get the ith transaction data from SM to global mem
        start_offset = offset_array[i];
        end_offset = offset_array[i+1];
        index1 = start_offset + threadIdx.x;
        __syncthreads();
        while (index1 < end_offset) {
            d_transactions[index1] = Ts[i - transaction_start_index][index1 - start_offset];        
            index1 += blockDim.x;
        }
        __syncthreads();
    }
    transaction_start_index += (blockDim.x * gridDim.x);
    }
} 

void sort_transaction(unsigned short *d_flist_key_16_index, unsigned int *d_flist, unsigned int *d_transactions, unsigned int *offset_array, unsigned int num_transactions, unsigned int num_items_in_transactions, unsigned int bins,bool indexFileInConstantMem) {
    cudaDeviceProp deviceProp;
    cudaError_t ret;
    cudaGetDeviceProperties(&deviceProp, 0);
    int SM_PER_BLOCK = deviceProp.sharedMemPerBlock;
    
    dim3 block_dim;
    dim3 grid_dim;
    
    unsigned int bytesPerTransaction = max_items_in_transaction * sizeof(unsigned int);
    
    block_dim.x = ((SM_PER_BLOCK / bytesPerTransaction) - 10) > TRANSACTION_PER_SM ? TRANSACTION_PER_SM : ((SM_PER_BLOCK / bytesPerTransaction) - 10);
    block_dim.y = 1;
    block_dim.y = 1;

    grid_dim.x = (int) ceil(num_transactions / (2.0 * block_dim.x));
    grid_dim.y = 1;
    grid_dim.z = 1;
#ifdef TEST_MODE
    cout<<"sort_transaction_kernel<bx,gx>"<<block_dim.x<<","<<grid_dim.x<<endl;
#endif
    sort_transaction_kernel<<<grid_dim, block_dim>>>(d_flist_key_16_index, d_flist, d_transactions, offset_array,
            num_transactions, num_items_in_transactions, bins, indexFileInConstantMem); 
    ret = cudaDeviceSynchronize();
    if(ret != cudaSuccess) FATAL("Unable to launch kernel");
    
    
}

__global__ void pruneList(unsigned int *input, int num_elements, int min_support) {
    int index = threadIdx.x + blockDim.x * blockIdx.x;

    if (index < num_elements) {
        if (input[index] < min_support) {
            input[index] = 0;    
        }    
    }
} 


__global__ void selfJoinKernel(int *input, int *mask, int num_elements) {
    int start = blockIdx.x * MAX_ITEM_PER_SM; 
    __shared__ int sm1[MAX_ITEM_PER_SM];   
    __shared__ int sm2[MAX_ITEM_PER_SM];
    int location_x = 0;
    for (int i = 0; i < ceil(MAX_ITEM_PER_SM / (1.0 * blockDim.x));i++) {
        location_x = threadIdx.x + i * blockDim.x;
        if (location_x < num_elements) {
            sm1[location_x] = input[start + location_x]; 
        }    
    }
    
    __syncthreads();
    for (int i = 0; i < ceil(MAX_ITEM_PER_SM / 1.0 * blockDim.x);i++) {
        int loop_tx = threadIdx.x + i * blockDim.x;
        for (int j = loop_tx + 1; j < MAX_ITEM_PER_SM; j++) {
            if ((sm1[loop_tx] / 10) == sm1[j] / 10) {
                mask[(start + loop_tx) * num_elements + (start + j)] = 0;    
            } else {
                mask[(start + loop_tx) * num_elements + (start + j)] = -1; // not needed ??    
            }
        }
    }
    
    for (int smid = blockIdx.x + 1; smid < ceil(num_elements/ (1.0 * MAX_ITEM_PER_SM));smid++) {
        for (int i = 0; i < ceil(MAX_ITEM_PER_SM / (1.0 * blockDim.x)); i++) {
            location_x = threadIdx.x + i * blockDim.x;
            if (location_x < num_elements) {
                sm2[location_x] = input[smid * MAX_ITEM_PER_SM + start + location_x];    
            }
        }
        __syncthreads();

        for (int i = 0; i < ceil(MAX_ITEM_PER_SM / (1.0 * blockDim.x)); i++) {
            int loop_tx = threadIdx.x + i * blockDim.x;
            for (int j = 0; j < MAX_ITEM_PER_SM; j++) {
                if ((sm1[loop_tx] / 10) == (sm2[j] / 10)) {
                    mask[(start + loop_tx) * num_elements + smid * MAX_ITEM_PER_SM + j] = 0;
                } else {
                    mask[(start + loop_tx) * num_elements + smid * MAX_ITEM_PER_SM + j] = -1;
                }
                
            } 
            
        }
    } 
}
#endif
