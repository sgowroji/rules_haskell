"""Actions for compiling Haskell source code"""

load(":private/packages.bzl", "expose_packages", "pkg_info_to_compile_flags")
load("@bazel_skylib//lib:dicts.bzl", "dicts")
load("@bazel_skylib//lib:paths.bzl", "paths")
load(":private/packages.bzl", "ghc_pkg_recache", "write_package_conf")
load(
    ":private/path_utils.bzl",
    "declare_compiled",
    "get_dirname",
    "get_lib_name",
    "module_name",
    "target_unique_name",
)
load(":private/pkg_id.bzl", "pkg_id")
load(":private/version_macros.bzl", "version_macro_includes")
load(
    ":providers.bzl",
    "GhcPluginInfo",
    "HaskellImportHack",
    "get_ghci_extra_libs",
    "get_libs_for_ghc_linker",
    "merge_HaskellCcInfo",
)
load(":private/set.bzl", "set")

def _process_hsc_file(hs, cc, hsc_flags, hsc_inputs, hsc_file):
    """Process a single hsc file.

    Args:
      hs: Haskell context.
      cc: CcInteropInfo, information about C dependencies.
      hsc_flags: extra flags to pass to hsc2hs
      hsc_inputs: extra file inputs for the hsc2hs command
      hsc_file: hsc file to process.

    Returns:
      (File, string): Haskell source file created by processing hsc_file and
         new import directory containing the produced file.
    """
    args = hs.actions.args()

    # Output a Haskell source file.
    hsc_dir_raw = paths.join("_hsc", hs.name)
    hs_out = declare_compiled(hs, hsc_file, ".hs", directory = hsc_dir_raw)
    args.add_all([hsc_file.path, "-o", hs_out.path])

    args.add_all(["-c", cc.tools.cc])
    args.add_all(["-l", cc.tools.cc])
    args.add("-ighcplatform.h")
    args.add("-ighcversion.h")
    args.add_all(
        hs.toolchain.hdrs,
        map_each = get_dirname,
        format_each = "-I%s",
        uniquify = True,
    )
    # XXX: Use cc_info
    args.add_all(["--cflag=" + f for f in cc.cpp_flags])
    args.add_all(["--cflag=" + f for f in cc.compiler_flags])
    args.add_all(["--cflag=" + f for f in cc.include_args])
    args.add_all(["--lflag=" + f for f in cc.linker_flags])
    args.add_all(hsc_flags)

    # Add an empty PATH variable if not already specified in hs.env.
    # Needed to avoid a "Couldn't read PATH" error on Windows.
    #
    # On Unix platforms, though, we musn't set PATH as it is automatically set up
    # by the run action, unless already set in the env parameter. This triggers
    # build errors when using GHC bindists on Linux.
    if hs.env.get("PATH") == None and hs.toolchain.is_windows:
        hs.env["PATH"] = ""

    hs.actions.run(
        inputs = depset(transitive = [
            depset(hs.toolchain.hdrs),
            depset(cc.hdrs),
            depset([hsc_file]),
            depset(cc.files),
            depset(hsc_inputs),
        ]),
        outputs = [hs_out],
        mnemonic = "HaskellHsc2hs",
        executable = hs.tools.hsc2hs,
        arguments = [args],
        env = hs.env,
    )

    idir = paths.join(
        hs.bin_dir.path,
        hs.label.package,
        hsc_dir_raw,
    )

    return hs_out, idir

def _compilation_defaults(hs, cc, java, dep_info, plugin_dep_info, srcs, import_dir_map, extra_srcs, user_compile_flags, with_profiling, my_pkg_id, version, plugins):
    """Compute variables common to all compilation targets (binary and library).

    Returns:
      struct with the following fields:
        args: default argument list
        compile_flags: arguments that were used to compile the package
        inputs: default inputs
        input_manifests: input manifests
        outputs: default outputs
        objects_dir: object files directory
        interfaces_dir: interface files directory
        source_files: set of files that contain Haskell modules
        extra_source_files: depset of non-Haskell source files
        import_dirs: c2hs Import hierarchy roots
        env: default environment variables
    """

    compile_flags = []

    # GHC expects the CC compiler as the assembler, but segregates the
    # set of flags to pass to it when used as an assembler. So we have
    # to set both -optc and -opta.
    #cc_args = [
    #    "-optc" + f
    #    for f in cc.compiler_flags
    #] + [
    #    "-opta" + f
    #    for f in cc.compiler_flags
    #]
    #compile_flags += cc_args

    interface_dir_raw = "_iface"
    object_dir_raw = "_obj"

    # Declare file directories.
    #
    # NOTE: We could have used -outputdir here and a single output
    # directory. But keeping interface and object files separate has
    # one advantage: if interface files are invariant under
    # a particular code change, then we don't need to rebuild
    # downstream.
    if my_pkg_id:
        # If we're compiling a package, put the interfaces inside the
        # package directory.
        interfaces_dir = hs.actions.declare_directory(
            paths.join(
                pkg_id.to_string(my_pkg_id),
                interface_dir_raw,
            ),
        )
    else:
        interfaces_dir = hs.actions.declare_directory(
            paths.join(interface_dir_raw, hs.name),
        )
    objects_dir = hs.actions.declare_directory(
        paths.join(object_dir_raw, hs.name),
    )

    # Default compiler flags.
    compile_flags += hs.toolchain.compiler_flags
    compile_flags += user_compile_flags

    # Work around macOS linker limits.  This fix has landed in GHC HEAD, but is
    # not yet in a release; plus, we still want to support older versions of
    # GHC.  For details, see: https://phabricator.haskell.org/D4714
    if hs.toolchain.is_darwin:
        compile_flags += ["-optl-Wl,-dead_strip_dylibs"]

    # GHC will pass all `-l` `-optl` flags to gcc before the object files. This
    # would cause missing symbol errors in case of static linking. To work
    # around this we create a dummy package configuration containing all
    # required linker flags so that they appear in the right place on the gcc
    # command line.
    ghci_extra_libs = get_ghci_extra_libs(hs, dep_info.cc_info)
    # XXX: What to do with plugin_dep_info.cc_info?
    # ghci_extra_libs += get_ghci_extra_libs(hs, plugin_dep_info.cc_info)
    conf_file = hs.actions.declare_file(paths.join(
        target_unique_name(hs, "compile.db"),
        "compile.conf",
    ))
    pkg_name = target_unique_name(hs, "compile").replace("_", "-")
    system_libraries = [
        opt[2:]
        for opt in dep_info.cc_info.linking_context.user_link_flags
        if opt.startswith("-l")
    ]
    system_library_dirs = [
        opt[2:]
        for opt in dep_info.cc_info.linking_context.user_link_flags
        if opt.startswith("-L")
    ]
    write_package_conf(hs, conf_file, {
        "name": pkg_name,
        "id": pkg_name,
        "include-dirs": depset(transitive = [
            depset([hdr.dirname for hdr in hs.toolchain.hdrs]),
            dep_info.cc_info.compilation_context.includes,
            plugin_dep_info.cc_info.compilation_context.includes,
        ]),
        "cc-defines": depset(transitive = [
            dep_info.cc_info.compilation_context.defines,
            plugin_dep_info.cc_info.compilation_context.defines,
        ]),
        "cc-quote-includes": depset(transitive = [
            dep_info.cc_info.compilation_context.quote_includes,
            plugin_dep_info.cc_info.compilation_context.quote_includes,
        ]),
        "cc-system-includes": depset(transitive = [
            dep_info.cc_info.compilation_context.system_includes,
            plugin_dep_info.cc_info.compilation_context.system_includes,
        ]),
        # XXX: Follow link_binary/library example
        "extra-ghci-libraries": [get_lib_name(lib) for lib in ghci_extra_libs] + system_libraries,
        "library-dirs": [lib.dirname for lib in ghci_extra_libs] + system_library_dirs,
    })
    cache_file = ghc_pkg_recache(hs, hs.tools.ghc_pkg, conf_file)
    compile_flags += [
        "-no-global-package-db",
        "-package-db", cache_file.dirname,
        "-package", pkg_name,
    ]

    compile_flags.extend(
        pkg_info_to_compile_flags(
            expose_packages(
                dep_info.hs_info,
                lib_info = None,
                use_direct = True,
                use_my_pkg_id = my_pkg_id,
                custom_package_databases = None,
                version = version,
            ),
        ),
    )
    compile_flags.extend(
        pkg_info_to_compile_flags(
            expose_packages(
                plugin_dep_info.hs_info,
                lib_info = None,
                use_direct = True,
                use_my_pkg_id = my_pkg_id,
                custom_package_databases = None,
                version = version,
            ),
            for_plugin = True,
        ),
    )

    header_files = []
    boot_files = []
    source_files = set.empty()

    # Forward all "-D" and "-optP-D" flags to hsc2hs
    hsc_flags = []
    hsc_flags += ["--cflag=" + x for x in user_compile_flags if x.startswith("-D")]
    hsc_flags += ["--cflag=" + x[len("-optP"):] for x in user_compile_flags if x.startswith("-optP-D")]

    hsc_inputs = []
    if version:
        (version_macro_headers, version_macro_flags) = version_macro_includes(dep_info.hs_info)
        hsc_flags += ["--cflag=" + x for x in version_macro_flags]
        hsc_inputs += set.to_list(version_macro_headers)

    # Add import hierarchy root.
    # Note that this is not perfect, since GHC requires hs-boot files
    # to be in the same directory as the corresponding .hs file.  Thus
    # the two must both have the same root; i.e., both plain files,
    # both in bin_dir, or both in genfiles_dir.

    import_dirs = set.from_list([
        hs.src_root,
        paths.join(hs.bin_dir.path, hs.src_root),
        paths.join(hs.genfiles_dir.path, hs.src_root),
    ])

    for s in srcs:
        if s.extension == "h":
            header_files.append(s)
        elif s.extension == "hsc":
            s0, idir = _process_hsc_file(hs, cc, hsc_flags, hsc_inputs, s)
            set.mutable_insert(source_files, s0)
            set.mutable_insert(import_dirs, idir)
        elif s.extension in ["hs-boot", "lhs-boot"]:
            boot_files.append(s)
        else:
            set.mutable_insert(source_files, s)

        if s in import_dir_map:
            idir = import_dir_map[s]
            set.mutable_insert(import_dirs, idir)

    compile_flags += ["-i{0}".format(d) for d in set.to_list(import_dirs)]

    # Write the -optP flags to a parameter file because they can be very long on Windows
    # e.g. 27Kb for grpc-haskell
    # Equivalent to: compile_flags += ["-optP" + f for f in cc.cpp_flags]
    optp_args_file = hs.actions.declare_file("optp_args_%s" % hs.name)
    optp_args = hs.actions.args()
    optp_args.add_all(cc.cpp_flags)
    optp_args.set_param_file_format("multiline")
    hs.actions.write(optp_args_file, optp_args)
    compile_flags += ["-optP@" + optp_args_file.path]

    #compile_flags += cc.include_args

    locale_archive_depset = (
        depset([hs.toolchain.locale_archive]) if hs.toolchain.locale_archive != None else depset()
    )

    # This is absolutely required otherwise GHC doesn't know what package it's
    # creating `Name`s for to put them in Haddock interface files which then
    # results in Haddock not being able to find names for linking in
    # environment after reading its interface file later.
    if my_pkg_id != None:
        unit_id_args = [
            "-this-unit-id",
            pkg_id.to_string(my_pkg_id),
            "-optP-DCURRENT_PACKAGE_KEY=\"{}\"".format(pkg_id.to_string(my_pkg_id)),
        ]
        compile_flags += unit_id_args

    args = hs.actions.args()

    # Compilation mode.  Allow rule-supplied compiler flags to override it.
    if hs.mode == "opt":
        args.add("-O2")

    args.add("-static")
    if with_profiling:
        args.add("-prof", "-fexternal-interpreter")

    # Common flags
    args.add_all([
        "-v0",
        "-no-link",
        "-fPIC",
        "-fexternal-dynamic-refs",
        "-hide-all-packages",
        # Should never trigger in sandboxed builds, but can be useful
        # to debug issues in non-sandboxed builds.
        "-Wmissing-home-modules",
    ])

    # Output directories
    args.add_all([
        "-odir",
        objects_dir.path,
        "-hidir",
        interfaces_dir.path,
    ])

    # Interface files with profiling have to have the extension "p_hi":
    # https://downloads.haskell.org/~ghc/latest/docs/html/users_guide/packages.html#installedpackageinfo-a-package-specification
    # otherwise we won't be able to register them with ghc-pkg.
    if with_profiling:
        args.add_all([
            "-hisuf",
            "p_hi",
            "-osuf",
            "p_o",
        ])

    args.add_all(compile_flags)

    # Plugins
    for plugin in plugins:
        args.add("-fplugin={}".format(plugin[GhcPluginInfo].module))
        for opt in plugin[GhcPluginInfo].args:
            args.add_all(["-fplugin-opt", "{}:{}".format(plugin[GhcPluginInfo].module, opt)])

    plugin_tool_inputs = [plugin[GhcPluginInfo].tool_inputs for plugin in plugins]
    plugin_tool_input_manifests = [
        manifest
        for plugin in plugins
        for manifest in plugin[GhcPluginInfo].tool_input_manifests
    ]

    # Pass source files
    for f in set.to_list(source_files):
        args.add(f)

    extra_source_files = depset(
        direct = [cache_file],
        transitive = [
            extra_srcs,
            depset(header_files),
            depset(boot_files),
        ],
    )

    # GHC requries the Rts.h header to build the main function.
    args.add_all(
        hs.toolchain.libraries["rts"][HaskellImportHack].includes,
        format_each = "-optc-I%s",
    )

    return struct(
        args = args,
        compile_flags = compile_flags,
        inputs = depset(transitive = [
            # GHC requries the Rts.h header to build the main function.
            hs.toolchain.libraries["rts"][HaskellImportHack].headers,
            depset(hs.toolchain.hdrs),
            depset(ghci_extra_libs),
            depset(header_files),
            depset(boot_files),
            set.to_depset(source_files),
            extra_source_files,
            depset(cc.hdrs),
            dep_info.hs_info.package_databases,
            dep_info.hs_info.interface_dirs,
            dep_info.hs_info.static_libraries,
            dep_info.hs_info.dynamic_libraries,
            plugin_dep_info.hs_info.package_databases,
            plugin_dep_info.hs_info.interface_dirs,
            plugin_dep_info.hs_info.static_libraries,
            plugin_dep_info.hs_info.dynamic_libraries,
            java.inputs,
            locale_archive_depset,
            depset(transitive = plugin_tool_inputs),
            depset([optp_args_file]),
        ]),
        input_manifests = plugin_tool_input_manifests,
        objects_dir = objects_dir,
        interfaces_dir = interfaces_dir,
        outputs = [objects_dir, interfaces_dir],
        source_files = source_files,
        extra_source_files = depset(transitive = [extra_source_files, depset([optp_args_file])]),
        import_dirs = import_dirs,
        env = dicts.add(
            java.env,
            hs.env,
        ),
    )

def _hpc_compiler_args(hs):
    hpcdir = "{}/{}/.hpc".format(hs.bin_dir.path, hs.package_root)
    return ["-fhpc", "-hpcdir", hpcdir]

def _coverage_datum(mix_file, src_file, target_label):
    return struct(
        mix_file = mix_file,
        src_file = src_file,
        target_label = target_label,
    )

def compile_binary(
        hs,
        cc,
        java,
        dep_info,
        plugin_dep_info,
        srcs,
        ls_modules,
        import_dir_map,
        extra_srcs,
        user_compile_flags,
        dynamic,
        with_profiling,
        main_function,
        version,
        inspect_coverage = False,
        plugins = []):
    """Compile a Haskell target into object files suitable for linking.

    Returns:
      struct with the following fields:
        object_files: list of static object files
        object_dyn_files: list of dynamic object files
        modules: set of module names
        source_files: set of Haskell source files
    """
    c = _compilation_defaults(hs, cc, java, dep_info, plugin_dep_info, srcs, import_dir_map, extra_srcs, user_compile_flags, with_profiling, my_pkg_id = None, version = version, plugins = plugins)
    c.args.add_all(["-main-is", main_function])
    if dynamic:
        # For binaries, GHC creates .o files even for code to be
        # linked dynamically. So we have to force the object suffix to
        # be consistent with the dynamic object suffix in the library
        # case.
        c.args.add_all(["-dynamic", "-osuf dyn_o"])

    coverage_data = []
    if inspect_coverage:
        c.args.add_all(_hpc_compiler_args(hs))
        for src_file in srcs:
            module = module_name(hs, src_file)
            mix_file = hs.actions.declare_file(".hpc/{module}.mix".format(module = module))
            coverage_data.append(_coverage_datum(mix_file, src_file, hs.label))

    hs.toolchain.actions.run_ghc(
        hs,
        cc,
        inputs = c.inputs,
        input_manifests = c.input_manifests,
        outputs = c.outputs + [datum.mix_file for datum in coverage_data],
        mnemonic = "HaskellBuildBinary" + ("Prof" if with_profiling else ""),
        progress_message = "HaskellBuildBinary {}".format(hs.label),
        env = c.env,
        arguments = c.args,
    )

    return struct(
        objects_dir = c.objects_dir,
        source_files = c.source_files,
        extra_source_files = c.extra_source_files,
        import_dirs = c.import_dirs,
        compile_flags = c.compile_flags,
        coverage_data = coverage_data,
    )

def compile_library(
        hs,
        cc,
        java,
        dep_info,
        plugin_dep_info,
        srcs,
        import_dir_map,
        extra_srcs,
        user_compile_flags,
        with_shared,
        with_profiling,
        my_pkg_id,
        plugins = []):
    """Build arguments for Haskell package build.

    Returns:
      struct with the following fields:
        interfaces_dir: directory containing interface files
        interface_files: list of interface files
        object_files: list of static object files
        object_dyn_files: list of dynamic object files
        compile_flags: list of string arguments suitable for Haddock
        modules: set of module names
        source_files: set of Haskell module files
        import_dirs: import directories that should make all modules visible (for GHCi)
    """
    c = _compilation_defaults(hs, cc, java, dep_info, plugin_dep_info, srcs, import_dir_map, extra_srcs, user_compile_flags, with_profiling, my_pkg_id = my_pkg_id, version = my_pkg_id.version, plugins = plugins)
    if with_shared:
        c.args.add("-dynamic-too")

    coverage_data = []
    if hs.coverage_enabled:
        c.args.add_all(_hpc_compiler_args(hs))
        for src_file in srcs:
            pkg_id_string = pkg_id.to_string(my_pkg_id)
            module = module_name(hs, src_file)
            mix_file = hs.actions.declare_file(".hpc/{pkg}/{module}.mix".format(pkg = pkg_id_string, module = module))
            coverage_data.append(_coverage_datum(mix_file, src_file, hs.label))

    hs.toolchain.actions.run_ghc(
        hs,
        cc,
        inputs = c.inputs,
        input_manifests = c.input_manifests,
        outputs = c.outputs + [datum.mix_file for datum in coverage_data],
        mnemonic = "HaskellBuildLibrary" + ("Prof" if with_profiling else ""),
        progress_message = "HaskellBuildLibrary {}".format(hs.label),
        env = c.env,
        arguments = c.args,
    )

    return struct(
        interfaces_dir = c.interfaces_dir,
        objects_dir = c.objects_dir,
        compile_flags = c.compile_flags,
        source_files = c.source_files,
        extra_source_files = c.extra_source_files,
        import_dirs = c.import_dirs,
        coverage_data = coverage_data,
    )

def list_exposed_modules(
        hs,
        ls_modules,
        other_modules,
        exposed_modules_reexports,
        interfaces_dir,
        with_profiling):
    """Construct file listing the exposed modules of this package.

    Args:
      hs: The Haskell context.
      ls_modules: The ls_modules.py executable.
      other_modules: List of hidden modules.
      exposed_modules_reexports: List of re-exported modules.
      interfaces_dir: The directory containing the interface files.
      with_profiling: Whether we're building in profiling mode.

    Returns:
      File: File holding the package ceonfiguration exposed-modules value.
    """
    hidden_modules_file = hs.actions.declare_file(
        target_unique_name(hs, "hidden-modules"),
    )
    hs.actions.write(
        output = hidden_modules_file,
        content = ", ".join(other_modules),
    )
    reexported_modules_file = hs.actions.declare_file(
        target_unique_name(hs, "reexported-modules"),
    )
    hs.actions.write(
        output = reexported_modules_file,
        content = ", ".join(exposed_modules_reexports),
    )
    exposed_modules_file = hs.actions.declare_file(
        target_unique_name(hs, "exposed-modules"),
    )
    hs.actions.run(
        inputs = [
            interfaces_dir,
            hs.toolchain.global_pkg_db,
            hidden_modules_file,
            reexported_modules_file,
        ],
        outputs = [exposed_modules_file],
        executable = ls_modules,
        arguments = [
            str(with_profiling),
            interfaces_dir.path,
            hs.toolchain.global_pkg_db.path,
            hidden_modules_file.path,
            reexported_modules_file.path,
            exposed_modules_file.path,
        ],
        use_default_shell_env = True,
    )
    return exposed_modules_file
