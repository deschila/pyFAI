/*
 *   Project: Azimuthal regroupping OpenCL kernel for PyFAI.
 *            Kernel with full pixel-split using a LUT
 *
 *
 *   Copyright (C) 2012 European Synchrotron Radiation Facility
 *                           Grenoble, France
 *
 *   Principal authors: J. Kieffer (kieffer@esrf.fr)
 *   Last revision: 26/10/2012
 *
 *   This program is free software: you can redistribute it and/or modify
 *   it under the terms of the GNU General Public License as published
 *   by the Free Software Foundation, either version 3 of the License, or
 *   (at your option) any later version.
 *
 *   This program is distributed in the hope that it will be useful,
 *   but WITHOUT ANY WARRANTY; without even the implied warranty of
 *   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 *   GNU Lesser General Public License for more details.
 *
 *   You should have received a copy of the GNU General Public License
 *   and the GNU Lesser General Public License  along with this program.
 *   If not, see <http://www.gnu.org/licenses/>.
 */

/**
 * \file
 * \brief OpenCL kernels for 1D azimuthal integration
 */


#ifdef ENABLE_FP64
	typedef double bigfloat_t;
#else
	typedef float bigfloat_t;
#endif

#define GROUP_SIZE BLOCK_SIZE
#define SET_SIZE 16

struct lut_point_t
{
	int idx;
	float coef;
};


/**
 * \brief cast values of an array of uint16 into a float output array.
 *
 * @param array_u16: Pointer to global memory with the input data as unsigned16 array
 * @param array_float:  Pointer to global memory with the output data as float array
 */
__kernel void
u16_to_float(__global unsigned short  *array_u16,
		     __global float *array_float
)
{
  int i = get_global_id(0);
  //Global memory guard for padding
  if(i < NIMAGE)
	array_float[i]=(float)array_u16[i];
}


/**
 * \brief convert values of an array of int32 into a float output array.
 *
 * @param array_int:  Pointer to global memory with the data in int
 * @param array_float:  Pointer to global memory with the data in float
 */
__kernel void
s32_to_float(	__global int  *array_int,
				__global float  *array_float
		)
{
  int i = get_global_id(0);
  //Global memory guard for padding
  if(i < NIMAGE)
	array_float[i] = (float)(array_int[i]);
}



/**
 * \brief Sets the values of 3 float output arrays to zero.
 *
 * Gridsize = size of arrays + padding.
 *
 * @param array0: float Pointer to global memory with the outMerge array
 * @param array1: float Pointer to global memory with the outCount array
 * @param array2: float Pointer to global memory with the outData array
 */
__kernel void
memset_out(__global float *array0,
		   __global float *array1,
		   __global float *array2
)
{
  int i = get_global_id(0);
  //Global memory guard for padding
  if(i < NBINS)
  {
	array0[i]=0.0f;
	array1[i]=0.0f;
	array2[i]=0.0f;
  }
}


/**
 * \brief Performs Normalization of input image
 *
 * Intensities of images are corrected by:
 *  - dark (read-out) noise subtraction
 *  - Solid angle correction (division)
 *  - polarization correction (division)
 *  - flat fiels correction (division)
 * Corrections are made in place unless the pixel is dummy.
 * Dummy pixels are left untouched so that they remain dummy
 *
 * @param image	          Float pointer to global memory storing the input image.
 * @param do_dark         Bool/int: shall dark-current correction be applied ?
 * @param dark            Float pointer to global memory storing the dark image.
 * @param do_flat         Bool/int: shall flat-field correction be applied ?
 * @param flat            Float pointer to global memory storing the flat image.
 * @param do_solidangle   Bool/int: shall flat-field correction be applied ?
 * @param solidangle      Float pointer to global memory storing the solid angle of each pixel.
 * @param do_polarization Bool/int: shall flat-field correction be applied ?
 * @param polarization    Float pointer to global memory storing the polarization of each pixel.
 * @param do_dummy    	  Bool/int: shall the dummy pixel be checked. Dummy pixel are pixels marked as bad and ignored
 * @param dummy       	  Float: value for bad pixels
 * @param delta_dummy 	  Float: precision for bad pixel value
 *
**/
__kernel void
corrections( 		__global float 	*image,
			const			 int 	do_dark,
			const 	__global float 	*dark,
			const			 int	do_flat,
			const 	__global float 	*flat,
			const			 int	do_solidangle,
			const 	__global float 	*solidangle,
			const			 int	do_polarization,
			const 	__global float 	*polarization,
			const		 	 int   	do_dummy,
			const			 float 	dummy,
			const		 	 float 	delta_dummy
			)
{
	float data;
	int i= get_global_id(0);
	if(i < NIMAGE)
	{
		data = image[i];
		if( (!do_dummy) || ((delta_dummy!=0.0f) && (fabs(data-dummy) > delta_dummy))|| ((delta_dummy==0.0f) && (data!=dummy)))
		{
			if(do_dark)
				data-=dark[i];
			if(do_flat)
				data/=flat[i];
			if(do_solidangle)
				data/=solidangle[i];
			if(do_polarization)
				data/=polarization[i];
			image[i] = data;
		}else{
			image[i] = dummy;
		}//end if do_dummy
	};//end if NIMAGE
};//end kernel



/**
 * \brief Performs 1d azimuthal integration with full pixel splitting based on a LUT in CSR form
 *
 * An image instensity value is spread across the bins according to the positions stored in the LUT.
 * The lut is represented by a set of 3 arrays (coefs, row_ind, col_ptr)
 * Values of 0 in the mask are processed and values of 1 ignored as per PyFAI
 *
 * This implementation is especially efficient on CPU where each core reads adjacents memory.
 * the use of local pointer can help on the CPU.
 *
 * @param weights     Float pointer to global memory storing the input image.
 * @param coefs       Float pointer to global memory holding the coeficient part of the LUT
 * @param row_ind     Integer pointer to global memory holding the corresponding index of the coeficient
 * @param col_ptr     Integer pointer to global memory holding the pointers to the coefs and row_ind for the CSR matrix
 * @param do_dummy    Bool/int: shall the dummy pixel be checked. Dummy pixel are pixels marked as bad and ignored
 * @param dummy       Float: value for bad pixels
 * @param outData     Float pointer to the output 1D array with the weighted histogram
 * @param outCount    Float pointer to the output 1D array with the unweighted histogram
 * @param outMerged   Float pointer to the output 1D array with the diffractogram
 *
 */
__kernel void
csr_integrate(	const 	__global	float	*weights,
                const   __global    float   *coefs,
                const   __global    int     *row_ind,
                const   __global    int     *col_ptr,
				const				int   	do_dummy,
				const			 	float 	dummy,
						__global 	float	*outData,
						__global 	float	*outCount,
						__global 	float	*outMerge
		     )
{
    int thread_id_loc = get_local_id(0);
    int bin_num = get_group_id(0); // each workgroup of size=warp is assinged to 1 bin
    int2 bin_bounds;
//    bin_bounds = (int2) *(col_ptr+bin_num);  // cool stuff!
    bin_bounds.x = col_ptr[bin_num];
    bin_bounds.y = col_ptr[bin_num+1];
    int bin_size = bin_bounds.y-bin_bounds.x;
	float sum_data = 0.0f;
	float sum_count = 0.0f;
	float cd = 0.0f;
	float cc = 0.0f;
	float t, y;
	const float epsilon = 1e-10f;
	float coef, data;
	int idx, k, j;

	for (j=bin_bounds.x;j<bin_bounds.y;j+=WORKGROUP_SIZE)
	{
		k = j+thread_id_loc;
        if (k < bin_bounds.y)     // I don't like conditionals!!
        {
   			coef = coefs[k];
   			idx = row_ind[k];
   			data = weights[idx];
   			if( (!do_dummy) || (data!=dummy) )
   			{
   				//sum_data +=  coef * data;
   				//sum_count += coef;
   				//Kahan summation allows single precision arithmetics with error compensation
   				//http://en.wikipedia.org/wiki/Kahan_summation_algorithm
   				y = coef*data - cd;
   				t = sum_data + y;
   				cd = (t - sum_data) - y;
   				sum_data = t;
   				y = coef - cc;
   				t = sum_count + y;
   				cc = (t - sum_count) - y;
   				sum_count = t;
   			};//end if dummy
       } //end if k < bin_bounds.y
   	};//for j
/*
 * parallel reduction
 */

// REMEMBER TO PASS WORKGROUP_SIZE AS A CPP DEF
    __local float super_sum_data[WORKGROUP_SIZE];
    __local float super_sum_data_correction[WORKGROUP_SIZE];
    __local float super_sum_count[WORKGROUP_SIZE];
    __local float super_sum_count_correction[WORKGROUP_SIZE];
    
    float super_sum_temp = 0.0f;
    int index, active_threads = WORKGROUP_SIZE;
    
    if (bin_size < WORKGROUP_SIZE)
    {
        if (thread_id_loc < bin_size)
        {
            super_sum_data_correction[thread_id_loc] = cd;
            super_sum_count_correction[thread_id_loc] = cc;
            super_sum_data[thread_id_loc] = sum_data;
            super_sum_count[thread_id_loc] = sum_count;
        }
        else
        {
            super_sum_data_correction[thread_id_loc] = 0.0f;
            super_sum_count_correction[thread_id_loc] = 0.0f;
            super_sum_data[thread_id_loc] = 0.0f;
            super_sum_count[thread_id_loc] = 0.0f;
        }
    }
    else
    {
        super_sum_data_correction[thread_id_loc] = cd;
        super_sum_count_correction[thread_id_loc] = cc;
        super_sum_data[thread_id_loc] = sum_data;
        super_sum_count[thread_id_loc] = sum_count;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
    cd = 0;
    cc = 0;

    while (active_threads != 1)
    {
        active_threads /= 2;
        if (thread_id_loc < active_threads)
        {
            index = thread_id_loc+active_threads;
            cd = super_sum_data_correction[thread_id_loc] + super_sum_data_correction[index];
            super_sum_temp = super_sum_data[thread_id_loc];
            y = super_sum_data[index] - cd;
            t = super_sum_temp + y;
            super_sum_data_correction[thread_id_loc] = (t - super_sum_temp) - y;
            super_sum_data[thread_id_loc] = t;

            cc = super_sum_count_correction[thread_id_loc] + super_sum_count_correction[index];
            super_sum_temp = super_sum_count[thread_id_loc];
            y = super_sum_count[index] - cc;
            t = super_sum_temp + y;
            super_sum_count_correction[thread_id_loc]  = (t - super_sum_temp) - y;
            super_sum_count[thread_id_loc] = t;
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (thread_id_loc == 0)
    {
        outData[bin_num] = super_sum_data[0];
        outCount[bin_num] = super_sum_count[0];
        if (outCount[bin_num] > epsilon)
            outMerge[bin_num] =  outData[bin_num] / outCount[bin_num];
        else
            outMerge[bin_num] = dummy;
    }
};//end kernel

/**
 * \brief Performs 1d azimuthal integration with full pixel splitting based on a LUT in CSR form
 *
 * An image instensity value is spread across the bins according to the positions stored in the LUT.
 * The lut is represented by a set of 3 arrays (coefs, row_ind, col_ptr)
 * Values of 0 in the mask are processed and values of 1 ignored as per PyFAI
 *
 * This kernel is ment to be ran with padded data (the span of each bin must be a multiple of the workgroup size)
 *
 * @param weights     Float pointer to global memory storing the input image.
 * @param coefs       Float pointer to global memory holding the coeficient part of the LUT
 * @param row_ind     Integer pointer to global memory holding the corresponding index of the coeficient
 * @param col_ptr     Integer pointer to global memory holding the pointers to the coefs and row_ind for the CSR matrix
 * @param do_dummy    Bool/int: shall the dummy pixel be checked. Dummy pixel are pixels marked as bad and ignored
 * @param dummy       Float: value for bad pixels
 * @param outData     Float pointer to the output 1D array with the weighted histogram
 * @param outCount    Float pointer to the output 1D array with the unweighted histogram
 * @param outMerged   Float pointer to the output 1D array with the diffractogram
 *
 */
__kernel void
csr_integrate_padded(	const 	__global	float	*weights,
                        const   __global    float   *coefs,
                        const   __global    int     *row_ind,
                        const   __global    int     *col_ptr,
                        const				int   	do_dummy,
                        const			 	float 	dummy,
                                __global 	float	*outData,
                                __global 	float	*outCount,
                                __global 	float	*outMerge
                    )
{
    int thread_id_loc = get_local_id(0);
    int bin_num = get_group_id(0); // each workgroup of size=warp is assinged to 1 bin
    int2 bin_bounds;
//    bin_bounds = (int2) *(col_ptr+bin_num);  // cool stuff!
    bin_bounds.x = col_ptr[bin_num];
    bin_bounds.y = col_ptr[bin_num+1];
	float sum_data = 0.0f;
	float sum_count = 0.0f;
	float cd = 0.0f;
	float cc = 0.0f;
	float t, y;
	const float epsilon = 1e-10f;
	float coef, data;
	int idx, k, j;

	for (j=bin_bounds.x;j<bin_bounds.y;j+=WORKGROUP_SIZE)
	{
		k = j+thread_id_loc;
   		coef = coefs[k];
        idx = row_ind[k];
   		data = weights[idx];
   		if( (!do_dummy) || (data!=dummy) )
   		{
   			//sum_data +=  coef * data;
   			//sum_count += coef;
   			//Kahan summation allows single precision arithmetics with error compensation
   			//http://en.wikipedia.org/wiki/Kahan_summation_algorithm
   			y = coef*data - cd;
   			t = sum_data + y;
   			cd = (t - sum_data) - y;
    		sum_data = t;
    		y = coef - cc;
    		t = sum_count + y;
    		cc = (t - sum_count) - y;
    		sum_count = t;
    	};//end if dummy
    };//for j
/*
 * parallel reduction
 */

// REMEMBER TO PASS WORKGROUP_SIZE AS A CPP DEF
    __local float super_sum_data[WORKGROUP_SIZE];
    __local float super_sum_data_correction[WORKGROUP_SIZE];
    __local float super_sum_count[WORKGROUP_SIZE];
    __local float super_sum_count_correction[WORKGROUP_SIZE];
    super_sum_data[thread_id_loc] = sum_data;
    super_sum_count[thread_id_loc] = sum_count;
    super_sum_data_correction[thread_id_loc] = cd;
    super_sum_count_correction[thread_id_loc] = cc;
    barrier(CLK_LOCAL_MEM_FENCE);

    float super_sum_temp = 0.0f;
    int index, active_threads = WORKGROUP_SIZE;
    cd = 0;
    cc = 0;
    
    while (active_threads != 1)
    {
        active_threads /= 2;
        if (thread_id_loc < active_threads)
        {
            index = thread_id_loc+active_threads;
            cd = super_sum_data_correction[thread_id_loc] + super_sum_data_correction[index];
            super_sum_temp = super_sum_data[thread_id_loc];
            y = super_sum_data[index] - cd;
            t = super_sum_temp + y;
            super_sum_data_correction[thread_id_loc] = (t - super_sum_temp) - y;
            super_sum_data[thread_id_loc] = t;
            
            cc = super_sum_count_correction[thread_id_loc] + super_sum_count_correction[index];
            super_sum_temp = super_sum_count[thread_id_loc];
            y = super_sum_count[index] - cc;
            t = super_sum_temp + y;
            super_sum_count_correction[thread_id_loc]  = (t - super_sum_temp) - y;
            super_sum_count[thread_id_loc] = t;
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (thread_id_loc == 0)
    {
        outData[bin_num] = super_sum_data[0];
        outCount[bin_num] = super_sum_count[0];
        if (outCount[bin_num] > epsilon)
            outMerge[bin_num] =  outData[bin_num] / outCount[bin_num];
        else
            outMerge[bin_num] = dummy;
    }
};//end kernel

/**
 * \brief Performs distortion corrections on an image using a LUT in CSR form
 *
 * @param weights     Float pointer to global memory storing the input image.
 * @param coefs       Float pointer to global memory holding the coeficient part of the LUT
 * @param row_ind     Integer pointer to global memory holding the corresponding index of the coeficient
 * @param col_ptr     Integer pointer to global memory holding the pointers to the coefs and row_ind for the CSR matrix
 * @param outData     Float pointer to the output 1D array with the corrected image
 *
 */

__kernel void
csr_integrate_dis(  const   __global    float   *weights,
                    const   __global    float   *coefs,
                    const   __global    int     *row_ind,
                    const   __global    int     *col_ptr,
                    const               int     do_dummy,
                    const               float   dummy,
                            __global    float   *outData,
                            __global    float   *outCount,
                            __global    float   *outMerge
                )
{
    int thread_id_loc = get_local_id(0);
    int bin_num = get_group_id(0); // each workgroup of size=warp is assinged to 1 bin
    int2 bin_bounds;
//    bin_bounds = (int2) *(col_ptr+bin_num);  // cool stuff!
    bin_bounds.x = col_ptr[bin_num];
    bin_bounds.y = col_ptr[bin_num+1];
    int bin_size = bin_bounds.y-bin_bounds.x;
    float sum_data = 0.0f;
    float cd = 0.0f;
    float t, y;
    float coef, data;
    int idx, k, j;

    for (j=bin_bounds.x;j<bin_bounds.y;j+=WORKGROUP_SIZE)
    {
        k = j+thread_id_loc;
        if (k < bin_bounds.y)     // I don't like conditionals!!
        {
            coef = coefs[k];
            idx = row_ind[k];
            data = weights[idx];
            if( (!do_dummy) || (data!=dummy) )
            {
                //sum_data +=  coef * data;
                //sum_count += coef;
                //Kahan summation allows single precision arithmetics with error compensation
                //http://en.wikipedia.org/wiki/Kahan_summation_algorithm
                y = coef*data - cd;
                t = sum_data + y;
                cd = (t - sum_data) - y;
                sum_data = t;
             };//end if dummy
       } //end if k < bin_bounds.y
    };//for j
/*
 * parallel reduction
 */

// REMEMBER TO PASS WORKGROUP_SIZE AS A CPP DEF
    __local float super_sum_data[WORKGROUP_SIZE];
    __local float super_sum_data_correction[WORKGROUP_SIZE];
    float super_sum_temp = 0.0f;
    int index, active_threads = WORKGROUP_SIZE;
    
    
    
    if (bin_size < WORKGROUP_SIZE)
    {
        if (thread_id_loc < bin_size)
        {
            super_sum_data_correction[thread_id_loc] = cd;
            super_sum_data[thread_id_loc] = sum_data;
        }
        else
        {
            super_sum_data_correction[thread_id_loc] = 0.0f;
            super_sum_data[thread_id_loc] = 0.0f;
        }
    }
    else
    {
        super_sum_data_correction[thread_id_loc] = cd;
        super_sum_data[thread_id_loc] = sum_data;
    }
    barrier(CLK_LOCAL_MEM_FENCE);
   
    cd = 0;
    
    while (active_threads != 1)
    {
        active_threads /= 2;
        if (thread_id_loc < active_threads)
        {
            index = thread_id_loc+active_threads;

            super_sum_temp = super_sum_data[thread_id_loc];
            y = super_sum_data[index] - cd;
            t = super_sum_temp + y;
            cd = (t - super_sum_temp) - y;
            super_sum_data[thread_id_loc] = t;
        }
        barrier(CLK_LOCAL_MEM_FENCE);
    }

    if (thread_id_loc == 0)
    {
        outData[bin_num] = super_sum_data[0];
    }


};//end kernel

