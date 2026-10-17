set(CMAKE_EXPORT_COMPILE_COMMANDS ON)
cmake_minimum_required(VERSION 3.16)
project(plistxx LANGUAGES CXX)

# ---- Options ----
option(BUILD_SHARED_LIBS "Build shared library (ON) or static (OFF)" ON)

set(PLIST_LIB_PATH
    "${CMAKE_CURRENT_SOURCE_DIR}/../../target/release/libplist.a"
    CACHE FILEPATH "Path to libplist (static or shared)")

set(PLIST_PUBLIC_INCLUDE_DIR "${CMAKE_CURRENT_SOURCE_DIR}/include")

# ---- Sources ----
file(GLOB_RECURSE PLISTXX_SOURCES CONFIGURE_DEPENDS
     "${CMAKE_CURRENT_SOURCE_DIR}/../src/*.cpp")

if(PLISTXX_SOURCES STREQUAL "")
  message(FATAL_ERROR "No C++ sources found under src/")
endif()

# ---- Library ----
add_library(plistxx ${PLISTXX_SOURCES})

if(WIN32)
  set_target_properties(plistxx PROPERTIES OUTPUT_NAME "plistxx-2.0")
else()
  set_target_properties(plistxx PROPERTIES OUTPUT_NAME "plist++-2.0")
endif()

set_target_properties(plistxx PROPERTIES
  CXX_STANDARD 17
  CXX_STANDARD_REQUIRED ON
  POSITION_INDEPENDENT_CODE ON
  SOVERSION 4
)

target_include_directories(plistxx
  PUBLIC
    "${PLIST_PUBLIC_INCLUDE_DIR}"
)

# Link to the Rust C ABI library
if(NOT EXISTS "${PLIST_LIB_PATH}")
  message(FATAL_ERROR "PLIST_LIB_PATH not found: ${PLIST_LIB_PATH}")
endif()

target_link_libraries(plistxx PRIVATE "${PLIST_LIB_PATH}")
