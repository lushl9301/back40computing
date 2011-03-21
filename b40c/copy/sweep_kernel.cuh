/******************************************************************************
 * 
 * Copyright 2010-2011 Duane Merrill
 * 
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 * 
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License. 
 * 
 * For more information, see our Google Code project site: 
 * http://code.google.com/p/back40computing/
 * 
 ******************************************************************************/

/******************************************************************************
 * Copy kernel
 ******************************************************************************/

#pragma once

#include <b40c/util/device_intrinsics.cuh>
#include <b40c/util/cta_work_distribution.cuh>
#include <b40c/util/cta_work_progress.cuh>
#include <b40c/copy/sweep_cta.cuh>

namespace b40c {
namespace copy {

/**
 * Copy pass (non-workstealing)
 */
template <typename KernelConfig, bool WORK_STEALING>
struct SweepPass
{
	static __device__ __forceinline__ void Invoke(
		typename KernelConfig::T 									*&d_in,
		typename KernelConfig::T 									*&d_out,
		util::CtaWorkDistribution<typename KernelConfig::SizeT> 	&work_decomposition,
		const util::WorkProgress 									&work_progress,
		const int 													&extra_bytes)
	{
		typedef SweepCta<KernelConfig> SweepCta;
		typedef typename KernelConfig::T T;
		typedef typename KernelConfig::SizeT SizeT;

		// CTA processing abstraction
		SweepCta cta(d_in, d_out);

		// Determine our threadblock's work range
		SizeT cta_offset;			// Offset at which this CTA begins processing
		SizeT cta_elements;			// Total number of elements for this CTA to process
		SizeT guarded_offset; 		// Offset of final, partially-full tile (requires guarded loads)
		SizeT guarded_elements;		// Number of elements in partially-full tile

		work_decomposition.GetCtaWorkLimits<KernelConfig::LOG_TILE_ELEMENTS, KernelConfig::LOG_SCHEDULE_GRANULARITY>(
			cta_offset, cta_elements, guarded_offset, guarded_elements);

		SizeT out_of_bounds = cta_offset + cta_elements;

		// Process full tiles of tile_elements
		while (cta_offset < guarded_offset) {

			cta.ProcessTile<true>(cta_offset, out_of_bounds);
			cta_offset += KernelConfig::TILE_ELEMENTS;
		}

		// Clean up last partial tile with guarded-io
		if (guarded_elements) {
			cta.ProcessTile<false>(cta_offset, out_of_bounds);
		}

		// Cleanup any extra bytes
		if ((sizeof(typename KernelConfig::T) > 1) && (blockIdx.x == gridDim.x - 1) && (threadIdx.x < extra_bytes)) {

			unsigned char* d_in_bytes = reinterpret_cast<unsigned char *>(d_in + out_of_bounds);
			unsigned char* d_out_bytes = reinterpret_cast<unsigned char *>(d_out + out_of_bounds);
			unsigned char extra_byte;

			util::io::ModifiedLoad<KernelConfig::READ_MODIFIER>::Ld(extra_byte, d_in_bytes + threadIdx.x);
			util::io::ModifiedStore<KernelConfig::WRITE_MODIFIER>::St(extra_byte, d_out_bytes + threadIdx.x);
		}

	}
};


/**
 * Copy pass (workstealing)
 */
template <typename KernelConfig>
struct SweepPass <KernelConfig, true>
{
	static __device__ __forceinline__ void Invoke(
		typename KernelConfig::T 									*&d_in,
		typename KernelConfig::T 									*&d_out,
		util::CtaWorkDistribution<typename KernelConfig::SizeT> 	&work_decomposition,
		const util::WorkProgress 									&work_progress,
		const int 													&extra_bytes)
	{
		typedef SweepCta<KernelConfig> SweepCta;
		typedef typename KernelConfig::T T;
		typedef typename KernelConfig::SizeT SizeT;

		// CTA processing abstraction
		SweepCta cta(d_in, d_out);

		// The offset at which this CTA performs tile processing
		__shared__ SizeT cta_offset;

		// First CTA resets the work progress for the next pass
		if ((blockIdx.x == 0) && (threadIdx.x == 0)) {
			work_progress.PrepareNext();
		}

		// Steal full-tiles of work, incrementing progress counter
		SizeT unguarded_elements = work_decomposition.num_elements & (~(KernelConfig::TILE_ELEMENTS - 1));
		while (true) {

			// Thread zero atomically steals work from the progress counter
			if (threadIdx.x == 0) {
				cta_offset = work_progress.Steal<KernelConfig::TILE_ELEMENTS>();
			}

			__syncthreads();		// Protect cta_offset

			if (cta_offset >= unguarded_elements) {
				// All done
				break;
			}

			cta.ProcessTile<true>(cta_offset, unguarded_elements);
		}

		// Last CTA does any extra, guarded work
		if (blockIdx.x == gridDim.x - 1) {

			cta.ProcessTile<false>(unguarded_elements, work_decomposition.num_elements);

			// Cleanup any extra bytes
			if ((sizeof(typename KernelConfig::T) > 1) && (threadIdx.x < extra_bytes)) {

				unsigned char* d_in_bytes = reinterpret_cast<unsigned char *>(d_in + work_decomposition.num_elements);
				unsigned char* d_out_bytes = reinterpret_cast<unsigned char *>(d_out + work_decomposition.num_elements);
				unsigned char extra_byte;

				util::io::ModifiedLoad<KernelConfig::READ_MODIFIER>::Ld(extra_byte, d_in_bytes + threadIdx.x);
				util::io::ModifiedStore<KernelConfig::WRITE_MODIFIER>::St(extra_byte, d_out_bytes + threadIdx.x);
			}
		}
	}
};


/******************************************************************************
 *  Copy Kernel Entrypoint
 ******************************************************************************/

/**
 *  Copy kernel entry point
 */
template <typename KernelConfig>
__launch_bounds__ (KernelConfig::THREADS, KernelConfig::CTA_OCCUPANCY)
__global__
void SweepKernel(
	typename KernelConfig::T 									*d_in,
	typename KernelConfig::T 									*d_out,
	util::CtaWorkDistribution<typename KernelConfig::SizeT> 	work_decomposition,
	util::WorkProgress 											work_progress,
	int 														extra_bytes)
{
	SweepPass<KernelConfig, KernelConfig::WORK_STEALING>::Invoke(
		d_in,
		d_out,
		work_decomposition,
		work_progress,
		extra_bytes);
}


} // namespace copy
} // namespace b40c

