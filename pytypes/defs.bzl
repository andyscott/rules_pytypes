""""""

load(
    "//pytypes/private:pytypes.bzl",
    _pytypes_aspect = "pytypes_aspect",
    _pytypes_config = "pytypes_config",
    _pytypes_test = "pytypes_test",
)

pytypes_config = _pytypes_config
pytypes_aspect = _pytypes_aspect
pytypes_test = _pytypes_test
