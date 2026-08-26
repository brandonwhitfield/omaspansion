cmake_minimum_required(VERSION 3.21)
project(omaspansion_typed_expander VERSION 0.1.0 LANGUAGES CXX)

find_package(Fcitx5Core REQUIRED)
include("${FCITX_INSTALL_CMAKECONFIG_DIR}/Fcitx5Utils/Fcitx5CompilerSettings.cmake")

add_library(omaspansionexpander SHARED typedexpander.cpp)
target_link_libraries(omaspansionexpander PRIVATE Fcitx5::Core)
set_target_properties(omaspansionexpander PROPERTIES PREFIX "")

include(CTest)
if(BUILD_TESTING)
  add_executable(candidatetracker_test candidatetracker_test.cpp)
  add_test(NAME candidatetracker_test COMMAND candidatetracker_test)
endif()
