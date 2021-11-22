#include "cuda_runtime.h"
#include "device_launch_parameters.h"
#include "sieve_impl.cuh"
#include "sieve.hpp"
#include "sieve_small_prime_constants.cuh"
#include "sieve_lookup_tables.cuh"

#include <cuda.h>
#include <stdio.h>
#include <math.h>
#include <inttypes.h>


#define checkCudaErrors(call)                                \
  do {                                                        \
    cudaError_t err = call;                                   \
    if (err != cudaSuccess) {                                 \
      printf("CUDA error at %s %d: %s\n", __FILE__, __LINE__, \
             cudaGetErrorString(err));                        \
      exit(EXIT_FAILURE);                                     \
    }                                                         \
  } while (0)

namespace nexusminer {
    namespace gpu {

        __device__ void cuda_chain_push_back(CudaChain& chain, uint16_t offset);
        __device__ void cuda_chain_open(CudaChain& chain, uint64_t base_offset);
        __device__  bool is_there_still_hope(CudaChain& chain);
        __device__  void get_best_fermat_chain(const CudaChain& chain, uint64_t& base_offset, int& offset, int& best_length);


        int round_up(int num, int factor)
        {
            return num + factor - 1 - (num + factor - 1) % factor;
        }
        
        // cross off small primes.  These primes hit the sieve often.  Primes up to 59 can hit a single sieve word two or more times.  
        // We iterate through the sieve words and cross them off using 
        // precalculated constants.  start is the offset from the sieve start 
        __global__ void sieveSmallPrimes(Cuda_sieve::sieve_word_t* sieve, uint64_t start, uint16_t* small_prime_offsets, uint32_t* masks, 
            uint8_t* small_primes)
        {

            uint32_t num_blocks = gridDim.x;
            uint32_t num_threads = blockDim.x;
            uint32_t block_id = blockIdx.x;
            uint32_t index = block_id * num_threads + threadIdx.x;
            uint32_t stride = num_blocks * num_threads;
            __shared__ uint16_t offsets[Cuda_sieve::m_small_prime_count];

            const uint32_t increment = Cuda_sieve::m_sieve_word_range;
            //this loop is faster than a big switch case block with the primes hardcoded.  
            for (uint32_t i = threadIdx.x; i < Cuda_sieve::m_small_prime_count; i += num_threads)
            {
                uint8_t start_offset = start % small_primes[i];
                offsets[i] = small_prime_offsets[i] + start_offset;
            }

            __syncthreads();
            uint32_t inc = increment * stride;
            
            //initialize the table indices
            //we mod intermediate values to avoid needing a 64 bit multiplication which is slow 
            //there is some risk of overflow if index gets too big.  max index is dependent on the sieve size.
            uint8_t index7 = (offsets[0] + index * (increment % 7)) % 7;  // 120 % 7 == 1.  
            uint8_t index11 = (offsets[1] + index * (increment % 11)) % 11;
            uint8_t index13 = (offsets[2] + index * (increment % 13)) % 13;  //120 % 13 == 3.  
            uint8_t index17 = (offsets[3] + index * (increment % 17)) % 17;  //120 % 17 == 1
            uint8_t index19 = (offsets[4] + index * (increment % 19)) % 19;
            uint8_t index23 = (offsets[5] + index * (increment % 23)) % 23;
            uint8_t index29 = (offsets[6] + index * (increment % 29)) % 29;
            uint8_t index31 = (offsets[7] + index * (increment % 31)) % 31;
            uint8_t index37 = (offsets[8] + index * (increment % 37)) % 37;
            uint8_t index41 = (offsets[9] + index * (increment % 41)) % 41;
            uint8_t index43 = (offsets[10] + index * (increment % 43)) % 43;
            uint8_t index47 = (offsets[11] + index * (increment % 47)) % 47;
            uint8_t index53 = (offsets[12] + index * (increment % 53)) % 53;
            uint8_t index59 = (offsets[13] + index * (increment % 59)) % 59;  //120 % 59 == 2. 

            //apply the masks the first time  
            uint32_t word = p7[index7] & p11[index11] & p13[index13] & p17[index17] & p19[index19] & p23[index23] & p29[index29] & p31[index31] &
                p37[index37] & p41[index41] & p43[index43] & p47[index47] & p53[index53] & p59[index59];

            //save the first sieve word to global memory
            sieve[index] = word;

            for (uint32_t i = index+stride; i < Cuda_sieve::m_sieve_total_size; i += stride) 
            {
                //update the lookup table indices
                index7 = (index7 + inc) % 7;
                index11 = (index11 + inc) % 11;
                index13 = (index13 + inc) % 13;
                index17 = (index17 + inc) % 17;
                index19 = (index19 + inc) % 19;
                index23 = (index23 + inc) % 23;
                index29 = (index29 + inc) % 29;
                index31 = (index31 + inc) % 31;
                index37 = (index37 + inc) % 37;
                index41 = (index41 + inc) % 41;
                index43 = (index43 + inc) % 43;
                index47 = (index47 + inc) % 47;
                index53 = (index53 + inc) % 53;
                index59 = (index59 + inc) % 59;
                
                //apply the masks.  
                word = p7[index7] & p11[index11] & p13[index13] & p17[index17] & p19[index19] & p23[index23] & p29[index29] & p31[index31] &
                    p37[index37] & p41[index41] & p43[index43] & p47[index47] & p53[index53] & p59[index59];

                //save the sieve word to global memory
                sieve[i] = word;

            }
        }

        //return the offset from x to the next integer multiple of n greater than x that is not divisible by 2, 3, or 5.  
       //x must be a multiple of the primorial 30 and n must be a prime greater than 5.
        template <typename T1, typename T2>
        __device__ __forceinline__ T2 get_offset_to_next_multiple(T1 x, T2 n)
        {
            T2 m = n - static_cast<T2>(x % n);            

           if (m % 2 == 0)
            {
                m += n;
            }
           if (m % 3 == 0 || m % 5 == 0)
           {
               m += 2 * n;
           }
           if (m % 3 == 0 || m % 5 == 0)
           {
               m += 2 * n;
           }
           
            return m;
        }

        //large primes hit the sieve no more than once per segment.  The large prime kernel works on a shared copy 
        //of the sieve one segment at a time.  The word and bit where the primes hit the segment are stored in the bucket array. 
        //The buckets must be filled prior to calling this kernel. We iterate through the hits in the bucket and cross off composites.  
        __global__ void sieveLargePrimes(uint32_t* large_prime_buckets, uint32_t* bucket_indices, Cuda_sieve::sieve_word_t* sieve_results)
        {
            //each kernel block works on one segment of the sieve.  
            unsigned int num_threads = blockDim.x;
            unsigned int block_id = blockIdx.x/Cuda_sieve::m_kernel_segments_per_block;
            unsigned int segment_id = blockIdx.x % Cuda_sieve::m_kernel_segments_per_block;
            unsigned int index = threadIdx.x;
            unsigned int stride = num_threads;

            if (block_id >= Cuda_sieve::m_num_blocks)
                return;

            //local shared copy of one segment of the sieve
            __shared__ Cuda_sieve::sieve_word_t sieve[Cuda_sieve::m_kernel_sieve_size_words];
            
            uint32_t sieve_results_index = blockIdx.x * Cuda_sieve::m_kernel_sieve_size_words;
            //each thread in the block initialize part of the shared sieve
            for (int j = index; j < Cuda_sieve::m_kernel_sieve_size_words; j += stride)
            {
                sieve[j] = sieve_results[sieve_results_index + j];
            }
            
            //the number of sieve hits in this segment
            unsigned int sieve_hits = bucket_indices[block_id * Cuda_sieve::m_kernel_segments_per_block + segment_id];
            uint32_t z = block_id;
            uint32_t y = segment_id;
            uint32_t x;
            const uint32_t ymax = Cuda_sieve::m_kernel_segments_per_block;
            const uint32_t xmax = Cuda_sieve::m_large_prime_bucket_size;
            __syncthreads();
            //iterate through the sieve hits
            for (unsigned int i = index; i < sieve_hits; i+=stride)
            {
                //unpack the sieve word and bit from the bucket data
                x = i;
                uint32_t bucket_data = large_prime_buckets[z * xmax * ymax + y * xmax + x];
                uint32_t sieve_word = (bucket_data >> 16) & 0x0000FFFF;
                uint32_t sieve_bit = bucket_data & 0x0000FFFF;
                //cross off the bit in the shared sieve
                uint32_t bit_mask = ~(1u << sieve_bit);
                atomicAnd(&sieve[sieve_word], bit_mask);
                //if (block_id == 1)
                //    printf("block %u segment %u bucket index %u word %u bit %u\n", block_id, segment_id, i, sieve_word, sieve_bit);
            }

            __syncthreads();

            //merge the sieve results back to global memory
            for (unsigned int j = index; j < Cuda_sieve::m_kernel_sieve_size_words; j += stride)
            {
                sieve_results[sieve_results_index + j] = sieve[j];
            }

        }
        
        //get the nth bit from the sieve.
        __device__ __forceinline__ bool get_bit(uint64_t bit_position, Cuda_sieve::sieve_word_t* sieve)
        {
            const uint32_t sieve_bits_per_word = Cuda_sieve::m_sieve_word_byte_count * 8;
            
            uint64_t word = bit_position / sieve_bits_per_word;
            unsigned bit_position_in_word = bit_position % sieve_bits_per_word;
            return ((sieve[word] >> bit_position_in_word) & 1) == 1;

        }

        //search the sieve for chains that meet the minimum length requirement.  
        __global__ void find_chain_kernel(Cuda_sieve::sieve_word_t* sieve, CudaChain* chains, uint32_t* chain_index, uint64_t sieve_start_offset,
            unsigned long long* chain_stat_count)
        {

            //const uint64_t sieve_size = Cuda_sieve::m_sieve_total_size;
            const uint32_t sieve_bits_per_word = Cuda_sieve::m_sieve_word_byte_count * 8;
            const uint64_t sieve_total_bits = Cuda_sieve::m_sieve_total_size * sieve_bits_per_word;
            uint64_t num_blocks = gridDim.x;
            uint64_t num_threads = blockDim.x;
            uint64_t block_id = blockIdx.x;
            uint64_t index = block_id * num_threads + threadIdx.x;
            uint64_t stride = num_blocks * num_threads;
            unsigned int sieve_offset;
            unsigned int gap;
            uint64_t chain_start, prime_candidate_offset;

            //shared copies of lookup tables
            __shared__ unsigned int sieve30_offsets_shared[8];
            __shared__ unsigned int sieve30_gaps_shared[8];
            //local stats
            __shared__ uint32_t chain_count_shared;
            
            if (threadIdx.x < 8)
            {
                int i = threadIdx.x;
                sieve30_offsets_shared[i] = sieve30_offsets[i];
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            
            if (threadIdx.x == 0)
                chain_count_shared = 0;
            __syncthreads();
           
            //search each sieve location for a possible chain
            for (uint64_t i = index; i < sieve_total_bits; i += stride)
            {
              
                //gross checks to ensure its possible to form a chain
                uint64_t word = i / sieve_bits_per_word;
                if (sieve[word] == 0)
                    continue;
                //check if the next 4 bytes (4*30 = range of 120 integers) has enough prime candidates to form a chain 
                //this is only valid up to min chain length 9.  above 9 requires 5 bytes.
                if (word < Cuda_sieve::m_sieve_total_size - 1)
                {
                    unsigned int next_4_bytes = 0;
                    unsigned int byte_index = (i/8) % 4;
                    next_4_bytes = (sieve[word] >> (byte_index * 8)) & 0xFF;
                    next_4_bytes |= (((sieve[word + (byte_index >= 3 ? 1 : 0)] >> ((byte_index + 1) % 4) * 8) & 0xFF) << 8);
                    next_4_bytes |= (((sieve[word + (byte_index >= 2 ? 1 : 0)] >> ((byte_index + 2) % 4) * 8) & 0xFF) << 16);
                    next_4_bytes |= (((sieve[word + (byte_index >= 1 ? 1 : 0)] >> ((byte_index + 3) % 4) * 8) & 0xFF) << 24);

                    int popc = __popc(next_4_bytes);
                    if (popc < Cuda_sieve::m_min_chain_length)
                        continue;
                }

                //chain must start with a prime
                if (!get_bit(i, sieve))
                {
                    continue;
                }
                //search left for another prime less than max gap away
                uint64_t j = i - 1;
                gap = sieve30_gaps_shared[j % 8];
                while (j < i && gap <= maxGap)
                {
                    if (get_bit(j, sieve))
                    {
                        //there is a valid element to the left.  this is not the first element in a chain. abort.
                        break;
                    }
                    j--;
                    gap += sieve30_gaps_shared[j % 8];
                }
                if (gap <= maxGap)
                    continue;
                //this is the start of a possible chain.  search right
                //where are we in the wheel
                sieve_offset = sieve30_offsets_shared[i % 8u];
                chain_start = sieve_start_offset + i / 8 * 30 + sieve_offset;
                CudaChain current_chain;
                cuda_chain_open(current_chain, chain_start);
                j = i;
                gap = sieve30_gaps_shared[j % 8u];
                j++;
                while (j < sieve_total_bits && gap <= maxGap)
                {
                    if (get_bit(j, sieve))
                    {
                        //another possible candidate.  add it to the chain
                        gap = 0;
                        sieve_offset = sieve30_offsets_shared[j % 8u];
                        prime_candidate_offset = sieve_start_offset + j / 8 * 30 + sieve_offset;
                        uint16_t offset = prime_candidate_offset - chain_start;
                        //printf("%" PRIu64 " %u\n", chain_start, prime_candidate_offset);
                        cuda_chain_push_back(current_chain, offset);
                    }
                    gap += sieve30_gaps_shared[j % 8u];
                    j++;
                        
                }
                //we reached the end of the chain.  check if it meets the length requirement
                if (current_chain.m_offset_count >= Cuda_sieve::m_min_chain_length)
                {
                    //increment the chain list index
                    uint32_t chain_idx = atomicInc(chain_index, Cuda_sieve::m_max_chains);
                    //copy the current chain to the global list
                    chains[chain_idx] = current_chain;
                    //updated block level stats
                    atomicInc(&chain_count_shared, 0xFFFFFFFF);
                }
            }
            //update global chain stats
            __syncthreads();
            if (threadIdx.x == 0)
                atomicAdd(chain_stat_count, chain_count_shared);
        }

        //experimental chain finder
        //each kernel block is a sieve segment.  Each thread searches a range of 2310*4 within a segment.   
        __global__ void find_chain_kernel2(Cuda_sieve::sieve_word_t* sieve, CudaChain* chains, uint32_t* chain_index, uint64_t sieve_start_offset,
            unsigned long long* chain_stat_count)
        {
            const unsigned int search_range = Cuda_sieve::m_sieve_chain_search_boundary * Cuda_sieve::m_sieve_word_byte_count;
            const unsigned int search_words = search_range / Cuda_sieve::m_sieve_word_range;
            const unsigned int total_search_regions = Cuda_sieve::m_sieve_range / search_range;
            unsigned int num_blocks = gridDim.x;
            unsigned int block_id = blockIdx.x / Cuda_sieve::m_kernel_segments_per_block;
            unsigned int segment_id = blockIdx.x % Cuda_sieve::m_kernel_segments_per_block;
            unsigned int index = threadIdx.x;
            unsigned int search_regions_per_kernel_block = (total_search_regions + num_blocks - 1) / num_blocks;
            unsigned int stride = blockDim.x;
            unsigned int gap;
            uint32_t chain_start;
            uint64_t segment_offset = sieve_start_offset + block_id * Cuda_sieve::m_block_range + segment_id * Cuda_sieve::m_segment_range;
            uint32_t sieve_segment_index = block_id * Cuda_sieve::m_kernel_sieve_size_words_per_block + segment_id * Cuda_sieve::m_kernel_sieve_size_words;
            uint32_t sieve_index;
            //shared copies of lookup tables
            __shared__ unsigned int sieve30_offsets_shared[8];
            //local stats
            __shared__ uint32_t chain_count_shared;
            //local shared copy of the sieve
            //__shared__ Cuda_sieve::sieve_word_t sieve_shared[Cuda_sieve::m_kernel_sieve_size_words];

            if (threadIdx.x < 8)
            {
                int i = threadIdx.x;
                sieve30_offsets_shared[i] = sieve30_offsets[i];
            }

            if (threadIdx.x == 0)
            {
                chain_count_shared = 0;
            }

            ////copy sieve segment from global to shared memory
            //for (int i = index; i < Cuda_sieve::m_kernel_sieve_size_words; i += stride)
            //{

            //    sieve_shared[i] = sieve[sieve_segment_index + i];
            //}
                
            __syncthreads();

            for (unsigned int region = index; region < search_regions_per_kernel_block; region += stride)
            {
                bool chain_in_process = false;
                CudaChain current_chain;
                uint64_t region_offset = segment_offset + region * search_range;
                chain_start = 0;
                sieve_index = region * search_words + sieve_segment_index;
                uint32_t last_offset = 0;
                //iterate through each word in the search region
                for (unsigned int word = 0; word < search_words; word++)
                {
                    //iterate through each set bit in the sieve word
                    for (unsigned int b = sieve[sieve_index + word]; b > 0; b &= b - 1)
                    {
                        //determine the position of the set bit in the sieve word.
                        int lowest_set_bit = __ffs(b) - 1;  //__ffs is a cuda primitive that finds the index of the lowest set bit in a word (ones based).
                        int byte_index = lowest_set_bit / 8;
                        unsigned int sieve30_offset = sieve30_offsets_shared[lowest_set_bit % 8];
                        uint32_t local_offset = word * Cuda_sieve::m_sieve_word_range +
                            byte_index * Cuda_sieve::m_sieve_byte_range + sieve30_offset;
                        gap = local_offset - last_offset;
                        /*if (region_offset + local_offset == 2055301)
                            printf("sieve word %u %x region offset %llu local offset % u\n", sieve_index + word, sieve[sieve_index + word], region_offset, local_offset);*/
                        if (chain_in_process)
                        {
                            if (gap > maxGap)
                            {
                                //We reached the end of the chain.  
                                if (current_chain.m_offset_count >= Cuda_sieve::m_min_chain_length)
                                {
                                    //increment the chain list index
                                    uint32_t chain_idx = atomicInc(chain_index, Cuda_sieve::m_max_chains);
                                    //copy the current chain to the global list
                                    chains[chain_idx] = current_chain;
                                    //updated block level stats
                                    atomicInc(&chain_count_shared, 0xFFFFFFFF);
                                }
                                /*if (current_chain.m_base_offset ==  2055301)
                                    printf("close. gap: %u len: %u block: %u segment %u: thread: %u word: %u byte: %u bit: %u offset30: %u local offset: %u\n ",
                                        gap, current_chain.m_offset_count, block_id, segment_id, index, word, byte_index, lowest_set_bit, sieve30_offset, local_offset);*/
                                //start a new chain
                                cuda_chain_open(current_chain, region_offset + local_offset);
                                chain_start = local_offset;
                                last_offset = local_offset;
                            }
                            else
                            {
                                //grow the chain
                                uint16_t offset_from_chain_start = local_offset - chain_start;
                                cuda_chain_push_back(current_chain, offset_from_chain_start);
                                last_offset = local_offset;
                            }
                        }
                        else
                        {
                            //start a new chain
                            cuda_chain_open(current_chain, region_offset + local_offset);
                            last_offset = local_offset;
                            chain_start = local_offset;
                            chain_in_process = true;
                        }
                    }
                }
                //we reached the end of the search region.  do a final check on the chain in process
                if (current_chain.m_offset_count >= Cuda_sieve::m_min_chain_length)
                {
                    //increment the chain list index
                    uint32_t chain_idx = atomicInc(chain_index, Cuda_sieve::m_max_chains);
                    //copy the current chain to the global list
                    chains[chain_idx] = current_chain;
                    //updated block level stats
                    atomicInc(&chain_count_shared, 0xFFFFFFFF);
          
                }
            }
            
            //update global chain stats
            __syncthreads();
            if (threadIdx.x == 0)
            {
                atomicAdd(chain_stat_count, chain_count_shared);
            }
            
        }


        __device__ void medium(uint8_t* sieve120_index_shared, uint8_t* sieve30_gaps_shared, uint64_t start_offset, int segment,
            uint32_t prime_count, uint32_t* sieving_primes, uint32_t* starting_multiples, uint32_t* sieve,
            unsigned int* prime_index, uint32_t* multiples)
        {
            uint32_t block_id = blockIdx.x;
            uint32_t index = threadIdx.x;
            //uint32_t stride = blockDim.x;
            //uint32_t num_threads = blockDim.x;
            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;

            uint8_t wheel_index;
            uint8_t next_wheel_gap;
            uint32_t j;
            uint32_t k;
            uint8_t prime_mod_inv;

            for (uint32_t i = index; i < prime_count; i = atomicInc(prime_index, 0xFFFFFFFF))
            {
                k = sieving_primes[i];

                //get aligned to this region
                if (segment == 0)
                {
                    j = starting_multiples[i];
                    //the first time through we need to calculate the starting offsets
                    if (start_offset > 0)
                    {
                        uint64_t x = start_offset - j;
                        //offset to the first integer multiple of the prime above the starting offset
                        uint32_t m = k - (x % k);
                        //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                        m += (m % 2 == 0) ? k : 0;
                        m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                        m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                        j = m;
                        //this does the same thing as above - it gets the next multiple using prime inverse mod 30 and a lookup table. 
                        //prime_mod_inv = prime_mod30_inverse[k % 30];
                        //j = m + k * next_multiple_mod30_offset[((m % 30) * prime_mod_inv) % 30];
                    }
                    //else
                        //j -= start_offset;
                }
                else
                {
                    j = multiples[block_id * prime_count + i];
                    //calculating the wheel index each time is faster than saving and retrieving it from global memory each loop
                }
                prime_mod_inv = prime_mod30_inverse[k % 30];
                wheel_index = sieve30_index[(prime_mod_inv * j) % 30];
                next_wheel_gap = sieve30_gaps_shared[wheel_index];

                while (j < segment_size)
                {
                    //cross off a multiple of the sieving prime
                    uint32_t sieve_index = j / Cuda_sieve::m_sieve_word_range;

                    Cuda_sieve::sieve_word_t bitmask = ~(static_cast<Cuda_sieve::sieve_word_t>(1) <<
                        sieve120_index_shared[j % Cuda_sieve::m_sieve_word_range]);

                    atomicAnd(&sieve[sieve_index], bitmask);

                    //increment the next multiple of the current prime (rotate the wheel).
                    j += k * next_wheel_gap;
                    wheel_index = (wheel_index + 1) % 8;
                    next_wheel_gap = sieve30_gaps_shared[wheel_index];

                }

                //save the starting multiple for this prime for the next segment
                multiples[block_id * prime_count + i] = j - segment_size;
            }

        }

        __device__ void medium_small(uint8_t* sieve120_index_shared, uint8_t* sieve30_gaps_shared, 
            unsigned int* sieve30_index_shared, unsigned int* prime_mod30_inverse_shared,
            uint64_t start_offset, int segment,
            uint32_t prime_count, uint32_t* sieving_primes, uint32_t* starting_multiples, uint32_t* sieve)
        {
            uint32_t index = threadIdx.x;
            uint32_t stride = blockDim.x;
            unsigned int block_id = blockIdx.x;
            unsigned int warp_id = threadIdx.x / 32;
            unsigned int lane_id = threadIdx.x % 32;
            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;

            uint8_t wheel_index;
            uint8_t next_wheel_gap;
            uint32_t j;
            uint32_t k;
            uint8_t prime_mod_inv;

            for (uint32_t i = warp_id; i < Cuda_sieve::m_medium_small_prime_count; i += stride / 32)
            {
                k = sieving_primes[i];
                j = starting_multiples[i];

                //the first time through we need to calculate the starting offsets
                if (start_offset > 0)
                {
                    uint64_t x = start_offset - j;
                    //offset to the first integer multiple of the prime above the starting offset
                    uint32_t m = k - (x % k);
                    //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                    m += (m % 2 == 0) ? k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    j = m;
                    //this does the same thing as above - it gets the next multiple using prime inverse mod 30 and a lookup table. 
                    //prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                    //j = m + k * next_multiple_mod30_offset_shared[((m % 30) * prime_mod_inv) % 30];
                }
                //else
                //    j -= start_offset;

                prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                unsigned int full_wheels = lane_id / 8;
                wheel_index = sieve30_index_shared[(prime_mod_inv * j) % 30];
                next_wheel_gap = 0;
                j += full_wheels * 30 * k;
                for (auto id = 0; id < lane_id % 8; id++)
                {
                    next_wheel_gap += sieve30_gaps_shared[wheel_index % 8];
                    wheel_index++;
                }
                j += k * next_wheel_gap;

                uint32_t sieve_index = j / Cuda_sieve::m_sieve_word_range;
                Cuda_sieve::sieve_word_t bitmask = ~(static_cast<Cuda_sieve::sieve_word_t>(1) <<
                    sieve120_index_shared[j % Cuda_sieve::m_sieve_word_range]);
                //each lane always crosses off the same spot on the wheel (the same bit in the word)
                while (sieve_index < Cuda_sieve::m_kernel_sieve_size_words)
                {
                    //cross off a multiple of the sieving prime
                    atomicAnd(&sieve[sieve_index], bitmask);

                    //Normally this is where we add the next multiple of the current prime (rotate the wheel).  
                    //j += increment; //we don't need to keep track of the multiple of the prime, only the index of the sieve word.
                    //there are 32 lanes working on a prime.  There are also 32 bits in the sieve word and the mod30 wheel is 8 bits.
                    //Each lane works on multiples of one bit in the wheel.   
                    sieve_index += k; //this looks wierd but it works because each lane works on a multiple of 120 * prime.  

                }

            }

        }

        //multi-stage sieve.  We use a block of shared memory to sieve in segments.  Each sieve reuses the same shared memory.
        //Each block sieves a different range. 
        //the final results are merged with the global sieve at the end using atomicAnd. 
        __global__ void do_sieve(uint64_t sieve_start_offset, uint32_t* medium_sieving_primes, uint32_t* medium_starting_multiples, 
            uint32_t* medium_small_sieving_primes, uint32_t* medium_small_starting_multiples,
            Cuda_sieve::sieve_word_t* sieve_results, uint32_t* multiples)
        {

            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;

            //local shared copy of the sieve
            __shared__ Cuda_sieve::sieve_word_t sieve[Cuda_sieve::m_kernel_sieve_size_words];
            //shared mem lookup tables
            __shared__ uint8_t sieve120_index_shared[120];
            //__shared__  Cuda_sieve::sieve_word_t unset_bit_mask_shared[32];
            //mod 30 wheel
            __shared__ uint8_t sieve30_gaps_shared[8];
            __shared__ unsigned int sieve30_index_shared[30];
            __shared__ unsigned int prime_mod30_inverse_shared[30];
            //__shared__ unsigned int next_multiple_mod30_offset_shared[30];
            //mod 210 wheel
            //__shared__ uint8_t wheel210_gaps_shared[48];
            //__shared__ uint8_t wheel210_index_shared[210];
            //__shared__ uint8_t prime_mod210_inverse_shared[210];
            //__shared__ uint8_t next_multiple_mod210_offset_shared[210];

            __shared__ unsigned int prime_index;
           
           // uint32_t block_id = blockIdx.x;
            uint32_t index = threadIdx.x;
            uint32_t stride = blockDim.x;
            uint32_t num_threads = blockDim.x;
            //unsigned int block_id = blockIdx.x / Cuda_sieve::m_kernel_segments_per_block;
            //unsigned int segment_id = blockIdx.x % Cuda_sieve::m_kernel_segments_per_block;

            //initialize shared lookup tables.  lookup tables in shared memory are faster than global memory lookup tables.
            for (int i = index; i < 120; i += stride)
            {
                sieve120_index_shared[i] = sieve120_index[i];
            }
            /*for (int i = index; i < 32; i += stride)
            {
                unset_bit_mask_shared[i] = unset_bit_mask[i];
            }*/
            for (int i = index; i < 8; i += stride)
            {
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            for (int i = index; i < 30; i += stride)
            {
                sieve30_index_shared[i] = sieve30_index[i];
                prime_mod30_inverse_shared[i] = prime_mod30_inverse[i];
                //next_multiple_mod30_offset_shared[i] = next_multiple_mod30_offset[i];
            }
            //for (int i = index; i < 48; i += stride)
           //{
                //wheel210_gaps_shared[i] = wheel210_gaps[i];
            //}
            //for (int i = index; i < 210; i += stride)
            //{
                //wheel210_index_shared[i] = wheel210_index[i];
                //prime_mod210_inverse_shared[i] = prime_mod210_inverse[i];
                //next_multiple_mod210_offset_shared[i] = next_multiple_mod210_offset[i];
            //}
            
           
            const uint32_t segments = Cuda_sieve::m_kernel_segments_per_block;
            uint32_t sieve_results_index = blockIdx.x * Cuda_sieve::m_kernel_sieve_size_words * segments;
            //each block sieves a different region
            uint64_t start_offset = sieve_start_offset + static_cast<uint64_t>(blockIdx.x) * Cuda_sieve::m_segment_range * segments;
            
            
            for (int s = 0; s < segments; s++)
            {
                //everyone in the block initialize part of the shared sieve
                for (int sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    //sieve[sieve_index] = ~0;
                    sieve[sieve_index] = sieve_results[sieve_results_index + sieve_index];
                }
                if (index == 0)
                {
                    prime_index = num_threads;
                }
                __syncthreads();

                medium_small(sieve120_index_shared, sieve30_gaps_shared, sieve30_index_shared, prime_mod30_inverse_shared,
                    start_offset, s, Cuda_sieve::m_medium_small_prime_count,
                    medium_small_sieving_primes, medium_small_starting_multiples, sieve);

                medium(sieve120_index_shared, sieve30_gaps_shared ,start_offset, s, Cuda_sieve::m_medium_prime_count,
                    medium_sieving_primes, medium_starting_multiples, sieve, &prime_index, multiples);

                
                __syncthreads();
                

                //merge the sieve results back to global memory
                for (uint32_t sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    sieve_results[sieve_results_index + sieve_index] = sieve[sieve_index];
                }
                
                sieve_results_index += Cuda_sieve::m_kernel_sieve_size_words;
                start_offset += segment_size;
            }

        }

        //medium prime sieve.  We use a block of shared memory to sieve in segments.  Each block sieves a different range. 
        //the final results are merged with the global sieve at the end using atomicAnd. 
        __global__ void medium_sieve(uint64_t sieve_start_offset, uint32_t* sieving_primes, uint32_t sieving_prime_count,
            uint32_t* starting_multiples, Cuda_sieve::sieve_word_t* sieve_results, uint32_t* multiples)
        {

            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;

            //local shared copy of the sieve
            __shared__ Cuda_sieve::sieve_word_t sieve[Cuda_sieve::m_kernel_sieve_size_words];
            //shared mem lookup tables
            __shared__ uint8_t sieve120_index_shared[120];
            //__shared__  Cuda_sieve::sieve_word_t unset_bit_mask_shared[32];
            //mod 30 wheel
            __shared__ uint8_t sieve30_gaps_shared[8];
            //__shared__ unsigned int sieve30_index_shared[30];
            //__shared__ unsigned int prime_mod30_inverse_shared[30];
            //__shared__ unsigned int next_multiple_mod30_offset_shared[30];
            //mod 210 wheel
            //__shared__ uint8_t wheel210_gaps_shared[48];
            //__shared__ uint8_t wheel210_index_shared[210];
            //__shared__ uint8_t prime_mod210_inverse_shared[210];
            //__shared__ uint8_t next_multiple_mod210_offset_shared[210];

            __shared__ unsigned int prime_index;

            uint32_t block_id = blockIdx.x;
            uint32_t index = threadIdx.x;
            uint32_t stride = blockDim.x;
            uint32_t num_threads = blockDim.x;
            //unsigned int block_id = blockIdx.x / Cuda_sieve::m_kernel_segments_per_block;
            //unsigned int segment_id = blockIdx.x % Cuda_sieve::m_kernel_segments_per_block;

            //initialize shared lookup tables.  lookup tables in shared memory are faster than global memory lookup tables.
            for (int i = index; i < 120; i += stride)
            {
                sieve120_index_shared[i] = sieve120_index[i];
            }
            /*for (int i = index; i < 32; i += stride)
            {
                unset_bit_mask_shared[i] = unset_bit_mask[i];
            }*/
            for (int i = index; i < 8; i += stride)
            {
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            for (int i = index; i < 30; i += stride)
            {
                //sieve30_index_shared[i] = sieve30_index[i];
                //prime_mod30_inverse_shared[i] = prime_mod30_inverse[i];
                //next_multiple_mod30_offset_shared[i] = next_multiple_mod30_offset[i];
            }
            //for (int i = index; i < 48; i += stride)
           //{
                //wheel210_gaps_shared[i] = wheel210_gaps[i];
            //}
            //for (int i = index; i < 210; i += stride)
            //{
                //wheel210_index_shared[i] = wheel210_index[i];
                //prime_mod210_inverse_shared[i] = prime_mod210_inverse[i];
                //next_multiple_mod210_offset_shared[i] = next_multiple_mod210_offset[i];
            //}


            const uint32_t segments = Cuda_sieve::m_kernel_segments_per_block;
            uint32_t sieve_results_index = blockIdx.x * Cuda_sieve::m_kernel_sieve_size_words * segments;
            //each block sieves a different region
            uint64_t start_offset = sieve_start_offset + static_cast<uint64_t>(blockIdx.x) * Cuda_sieve::m_segment_range * segments;

            uint8_t wheel_index;
            uint8_t next_wheel_gap;
            uint32_t j;
            uint32_t k;
            uint8_t prime_mod_inv;
            for (int s = 0; s < segments; s++)
            {
                //everyone in the block initialize part of the shared sieve
                for (int sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    //sieve[sieve_index] = ~0;
                    sieve[sieve_index] = sieve_results[sieve_results_index + sieve_index];
                }
                if (index == 0)
                {
                    prime_index = num_threads;
                }
                __syncthreads();
                for (uint32_t i = index; i < sieving_prime_count; i = atomicInc(&prime_index, 0xFFFFFFFF))
                {
                    k = sieving_primes[i];

                    //get aligned to this region
                    if (s == 0)
                    {
                        j = starting_multiples[i];
                        //the first time through we need to calculate the starting offsets
                        if (start_offset > 0)
                        {
                            uint64_t x = start_offset - j;
                            //offset to the first integer multiple of the prime above the starting offset
                            uint32_t m = k - (x % k);
                            //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                            m += (m % 2 == 0) ? k : 0;
                            m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                            m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                            j = m;
                            //this does the same thing as above - it gets the next multiple using prime inverse mod 30 and a lookup table. 
                            //prime_mod_inv = prime_mod30_inverse[k % 30];
                            //j = m + k * next_multiple_mod30_offset[((m % 30) * prime_mod_inv) % 30];
                        }
                        //else
                            //j -= start_offset;
                    }
                    else
                    {
                        j = multiples[block_id * sieving_prime_count + i];
                        //calculating the wheel index each time is faster than saving and retrieving it from global memory each loop
                    }
                    prime_mod_inv = prime_mod30_inverse[k % 30];
                    wheel_index = sieve30_index[(prime_mod_inv * j) % 30];
                    next_wheel_gap = sieve30_gaps_shared[wheel_index];

                    while (j < segment_size)
                    {
                        //cross off a multiple of the sieving prime
                        uint32_t sieve_index = j / Cuda_sieve::m_sieve_word_range;

                        Cuda_sieve::sieve_word_t bitmask = ~(static_cast<Cuda_sieve::sieve_word_t>(1) <<
                            sieve120_index_shared[j % Cuda_sieve::m_sieve_word_range]);

                        atomicAnd(&sieve[sieve_index], bitmask);

                        //increment the next multiple of the current prime (rotate the wheel).
                        j += k * next_wheel_gap;
                        wheel_index = (wheel_index + 1) % 8;
                        next_wheel_gap = sieve30_gaps_shared[wheel_index];

                    }

                    //save the starting multiple for this prime for the next segment
                    multiples[block_id * sieving_prime_count + i] = j - segment_size;
                }
                __syncthreads();


                //merge the sieve results back to global memory
                for (uint32_t sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    sieve_results[sieve_results_index + sieve_index] = sieve[sieve_index];
                }

                sieve_results_index += Cuda_sieve::m_kernel_sieve_size_words;
                start_offset += segment_size;
            }

        }

        //This is a sieve optimized for primes in the neighborhood of 100 - 1000.  Primes in this range hit each sieve segment hundreds of times
        //and hit each sieve word no more than once.  Each prime is processed by one full warp which helps minimize thread divergence.  
        // There are enough hits per segment to keep a full warp busy with a single prime.  The sieve is stored in shared memory. 
        // At the end the results are merged with the global sieve. 
        __global__ void medium_small_sieve(uint64_t sieve_start_offset, uint32_t* sieving_primes, 
            uint32_t* starting_multiples, Cuda_sieve::sieve_word_t* sieve_results)
        {
            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;

            //local shared copy of the sieve
            __shared__ Cuda_sieve::sieve_word_t sieve[Cuda_sieve::m_kernel_sieve_size_words];
            //shared mem lookup tables
            __shared__ uint8_t sieve120_index_shared[120];
            __shared__ uint8_t sieve30_gaps_shared[8];
            __shared__ uint8_t sieve30_index_shared[30];
            __shared__ uint8_t prime_mod30_inverse_shared[30];

            uint32_t index = threadIdx.x;
            uint32_t stride = blockDim.x;
            unsigned int block_id = blockIdx.x;
            unsigned int warp_id = threadIdx.x / 32;
            unsigned int lane_id = threadIdx.x % 32;

            //initialize shared lookup tables.  lookup tables in shared memory are faster than global memory lookup tables.
            for (int i = index; i < 120; i += stride)
            {
                sieve120_index_shared[i] = sieve120_index[i];
            }
            for (int i = index; i < 8; i += stride)
            {
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            for (int i = index; i < 30; i += stride)
            {
                sieve30_index_shared[i] = sieve30_index[i];
                prime_mod30_inverse_shared[i] = prime_mod30_inverse[i];
            }

            const uint32_t segments = Cuda_sieve::m_kernel_segments_per_block;
            uint32_t sieve_results_index = block_id * Cuda_sieve::m_kernel_sieve_size_words_per_block;
            uint64_t start_offset = sieve_start_offset +
                static_cast<uint64_t>(block_id) * Cuda_sieve::m_kernel_sieve_size_words_per_block * Cuda_sieve::m_sieve_word_range;
            uint8_t wheel_index;
            unsigned int next_wheel_gap;
            uint32_t j;
            uint32_t k;
            uint32_t prime_mod_inv;
            for (int s = 0; s < segments; s++)
            {
                //everyone in the block initialize part of the shared sieve
                for (unsigned int sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    //sieve[sieve_index] = ~0;
                    sieve[sieve_index] = sieve_results[sieve_results_index + sieve_index];
                }

                __syncthreads();
                for (uint32_t i = warp_id; i < Cuda_sieve::m_medium_small_prime_count; i += stride/32)
                {
                    k = sieving_primes[i];
                    j = starting_multiples[i];

                    //the first time through we need to calculate the starting offsets
                    if (start_offset > 0)
                    {
                        uint64_t x = start_offset - j;
                        //offset to the first integer multiple of the prime above the starting offset
                        uint32_t m = k - (x % k);
                        //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                        m += (m % 2 == 0) ? k : 0;
                        m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                        m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                        j = m;
                        //this does the same thing as above - it gets the next multiple using prime inverse mod 30 and a lookup table. 
                        //prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                        //j = m + k * next_multiple_mod30_offset_shared[((m % 30) * prime_mod_inv) % 30];
                    }
                    //else
                    //    j -= start_offset;
                   
                    prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                    unsigned int full_wheels = lane_id / 8;
                    wheel_index = sieve30_index_shared[(prime_mod_inv * j) % 30];
                    next_wheel_gap = 0;
                    j += full_wheels * 30 * k;
                    for (auto id = 0; id < lane_id % 8; id++)
                    {
                        next_wheel_gap += sieve30_gaps_shared[wheel_index % 8];
                        wheel_index++;
                    }
                    j += k * next_wheel_gap;
                    
                    uint32_t sieve_index = j / Cuda_sieve::m_sieve_word_range;
                    Cuda_sieve::sieve_word_t bitmask = ~(static_cast<Cuda_sieve::sieve_word_t>(1) <<
                        sieve120_index_shared[j % Cuda_sieve::m_sieve_word_range]);
                    //each lane always crosses off the same spot on the wheel (the same bit in the word)
                    while(sieve_index < Cuda_sieve::m_kernel_sieve_size_words)
                    {
                        //cross off a multiple of the sieving prime
                        atomicAnd(&sieve[sieve_index], bitmask);

                        //Normally this is where we add the next multiple of the current prime (rotate the wheel).  
                        //j += increment; //we don't need to keep track of the multiple of the prime, only the index of the sieve word.
                        //there are 32 lanes working on a prime.  There are also 32 bits in the sieve word and the mod30 wheel is 8 bits.
                        //Each lane works on multiples of one bit in the wheel.   
                        sieve_index += k; //this looks wierd but it works because each lane works on a multiple of 120 * prime.  
                       
                    }
                   
                }
                __syncthreads();


                //merge the sieve results back to global memory
                for (uint32_t sieve_index = index; sieve_index < Cuda_sieve::m_kernel_sieve_size_words; sieve_index += stride)
                {
                    sieve_results[sieve_results_index + sieve_index] = sieve[sieve_index];
                }

                sieve_results_index += Cuda_sieve::m_kernel_sieve_size_words;
                start_offset += segment_size;
            }

        }

        //count the prime candidates in the global sieve
        __global__ void count_prime_candidates(Cuda_sieve::sieve_word_t* sieve, unsigned long long* prime_candidate_count)
        {
            uint64_t num_blocks = gridDim.x;
            uint64_t num_threads = blockDim.x;
            uint64_t block_id = blockIdx.x;
            uint64_t index = block_id * num_threads + threadIdx.x;
            uint64_t stride = num_blocks * num_threads;
            
            uint64_t count = 0;
            if (index == 0)
                *prime_candidate_count = 0;
            __syncthreads();

            for (uint64_t i = index; i < Cuda_sieve::m_sieve_total_size; i += stride)
            {
                count += __popcll(sieve[i]);
            }
            atomicAdd(prime_candidate_count, count);

        }

        //go through the list of chains.  copy winners to the long chain list.  copy survivors to a temporary chain
        __global__ void filter_busted_chains(CudaChain* chains, uint32_t* chain_index, CudaChain* surviving_chains,
            uint32_t* surviving_chain_index, CudaChain* long_chains, uint32_t* long_chain_index, uint32_t* histogram)
        {
            uint32_t num_threads = blockDim.x;
            uint32_t block_id = blockIdx.x;
            uint32_t index = block_id * num_threads + threadIdx.x;

            if (index >= *chain_index)
                return;
            if (index == 0)
            {
                *surviving_chain_index = 0;
            }
            __syncthreads();
            //printf("%" PRIu64 " %u\n", index, *chain_index);
            if (!is_there_still_hope(chains[index]))
            {
                //this chain is busted.  check how long it is
                //collect stats
                //only count chains 3 or longer to minimize memory accesses
                if (chains[index].m_prime_count >= 3)
                {
                    int chain_length, local_offset;
                    uint64_t base_offset;
                    get_best_fermat_chain(chains[index], base_offset, local_offset, chain_length);
                    uint32_t histogram_chain_length = min(chain_length, Cuda_sieve::chain_histogram_max);
                    if (chain_length >= 3)
                        atomicInc(&histogram[histogram_chain_length], 0xFFFFFFFF);

                    //check for winners
                    if (chain_length >= chains[index].m_min_chain_report_length)
                    {
                        //chain is long. save it. 
                        uint32_t last_long_chain_index = atomicInc(long_chain_index, Cuda_sieve::m_max_long_chains);
                        long_chains[last_long_chain_index] = chains[index];
                    }
                }
            }
            else
            {
                //copy chain to the survival list
                uint32_t last_surviving_chain_index = atomicInc(surviving_chain_index, Cuda_sieve::m_max_chains);
                surviving_chains[last_surviving_chain_index] = chains[index];
            }
        }

        //sort large primes into buckets by where they hit the sieve
        __global__ void sort_large_primes(uint64_t sieve_start_offset, uint32_t* large_primes, uint32_t sieving_prime_count,
            uint32_t* starting_multiples, uint32_t* large_prime_buckets, uint32_t* bucket_indices)
        {
            int num_threads = blockDim.x;
            int block_id = blockIdx.x;
            int index = threadIdx.x;
            int stride = num_threads;
            
            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;
            const uint32_t segments = Cuda_sieve::m_kernel_segments_per_block * Cuda_sieve::m_num_blocks / gridDim.x;
            const uint32_t block_range = segments * segment_size;

            //each block sieves a different region
            uint64_t start_offset = sieve_start_offset + static_cast<uint64_t>(block_id) * block_range;

            //shared mem lookup tables
            __shared__ uint8_t sieve30_gaps_shared[8];
            __shared__ uint8_t sieve30_index_shared[30];
            __shared__ uint8_t prime_mod30_inverse_shared[30];
            __shared__ uint32_t sieve120_index_shared[120];
            __shared__ unsigned int prime_index;

            //shared copy of bucket index array
            //this local array could be smaller than the global array
            __shared__ uint32_t bucket_indices_shared[Cuda_sieve::m_kernel_segments_per_block * Cuda_sieve::m_num_blocks];
            uint32_t bucket_index = 0;

            //initialize shared lookup tables.  lookup tables in shared memory are faster than global memory lookup tables.
            for (int i = index; i < 8; i += stride)
            {
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            for (int i = index; i < 30; i += stride)
            {
                sieve30_index_shared[i] = sieve30_index[i];
                prime_mod30_inverse_shared[i] = prime_mod30_inverse[i];
            }
            for (int i = index; i < 120; i += stride)
            {
                sieve120_index_shared[i] = sieve120_index[i];
            }

            //reset the bucket indices
            for (int i = index; i < segments; i += stride)
            {
                bucket_indices_shared[block_id* segments + i] = 0;
            }
            if (index == 0)
            {
                prime_index = num_threads;
            }
            __syncthreads();
            //iterate through the list of primes
            for (uint32_t i = index; i < sieving_prime_count; i = atomicInc(&prime_index, 0xFFFFFFFF))
            //for (uint32_t i = index; i < Cuda_sieve::m_large_prime_count; i += stride)
            {
                uint32_t k = large_primes[i];
                uint32_t j = starting_multiples[i];

                //calculate the starting offsets for this block
                if (start_offset >= j)
                {
                    uint64_t x = start_offset - j;
                    //offset to the first integer multiple of the prime above the starting offset
                    uint32_t m = k - (x % k);
                    //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                    m += (m % 2 == 0) ? k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    j = m;
                }
                else
                    j -= start_offset;
                
                uint8_t prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                uint8_t wheel_index = sieve30_index_shared[(prime_mod_inv * j) % 30];
                uint8_t next_wheel_gap = sieve30_gaps_shared[wheel_index];
                uint32_t next_segment = j / segment_size;
                uint32_t segment_offset = j % segment_size;
               // uint32_t loop_count = 0;
                while (next_segment < segments)
                {
                    //which word within the segment does the prime hit
                    uint32_t sieve_word = segment_offset / Cuda_sieve::m_sieve_word_range;
                    //which bit within the word does the prime hit
                    uint32_t sieve_bit = sieve120_index_shared[segment_offset % Cuda_sieve::m_sieve_word_range];
                    //pack the word index and bit into one 32 bit word
                    uint32_t sieve_segment_hit = (sieve_word << 16) | sieve_bit;
                    //add the sieve hit to the segment's bucket
                    bucket_index = atomicInc(&bucket_indices_shared[block_id * segments + next_segment], 0xFFFFFFFF);
                    //we are indexing a 1D array as if it were a 3D array. 
                    uint32_t z = block_id;
                    uint32_t y = next_segment;
                    uint32_t x = bucket_index;
                    const uint32_t ymax = segments;
                    const uint32_t xmax = Cuda_sieve::m_large_prime_bucket_size;
                    large_prime_buckets[z*xmax*ymax + y*xmax + x] = sieve_segment_hit;
                   
                    //increment the next multiple of the current prime (rotate the wheel).
                    j += k * next_wheel_gap;
                    wheel_index = (wheel_index + 1) % 8;
                    next_wheel_gap = sieve30_gaps_shared[wheel_index];
                    next_segment = j / segment_size;
                    segment_offset = j % segment_size;
                    //loop_count++;
                }
                //if (threadIdx.x == 0)
                //    printf("%u %u\n", k, loop_count);
            }
            __syncthreads();
            //copy bucket indices to global memory
            for (int i = index; i < segments; i += stride)
            {
                bucket_indices[block_id * segments + i] = bucket_indices_shared[block_id * segments + i];
            }

        }

        //sort large primes into buckets by where they hit the sieve.  one warp per prime. 
        __global__ void sort_large_primes_warp(uint64_t sieve_start_offset, uint32_t* primes, uint32_t sieving_prime_count,
            uint32_t* starting_multiples, uint32_t* large_prime_buckets, uint32_t* bucket_indices)
        {
            unsigned int num_threads = blockDim.x;
            unsigned int block_id = blockIdx.x;
            unsigned int index = threadIdx.x;
            unsigned int stride = num_threads;
            unsigned int warp_id = threadIdx.x / 32;
            unsigned int lane_id = threadIdx.x % 32;

            const uint32_t segment_size = Cuda_sieve::m_kernel_sieve_size_bytes * Cuda_sieve::m_sieve_byte_range;
            const uint32_t segments = Cuda_sieve::m_kernel_segments_per_block * Cuda_sieve::m_num_blocks / gridDim.x;
            const uint32_t block_range = segments * segment_size;

            //each block sieves a different region
            uint64_t start_offset = sieve_start_offset + static_cast<uint64_t>(block_id) * block_range;

            //shared mem lookup tables
            __shared__ unsigned int sieve30_gaps_shared[8];
            __shared__ unsigned int sieve30_index_shared[30];
            __shared__ unsigned int prime_mod30_inverse_shared[30];
            __shared__ unsigned int sieve120_index_shared[120];
            //__shared__ unsigned int prime_index;
            uint32_t bucket_index = 0;

            //initialize shared lookup tables.  lookup tables in shared memory are faster than global memory lookup tables.
            for (int i = index; i < 8; i += stride)
            {
                sieve30_gaps_shared[i] = sieve30_gaps[i];
            }
            for (int i = index; i < 30; i += stride)
            {
                sieve30_index_shared[i] = sieve30_index[i];
                prime_mod30_inverse_shared[i] = prime_mod30_inverse[i];
            }
            for (int i = index; i < 120; i += stride)
            {
                sieve120_index_shared[i] = sieve120_index[i];
            }

            //reset the bucket indices
            for (int i = index; i < segments; i += stride)
            {
                bucket_indices[block_id * segments + i] = 0;
            }
            /*if (index == 0)
            {
                prime_index = num_threads;
            }*/
            __syncthreads();
            //iterate through the list of primes
            for (uint32_t i = warp_id; i < sieving_prime_count; i += stride/32)
            //for (uint32_t i = index; i < sieving_prime_count; i = atomicInc(&prime_index, 0xFFFFFFFF))
                //for (uint32_t i = index; i < Cuda_sieve::m_large_prime_count; i += stride)
            {
                uint32_t k = primes[i];
                uint64_t j = starting_multiples[i];

                //calculate the starting offsets for this block
                if (start_offset >= j)
                {
                    uint64_t x = start_offset - j;
                    //offset to the first integer multiple of the prime above the starting offset
                    uint32_t m = k - (x % k);
                    //find the next integer multiple of the prime that is not divisible by 2,3 or 5
                    m += (m % 2 == 0) ? k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    m += (m % 3 == 0 || m % 5 == 0) ? 2 * k : 0;
                    j = m;
                }
                else
                    j -= start_offset;


                uint32_t prime_mod_inv = prime_mod30_inverse_shared[k % 30];
                unsigned int full_wheels = lane_id / 8;
                uint8_t wheel_index = sieve30_index_shared[(prime_mod_inv * j) % 30];
                unsigned int next_wheel_gap = 0;
                j += full_wheels * 30 * k;
                for (auto id = 0; id < lane_id % 8; id++)
                {
                    next_wheel_gap += sieve30_gaps_shared[wheel_index % 8];
                    wheel_index++;
                }
                j += k * next_wheel_gap;

                uint32_t next_segment = j / segment_size;
                uint32_t segment_offset = j % segment_size;
               
                //each lane always crosses off the same spot on the wheel (the same bit in the word)
                uint32_t sieve_bit = sieve120_index_shared[segment_offset % Cuda_sieve::m_sieve_word_range];
                uint64_t increment = k * 120ull;

                while (next_segment < segments)
                {
                    uint32_t sieve_word = segment_offset / Cuda_sieve::m_sieve_word_range;
                    //pack the word index and bit into one 32 bit word
                    uint32_t sieve_segment_hit = (sieve_word << 16) | sieve_bit;
                    //add the sieve hit to the segment's bucket
                    bucket_index = atomicInc(&bucket_indices[block_id * segments + next_segment], 0xFFFFFFFF);
                    //we are indexing a 1D array as if it were a 3D array. 
                    uint32_t z = block_id;
                    uint32_t y = next_segment;
                    uint32_t x = bucket_index;
                    const uint32_t ymax = segments;
                    const uint32_t xmax = Cuda_sieve::m_large_prime_bucket_size;
                    large_prime_buckets[z * xmax * ymax + y * xmax + x] = sieve_segment_hit;

                    j += increment;
                    next_segment = j / segment_size;
                    segment_offset = j % segment_size;

                }

            }

        }

        void Cuda_sieve_impl::run_large_prime_sieve(uint64_t sieve_start_offset)
        {

            int threads = 1024;
            //one kernel block per sieve block
            int blocks = Cuda_sieve::m_num_blocks ;

            int split_denominator = 4;
            int split_numerator = split_denominator - 1;
            sort_large_primes << <blocks, threads >> > (sieve_start_offset, d_large_primes, Cuda_sieve::m_large_prime_count/ split_denominator,
                d_large_prime_starting_multiples, d_large_prime_buckets, d_bucket_indices);

            //one kernel block per sieve segment
            blocks = Cuda_sieve::m_num_blocks * Cuda_sieve::m_kernel_segments_per_block;
            threads = 1024;
            sieveLargePrimes << <blocks, threads >> > (d_large_prime_buckets, d_bucket_indices, d_sieve);

            blocks = Cuda_sieve::m_num_blocks / 2;

            sort_large_primes << <blocks, threads >> > (sieve_start_offset, d_large_primes+ Cuda_sieve::m_large_prime_count / split_denominator,
                split_numerator *Cuda_sieve::m_large_prime_count/ split_denominator,
                d_large_prime_starting_multiples + Cuda_sieve::m_large_prime_count / split_denominator, d_large_prime_buckets, d_bucket_indices);

            //one kernel block per sieve segment
            blocks = Cuda_sieve::m_num_blocks * Cuda_sieve::m_kernel_segments_per_block;
            threads = 1024;
            sieveLargePrimes << <blocks, threads >> > (d_large_prime_buckets, d_bucket_indices, d_sieve);


        }

        void Cuda_sieve_impl::run_small_prime_sieve(uint64_t sieve_start_offset)
        {
            const int threads = 256;
            const int loops_per_block = 32;
            const int blocks = (Cuda_sieve::m_sieve_total_size/loops_per_block + threads - 1)/threads;
            
            sieveSmallPrimes << <blocks, threads >> > (d_sieve, sieve_start_offset, d_small_prime_offsets, d_small_prime_masks, d_small_primes);

        }

        //experimental combo medium small plus medium sieve in one kernel
        void Cuda_sieve_impl::run_sieve(uint64_t sieve_start_offset)
        {
            int blocks = Cuda_sieve::m_num_blocks;// * Cuda_sieve::m_kernel_segments_per_block;
            int threads = 1024;
            m_sieve_start_offset = sieve_start_offset;

            //medium_sieve << <blocks, threads >> > (sieve_start_offset, d_sieving_primes, m_sieving_prime_count,
            //    d_starting_multiples, d_sieve, d_multiples);


            do_sieve <<<blocks, threads >>> (sieve_start_offset, d_sieving_primes, d_starting_multiples, 
                d_medium_small_primes, d_medium_small_prime_starting_multiples, d_sieve, d_multiples);

        }

        void Cuda_sieve_impl::run_medium_small_prime_sieve(uint64_t sieve_start_offset)
        {

           medium_small_sieve << <Cuda_sieve::m_num_blocks, Cuda_sieve::m_threads_per_block >> > 
               (sieve_start_offset, d_medium_small_primes, d_medium_small_prime_starting_multiples, d_sieve);

          

        }

        void Cuda_sieve_impl::get_sieve(Cuda_sieve::sieve_word_t sieve[])
        {
            checkCudaErrors(cudaMemcpy(sieve, d_sieve, Cuda_sieve::m_sieve_total_size * sizeof(*d_sieve), cudaMemcpyDeviceToHost));

        }

        void Cuda_sieve_impl::get_prime_candidate_count(uint64_t& prime_candidate_count)
        {
            const int threads = 256;
            const int blocks = 1; // (Cuda_sieve::m_sieve_total_size + threads - 1) / threads;
            count_prime_candidates << <blocks, threads >> > (d_sieve, d_prime_candidate_count);
            checkCudaErrors(cudaDeviceSynchronize());
            
            checkCudaErrors(cudaMemcpy(&prime_candidate_count, d_prime_candidate_count, sizeof(*d_prime_candidate_count), cudaMemcpyDeviceToHost));

        }

        void Cuda_sieve_impl::find_chains()
        {
            //const int sieve_threads = 64;
            //const int checks_per_block = 64;
            //const uint32_t sieve_bits_per_word = Cuda_sieve::m_sieve_word_byte_count * 8;
            //const uint64_t sieve_total_bits = Cuda_sieve::m_sieve_total_size * sieve_bits_per_word;
            //const int sieve_blocks = (sieve_total_bits /checks_per_block + sieve_threads - 1)/ sieve_threads;
            //find_chain_kernel << <sieve_blocks, sieve_threads >> > (d_sieve, d_chains, d_last_chain_index, m_sieve_start_offset, d_chain_stat_count);

            const int blocks = Cuda_sieve::m_num_blocks * Cuda_sieve::m_kernel_segments_per_block;
            const int search_regions_per_thread = 1;
            const unsigned int search_range = Cuda_sieve::m_sieve_chain_search_boundary * Cuda_sieve::m_sieve_word_byte_count;
            const unsigned int search_regions_per_segment = (Cuda_sieve::m_segment_range + search_range - 1) / search_range;
            const unsigned int threads = round_up((search_regions_per_segment + search_regions_per_thread - 1) / search_regions_per_thread,32);
            find_chain_kernel2 << <blocks, threads >> > (d_sieve, d_chains, d_last_chain_index, m_sieve_start_offset, d_chain_stat_count);
            
        }

        void Cuda_sieve_impl::get_chains(CudaChain chains[], uint32_t& chain_count)
        {
            checkCudaErrors(cudaMemcpy(&chain_count, d_last_chain_index, sizeof(*d_last_chain_index), cudaMemcpyDeviceToHost));
            checkCudaErrors(cudaMemcpy(chains, d_chains, chain_count * sizeof(*d_chains), cudaMemcpyDeviceToHost));
        }

        void Cuda_sieve_impl::get_chain_count(uint32_t& chain_count)
        {
            checkCudaErrors(cudaMemcpy(&chain_count, d_last_chain_index, sizeof(*d_last_chain_index), cudaMemcpyDeviceToHost));
        }

        //get a pointer to the chain array.  fermat test uses the chain array as input. 
        void Cuda_sieve_impl::get_chain_pointer(CudaChain*& chains_ptr, uint32_t*& chain_count_ptr)
        {
            chains_ptr = d_chains;
            chain_count_ptr = d_last_chain_index;
        }

        //check the list of chains for winners.  save winners and remove losers
        void Cuda_sieve_impl::clean_chains()
        {
            const int threads = 256;
            uint32_t chain_count;
            get_chain_count(chain_count);
            int blocks = (chain_count + threads - 1) / threads;
            //copy surviving chains to a temporary location. 
            filter_busted_chains << <blocks, threads >> > (d_chains, d_last_chain_index, d_good_chains, d_good_chain_index,
                d_long_chains, d_last_long_chain_index, d_chain_histogram);
            uint32_t good_chain_count;
            //get the count of good chains from device memory
            checkCudaErrors(cudaMemcpy(&good_chain_count, d_good_chain_index, sizeof(*d_good_chain_index), cudaMemcpyDeviceToHost));
            //copy the temporary good chain list back to the chain list
            checkCudaErrors(cudaMemcpyAsync(d_chains, d_good_chains, good_chain_count*sizeof(*d_chains), cudaMemcpyDeviceToDevice));
            //update the chain count
            checkCudaErrors(cudaMemcpy(d_last_chain_index, d_good_chain_index, sizeof(*d_last_chain_index), cudaMemcpyDeviceToDevice));

        }

        void Cuda_sieve_impl::get_long_chains(CudaChain chains[], uint32_t& chain_count)
        {
            checkCudaErrors(cudaMemcpy(&chain_count, d_last_long_chain_index, sizeof(*d_last_long_chain_index), cudaMemcpyDeviceToHost));
            if (chain_count > 0)
            {
                checkCudaErrors(cudaMemcpy(chains, d_long_chains, chain_count * sizeof(*d_long_chains), cudaMemcpyDeviceToHost));
                //clear the long chain list
                checkCudaErrors(cudaMemset(d_last_long_chain_index, 0, sizeof(*d_last_long_chain_index)));
            }
        }

        //read the histogram
        void Cuda_sieve_impl::get_stats(uint32_t chain_histogram[], uint64_t& chain_count)
        {
            checkCudaErrors(cudaMemcpy(chain_histogram, d_chain_histogram, (Cuda_sieve::chain_histogram_max+1) * sizeof(*d_chain_histogram), cudaMemcpyDeviceToHost));
            checkCudaErrors(cudaMemcpy(&chain_count, d_chain_stat_count, sizeof(*d_chain_stat_count), cudaMemcpyDeviceToHost));

        }

        void Cuda_sieve_impl::synchronize()
        {
            checkCudaErrors(cudaDeviceSynchronize());
        }

        //allocate global memory and load values used by the sieve to the gpu 
        void Cuda_sieve_impl::load_sieve(uint32_t primes[], uint32_t prime_count, uint32_t large_primes[], uint32_t medium_small_primes[], 
            uint32_t small_prime_masks[], uint32_t small_prime_mask_count, uint8_t small_primes[], uint32_t sieve_size, uint16_t device)
        {
          
            m_sieving_prime_count = prime_count;
            m_device = device;
            checkCudaErrors(cudaSetDevice(device));
            //allocate memory on the gpu
            checkCudaErrors(cudaMalloc(&d_sieving_primes, prime_count * sizeof(*d_sieving_primes)));
            checkCudaErrors(cudaMalloc(&d_starting_multiples, prime_count * sizeof(*d_starting_multiples)));
            //checkCudaErrors(cudaMalloc(&d_medium_primes, prime_count * sizeof(*d_medium_primes)));

            checkCudaErrors(cudaMalloc(&d_small_prime_offsets, Cuda_sieve::m_small_prime_count * sizeof(*d_small_prime_offsets)));
            checkCudaErrors(cudaMalloc(&d_medium_small_primes, Cuda_sieve::m_medium_small_prime_count * sizeof(*d_medium_small_primes)));
            checkCudaErrors(cudaMalloc(&d_medium_small_prime_starting_multiples, 
                Cuda_sieve::m_medium_small_prime_count * sizeof(*d_medium_small_prime_starting_multiples)));
            checkCudaErrors(cudaMalloc(&d_small_prime_masks, small_prime_mask_count * sizeof(*d_small_prime_masks)));
            checkCudaErrors(cudaMalloc(&d_small_primes, Cuda_sieve::m_small_prime_count * sizeof(*d_small_primes)));
            checkCudaErrors(cudaMalloc(&d_large_primes, Cuda_sieve::m_large_prime_count * sizeof(*d_large_primes)));
            checkCudaErrors(cudaMalloc(&d_large_prime_starting_multiples, Cuda_sieve::m_large_prime_count * sizeof(*d_large_prime_starting_multiples)));
            checkCudaErrors(cudaMalloc(&d_large_prime_buckets, Cuda_sieve::m_num_blocks * Cuda_sieve::m_kernel_segments_per_block
                * Cuda_sieve::m_large_prime_bucket_size * sizeof(*d_large_prime_buckets)));
            checkCudaErrors(cudaMalloc(&d_bucket_indices, Cuda_sieve::m_num_blocks * Cuda_sieve::m_kernel_segments_per_block * sizeof(*d_bucket_indices)));
            checkCudaErrors(cudaMalloc(&d_sieve, sieve_size * sizeof(*d_sieve)));
            checkCudaErrors(cudaMalloc(&d_multiples, prime_count * Cuda_sieve::m_num_blocks * sizeof(*d_multiples)));
            checkCudaErrors(cudaMalloc(&d_chains, Cuda_sieve::m_max_chains * sizeof(*d_chains)));
            checkCudaErrors(cudaMalloc(&d_long_chains, Cuda_sieve::m_max_long_chains * sizeof(*d_long_chains)));
            checkCudaErrors(cudaMalloc(&d_last_chain_index, sizeof(*d_last_chain_index)));
            checkCudaErrors(cudaMalloc(&d_last_long_chain_index, sizeof(*d_last_long_chain_index)));
            checkCudaErrors(cudaMalloc(&d_prime_candidate_count, sizeof(*d_prime_candidate_count)));
            checkCudaErrors(cudaMalloc(&d_good_chain_index, sizeof(*d_good_chain_index)));
            checkCudaErrors(cudaMalloc(&d_good_chains, Cuda_sieve::m_max_chains/2 * sizeof(*d_good_chains)));
            checkCudaErrors(cudaMalloc(&d_chain_histogram, (Cuda_sieve::chain_histogram_max + 1) * sizeof(*d_chain_histogram)));
            checkCudaErrors(cudaMalloc(&d_chain_stat_count, sizeof(*d_chain_stat_count)));

            //copy data to the gpu
            checkCudaErrors(cudaMemcpy(d_small_primes, small_primes, Cuda_sieve::m_small_prime_count * sizeof(*d_small_primes), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemcpy(d_small_prime_masks, small_prime_masks, small_prime_mask_count * sizeof(*d_small_prime_masks), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemcpy(d_sieving_primes, primes, prime_count * sizeof(*d_sieving_primes), cudaMemcpyHostToDevice));

            checkCudaErrors(cudaMemcpy(d_large_primes, large_primes, Cuda_sieve::m_large_prime_count * sizeof(*d_large_primes), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemcpy(d_medium_small_primes, medium_small_primes,
                Cuda_sieve::m_medium_small_prime_count * sizeof(*d_medium_small_primes), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemset(d_last_chain_index, 0, sizeof(*d_last_chain_index)));
            checkCudaErrors(cudaMemset(d_prime_candidate_count, 0, sizeof(*d_prime_candidate_count)));
            checkCudaErrors(cudaMemset(d_last_long_chain_index, 0, sizeof(*d_last_long_chain_index)));
            checkCudaErrors(cudaMemset(d_chain_stat_count, 0, sizeof(*d_chain_stat_count)));
            reset_stats();

        }

        //reset sieve with new starting offsets
        void Cuda_sieve_impl::init_sieve(uint32_t starting_multiples[], uint16_t small_prime_offsets[], uint32_t large_prime_multiples[],
            uint32_t medium_small_prime_multiples[])
        {
            checkCudaErrors(cudaSetDevice(m_device));
            checkCudaErrors(cudaMemcpy(d_starting_multiples, starting_multiples, m_sieving_prime_count * sizeof(*d_starting_multiples), cudaMemcpyHostToDevice));
            //checkCudaErrors(cudaMemcpy(d_medium_primes, starting_multiples, m_sieving_prime_count * sizeof(*d_medium_primes), cudaMemcpyHostToDevice));

            checkCudaErrors(cudaMemcpy(d_large_prime_starting_multiples, large_prime_multiples, Cuda_sieve::m_large_prime_count * sizeof(*d_large_prime_starting_multiples), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemcpy(d_small_prime_offsets, small_prime_offsets, Cuda_sieve::m_small_prime_count * sizeof(*d_small_prime_offsets), cudaMemcpyHostToDevice));
            checkCudaErrors(cudaMemset(d_last_chain_index, 0, sizeof(*d_last_chain_index)));
            checkCudaErrors(cudaMemset(d_prime_candidate_count, 0, sizeof(*d_prime_candidate_count)));
            checkCudaErrors(cudaMemset(d_last_long_chain_index, 0, sizeof(*d_last_long_chain_index)));
            checkCudaErrors(cudaMemcpy(d_medium_small_prime_starting_multiples, medium_small_prime_multiples,
                Cuda_sieve::m_medium_small_prime_count * sizeof(*d_medium_small_prime_starting_multiples), cudaMemcpyHostToDevice));
        }

        void Cuda_sieve_impl::reset_stats()
        {
            checkCudaErrors(cudaMemset(d_chain_histogram, 0, (Cuda_sieve::chain_histogram_max + 1) * sizeof(*d_chain_histogram)));
            checkCudaErrors(cudaMemset(d_chain_stat_count, 0, sizeof(*d_chain_stat_count)));

        }

        void Cuda_sieve_impl::free_sieve()
        {
            checkCudaErrors(cudaSetDevice(m_device));
            checkCudaErrors(cudaFree(d_sieving_primes));
            checkCudaErrors(cudaFree(d_large_primes));
            checkCudaErrors(cudaFree(d_starting_multiples));
            //checkCudaErrors(cudaFree(d_medium_primes));
            checkCudaErrors(cudaFree(d_multiples));
            checkCudaErrors(cudaFree(d_sieve));
            checkCudaErrors(cudaFree(d_chains));
            checkCudaErrors(cudaFree(d_last_chain_index));
            checkCudaErrors(cudaFree(d_long_chains));
            checkCudaErrors(cudaFree(d_last_long_chain_index));
            checkCudaErrors(cudaFree(d_good_chains));
            checkCudaErrors(cudaFree(d_good_chain_index));
            checkCudaErrors(cudaFree(d_chain_histogram));
            checkCudaErrors(cudaFree(d_large_prime_buckets));
            checkCudaErrors(cudaFree(d_bucket_indices));
            checkCudaErrors(cudaFree(d_medium_small_primes));
            checkCudaErrors(cudaFree(d_medium_small_prime_starting_multiples));
            checkCudaErrors(cudaFree(d_small_primes));
            checkCudaErrors(cudaFree(d_small_prime_masks));



        }
    }
}
