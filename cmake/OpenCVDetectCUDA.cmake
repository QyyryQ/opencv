if(${CMAKE_VERSION} VERSION_LESS "2.8.3")
  message(STATUS "WITH_CUDA flag requires CMake 2.8.3 or newer. CUDA support is disabled.")
  return()
endif()

if(WIN32 AND NOT MSVC)
  message(STATUS "CUDA compilation is disabled (due to only Visual Studio compiler suppoted on your platform).")
  return()
endif()

if(CMAKE_COMPILER_IS_GNUCXX AND NOT APPLE AND CMAKE_CXX_COMPILER_ID STREQUAL "Clang")
  message(STATUS "CUDA compilation is disabled (due to Clang unsuppoted on your platform).")
  return()
endif()

find_package(CUDA 4.2)

if(CUDA_FOUND)
  set(HAVE_CUDA 1)

  if(WITH_CUFFT)
    set(HAVE_CUFFT 1)
  endif()

  if(WITH_CUBLAS)
    set(HAVE_CUBLAS 1)
  endif()

  if(WITH_NVCUVID)
    find_cuda_helper_libs(nvcuvid)
    set(HAVE_NVCUVID 1)
  endif()

  message(STATUS "CUDA detected: " ${CUDA_VERSION})

  if (CARMA)
    set(CUDA_ARCH_BIN "2.1(2.0) 3.0" CACHE STRING "Specify 'real' GPU architectures to build binaries for, BIN(PTX) format is supported")
    set(CUDA_ARCH_PTX "3.0" CACHE STRING "Specify 'virtual' PTX architectures to build PTX intermediate code for")
  else()
    set(CUDA_ARCH_BIN "1.1 1.2 1.3 2.0 2.1(2.0) 3.0" CACHE STRING "Specify 'real' GPU architectures to build binaries for, BIN(PTX) format is supported")
    set(CUDA_ARCH_PTX "2.0 3.0" CACHE STRING "Specify 'virtual' PTX architectures to build PTX intermediate code for")
  endif()

  string(REGEX REPLACE "\\." "" ARCH_BIN_NO_POINTS "${CUDA_ARCH_BIN}")
  string(REGEX REPLACE "\\." "" ARCH_PTX_NO_POINTS "${CUDA_ARCH_PTX}")

  # Ckeck if user specified 1.0 compute capability: we don't support it
  string(REGEX MATCH "1.0" HAS_ARCH_10 "${CUDA_ARCH_BIN} ${CUDA_ARCH_PTX}")
  set(CUDA_ARCH_BIN_OR_PTX_10 0)
  if(NOT ${HAS_ARCH_10} STREQUAL "")
    set(CUDA_ARCH_BIN_OR_PTX_10 1)
  endif()

  # NVCC flags to be set
  set(NVCC_FLAGS_EXTRA "")

  # These vars will be passed into the templates
  set(OPENCV_CUDA_ARCH_BIN "")
  set(OPENCV_CUDA_ARCH_PTX "")
  set(OPENCV_CUDA_ARCH_FEATURES "")

  # Tell NVCC to add binaries for the specified GPUs
  string(REGEX MATCHALL "[0-9()]+" ARCH_LIST "${ARCH_BIN_NO_POINTS}")
  foreach(ARCH IN LISTS ARCH_LIST)
    if(ARCH MATCHES "([0-9]+)\\(([0-9]+)\\)")
      # User explicitly specified PTX for the concrete BIN
      set(NVCC_FLAGS_EXTRA ${NVCC_FLAGS_EXTRA} -gencode arch=compute_${CMAKE_MATCH_2},code=sm_${CMAKE_MATCH_1})
      set(OPENCV_CUDA_ARCH_BIN "${OPENCV_CUDA_ARCH_BIN} ${CMAKE_MATCH_1}")
      set(OPENCV_CUDA_ARCH_FEATURES "${OPENCV_CUDA_ARCH_FEATURES} ${CMAKE_MATCH_2}")
    else()
      # User didn't explicitly specify PTX for the concrete BIN, we assume PTX=BIN
      set(NVCC_FLAGS_EXTRA ${NVCC_FLAGS_EXTRA} -gencode arch=compute_${ARCH},code=sm_${ARCH})
      set(OPENCV_CUDA_ARCH_BIN "${OPENCV_CUDA_ARCH_BIN} ${ARCH}")
      set(OPENCV_CUDA_ARCH_FEATURES "${OPENCV_CUDA_ARCH_FEATURES} ${ARCH}")
    endif()
  endforeach()

  # Tell NVCC to add PTX intermediate code for the specified architectures
  string(REGEX MATCHALL "[0-9]+" ARCH_LIST "${ARCH_PTX_NO_POINTS}")
  foreach(ARCH IN LISTS ARCH_LIST)
    set(NVCC_FLAGS_EXTRA ${NVCC_FLAGS_EXTRA} -gencode arch=compute_${ARCH},code=compute_${ARCH})
    set(OPENCV_CUDA_ARCH_PTX "${OPENCV_CUDA_ARCH_PTX} ${ARCH}")
    set(OPENCV_CUDA_ARCH_FEATURES "${OPENCV_CUDA_ARCH_FEATURES} ${ARCH}")
  endforeach()

  if(CARMA)
    set(CUDA_NVCC_FLAGS "${CUDA_NVCC_FLAGS} --target-cpu-architecture=ARM" )

    if (CMAKE_VERSION VERSION_LESS 2.8.10)
      set(CUDA_NVCC_FLAGS "${CUDA_NVCC_FLAGS} -ccbin=${CMAKE_CXX_COMPILER}" )
    endif()

  endif()

  # These vars will be processed in other scripts
  set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} ${NVCC_FLAGS_EXTRA})
  set(OpenCV_CUDA_CC "${NVCC_FLAGS_EXTRA}")

  message(STATUS "CUDA NVCC target flags: ${CUDA_NVCC_FLAGS}")

  OCV_OPTION(CUDA_FAST_MATH "Enable --use_fast_math for CUDA compiler " OFF)

  if(CUDA_FAST_MATH)
    set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} --use_fast_math)
  endif()

  mark_as_advanced(CUDA_BUILD_CUBIN CUDA_BUILD_EMULATION CUDA_VERBOSE_BUILD CUDA_SDK_ROOT_DIR)

  find_cuda_helper_libs(npp)

  macro(ocv_cuda_compile VAR)
    foreach(var CMAKE_CXX_FLAGS CMAKE_CXX_FLAGS_RELEASE CMAKE_CXX_FLAGS_DEBUG)
      set(${var}_backup_in_cuda_compile_ "${${var}}")

      # we reomove /EHa as it leasd warnings under windows
      string(REPLACE "/EHa" "" ${var} "${${var}}")

      # we remove -ggdb3 flag as it leads to preprocessor errors when compiling CUDA files (CUDA 4.1)
      string(REPLACE "-ggdb3" "" ${var} "${${var}}")
    endforeach()

    if(BUILD_SHARED_LIBS)
      set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xcompiler -DCVAPI_EXPORTS)
    endif()

    if(UNIX OR APPLE)
      set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xcompiler -fPIC)
    endif()
    if(APPLE)
      set(CUDA_NVCC_FLAGS ${CUDA_NVCC_FLAGS} -Xcompiler -fno-finite-math-only)
    endif()

    # disabled because of multiple warnings during building nvcc auto generated files
    if(CMAKE_COMPILER_IS_GNUCXX AND CMAKE_GCC_REGEX_VERSION VERSION_GREATER "4.6.0")
      ocv_warnings_disable(CMAKE_CXX_FLAGS -Wunused-but-set-variable)
    endif()

    CUDA_COMPILE(${VAR} ${ARGN})

    foreach(var CMAKE_CXX_FLAGS CMAKE_CXX_FLAGS_RELEASE CMAKE_CXX_FLAGS_DEBUG)
      set(${var} "${${var}_backup_in_cuda_compile_}")
      unset(${var}_backup_in_cuda_compile_)
    endforeach()
  endmacro()
else()
  unset(CUDA_ARCH_BIN CACHE)
  unset(CUDA_ARCH_PTX CACHE)
endif()
