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
 * "Metatype" for guiding BFS expansion granularity configuration
 ******************************************************************************/

#pragma once

#include <b40c/util/basic_utils.cuh>
#include <b40c/util/cuda_properties.cuh>
#include <b40c/util/cta_work_distribution.cuh>
#include <b40c/util/srts_grid.cuh>
#include <b40c/util/srts_details.cuh>
#include <b40c/util/io/modified_load.cuh>
#include <b40c/util/io/modified_store.cuh>

namespace b40c {
namespace bfs {
namespace expand_atomic {

/**
 * BFS atomic expansion kernel granularity configuration meta-type.  Parameterizations of this
 * type encapsulate our kernel-tuning parameters (i.e., they are reflected via
 * the static fields).
 *
 * Kernels can be specialized for problem-type, SM-version, etc. by parameterizing
 * them with different performance-tuned parameterizations of this type.  By
 * incorporating this type into the kernel code itself, we guide the compiler in
 * expanding/unrolling the kernel code for specific architectures and problem
 * types.
 */
template <
	// ProblemType type parameters
	typename _ProblemType,

	// Machine parameters
	int CUDA_ARCH,

	// Tunable parameters
	int _MAX_CTA_OCCUPANCY,
	int _LOG_THREADS,
	int _LOG_LOAD_VEC_SIZE,
	int _LOG_LOADS_PER_TILE,
	int _LOG_RAKING_THREADS,
	util::io::ld::CacheModifier _QUEUE_READ_MODIFIER,
	util::io::ld::CacheModifier _COLUMN_READ_MODIFIER,
	util::io::ld::CacheModifier _ROW_OFFSET_ALIGNED_READ_MODIFIER,
	util::io::ld::CacheModifier _ROW_OFFSET_UNALIGNED_READ_MODIFIER,
	util::io::st::CacheModifier _QUEUE_WRITE_MODIFIER,
	bool _WORK_STEALING,
	int _LOG_SCHEDULE_GRANULARITY>

struct SweepKernelConfig : _ProblemType
{
	typedef _ProblemType 					ProblemType;
	typedef typename ProblemType::SizeT 	SizeT;

	static const util::io::ld::CacheModifier QUEUE_READ_MODIFIER 					= _QUEUE_READ_MODIFIER;
	static const util::io::ld::CacheModifier COLUMN_READ_MODIFIER 					= _COLUMN_READ_MODIFIER;
	static const util::io::ld::CacheModifier ROW_OFFSET_ALIGNED_READ_MODIFIER 		= _ROW_OFFSET_ALIGNED_READ_MODIFIER;
	static const util::io::ld::CacheModifier ROW_OFFSET_UNALIGNED_READ_MODIFIER 	= _ROW_OFFSET_UNALIGNED_READ_MODIFIER;
	static const util::io::st::CacheModifier QUEUE_WRITE_MODIFIER 					= _QUEUE_WRITE_MODIFIER;

	static const bool WORK_STEALING		= _WORK_STEALING;

	enum {
		LOG_THREADS 					= _LOG_THREADS,
		THREADS							= 1 << LOG_THREADS,

		LOG_LOAD_VEC_SIZE  				= _LOG_LOAD_VEC_SIZE,
		LOAD_VEC_SIZE					= 1 << LOG_LOAD_VEC_SIZE,

		LOG_LOADS_PER_TILE 				= _LOG_LOADS_PER_TILE,
		LOADS_PER_TILE					= 1 << LOG_LOADS_PER_TILE,

		LOG_LOAD_STRIDE					= LOG_THREADS + LOG_LOAD_VEC_SIZE,
		LOAD_STRIDE						= 1 << LOG_LOAD_STRIDE,

		LOG_RAKING_THREADS				= _LOG_RAKING_THREADS,
		RAKING_THREADS					= 1 << LOG_RAKING_THREADS,

		LOG_WARPS						= LOG_THREADS - B40C_LOG_WARP_THREADS(CUDA_ARCH),
		WARPS							= 1 << LOG_WARPS,

		LOG_TILE_ELEMENTS_PER_THREAD	= LOG_LOAD_VEC_SIZE + LOG_LOADS_PER_TILE,
		TILE_ELEMENTS_PER_THREAD		= 1 << LOG_TILE_ELEMENTS_PER_THREAD,

		LOG_TILE_ELEMENTS 				= LOG_TILE_ELEMENTS_PER_THREAD + LOG_THREADS,
		TILE_ELEMENTS					= 1 << LOG_TILE_ELEMENTS,

		LOG_SCHEDULE_GRANULARITY		= _LOG_SCHEDULE_GRANULARITY,
		SCHEDULE_GRANULARITY			= 1 << LOG_SCHEDULE_GRANULARITY
	};

	// SRTS grid type
	typedef util::SrtsGrid<
		CUDA_ARCH,
		SizeT,									// Partial type
		LOG_THREADS,							// Depositing threads (the CTA size)
		LOG_LOADS_PER_TILE,						// Lanes (the number of loads)
		LOG_RAKING_THREADS,						// Raking threads
		true>									// There are prefix dependences between lanes
			SrtsGrid;


	// Operational details type for SRTS grid type
	typedef util::SrtsDetails<SrtsGrid> SrtsDetails;


	/**
	 * Shared memory structure
	 */
	struct SmemStorage
	{
		// Shared work-processing limits
		util::CtaWorkDistribution<SizeT>	work_decomposition;

		// Three shared memory channels for intra-warp communication
		SizeT 								warp_comm[WARPS][3];

		// Storage for scanning local expansion ranks
		SizeT 								warpscan[2][B40C_WARP_THREADS(CUDA_ARCH)];

		SizeT								enqueue_offset;

		enum {
			// Amount of storage we can use for hashing scratch space under target occupancy
			MAX_SCRATCH_BYTES_PER_CTA		= (B40C_SMEM_BYTES(CUDA_ARCH) / _MAX_CTA_OCCUPANCY)
												- sizeof(util::CtaWorkDistribution<SizeT>)
												- sizeof(SizeT[WARPS][3])
												- sizeof(SizeT[2][B40C_WARP_THREADS(CUDA_ARCH)])
												- sizeof(SizeT)
												- 64,
			MAX_SCRATCH_OFFSETS				= MAX_SCRATCH_BYTES_PER_CTA / sizeof(SizeT),
			SCRATCH_OFFSETS_PER_THREAD		= MAX_SCRATCH_OFFSETS / THREADS,
			SCRATCH_OFFSETS					= SCRATCH_OFFSETS_PER_THREAD * THREADS,

			SCRATCH_QUADS					= B40C_QUADS(SCRATCH_OFFSETS * sizeof(SizeT)),

			SMEM_POOL_QUADS					= B40C_MAX(SrtsGrid::TOTAL_RAKING_QUADS, SCRATCH_QUADS),
		};


		uint4 								smem_pool_int4s[SMEM_POOL_QUADS];	// Repurposable scan lanes
	};

	enum {
		// Total number of smem quads needed by this kernel
		SMEM_QUADS						= B40C_QUADS(sizeof(SmemStorage)),

		THREAD_OCCUPANCY				= B40C_SM_THREADS(CUDA_ARCH) >> LOG_THREADS,
		SMEM_OCCUPANCY					= B40C_SMEM_BYTES(CUDA_ARCH) / (SMEM_QUADS * sizeof(uint4)),
		CTA_OCCUPANCY  					= B40C_MIN(_MAX_CTA_OCCUPANCY, B40C_MIN(B40C_SM_CTAS(CUDA_ARCH), B40C_MIN(THREAD_OCCUPANCY, SMEM_OCCUPANCY))),

		VALID							= (CTA_OCCUPANCY > 0),
	};
};


} // namespace expand_atomic
} // namespace bfs
} // namespace b40c
