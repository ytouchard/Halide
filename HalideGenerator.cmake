include(CMakeParseArguments)

# This function returns the intermediate output directory where the Halide
# generator output will be placed. This path is automatically added to the
# library path and include path of the specified target. This function can be
# used to determine the location of the other output files like the bit code and
# html.
function(halide_generator_output_path args_GENERATOR_NAME result_var)
  # Convert the binary dir to a native path
  file(TO_NATIVE_PATH "${CMAKE_CURRENT_BINARY_DIR}/" NATIVE_INT_DIR)

  # Create a directory to contain generator specific intermediate files
  set(scratch_dir "${NATIVE_INT_DIR}scratch_${args_GENERATOR_NAME}")
  file(MAKE_DIRECTORY "${scratch_dir}")

  # Set the output variable
  set(${result_var} "${scratch_dir}" PARENT_SCOPE)
endfunction(halide_generator_output_path)

# This function adds custom build steps to invoke a Halide generator exectuable,
# produce a static library containing the generated code, and then link that
# static library to the specified target.
# The generator executable must be produced separately, e.g. using a call to the
# function halide_project(...) or add_executable(...) and passed to this
# function in the GENERATOR_TARGET parameter.
#
# Usage:
#   halide_add_generator_dependency(TARGET <app name>
#                                   GENERATOR_TARGET <new target>
#                                   GENERATOR_NAME <string>
#                                   GENERATED_FUNCTION <string>
#                                   GENERATED_FUNCTION_NAMESPACE <string>
#                                   GENERATOR_ARGS <arg> <arg> ...
#                                   [TARGET_SUFFIX <string>]
#                                   [OUTPUT_LIB_VAR <var>]
#                                   [OUTPUT_TARGET_VAR <var>])
#
#   TARGET is the name of the app or test target that the generator
#     invocation target should be added to. Can either be a ordinary or Utility
#     cmake target created by halide_project(), add_executable(), etc.
#   GENERATOR_TARGET is the name of the generator executable target.
#   TARGET_SUFFIX is an optional string to make this target unique.
#   GENERATOR_NAME is the C++ class name of the Halide::Generator derived object
#   GENERATED_FUNCTION is the name of the C function to be generated by Halide
#   GENERATED_FUNCTION_NAMESPACE is the C++ namespace to generate the function in. Should end in "::"
#   GENERATOR_ARGS are extra arguments passed to the generator executable during
#     build for example, "-e html target=host-opengl"
#   OUTPUT_LIB_VAR is the output variable that will be set to the path of the
#     halide generated library. Use this to add the output to Utility targets.
#   OUTPUT_TARGET_VAR is the output variable that will be set to the name of the
#     target created by this function to invoke the generator. It is
#     automatically added as a dependency to ordinary non-Utility cmake targets.
function(halide_add_generator_dependency)

  # Parse arguments
  set(options )
  set(oneValueArgs TARGET GENERATOR_TARGET TARGET_SUFFIX GENERATOR_NAME GENERATED_FUNCTION GENERATED_FUNCTION_NAMESPACE OUTPUT_LIB_VAR OUTPUT_TARGET_VAR)
  set(multiValueArgs GENERATOR_ARGS)
  cmake_parse_arguments(args "" "${oneValueArgs}" "${multiValueArgs}" ${ARGN} )

  set(unique_generator_target "${args_GENERATOR_NAME}${args_TARGET_SUFFIX}")

  # Determine a scratch directory to build and execute the generator. ${args_TARGET}
  # will include the generated header from this directory.
  halide_generator_output_path(${unique_generator_target} SCRATCH_DIR)

  # Determine the name of the output files
  set(FILTER_LIB "${args_GENERATED_FUNCTION}${CMAKE_STATIC_LIBRARY_SUFFIX}")
  set(FILTER_HDR "${args_GENERATED_FUNCTION}.h")

  # Check to see if the target includes pnacl
  if ("${args_GENERATOR_ARGS}" MATCHES ".*pnacl.*")
    set(FILTER_LIB "${args_GENERATED_FUNCTION}.bc")
    set(target_is_pnacl TRUE)
  endif()

  set(invoke_args "-g" "${args_GENERATOR_NAME}" "-f" "${args_GENERATED_FUNCTION_NAMESPACE}${args_GENERATED_FUNCTION}" "-o" "${SCRATCH_DIR}" ${args_GENERATOR_ARGS})
  set(generator_exec ${args_GENERATOR_TARGET}${CMAKE_EXECUTABLE_SUFFIX})

  # Add a custom target to invoke the GENERATOR_TARGET and output the Halide
  # generated library
  if (MSVC)
    add_custom_command(OUTPUT "${SCRATCH_DIR}/${FILTER_LIB}" "${SCRATCH_DIR}/${FILTER_HDR}"
                              "${SCRATCH_DIR}/${args_GENERATED_FUNCTION}.lib"
      DEPENDS "${args_GENERATOR_TARGET}"
      COMMAND "${CMAKE_BINARY_DIR}/bin/${CMAKE_CFG_INTDIR}/${generator_exec}" ${invoke_args}
      COMMAND "lib.exe" "/OUT:${FILTER_LIB}" "${SCRATCH_DIR}\\${args_GENERATED_FUNCTION}.lib"
      WORKING_DIRECTORY "${SCRATCH_DIR}"
      )
  elseif(XCODE)
    add_custom_command(OUTPUT "${SCRATCH_DIR}/${FILTER_LIB}" "${SCRATCH_DIR}/${FILTER_HDR}"
      DEPENDS "${args_GENERATOR_TARGET}"

      # The generator executable will be placed in a configuration specific
      # directory, so the Xcode variable $(CONFIGURATION) is passed in the custom
      # build script.
      COMMAND "${CMAKE_BINARY_DIR}/bin/$(CONFIGURATION)/${generator_exec}" ${invoke_args}

      WORKING_DIRECTORY "${SCRATCH_DIR}"
      )
  elseif(target_is_pnacl)
    # No archive step for pnacl targets
    add_custom_command(OUTPUT "${SCRATCH_DIR}/${FILTER_LIB}" "${SCRATCH_DIR}/${FILTER_HDR}"
      DEPENDS "${args_GENERATOR_TARGET}"
      COMMAND "${CMAKE_BINARY_DIR}/bin/${generator_exec}" ${invoke_args}
      WORKING_DIRECTORY "${SCRATCH_DIR}"
      )
  else()
    add_custom_command(OUTPUT "${SCRATCH_DIR}/${FILTER_LIB}" "${SCRATCH_DIR}/${FILTER_HDR}"
      DEPENDS "${args_GENERATOR_TARGET}"
      COMMAND "${CMAKE_BINARY_DIR}/bin/${generator_exec}" ${invoke_args}
      WORKING_DIRECTORY "${SCRATCH_DIR}"
      )
  endif()

  # Use a custom target to force it to run the generator before the
  # object file for the runner. The target name will start with the prefix
  #  "exec_generator_"
  set(exec_generator_target "exec_generator_${unique_generator_target}_${args_GENERATED_FUNCTION}")
  add_custom_target(${exec_generator_target}
                    DEPENDS "${SCRATCH_DIR}/${FILTER_LIB}" "${SCRATCH_DIR}/${FILTER_HDR}"
                    )

  # Place the target in a special folder in IDEs
  set_target_properties(${exec_generator_target} PROPERTIES
                        FOLDER "generator"
                        )

  # Associate the generator invocation target with the main app target
  if (TARGET "${args_TARGET}")

    # Make the generator invocation target run before the app target is built
    add_dependencies("${args_TARGET}" ${exec_generator_target})

    # Check if it is safe to call target_link_libraries on the target
    get_target_property(target_type "${args_TARGET}" TYPE)
    if (NOT (${target_type} MATCHES "UTILITY"))

      target_link_libraries("${args_TARGET}" "${SCRATCH_DIR}/${FILTER_LIB}")

      # Add the scratch directory to the include path for ${args_TARGET}. The generated
      # header may be included via #include "${args_GENERATOR_NAME}.h"
      target_include_directories("${args_TARGET}" PRIVATE "${SCRATCH_DIR}")
    endif()

  endif()

  # Set the output vars
  if (NOT ${args_OUTPUT_LIB_VAR} STREQUAL "")
    set(${args_OUTPUT_LIB_VAR} "${SCRATCH_DIR}/${FILTER_LIB}" PARENT_SCOPE)
  endif()

  if (NOT ${args_OUTPUT_TARGET_VAR} STREQUAL "")
    set(${args_OUTPUT_TARGET_VAR} ${exec_generator_target} PARENT_SCOPE)
  endif()

endfunction(halide_add_generator_dependency)
