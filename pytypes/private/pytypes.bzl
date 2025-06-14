""""""

load("@aspect_rules_py//py/private:py_semantics.bzl", _py_semantics = "semantics")
load("@aspect_rules_py//py/private/toolchain:types.bzl", "PY_TOOLCHAIN")
load("@bazel_skylib//rules:common_settings.bzl", "BuildSettingInfo")
load("@rules_python//python:py_info.bzl", "PyInfo")

PytypesInfo = provider(
    doc = "General output from a pytypes run.",
    fields = {
        "output_file": "stdout",
        "status_file": "the status code",
    },
)

PytypesConfigInfo = provider(
    doc = "A config file for a Python type checker.",
    fields = {
        "config": "The config file.",
    },
)

_pytypes_tool_attrs = dict({
    "_pytypes_tool": attr.label(
        default = "@rules_pytypes//pytypes/private/tools/pytypes",
        cfg = "exec",
        executable = True,
    ),
    "_debug": attr.label(default = "@rules_pytypes//pytypes/private:debug"),
})

def _pytypes_tool_args(ctx):
    args = ctx.actions.args()
    args.use_param_file("@%s", use_always = False)
    if ctx.attr._debug[BuildSettingInfo].value:
        args.add("--debug")
    return args

def _pytypes_impl(target, ctx):
    if (
        PyInfo not in target or
        not hasattr(ctx.rule.files, "srcs")
    ):
        return []

    output_file = ctx.actions.declare_file(ctx.rule.attr.name + ".mypy.stdout")
    status_file = ctx.actions.declare_file(ctx.rule.attr.name + ".mypy.status")

    py_toolchain = _py_semantics.resolve_toolchain(ctx)
    venv_deps = getattr(ctx.rule.attr, "deps", []) + ctx.attr._mypy_deps

    mypy_config = None
    for data in getattr(ctx.rule.attr, "data", []):
        if PytypesConfigInfo in data:
            mypy_config = data[PytypesConfigInfo].config
            break

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
    args.add(target.label.package)
    args.add("--")
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

    output_files = depset([output_file, status_file])
    return [
        OutputGroupInfo(**{
            output_group: output_files
            for output_group in ctx.attr._output_groups.split(",")
        }),
        PytypesInfo(
            output_file = output_file,
            status_file = status_file,
        ),
    ]

pytypes_aspect = aspect(
    implementation = _pytypes_impl,
    attr_aspects = ["deps"],
    toolchains = [
        PY_TOOLCHAIN,
    ],
    attrs = _pytypes_tool_attrs | {
        "_mypy_deps": attr.label_list(
            default = ["@pip//mypy"],
            cfg = "exec",
        ),
        "_output_groups": attr.string(default = "_validation"),
    },
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

pytypes_test = rule(
    implementation = _pytypes_test_rule_impl,
    attrs = {
        "deps": attr.label_list(aspects = [pytypes_aspect]),
    },
    test = True,
)
