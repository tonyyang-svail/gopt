#include <stdio.h>
#include <assert.h>
#include <sys/ipc.h>
#include <sys/shm.h>

/**< NVCC assumes that all header files are C++ files. Tell it that these are
  *  C header files. */
extern "C" {
#include "common.h"
}

cudaStream_t myStream;

void printDeviceProperties()
{
	struct cudaDeviceProp deviceProp;
	int ret = cudaGetDeviceProperties(&deviceProp, 0);
	CPE(ret != cudaSuccess, "Get Device Properties failed\n", -1);

	printf("\n=================DEVICE PROPERTIES=================\n");
	printf("\tDevice name: %s\n", deviceProp.name);
	printf("\tTotal global memory: %lu bytes\n", deviceProp.totalGlobalMem);
	printf("\tWarp size: %d\n", deviceProp.warpSize);
	printf("\tCompute capability: %d.%d\n", deviceProp.major, deviceProp.minor);

	printf("\tMulti-processor count: %d\n", deviceProp.multiProcessorCount);
	printf("\tThreads per multi-processor: %d\n", deviceProp.maxThreadsPerMultiProcessor);

	printf("\n");
}

__global__ void
randMem(int *pkts, const int *log, int num_pkts)
{
	int i = blockDim.x * blockIdx.x + threadIdx.x;

	if (i < num_pkts) {
		int j;
		for(j = 0; j < DEPTH; j ++) {
			pkts[i] = log[pkts[i]];
		}
	}
}

double cpu_run(int *pkts, int *log, int num_pkts)
{
	int i;
	struct timespec start, end;
	clock_gettime(CLOCK_REALTIME, &start);

	for(i = 0; i < num_pkts; i += 8) {
		int j;
		for(j = 0; j < DEPTH; j ++) {
			pkts[i] = log[pkts[i]];
			pkts[i + 1] = log[pkts[i + 1]];
			pkts[i + 2] = log[pkts[i + 2]];
			pkts[i + 3] = log[pkts[i + 3]];
			pkts[i + 4] = log[pkts[i + 4]];
			pkts[i + 5] = log[pkts[i + 5]];
			pkts[i + 6] = log[pkts[i + 6]];
			pkts[i + 7] = log[pkts[i + 7]];
		}
	}

	clock_gettime(CLOCK_REALTIME, &end);
	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);
	return time;
}

#if INCLUDE_COPY_TIME == 1
/**< Include copy overhead in measurement */
double gpu_run(int *h_pkts, int *d_pkts, int *d_log, int num_pkts)
{
	struct timespec start, end;
	int err = cudaSuccess;

	clock_gettime(CLOCK_REALTIME, &start);

	/**< Copy packets to device */
	err = cudaMemcpyAsync(d_pkts, h_pkts, num_pkts * sizeof(int), 
		cudaMemcpyHostToDevice, myStream);
	CPE(err != cudaSuccess, "Failed to copy to device memory\n", -1);

	/**< Kernel launch */
	int threadsPerBlock = 256;
	int blocksPerGrid = (num_pkts + threadsPerBlock - 1) / threadsPerBlock;

	randMem<<<blocksPerGrid, threadsPerBlock, 0, myStream>>>(d_pkts, 
		d_log, num_pkts);
	err = cudaGetLastError();
	CPE(err != cudaSuccess, "Failed to launch randMem kernel. This can happen "
		"if the GPU does not have compute 3.5\n", -1);

	/**< Copy back the results */
	err = cudaMemcpyAsync(h_pkts, d_pkts, num_pkts * sizeof(int),
		cudaMemcpyDeviceToHost, myStream);
	CPE(err != cudaSuccess, "Failed to copy C from device to host\n", -1);

	/**< Wait for all stream ops to complete */
	cudaStreamSynchronize(myStream);

	clock_gettime(CLOCK_REALTIME, &end);
	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);

	return time;
}

#else
/**< Don't include copy overhead in measurement */
double gpu_run(int *h_pkts, int *d_pkts, int *d_log, int num_pkts)
{
	struct timespec start, end;
	int err = cudaSuccess;

	/**< Copy packets to device */
	err = cudaMemcpy(d_pkts, h_pkts, num_pkts * sizeof(int), 
		cudaMemcpyHostToDevice);
	CPE(err != cudaSuccess, "Failed to copy to device memory\n", -1);

	/**< Memcpy has completed: start timer */
	clock_gettime(CLOCK_REALTIME, &start);

	/**< Kernel launch */
	int threadsPerBlock = 256;
	int blocksPerGrid = (num_pkts + threadsPerBlock - 1) / threadsPerBlock;

	randMem<<<blocksPerGrid, threadsPerBlock>>>(d_pkts, d_log, num_pkts);
	err = cudaGetLastError();
	CPE(err != cudaSuccess, "Failed to launch randMem kernel\n", -1);
	cudaDeviceSynchronize();

	/**< Kernel execution finished: stop timer */
	clock_gettime(CLOCK_REALTIME, &end);

	/**< Copy back the results */
	err = cudaMemcpy(h_pkts, d_pkts, num_pkts * sizeof(int),
		cudaMemcpyDeviceToHost);
	CPE(err != cudaSuccess, "Failed to copy C from device to host\n", -1);

	double time = (double) (end.tv_nsec - start.tv_nsec) / 1000000000 + 
		(end.tv_sec - start.tv_sec);

	return time;
}

#endif

int main(int argc, char *argv[])
{
	int err = cudaSuccess;
	int i, j;
	int *h_log, *d_log;
	int *h_pkts_cpu;
	/**< Separate packet buffer to compare GPU's result with the CPU's */
	int *h_pkts_gpu, *d_pkts_gpu;

	srand(time(NULL));

	printDeviceProperties();

	/**< Initialize a cudaStream for async calls */
	err = cudaStreamCreate(&myStream);
	CPE(err != cudaSuccess, "Failed to create cudaStream\n", -1);

	/**< Initialize hugepage log and copy it to the device: do it once */
	red_printf("Allocating host log of size %lu bytes\n", LOG_CAP * sizeof(int));

	int sid = shmget(1, LOG_CAP * sizeof(int), SHM_HUGETLB | 0666 | IPC_CREAT);
	assert(sid >= 0);
	h_log = (int *) shmat(sid, 0, 0);
	assert(h_log != NULL);

	init_ht_log(h_log, LOG_CAP);

	red_printf("Allocating device log\n");
	err = cudaMalloc((void **) &d_log, LOG_CAP * sizeof(int));
	CPE(err != cudaSuccess, "Failed to allocate log on device\n", -1);

	red_printf("Copying log to device\n");
	err = cudaMemcpy(d_log, h_log, LOG_CAP * sizeof(int), cudaMemcpyHostToDevice);
	CPE(err != cudaSuccess, "Failed to copy to device memory\n", -1);

	/**< Initialize the packet arrays for CPU and GPU code */
	h_pkts_cpu = (int *) malloc(GPU_MAX_PKTS * sizeof(int));

	/**< The host packet-array for GPU code should be pinned */
	err = cudaMallocHost((void **) &h_pkts_gpu, GPU_MAX_PKTS * sizeof(int));
	err = cudaMalloc((void **) &d_pkts_gpu, GPU_MAX_PKTS * sizeof(int));

	/**< Test for different batch sizes */
	assert(GPU_MAX_PKTS % 8 == 0);
	for(int num_pkts = 16; num_pkts < GPU_MAX_PKTS; num_pkts *= 2) {

		double cpu_time = 0, gpu_time = 0;
	
		/**< Perform several measurements for averaging */
		for(i = 0; i < GPU_ITERS; i ++) {

			/**< Generate a different set of packets for each iteration */
			for(j = 0; j < num_pkts; j ++) {
				h_pkts_cpu[j] = rand() & LOG_CAP_;
				h_pkts_gpu[j] = h_pkts_cpu[j];
			}

			cpu_time += cpu_run(h_pkts_cpu, h_log, num_pkts);
			gpu_time += gpu_run(h_pkts_gpu, d_pkts_gpu, d_log, num_pkts);
		}
		
		cpu_time = cpu_time / GPU_ITERS;
		gpu_time = gpu_time / GPU_ITERS;
	
		/**< Verify that the result vector is correct */
		for(int i = 0; i < num_pkts; i ++) {
			if (h_pkts_cpu[i] != h_pkts_gpu[i]) {
				fprintf(stderr, "Result verification failed at element %d!\n", i);
				fprintf(stderr, "CPU %d, GPU %d\n", h_pkts_cpu[i], h_pkts_gpu[i]);
				exit(-1);
			}
		}
	
		printf("PASS for num_pkts = %d\n", num_pkts);

		/**< Print the number of packets processed per second */
		printf("num_pkts %d CPU %.2f GPU %.2f\n", num_pkts,
			num_pkts / (cpu_time * 1000000),
			num_pkts / (gpu_time * 1000000));

		printf("\n");
	}

	/**< Free device memory */
	cudaFree(d_pkts_gpu);
	cudaFree(d_log);

	/**< Free host memory */
	free(h_pkts_cpu);
	cudaFreeHost(h_pkts_gpu);
	free(h_log);

	/**< Reset the device and exit */
	err = cudaDeviceReset();
	CPE(err != cudaSuccess, "Failed to de-initialize the device\n", -1);

	printf("Done\n");
	return 0;
}

