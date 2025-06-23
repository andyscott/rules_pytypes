""""""

load("@aspect_rules_py//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("@aspect_rules_py//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("@bazel_skylib//lib:paths.bzl", "paths")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_python//python:py_info.bzl", "PyInfo")

PytypesInfo = provider(
    doc = "General output from a pytypes run.",
    fields = {
        "output_file": "typing stdout/stderr",
        "status_file": "typing run status code",
        "marker_file": "marker for success",
    },
)

PytypesMetaInfo = provider(
    doc = "Meta output from a pytypes run.",
    fields = {
        "skip": "TODO",
    },
)

PytypesConfigInfo = provider(
    doc = "A config file for a Python type checker.",
    fields = {
        "config": "The config file.",
    },
)

PytypesTypeMappingsInfo = provider(
    doc = "Maps/adds extra deps",
    fields = {
        "type_mappings": "TODO",
    },
)

_pytypes_tool_attrs = dict({
    "_pytypes_tool": attr.label(
        default = "@rules_pytypes//pytypes/private/tools/pytypes",
        cfg = "exec",
        executable = True,
    ),
    "_debug": attr.label(default = "@rules_pytypes//pytypes/private:debug"),
    "_failure_mode": attr.label(default = "@rules_pytypes//pytypes:failure_mode"),
})

def _pytypes_tool_args(ctx):
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = False)
    if ctx.attr._debug[BuildSettingInfo].value:
        args.add("--debug")
    return args

def _direct_original_sources(_target, ctx):
    """
    Access PyInfo.direct_original_sources, or something similar.
    """

    # aspect_rules_py doesn't get populate the direct_original_sources field:
    # https://github.com/bazel-contrib/rules_python/commit/c8346f9cba12301092a6946fd317220179ba3bea

    # srcs = target[PyInfo].direct_original_sources
    # if srcs:
    #     return srcs

    srcs = getattr(ctx.rule.attr, "srcs", [])
    return depset(srcs) if srcs else depset()

def _expand_files(files):
    """
    Expands a files attribute to all actual files.

    Files attributes like "srcs" might depend on filegroups or generated source
    targets which come through as Target objects instead of File objects. So we
    expand the Targets to get the all of the Files.
    """

    files_set = set()
    for file in files.to_list():
        if type(file) == "File":
            files_set.add(file)
        elif DefaultInfo in file:
            if PytypesMetaInfo in file and file[PytypesMetaInfo].skip:
                continue
            for file in file[DefaultInfo].files.to_list():
                files_set.add(file)

    return files_set

def _pytypes_impl(target, ctx):
    # skip non python targets
    if PyInfo not in target:
        return []

    # # skip targets without source files
    srcs = _direct_original_sources(target, ctx)
    if not srcs:
        return []

    for tag in ctx.rule.attr.tags:
        # skip rules_python third party dep generated py_library targets
        if tag.startswith("pypi_name="):
            return []

        # skip targets tagged for skipping
        if tag == "pytypes:skip":
            return [
                PytypesMetaInfo(skip = True),
            ]

    output_file = ctx.actions.declare_file(ctx.rule.attr.name + ".mypy.output")
    status_file = ctx.actions.declare_file(ctx.rule.attr.name + ".mypy.status")

    py_toolchain = _py_semantics.resolve_toolchain(ctx)

    mypy_config = None
    for data in getattr(ctx.rule.attr, "data", []):
        if PytypesConfigInfo in data:
            mypy_config = data[PytypesConfigInfo].config
            break

    rule_deps = getattr(ctx.rule.attr, "deps", [])
    type_mappings = ctx.attr._type_mappings[PytypesTypeMappingsInfo].type_mappings
    type_stubs = []
    for dep in rule_deps:
        type_stub = type_mappings.get(dep.label, None)
        if type_stub:
            type_stubs.append(type_stub)

    venv_deps = rule_deps + ctx.attr._mypy_deps + type_stubs

    roots = set()
    for src in _expand_files(srcs):
        roots.add(src.root)

    args = _pytypes_tool_args(ctx)
    args.add("mypy")
    args.add("--python-bin", py_toolchain.python)
    args.add_all("--python-flags", py_toolchain.flags)
    args.add("--")
    args.add_all("--imports", depset(
        transitive = [
            dep[PyInfo].imports
            for dep in venv_deps
            if PyInfo in dep
        ],
    ))
    args.add("--mypy-args")
    if mypy_config:
        args.add("--config-file", mypy_config.path)
    args.add("--pretty")
    for root in roots:
        args.add(paths.join(root.path, target.label.package))
    args.add("--")
    args.add("--bin-dir", ctx.bin_dir.path)
    args.add("--output-file", output_file)
    args.add("--status-file", status_file)

    ctx.actions.run(
        mnemonic = "PytypesMypy",
        progress_message = "pytypes(mypy) %{label}",
        inputs = ctx.runfiles(files = [mypy_config] if mypy_config else []).merge_all(
            [
                target[DefaultInfo].default_runfiles,
            ] + [
                dep[DefaultInfo].default_runfiles
                for dep in venv_deps
            ],
        ).files,
        outputs = [output_file, status_file],
        executable = ctx.executable._pytypes_tool,
        tools = [
            py_toolchain.files,
        ],
        arguments = [args],
    )

    inputs = depset([output_file, status_file])
    marker_file = ctx.actions.declare_file(ctx.rule.attr.name + ".pytypes")

    args = _pytypes_tool_args(ctx)
    args.add("check")
    args.add("--failure-mode", ctx.attr._failure_mode[BuildSettingInfo].value)
    args.add("--marker-file", marker_file)
    args.add_all(inputs)

    ctx.actions.run(
        mnemonic = "PytypesPropagate",
        progress_message = "pytypes(output) %{label}",
        inputs = inputs,
        outputs = [marker_file],
        executable = ctx.executable._pytypes_tool,
        arguments = [args],
    )

    output_files = depset([output_file, status_file, marker_file])
    return [
        OutputGroupInfo(**{
            output_group: output_files
            for output_group in ctx.attr._output_groups.split(",")
        }),
        PytypesInfo(
            output_file = output_file,
            status_file = status_file,
            marker_file = marker_file,
        ),
    ]

def _pytypes_type_mappings_rule_impl(ctx):
    if len(ctx.attr.type_mappings_keys) != len(ctx.attr.type_mappings_values):
        fail("mismatched key/values for type_mappings")
    type_mappings = {}
    for i in range(len(ctx.attr.type_mappings_keys)):
        type_mappings[ctx.attr.type_mappings_keys[i].label] = ctx.attr.type_mappings_values[i]
    return [
        PytypesTypeMappingsInfo(
            type_mappings = type_mappings,
        ),
    ]

_pytypes_type_mappings_rule = rule(
    implementation = _pytypes_type_mappings_rule_impl,
    attrs = {
        "type_mappings_keys": attr.label_list(
            mandatory = True,
        ),
        "type_mappings_values": attr.label_list(
            mandatory = True,
        ),
    },
    # dependency_resolution_rule = True,
)

_FIXED_MAPPINGS = {
    "grpc_stubs": ["grpcio"],
    "sqlalchemy2_stubs": ["sqlalchemy"],
    "types_psycopg2": ["psycopg2", "psycopg2-binary"],
}

def pytypes_default_resolve_mapping(package):
    """
    Default mappings from type stubs to packages.
    """
    if package in _FIXED_MAPPINGS:
        return _FIXED_MAPPINGS[package]
    if package.startswith("types_"):
        return [package.removeprefix("types_")]
    if package.endswith("_stubs"):
        return [package.removesuffix("_stubs")]
    return None

def _warn(msg):
    print("{red}{msg}{nc}".format(red = "\033[0;31m", msg = msg, nc = "\033[0m"))

def pytypes_type_mappings(
        name,
        all_requirements):
    lookup = {}
    for r in all_requirements:
        r = Label(r)
        tp = pytypes_default_resolve_mapping(r.package)
        keys = tp or [r.package]
        for key in keys:
            o = lookup.get(key, {
                "types": [],
            })
            if tp:
                o["types"].append(r)
            else:
                o["package"] = r
            lookup[key] = o

    for o in lookup.values():
        if "package" not in o:
            _warn("unmatched type target(s) {}".format(", ".join([str(t) for t in o["types"]])))
        if len(o["types"]) > 1:
            _warn("too many types for {}: {}".format(str(o["package"]), ", ".join([str(t) for t in o["types"]])))

    type_mappings = {
        r["package"]: r["types"][0]
        for r in lookup.values()
        if "package" in r and r["types"]
    }

    _pytypes_type_mappings_rule(
        name = name,
        type_mappings_keys = type_mappings.keys(),
        type_mappings_values = type_mappings.values(),
    )

def _pytypes_config_impl(ctx):
    out_file = ctx.actions.declare_file(
        "{}.canonical/{}".format(ctx.attr.name, ctx.file.config.basename),
    )

    args = _pytypes_tool_args(ctx)
    args.add("canonicalize")
    args.add("--in-file", ctx.file.config)
    args.add("--out-file", out_file)

    ctx.actions.run(
        mnemonic = "PytypesCanonicalize",
        progress_message = "pytypes(canonicalize) %{label}",
        inputs = [ctx.file.config],
        outputs = [out_file],
        executable = ctx.executable._pytypes_tool,
        arguments = [args],
    )

    return [
        PytypesConfigInfo(config = out_file),
    ]

pytypes_config = rule(
    implementation = _pytypes_config_impl,
    attrs = _pytypes_tool_attrs | {
        "config": attr.label(
            doc = "The mypy configuration file.",
            allow_single_file = True,
            mandatory = True,
        ),
    },
)

def _pytypes_test_rule_impl(ctx):
    # TODO

    script = "\n".join(
        ["err=1"] +
        ["exit $err"],
    )

    ctx.actions.write(
        output = ctx.outputs.executable,
        content = script,
    )

    # return [DefaultInfo(files = depset(
    #     direct = [
    #         dep[PytypesInfo].output_file
    #         for dep in ctx.attr.deps
    #         if PytypesInfo in dep
    #     ],
    # ))]

    runfiles = ctx.runfiles(files = [])
    return [DefaultInfo(runfiles = runfiles)]

def make_pytypes_aspect(
        mypy_deps = None,
        type_mappings = None):
    return aspect(
        implementation = _pytypes_impl,
        attr_aspects = ["deps", "srcs"],
        toolchains = [
            PY_TOOLCHAIN,
        ],
        attrs = _pytypes_tool_attrs | {
            "_mypy_deps": attr.label_list(
                default = mypy_deps,
                cfg = "exec",
            ),
            "_output_groups": attr.string(default = "_validation"),
            # Note: would like to make this a dormant dep but it's not yet allowed
            # on aspects.
            #
            # With a dormant dep we could move type mapping/processing into the aspect
            # instead of doing macro shenanigans. It'd also be more efficient (well, lazy).
            "_type_mappings": attr.label(
                default = type_mappings,
                providers = [PytypesTypeMappingsInfo],
            ),
        },
    )

def make_pytypes_test(
        pytypes_aspect):
    return rule(
        implementation = _pytypes_test_rule_impl,
        attrs = {
            "deps": attr.label_list(aspects = [pytypes_aspect]),
        },
        test = True,
    )
