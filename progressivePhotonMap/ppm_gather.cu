
/*
 * Copyright (c) 2008 - 2009 NVIDIA Corporation.  All rights reserved.
 *
 * NVIDIA Corporation and its licensors retain all intellectual property and proprietary
 * rights in and to this software, related documentation and any modifications thereto.
 * Any use, reproduction, disclosure or distribution of this software and related
 * documentation without an express license agreement from NVIDIA Corporation is strictly
 * prohibited.
 *
 * TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, THIS SOFTWARE IS PROVIDED *AS IS*
 * AND NVIDIA AND ITS SUPPLIERS DISCLAIM ALL WARRANTIES, EITHER EXPRESS OR IMPLIED,
 * INCLUDING, BUT NOT LIMITED TO, IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A
 * PARTICULAR PURPOSE.  IN NO EVENT SHALL NVIDIA OR ITS SUPPLIERS BE LIABLE FOR ANY
 * SPECIAL, INCIDENTAL, INDIRECT, OR CONSEQUENTIAL DAMAGES WHATSOEVER (INCLUDING, WITHOUT
 * LIMITATION, DAMAGES FOR LOSS OF BUSINESS PROFITS, BUSINESS INTERRUPTION, LOSS OF
 * BUSINESS INFORMATION, OR ANY OTHER PECUNIARY LOSS) ARISING OUT OF THE USE OF OR
 * INABILITY TO USE THIS SOFTWARE, EVEN IF NVIDIA HAS BEEN ADVISED OF THE POSSIBILITY OF
 * SUCH DAMAGES
 */

#include <optix.h>
#include <optixu/optixu_math_namespace.h>
#include "ppm.h"
#include "helpers.h"
#include "path_tracer.h"
#include "random.h"

using namespace optix;

//
// Ray generation program
//

rtDeclareVariable(rtObject,      top_object, , );
rtBuffer<float4, 2>              output_buffer;
rtBuffer<float4, 3>              frame_output_buffer;
rtBuffer<float4, 2>              debug_buffer;
rtBuffer<PackedPhotonRecord, 1>  photon_map;
rtBuffer<PackedHitRecord, 2>     rtpass_output_buffer;
rtBuffer<uint2, 2>               image_rnd_seeds;
rtDeclareVariable(float,         scene_epsilon, , );
rtDeclareVariable(float,         alpha, , );
rtDeclareVariable(float,         total_emitted, , );
rtDeclareVariable(float,         frame_number , , );
rtDeclareVariable(float3,        ambient_light , , );
rtDeclareVariable(uint,          use_debug_buffer, , );
rtDeclareVariable(PPMLight,      light , , );
rtDeclareVariable(uint2, launch_index, rtLaunchIndex, );
rtDeclareVariable(ShadowPRD, shadow_prd, rtPayload, );

static __device__ __inline__ 
void accumulatePhoton( const PackedPhotonRecord& photon,
                       const float3& rec_normal,
                       const float3& rec_atten_Kd,
                       uint& num_new_photons, float3& flux_M )
{
  float3 photon_energy = make_float3( photon.c.y, photon.c.z, photon.c.w );
  float3 photon_normal = make_float3( photon.a.w, photon.b.x, photon.b.y );
  float p_dot_hit = dot(photon_normal, rec_normal);
  if (p_dot_hit > 0.01f) { // Fudge factor for imperfect cornell box geom
    float3 photon_ray_dir = make_float3( photon.b.z, photon.b.w, photon.c.x );
    float3 flux = photon_energy * rec_atten_Kd; // * -dot(photon_ray_dir, rec_normal);
    num_new_photons++;
    flux_M += flux;
  }
}

#if 0
#define check( condition, color ) \
{ \
  if( !(condition) ) { \
    debug_buffer[index] = make_float4( stack_current, node, photon_map_size, 0 ); \
    output_buffer[index] = make_color( color ); \
    return; \
  } \
}
#else
#define check( condition, color )
#endif

#define MAX_DEPTH 20 // one MILLION photons
RT_PROGRAM void gather()
{
  clock_t start = clock();
  PackedHitRecord rec = rtpass_output_buffer[launch_index];
  float3 rec_position = make_float3( rec.a.x, rec.a.y, rec.a.z );
  float3 rec_normal   = make_float3( rec.a.w, rec.b.x, rec.b.y );
  float3 rec_atten_Kd = make_float3( rec.b.z, rec.b.w, rec.c.x );
  uint   rec_flags    = __float_as_int( rec.c.y );
  float  rec_radius2  = rec.c.z;
  float  rec_photon_count = rec.c.w;
  float3 rec_flux     = make_float3( rec.d.x, rec.d.y, rec.d.z );
  float  rec_accum_atten = rec.d.w;
  float3 rec_volumetricRadiance[FRAME];
  float unpacked[FRAME*3];
  for (int i=0; i<FRAME_PACKED; ++i)
  {
    unpacked[4 * i] = rec.e[i].x;
    unpacked[4 * i + 1] = rec.e[i].y;
    unpacked[4 * i + 2] = rec.e[i].z;
    unpacked[4 * i + 3] = rec.e[i].w;
  }
  for (int i =0; i<FRAME; ++i)
    rec_volumetricRadiance[i] = make_float3( unpacked[3*i], unpacked[3*i+1], unpacked[3*i+2]);

  // Check if this is hit point lies on an emitter or hit background 
  if( !(rec_flags & PPM_HIT) || rec_flags & PPM_OVERFLOW ) {
	  output_buffer[launch_index] = make_float4(rec_atten_Kd + rec_volumetricRadiance[FRAME-1] / total_emitted);
      for (int i=0; i<FRAME; ++i)
        frame_output_buffer[make_uint3(launch_index, i)] = make_float4(rec_atten_Kd + rec_volumetricRadiance[i] / total_emitted);
    return;
  }

  unsigned int stack[MAX_DEPTH];
  unsigned int stack_current = 0;
  unsigned int node = 0; // 0 is the start

#define push_node(N) stack[stack_current++] = (N)
#define pop_node()   stack[--stack_current]

  push_node( 0 );

  int photon_map_size = photon_map.size(); // for debugging

  float direct_hit_point_distance = 50000.0;
  float indirect_hit_point_distance = 50000.0;

  uint num_new_photons = 0u;
  float3 flux_M = make_float3( 0.0f, 0.0f, 0.0f );
  uint loop_iter = 0;
  do {

    check( node < photon_map_size, make_float3( 1,0,0 ) );
    PackedPhotonRecord& photon = photon_map[ node ];

    uint axis = __float_as_int( photon.d.x );
    if( !( axis & PPM_NULL ) ) {

      float3 photon_position = make_float3( photon.a );
      float3 diff = rec_position - photon_position;
      float distance2 = dot(diff, diff);

      if (distance2 <= rec_radius2) {
        accumulatePhoton(photon, rec_normal, rec_atten_Kd, num_new_photons, flux_M);
		indirect_hit_point_distance = photon.d.y;
		//rtPrintf("%f\n", hit_point_distance);
      }

      // Recurse
      if( !( axis & PPM_LEAF ) ) {
        float d;
        if      ( axis & PPM_X ) d = diff.x;
        else if ( axis & PPM_Y ) d = diff.y;
        else                      d = diff.z;

        // Calculate the next child selector. 0 is left, 1 is right.
        int selector = d < 0.0f ? 0 : 1;
        if( d*d < rec_radius2 ) {
          check( stack_current+1 < MAX_DEPTH, make_float3( 0,1,0) );
          push_node( (node<<1) + 2 - selector );
        }

        check( stack_current+1 < MAX_DEPTH, make_float3( 0,1,1) );
        node = (node<<1) + 1 + selector;
      } else {
        node = pop_node();
      }
    } else {
      node = pop_node();
    }
    loop_iter++;
  } while ( node );

  // Compute new N,R
  float R2 = rec_radius2;
  float N = rec_photon_count;
  float M = static_cast<float>( num_new_photons ) ;
  float new_N = N + alpha*M;
  rec.c.w = new_N;  // set rec.photon_count

  float reduction_factor2 = 1.0f;
  float new_R2 = R2;
  if( M != 0 ) {
    reduction_factor2 = ( N + alpha*M ) / ( N + M );
    new_R2 = R2*( reduction_factor2 ); 
    rec.c.z = new_R2; // set rec.radius2
  }

  // Compute indirectflux
  float3 new_flux = ( rec_flux + flux_M ) * reduction_factor2;
  rec.d = make_float4( new_flux ); // set rec.flux
  float3 indirect_flux = 1.0f / ( M_PIf * new_R2 ) * new_flux / total_emitted;
  //rtPrintf("%f\n", new_flux.x);
  // Compute direct
  float3 point_on_light;
  float dist_scale;
  if( light.is_area_light ) {
    if (1)
    {
	  float3 diff = light.anchor - rec_position;
	  direct_hit_point_distance = sqrt(dot(diff, diff));
      uint2 seed = image_rnd_seeds[launch_index];
      float2 sample = make_float2(rnd(seed.x), rnd(seed.y));
      image_rnd_seeds[launch_index] = seed;
      point_on_light = light.anchor + sample.x * light.v1 + sample.y * light.v2;
      dist_scale = 1.0f;
    } else
    {
      dist_scale = dot((rec_position - light.anchor), light.direction);
      point_on_light = rec_position - dist_scale * light.direction;
    }
  } else {
	float3 diff = light.position - rec_position;
	direct_hit_point_distance = sqrt(dot(diff, diff));
    point_on_light = light.position;
    dist_scale = light.radius / ( M_PIf * 0.5f); 
  }
  float3 to_light    = point_on_light - rec_position;
  float  light_dist  = length( to_light );
  to_light = to_light / light_dist;
  float  n_dot_l     = fmaxf( 0.0f, dot( rec_normal, to_light ) );
  float  light_atten = n_dot_l;
  
  // TODO Should clip direct light to photon emiting code -- but we will ignore this for demo 
  //if( !light.is_area_light && acosf( dot( -to_light, light.direction )  ) > light.radius ) {
  //  light_atten = 0.0f;
  //}

  // PPM_IN_SHADOW will be set if this is a point light and we have already performed an occluded shadow query 
  if( rec_flags & PPM_IN_SHADOW ) {
    light_atten = 0.0f;
  }
  if ( light_atten > 0.0f ) {
    ShadowPRD prd;
    prd.attenuation = 1.0f;
    optix::Ray shadow_ray( rec_position, to_light, shadow_ray_type, scene_epsilon, light_dist - scene_epsilon );
    rtTrace( top_object, shadow_ray, prd );
    light_atten *= prd.attenuation * dot( -to_light, light.direction );
    rec.c.y = __int_as_float(  prd.attenuation == 0.0f && !light.is_area_light ? rec_flags|PPM_IN_SHADOW : rec_flags ); 
  } 
  light_atten /= dist_scale*light_dist*light_dist;
  if( light_atten < 0.0f ) light_atten = 0.0f;   // TODO Shouldnt be needed but we get acne near light w/out it
  rec.d.w = rec_accum_atten + light_atten;

  //float distance = rec.f.x;
  //rtPrintf("%f\n", hit_point_distance);
  unsigned int directFluxFrame = floor(direct_hit_point_distance * TOTAL_FRAME / TOTAL_DISTANCE) - (START_SECTION*FRAME);
  unsigned int indirectFluxFrame = floor(indirect_hit_point_distance * TOTAL_FRAME / TOTAL_DISTANCE) - (START_SECTION*FRAME);

  float avg_atten = rec.d.w / (frame_number + 1.0f);
  //rtPrintf("%d\n", directFluxFrame);


  //rec_atten_Kd += make_float3(tex2D(diffuse_map, texcoord.x*diffuse_map_scale, texcoord.y*diffuse_map_scale));
  float3 direct_flux = light.power * avg_atten *rec_atten_Kd;
  rtpass_output_buffer[launch_index] = rec;
  //float3 final_color = indirect_flux;

  //rtPrintf("%f\n", total_emitted);
  //Attention: sum them up here
  float3 sum_volRadiance[FRAME];
  sum_volRadiance[0]=rec_volumetricRadiance[0];
  #ifdef PREFIX_SUM
    for (int i =1; i<FRAME; ++i)
      sum_volRadiance[i]=sum_volRadiance[i-1]+rec_volumetricRadiance[i];
  #else
    for (int i =1; i<FRAME; ++i)
      sum_volRadiance[i]=rec_volumetricRadiance[i];
  #endif
  float3 final_color[FRAME];
  for (int i = 0; i < FRAME; ++i) {
	  //rtPrintf("%f, %f, %f \n", sum_volRadiance[i].x, sum_volRadiance[i].y, sum_volRadiance[i].z);
	  final_color[i] = sum_volRadiance[i] / total_emitted + ambient_light*rec_atten_Kd;
#ifdef PREFIX_SUM
	  if (i >= directFluxFrame)
		  final_color[i] += direct_flux;
	  if (i >= indirectFluxFrame)
		  final_color[i] += indirect_flux;
#else
	  if (i == directFluxFrame)
		  final_color[i] += direct_flux;
	  if (i == indirectFluxFrame)
		  final_color[i] += indirect_flux;
#endif
  }
    //final_color[i] = direct_flux + indirect_flux + ambient_light*rec_atten_Kd;

  //if (fmaxf(rec_volumetricRadiance[i] / total_emitted)>0.0f) final_color = make_float3(0.7f,0.0f,0.0f);
  //if (fmaxf(rec_volumetricRadiance[i])>0.0f) final_color = make_float3(0.7f,0.0f,0.0f);

  //float3 tmp =  rec_volumetricRadiance[i]/total_emitted;
  //if (tmp.x>0)
  //rtPrintf("%f %f\n", tmp.x, total_emitted);
  //if (tmp.x>0)
  //rtPrintf("Final color: (%f, %f, %f), VolRadiance: (%f, %f, %f)\n", final_color.x, final_color.y, final_color.z,tmp.x, tmp.y, tmp.z);
  output_buffer[launch_index] = make_float4(final_color[11]);
  for (int i=0; i<FRAME; ++i)
    frame_output_buffer[make_uint3(launch_index, i)] = make_float4(final_color[i]);
  if(use_debug_buffer == 1)
    debug_buffer[launch_index] = make_float4( loop_iter, new_R2, new_N, M );
}

RT_PROGRAM void gather_any_hit()
{
  shadow_prd.attenuation = 0.0f;

  rtTerminateRay();
}


//
// Stack overflow program
//
rtDeclareVariable(float3, rtpass_bad_color, , );
RT_PROGRAM void gather_exception()
{
  output_buffer[launch_index] = make_float4(1.0f, 1.0f, 0.0f, 0.0f);
}