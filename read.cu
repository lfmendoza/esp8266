#include <iostream>
#include <vector>
#include <string>
#include <sstream>
#include <curl/curl.h>
#include <cuda_runtime.h>
#include <cmath>

using namespace std;

// Callback function for writing data received
size_t WriteCallback(void* contents, size_t size, size_t nmemb, void* userp) {
    ((string*)userp)->append((char*)contents, size * nmemb);
    return size * nmemb;
}

#define cudaCheckError(ans) { gpuAssert((ans), __FILE__, __LINE__); }
inline void gpuAssert(cudaError_t code, const char *file, int line, bool abort=true) {
   if (code != cudaSuccess) {
      fprintf(stderr, "GPUassert: %s %s %d\n", cudaGetErrorString(code), file, line);
      if (abort) exit(code);
   }
}

// Kernel 1: Reduce Sum Optimized
__global__ void reduceSumOptimized(float* input, float* output, int N) {
    extern __shared__ float sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x * 2 + threadIdx.x;

    sdata[tid] = (i < N ? input[i] : 0) + (i + blockDim.x < N ? input[i + blockDim.x] : 0);
    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) sdata[tid] += sdata[tid + s];
        __syncthreads();
    }

    if (tid == 0) output[blockIdx.x] = sdata[0];
}

// Kernel 2: Compute Mean
__global__ void computeMean(float* sum, float* mean, int size) {
    if (threadIdx.x == 0) {
        *mean = *sum / size;
    }
}

// Kernel 3: Compute Standard Deviation
__global__ void computeStdDev(float* data, float mean, float* stddev, int size) {
    extern __shared__ float sdata[];
    unsigned int tid = threadIdx.x;
    unsigned int i = blockIdx.x * blockDim.x + threadIdx.x;

    float diff = (i < size) ? (data[i] - mean) * (data[i] - mean) : 0;
    sdata[tid] = diff;
    __syncthreads();

    for (unsigned int s = blockDim.x / 2; s > 0; s >>= 1) {
        if (tid < s) sdata[tid] += sdata[tid + s];
        __syncthreads();
    }

    if (tid == 0) atomicAdd(stddev, sdata[0]);
}

// Kernel 4: Check Cultivation Feasibility
__global__ void checkFeasibility(float* results, int* feasibilityFlags, int numCultivos, float* limits) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < numCultivos) {
        int tempIndex = i * 6;
        feasibilityFlags[i] = (results[0] >= limits[tempIndex] && results[0] <= limits[tempIndex + 1] &&
                               results[1] >= limits[tempIndex + 2] && results[1] <= limits[tempIndex + 3] &&
                               results[2] >= limits[tempIndex + 4] && results[2] <= limits[tempIndex + 5]) ? 1 : 0;
    }
}

// Kernel 5: Compute Viability Index
__global__ void computeViabilityIndex(float* results, float* viabilityIndex, int numCultivos, float* limits) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < numCultivos) {
        int tempIndex = i * 6;
        float tempScore = (results[0] - limits[tempIndex]) / (limits[tempIndex + 1] - limits[tempIndex]);
        float humScore = (results[1] - limits[tempIndex + 2]) / (limits[tempIndex + 3] - limits[tempIndex + 2]);
        float luzScore = (results[2] - limits[tempIndex + 4]) / (limits[tempIndex + 5] - limits[tempIndex + 4]);
        viabilityIndex[i] = (tempScore + humScore + luzScore) / 3.0;
    }
}

int main() {
    // Initialize libcurl
    CURL* curl;
    CURLcode res;
    string readBuffer;

    curl = curl_easy_init();
    if (curl) {
        string sheet_id = "1WeLe9zO71zoKhkdj2usptbRQC0Gy6PT6_3CibpJ6gEU";
        string gid = "0";
        string url = "https://docs.google.com/spreadsheets/d/" + sheet_id + "/export?format=csv&gid=" + gid;

        curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
        curl_easy_setopt(curl, CURLOPT_FOLLOWLOCATION, 1L);
        curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, WriteCallback);
        curl_easy_setopt(curl, CURLOPT_WRITEDATA, &readBuffer);

        res = curl_easy_perform(curl);
        curl_easy_cleanup(curl);
    }

    // Parse CSV data
    vector<float> temperatures, humidities, intensities;
    stringstream sstream(readBuffer);
    string line;
    getline(sstream, line);  // Skip header
    while (getline(sstream, line)) {
        stringstream ss(line);
        string value;
        vector<string> row;
        while (getline(ss, value, ',')) row.push_back(value);

        if (row.size() >= 5) {
            temperatures.push_back(stof(row[1]));
            humidities.push_back(stof(row[2]));
            intensities.push_back(stof(row[3]));
        }
    }

    int N = temperatures.size();
    if (N == 0) {
        cout << "No data found." << endl;
        return 1;
    }

    // CUDA configuration
    float *d_data, *d_intermediate, *d_mean, *d_stddev, *d_viabilityIndex;
    vector<float> results(3);  // To store means
    int blockSize = 256;

    for (int i = 0; i < 3; ++i) {
        vector<float>& data = (i == 0 ? temperatures : (i == 1 ? humidities : intensities));
        cudaCheckError(cudaMalloc((void**)&d_data, data.size() * sizeof(float)));
        cudaCheckError(cudaMemcpy(d_data, data.data(), data.size() * sizeof(float), cudaMemcpyHostToDevice));

        int gridSize = (data.size() + blockSize * 2 - 1) / (blockSize * 2);
        cudaCheckError(cudaMalloc((void**)&d_intermediate, gridSize * sizeof(float)));
        reduceSumOptimized<<<gridSize, blockSize, blockSize * sizeof(float)>>>(d_data, d_intermediate, data.size());
        cudaCheckError(cudaDeviceSynchronize());

        // Reduce on CPU
        vector<float> h_intermediate(gridSize);
        cudaCheckError(cudaMemcpy(h_intermediate.data(), d_intermediate, gridSize * sizeof(float), cudaMemcpyDeviceToHost));
        float totalSum = 0.0f;
        for (float val : h_intermediate) totalSum += val;

        results[i] = round(totalSum / data.size());  // Correct mean calculation

        // Compute standard deviation
        cudaCheckError(cudaMalloc((void**)&d_stddev, sizeof(float)));
        cudaCheckError(cudaMemset(d_stddev, 0, sizeof(float)));
        computeStdDev<<<gridSize, blockSize, blockSize * sizeof(float)>>>(d_data, results[i], d_stddev, data.size());
        cudaCheckError(cudaDeviceSynchronize());
        float stddev;
        cudaCheckError(cudaMemcpy(&stddev, d_stddev, sizeof(float), cudaMemcpyDeviceToHost));
        stddev = sqrt(stddev / data.size());
        cout << "Desviación Estándar (" << (i == 0 ? "Temperatura" : (i == 1 ? "Humedad" : "Intensidad")) << "): " << stddev << endl;

        cudaFree(d_data);
        cudaFree(d_intermediate);
        cudaFree(d_stddev);
    }

    // Crop data
    struct Cultivo {
        string nombre;
        int minTemp, maxTemp, minHum, maxHum, minLuz, maxLuz;
    };

    vector<Cultivo> cultivos = {
        {"Cafe", 18, 24, 60, 80, 40, 60},
        {"Maiz", 20, 30, 50, 70, 50, 100},
        {"Frijol", 15, 25, 50, 70, 60, 80},
        {"Arroz", 24, 35, 70, 90, 60, 80},
        {"Trigo", 10, 25, 30, 50, 60, 80},
    };

    int numCultivos = cultivos.size();
    vector<int> feasibilityFlags(numCultivos);
    vector<float> viabilityIndexes(numCultivos);
    vector<float> limits;

    for (const auto& cultivo : cultivos) {
        limits.push_back(cultivo.minTemp);
        limits.push_back(cultivo.maxTemp);
        limits.push_back(cultivo.minHum);
        limits.push_back(cultivo.maxHum);
        limits.push_back(cultivo.minLuz);
        limits.push_back(cultivo.maxLuz);
    }

    float* d_limits;
    cudaCheckError(cudaMalloc((void**)&d_limits, limits.size() * sizeof(float)));
    cudaCheckError(cudaMalloc((void**)&d_viabilityIndex, numCultivos * sizeof(float)));
    cudaCheckError(cudaMemcpy(d_limits, limits.data(), limits.size() * sizeof(float), cudaMemcpyHostToDevice));

    float* d_results;
    int* d_feasibilityFlags;
    cudaCheckError(cudaMalloc((void**)&d_results, results.size() * sizeof(float)));
    cudaCheckError(cudaMalloc((void**)&d_feasibilityFlags, numCultivos * sizeof(int)));
    cudaCheckError(cudaMemcpy(d_results, results.data(), results.size() * sizeof(float), cudaMemcpyHostToDevice));

    // Kernel 4: Check feasibility
    checkFeasibility<<<1, numCultivos>>>(d_results, d_feasibilityFlags, numCultivos, d_limits);
    cudaCheckError(cudaMemcpy(feasibilityFlags.data(), d_feasibilityFlags, numCultivos * sizeof(int), cudaMemcpyDeviceToHost));

    // Kernel 5: Compute viability index
    computeViabilityIndex<<<1, numCultivos>>>(d_results, d_viabilityIndex, numCultivos, d_limits);
    cudaCheckError(cudaMemcpy(viabilityIndexes.data(), d_viabilityIndex, numCultivos * sizeof(float), cudaMemcpyDeviceToHost));

    vector<string> aptos, noAptos;
    for (int i = 0; i < numCultivos; ++i) {
        if (feasibilityFlags[i]) {
            aptos.push_back(cultivos[i].nombre);
        } else {
            noAptos.push_back(cultivos[i].nombre);
        }
        cout << "Índice de Viabilidad (" << cultivos[i].nombre << "): " << viabilityIndexes[i] << endl;
    }

    // Print final results
    cout << "Media Temperatura: " << results[0] << "°C" << endl;
    cout << "Media Humedad: " << results[1] << "%" << endl;
    cout << "Media Intensidad de Luz: " << results[2] << "%" << endl;

    cout << "Se pueden cultivar: ";
    for (const auto& cultivo : aptos) cout << cultivo << ", ";
    cout << endl;

    cout << "No se pueden cultivar: ";
    for (const auto& cultivo : noAptos) cout << cultivo << ", ";
    cout << endl;

    cudaFree(d_limits);
    cudaFree(d_results);
    cudaFree(d_feasibilityFlags);
    cudaFree(d_viabilityIndex);

    return 0;
}
