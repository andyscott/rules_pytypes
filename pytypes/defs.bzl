""""""

load(
    "//pytypes/private:pytypes.bzl",
    _make_pytypes_aspect = "make_pytypes_aspect",
    _make_pytypes_test = "make_pytypes_test",
    _pytypes_config = "pytypes_config",
    _pytypes_type_mappings = "pytypes_type_mappings",
)

make_pytypes_aspect = _make_pytypes_aspect
make_pytypes_test = _make_pytypes_test
pytypes_config = _pytypes_config
pytypes_type_mappings = _pytypes_type_mappings
