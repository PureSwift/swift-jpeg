# Builds the installable artifact.
#
# SwiftPM drives development, the Swift library and the tests, but it cannot set
# a soname, an install name, or an export list — and those are exactly what make
# one library substitutable for another. So the shared object that gets
# installed is built here instead.
#
# CMake compiles Swift only under the Ninja and Xcode generators, and no single
# target may mix Swift with another language, so each Swift module builds as its
# own static archive and the shared library links them together.

cmake_minimum_required(VERSION 3.29)  # CMP0157, for Swift compilation mode

# C is enabled even though there are no C sources: GNUInstallDirs cannot pick
# between lib and lib64 without a language to infer the target architecture
# from, and getting that wrong installs to the wrong path on multilib systems.
# The ABI phase will want a C target for the vendored header regardless.
project(swift-jpeg
    VERSION 0.1.0
    DESCRIPTION "libturbojpeg, implemented in Swift"
    LANGUAGES C Swift)

set(CMAKE_C_STANDARD 99)
set(CMAKE_C_STANDARD_REQUIRED ON)

include(GNUInstallDirs)

option(SWIFT_JPEG_STATIC_STDLIB
    "Link the Swift runtime statically, so the library needs no toolchain at run time" OFF)

# The ABI being replaced. This is libjpeg-turbo's number, not this project's:
# clients bind against it, so it is part of the contract rather than a version
# we are free to choose. The project version above moves independently.
set(TURBOJPEG_ABI_SONAME 0)

set(TURBOJPEG_VERSION_SCRIPT ${CMAKE_CURRENT_SOURCE_DIR}/scripts/turbojpeg.vers)
set(TURBOJPEG_EXPORT_LIST ${CMAKE_CURRENT_SOURCE_DIR}/scripts/turbojpeg.exp)

# Whole-module optimization matters once a hot path crosses files: the inlining
# that erases those boundaries is much of what would keep this competitive with
# the C implementation.
set(SWIFT_JPEG_COMPILATION_MODE $<IF:$<CONFIG:Release>,wholemodule,incremental>)

# -- Swift modules -----------------------------------------------------------
#
# One CMake target per module, mirroring the SwiftPM layout, so the same import
# lines work under both build systems. Keeping them separate rather than
# compiling every source into one blob is also what leaves the engine
# structurally unable to reach the C API by accident.

function(swift_jpeg_add_module name)
    file(GLOB_RECURSE sources CONFIGURE_DEPENDS
        ${CMAKE_CURRENT_SOURCE_DIR}/Sources/${name}/*.swift)

    add_library(${name} STATIC ${sources})

    set_target_properties(${name} PROPERTIES
        POSITION_INDEPENDENT_CODE ON
        Swift_MODULE_NAME ${name}
        Swift_COMPILATION_MODE ${SWIFT_JPEG_COMPILATION_MODE})
endfunction()

swift_jpeg_add_module(JPEG)

# -- the shared library ------------------------------------------------------
#
# libturbojpeg.so.0, made of two halves: the Swift boundary target for the
# symbols that are implemented, and generated C stubs for the rest. Together
# they cover the whole published API, so a client links and loads against this
# unchanged even though most of it is not written yet.
#
# Guarded so the engine still builds on its own if the boundary is absent.

set(TURBOJPEG_INCLUDE_DIR ${CMAKE_CURRENT_SOURCE_DIR}/Sources/CTurboJPEG/include)

if(EXISTS ${CMAKE_CURRENT_SOURCE_DIR}/Sources/TurboJPEGABI)
    swift_jpeg_add_module(TurboJPEGABI)
    target_link_libraries(TurboJPEGABI PUBLIC JPEG)
    # The boundary imports the vendored header as a Clang module, so the Swift
    # compiler needs both the search path and the module map.
    target_compile_options(TurboJPEGABI PRIVATE
        "SHELL:-Xcc -I${TURBOJPEG_INCLUDE_DIR}"
        "SHELL:-Xcc -fmodule-map-file=${TURBOJPEG_INCLUDE_DIR}/module.modulemap")

    # The generated stubs are the other half of the export table: everything
    # published but not yet implemented in Swift.
    add_library(turbojpeg SHARED
        Sources/CTurboJPEG/gen/stubs.c)
    target_include_directories(turbojpeg PRIVATE ${TURBOJPEG_INCLUDE_DIR})
    target_link_libraries(turbojpeg PRIVATE TurboJPEGABI)

    # Driving the link with swiftc is what pulls in the Swift runtime and the
    # metadata registration object the static archives depend on.
    set_target_properties(turbojpeg PROPERTIES
        LINKER_LANGUAGE Swift
        OUTPUT_NAME turbojpeg
        VERSION ${TURBOJPEG_ABI_SONAME}
        SOVERSION ${TURBOJPEG_ABI_SONAME})

    if(APPLE)
        set_target_properties(turbojpeg PROPERTIES
            INSTALL_NAME_DIR ${CMAKE_INSTALL_FULL_LIBDIR})

        # dyld refuses a library offering a lower compatibility version than the
        # client recorded, so this tracks libjpeg-turbo's rather than ours. The
        # MACHO_* target properties do not reach the link when swiftc drives it,
        # hence the raw flags.
        target_link_options(turbojpeg PRIVATE
            "LINKER:-compatibility_version,${TURBOJPEG_ABI_SONAME}"
            "LINKER:-current_version,${TURBOJPEG_ABI_SONAME}"
            # Without this the engine's Swift symbols would be exported too.
            "LINKER:-exported_symbols_list,${TURBOJPEG_EXPORT_LIST}")
    else()
        target_link_options(turbojpeg PRIVATE
            "LINKER:--version-script=${TURBOJPEG_VERSION_SCRIPT}")

        # The exported entry points live in the boundary archive and nothing
        # inside the library calls them, so an ELF link drops those objects as
        # unreferenced. ld64 resolves exports out of an archive; GNU ld only
        # versions what is already in the link, and the whole archive is what
        # the dynamic symbol table gets made from. The version script then hides
        # everything unpublished.
        #
        # The engine archive follows here rather than through
        # target_link_libraries because the driver emits linker options and
        # libraries in separate runs of the final command, and an archive
        # scanned before the whole-archive raised its undefined references
        # contributes nothing to them.
        target_link_options(turbojpeg PRIVATE
            "LINKER:--whole-archive,$<TARGET_FILE:TurboJPEGABI>,--no-whole-archive"
            "LINKER:$<TARGET_FILE:JPEG>")

        if(SWIFT_JPEG_STATIC_STDLIB)
            target_link_options(turbojpeg PRIVATE -static-stdlib)
        endif()
    endif()

    install(TARGETS turbojpeg LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR})

    # The export table is part of the contract, so it is checked at build time
    # and not only in CI.
    add_custom_command(TARGET turbojpeg POST_BUILD
        COMMAND ${CMAKE_CURRENT_SOURCE_DIR}/scripts/check-exports.sh
                $<TARGET_FILE:turbojpeg>
                ${CMAKE_CURRENT_SOURCE_DIR}/scripts/symbols.txt
        COMMENT "Checking exported symbols")
else()
    message(STATUS
        "Sources/TurboJPEGABI not present — building the engine only, no shared library")
endif()
