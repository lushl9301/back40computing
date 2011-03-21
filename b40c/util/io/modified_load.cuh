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
 * Thanks!
 * 
 ******************************************************************************/

/******************************************************************************
 * Kernel utilities for loading types through global memory with cache modifiers
 ******************************************************************************/

#pragma once

#include <cuda.h>
#include <b40c/util/cuda_properties.cuh>
#include <b40c/util/vector_types.cuh>

namespace b40c {
namespace util {
namespace io {


/**
 * Enumeration of data movement cache modifiers.
 */
namespace ld {

	enum CacheModifier {
		NONE,				// default (currently ca)
		cg,					// cache global
		ca,					// cache all
		cs, 				// cache streaming

		LIMIT
	};

} // namespace ld



/**
 * TODO: replace this with something better
 */
#define CacheModifierToString(modifier)	(	(modifier == b40c::util::io::ld::NONE) ? 	"NONE" :	\
											(modifier == b40c::util::io::ld::cg) ? 		"cg" :		\
											(modifier == b40c::util::io::ld::ca) ? 		"ca" :		\
											(modifier == b40c::util::io::ld::cs) ? 		"cs" :		\
											(modifier == b40c::util::io::st::NONE) ? 	"NONE" :	\
											(modifier == b40c::util::io::st::cg) ? 		"cg" :		\
											(modifier == b40c::util::io::st::wb) ? 		"wb" :		\
											(modifier == b40c::util::io::st::cs) ? 		"cs" :		\
																						"<ERROR>")

/**
 * Basic utility for performing modified loads through cache.
 */
template <ld::CacheModifier CACHE_MODIFIER>
struct ModifiedLoad
{
	/**
	 * Load operation we will provide specializations for
	 */
	template <typename T>
	__device__ __forceinline__ static void Ld(T &val, T *ptr);


	/**
	 * Vec-4 loads for 64-bit types are implemented as two vec-2 loads
	 */
	__device__ __forceinline__ static void Ld(double4 &val, double4* ptr)
	{
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<double2*>(&val.x), reinterpret_cast<double2*>(ptr));
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<double2*>(&val.z), reinterpret_cast<double2*>(ptr) + 1);
	}

	__device__ __forceinline__ static void Ld(ulonglong4 &val, ulonglong4* ptr)
	{
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<ulonglong2*>(&val.x), reinterpret_cast<ulonglong2*>(ptr));
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<ulonglong2*>(&val.z), reinterpret_cast<ulonglong2*>(ptr) + 1);
	}

	__device__ __forceinline__ static void Ld(longlong4 &val, longlong4* ptr)
	{
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<longlong2*>(&val.x), reinterpret_cast<longlong2*>(ptr));
		ModifiedLoad<CACHE_MODIFIER>::Ld(*reinterpret_cast<longlong2*>(&val.z), reinterpret_cast<longlong2*>(ptr) + 1);
	}
};



/**
 * Load operations specialized for ld::NONE modifier
 */
template <>
template <typename T>
void ModifiedLoad<ld::NONE>::Ld(T &val, T *ptr)
{
	val = *ptr;
}


#if __CUDA_ARCH__ >= 200


	/**
	 * Vector load ops
	 */
	#define B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, modifier)																	\
		template<> template<> void ModifiedLoad<ld::modifier>::Ld(base_type &val, base_type* ptr) {												\
			asm("ld.global."#modifier"."#ptx_type" %0, [%1];" : "="#reg_mod(*reinterpret_cast<cast_type*>(&val)) : _B40C_ASM_PTR_(ptr));		\
		}

	#define B40C_LOAD_VEC2(base_type, ptx_type, reg_mod, cast_type, modifier)																	\
		template<> template<> void ModifiedLoad<ld::modifier>::Ld(base_type &val, base_type* ptr) {												\
			asm("ld.global."#modifier".v2."#ptx_type" {%0, %1}, [%2];" : "="#reg_mod(*reinterpret_cast<cast_type*>(&val.x)), "="#reg_mod(*reinterpret_cast<cast_type*>(&val.y)) : _B40C_ASM_PTR_(ptr));		\
		}

	#define B40C_LOAD_VEC4(base_type, ptx_type, reg_mod, cast_type, modifier)																	\
		template<> template<> void ModifiedLoad<ld::modifier>::Ld(base_type &val, base_type* ptr) {												\
			asm("ld.global."#modifier".v4."#ptx_type" {%0, %1, %2, %3}, [%4];" : "="#reg_mod(*reinterpret_cast<cast_type*>(&val.x)), "="#reg_mod(*reinterpret_cast<cast_type*>(&val.y)), "="#reg_mod(*reinterpret_cast<cast_type*>(&val.z)), "="#reg_mod(*reinterpret_cast<cast_type*>(&val.w)) : _B40C_ASM_PTR_(ptr));		\
		}


	/**
	 * Defines specialized load ops for only the base type
	 */
	#define B40C_LOAD_BASE(base_type, ptx_type, reg_mod, cast_type)		\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, cg)		\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, ca)		\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, cs)


	/**
	 * Defines specialized load ops for the base type and for its derivative vec1 and vec2 types
	 */
	#define B40C_LOAD_BASE_ONE_TWO(base_type, dest_type, short_type, ptx_type, reg_mod, cast_type)	\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, cg)									\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, ca)									\
		B40C_LOAD_VEC1(base_type, ptx_type, reg_mod, cast_type, cs)									\
																									\
		B40C_LOAD_VEC1(short_type##1, ptx_type, reg_mod, cast_type, cg)								\
		B40C_LOAD_VEC1(short_type##1, ptx_type, reg_mod, cast_type, ca)								\
		B40C_LOAD_VEC1(short_type##1, ptx_type, reg_mod, cast_type, cs)								\
																									\
		B40C_LOAD_VEC2(short_type##2, ptx_type, reg_mod, cast_type, cg)								\
		B40C_LOAD_VEC2(short_type##2, ptx_type, reg_mod, cast_type, ca)								\
		B40C_LOAD_VEC2(short_type##2, ptx_type, reg_mod, cast_type, cs)


	/**
	 * Defines specialized load ops for the base type and for its derivative vec1, vec2, and vec4 types
	 */
	#define B40C_LOAD_BASE_ONE_TWO_FOUR(base_type, dest_type, short_type, ptx_type, reg_mod, cast_type)	\
		B40C_LOAD_BASE_ONE_TWO(base_type, dest_type, short_type, ptx_type, reg_mod, cast_type)			\
		B40C_LOAD_VEC4(short_type##4, ptx_type, reg_mod, cast_type, cg)									\
		B40C_LOAD_VEC4(short_type##4, ptx_type, reg_mod, cast_type, ca)									\
		B40C_LOAD_VEC4(short_type##4, ptx_type, reg_mod, cast_type, cs)


#if __CUDA_VERSION >= 4000
	#define B40C_CAST_SELECT(v3, v4) v4
#else
	#define B40C_CAST_SELECT(v3, v4) v3
#endif


	/**
	 * Define cache-modified loads for all 4-byte (and smaller) structures
	 */
	B40C_LOAD_BASE_ONE_TWO_FOUR(char, 			signed char, 	char, 	s8, 	r, B40C_CAST_SELECT(char, unsigned int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(short, 			short, 			short, 	s16, 	r, B40C_CAST_SELECT(short, unsigned int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(int, 			int, 			int, 	s32, 	r, B40C_CAST_SELECT(int, int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(unsigned char, 	unsigned char, 	uchar,	u8, 	r, B40C_CAST_SELECT(unsigned char, unsigned int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(unsigned short,	unsigned short,	ushort,	u16, 	r, B40C_CAST_SELECT(unsigned short, unsigned int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(unsigned int, 	unsigned int, 	uint,	u32, 	r, B40C_CAST_SELECT(unsigned int, unsigned int))
	B40C_LOAD_BASE_ONE_TWO_FOUR(float, 			float, 			float, 	f32, 	f, B40C_CAST_SELECT(float, float))

	#if !defined(_B40C_LP64_) || (_B40C_LP64_ == 0)
	B40C_LOAD_BASE_ONE_TWO_FOUR(long, 			long, 			long, 	s32, 	r, long)
	B40C_LOAD_BASE_ONE_TWO_FOUR(unsigned long, 	unsigned long, 	ulong, 	u32, 	r, unsigned long)
	#endif

	B40C_LOAD_BASE(signed char, s8, r, unsigned int)		// Only need to define base: char2,char4, etc already defined from char


	/**
	 * Define cache-modified loads for all 8-byte structures
	 */
	B40C_LOAD_BASE_ONE_TWO(unsigned long long, 	unsigned long long, 	ulonglong, 	u64, l, unsigned long long)
	B40C_LOAD_BASE_ONE_TWO(long long, 			long long, 				longlong, 	s64, l, long long)
	B40C_LOAD_BASE_ONE_TWO(double, 				double, 				double, 	s64, l, long long)				// Cast to 64-bit long long a workaround for the fact that the 3.x assembler has no register constraint for doubles

	#if _B40C_LP64_ > 0
	B40C_LOAD_BASE_ONE_TWO(long, 				long, 					long, 		s64, l, long)
	B40C_LOAD_BASE_ONE_TWO(unsigned long, 		unsigned long, 			ulong, 		u64, l, unsigned long)
	#endif


	/**
	 * Undefine macros
	 */
	#undef B40C_LOAD_VEC1
	#undef B40C_LOAD_VEC2
	#undef B40C_LOAD_VEC4
	#undef B40C_LOAD_BASE
	#undef B40C_LOAD_BASE_ONE_TWO
	#undef B40C_LOAD_BASE_ONE_TWO_FOUR
	#undef B40C_CAST_SELECT


#endif //__CUDA_ARCH__




} // namespace io
} // namespace util
} // namespace b40c

